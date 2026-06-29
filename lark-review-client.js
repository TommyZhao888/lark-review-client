#!/usr/bin/env node
// lark-review-client — 团队成员在自己机器上跑的 review 客户端（单进程）。
//
// 做什么：
//   - 外连服务端 review-hub 的 WSS，用 token 注册身份（你的 Lark open_id + 名字 + 你配置的 repo）。
//   - 心跳 + 断线自动重连。hub 据此实时判定你是否在线。
//   - 收到派给你的 review_job → 在「你本机」按配置建/更新 git worktree → 跑「你自己的」claude
//     → 解析结论 → 回传给 hub（hub 负责回 Lark）。GitHub 上的 inline / general comment 由你本机
//     的 claude/gh 提交，用的是你自己的 Claude 账号。
//   - 收到 pr_closed 广播 → 删除对应 worktree；并定期自清理过期 worktree。
//
// 用法：
//   node lark-review-client.js [config.json]
//   或   LARK_REVIEW_CLIENT_CONFIG=/path/to/config.json node lark-review-client.js
//   默认配置路径： ~/.lark-review-client.json
//
// 依赖：本机已装并登录好 git、gh、claude（与原单机版要求一致）。

const fs = require('fs');
const os = require('os');
const http = require('http');
const path = require('path');
const { spawn } = require('child_process');
const WebSocket = require('ws');

// 客户端版本：升级功能时手动 +1（与 package.json 保持一致）。服务端据此判断是否提示升级。
const CLIENT_VERSION = '1.0.0';

// ---------- config ----------
const CONFIG_PATH = process.argv[2]
  || process.env.LARK_REVIEW_CLIENT_CONFIG
  || path.join(os.homedir(), '.lark-review-client.json');

// 容错读取: 文件不存在 / 非法 JSON 都不退出, 而是以空配置启动并把配置页拉起来,
// 让首次使用的人在网页里填(身份 open_id/name 由服务端按 token 下发, 不在本地配)。
function loadConfig() {
  let cfg = {};
  try {
    const raw = fs.readFileSync(CONFIG_PATH, 'utf-8');
    try { cfg = JSON.parse(raw); }
    catch (e) { logErr(`配置不是合法 JSON (${e.message}); 先以空配置启动, 请在配置页修复`); cfg = {}; }
  } catch { /* 文件不存在: 首次运行, 用空配置 + 配置页引导 */ }
  if (typeof cfg !== 'object' || !cfg) cfg = {};
  cfg.reviewModel = cfg.reviewModel || 'claude-opus-4-8';
  cfg.heartbeatMs = cfg.heartbeatMs || 15000;
  cfg.worktreeMaxAgeDays = cfg.worktreeMaxAgeDays || 14;
  cfg.claudePath = cfg.claudePath || 'claude';
  cfg.configPort = cfg.configPort || 8790;   // 本机配置页端口
  return cfg;
}

// 配置是否完整到可以连接服务端(否则只起配置页, 不连)。
function configReady(c) {
  return !!(c && c.serverUrl && c.token && c.repos
    && typeof c.repos === 'object' && Object.keys(c.repos).length);
}

function ts() { return new Date().toISOString(); }
function log(...a)    { console.log('[client]', ts(), ...a); }
function logErr(...a) { console.error('[client]', ts(), ...a); }
function fail(msg)    { console.error('[client] FATAL:', msg); process.exit(1); }

let cfg = loadConfig();
log(`config ${CONFIG_PATH} loaded, repos: ${Object.keys(cfg.repos || {}).join(', ') || '(无)'} (身份由服务端按 token 下发)`);

// ---------- 默认 review prompt 模板（与服务端原 worker.sh 一致）----------
// 可在配置里用 promptOverride 覆盖；支持占位符 {{PR_NUM}} {{WORKTREE_PATH}} {{CI_STATUS}}。
const DEFAULT_PROMPT_TEMPLATE = `Run /pr-review {{PR_NUM}} fully autonomously and submit the result yourself.

HARD REQUIREMENTS:
1. Do NOT wait for CI. Give your review verdict NOW, based purely on reading the code and local verification. Never poll, watch, or block on CI under any circumstance. CI status is context only -- you may mention a failing check in the General Comment, but it must never delay or replace your verdict. Current CI status: {{CI_STATUS}}.
2. Submit the review YOURSELF, without asking. The user has pre-approved all submissions -- post the inline comments, the General Comment, and the review verdict directly to GitHub. Do NOT ask for confirmation at any step.

The worktree already exists at {{WORKTREE_PATH}}; skip Step 0 (worktree creation) and Step 5 (worktree cleanup).

IMPORTANT: this is a one-shot headless run. The process terminates the moment you stop producing output, so NEVER suspend, schedule background monitors, or promise to continue later -- any such follow-up will never run.

After completing, output a single final line in this exact format:
___RESULT___ verdict=<APPROVE|COMMENT|REQUEST_CHANGES> general_comment_url=<url-or-NONE> inline_count=<integer>`;

function renderPrompt(prNum, worktreePath, ciStatus) {
  const tmpl = cfg.promptOverride || DEFAULT_PROMPT_TEMPLATE;
  return tmpl
    .replaceAll('{{PR_NUM}}', String(prNum))
    .replaceAll('{{WORKTREE_PATH}}', worktreePath)
    .replaceAll('{{CI_STATUS}}', ciStatus);
}

// ---------- 异步执行（不阻塞事件循环，保证 review 期间心跳/pong 正常）----------
function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { ...opts });
    let stdout = '', stderr = '';
    if (child.stdout) child.stdout.on('data', (d) => { stdout += d; });
    if (child.stderr) child.stderr.on('data', (d) => { stderr += d; });
    if (opts.stdin != null && child.stdin) { child.stdin.write(opts.stdin); child.stdin.end(); }
    child.on('error', (e) => resolve({ code: 127, stdout, stderr: stderr + e.message }));
    child.on('close', (code) => resolve({ code: code == null ? 1 : code, stdout, stderr }));
  });
}

// ---------- worktree 管理（复刻 worker.sh STAGE 6）----------
async function ensureWorktree(mainRepo, worktreeBase, prNum, branch) {
  const worktreePath = path.join(worktreeBase, `pr-${prNum}`);
  const env = { ...process.env, GIT_LFS_SKIP_SMUDGE: '1' };
  const exists = fs.existsSync(worktreePath);
  let r;
  if (exists) {
    log(`worktree exists, refreshing to origin/${branch}`);
    await run('git', ['-C', mainRepo, 'fetch', 'origin', branch], { env });
    r = await run('git', ['-C', worktreePath, 'reset', '--hard', `origin/${branch}`], { env });
    if (r.code === 0) await run('git', ['-C', worktreePath, 'clean', '-fd'], { env });
  } else {
    log(`creating worktree ${worktreePath}`);
    await run('git', ['-C', mainRepo, 'fetch', 'origin', branch], { env });
    r = await run('git', ['-C', mainRepo, 'worktree', 'add', worktreePath, branch], { env });
    if (r.code !== 0) {
      r = await run('git', ['-C', mainRepo, 'worktree', 'add', '--detach', worktreePath, `origin/${branch}`], { env });
    }
  }
  return { worktreePath, ok: r.code === 0, detail: (r.stdout || '') + (r.stderr || '') };
}

async function removeWorktree(mainRepo, worktreeBase, prNum) {
  const worktreePath = path.join(worktreeBase, `pr-${prNum}`);
  if (!fs.existsSync(worktreePath)) return;
  log(`removing worktree ${worktreePath}`);
  const r = await run('git', ['-C', mainRepo, 'worktree', 'remove', '--force', worktreePath]);
  if (r.code !== 0) { try { fs.rmSync(worktreePath, { recursive: true, force: true }); } catch {} }
  await run('git', ['-C', mainRepo, 'worktree', 'prune']);
}

// 定期清理超过 N 天没动过的 pr-* worktree。
async function pruneStaleWorktrees() {
  const cutoff = Date.now() - cfg.worktreeMaxAgeDays * 86400_000;
  for (const [repo, conf] of Object.entries(cfg.repos)) {
    let entries;
    try { entries = fs.readdirSync(conf.worktreeBase, { withFileTypes: true }); } catch { continue; }
    for (const ent of entries) {
      if (!ent.isDirectory() || !/^pr-\d+$/.test(ent.name)) continue;
      const p = path.join(conf.worktreeBase, ent.name);
      let st; try { st = fs.statSync(p); } catch { continue; }
      if (st.mtimeMs < cutoff) {
        log(`pruning stale worktree ${p} (repo ${repo})`);
        const r = await run('git', ['-C', conf.mainRepo, 'worktree', 'remove', '--force', p]);
        if (r.code !== 0) { try { fs.rmSync(p, { recursive: true, force: true }); } catch {} }
        await run('git', ['-C', conf.mainRepo, 'worktree', 'prune']);
      }
    }
  }
}

// ---------- review job 执行 ----------
const RESULT_RE = /___RESULT___ verdict=([A-Z_]+) general_comment_url=(\S+) inline_count=([0-9]+)/g;
function parseResult(logText) {
  let last = null, m;
  while ((m = RESULT_RE.exec(logText)) !== null) last = m;
  if (!last) return { result_line: '', verdict: '', general_comment_url: '', inline_count: '?' };
  return { result_line: last[0], verdict: last[1], general_comment_url: last[2], inline_count: last[3] };
}

async function runReviewJob(job) {
  const conf = cfg.repos[job.repo];
  // hub 已校验 repo，这里再防一手。
  if (!conf) return { exit_code: 1, log_tail: `本机未配置 repo ${job.repo}`, verdict: '', general_comment_url: '', inline_count: '?', result_line: '' };

  send({ type: 'review_progress', job_id: job.job_id, stage: 'worktree' });
  const wt = await ensureWorktree(conf.mainRepo, conf.worktreeBase, job.pr_num, job.branch);
  if (!wt.ok) {
    return { exit_code: 1, log_tail: `worktree 准备失败:\n${wt.detail}`.slice(-4000),
      verdict: '', general_comment_url: '', inline_count: '?', result_line: '' };
  }

  const ciStatus = job.ci_failed_names
    ? `${job.ci_overall}; failed checks: ${job.ci_failed_names}`
    : job.ci_overall;
  const prompt = renderPrompt(job.pr_num, wt.worktreePath, ciStatus);
  const model = job.review_model || cfg.reviewModel;

  send({ type: 'review_progress', job_id: job.job_id, stage: 'claude' });
  log(`running claude --print --model ${model} in ${wt.worktreePath}`);
  const r = await run(cfg.claudePath, [
    '--print', '--model', model, '--dangerously-skip-permissions',
    '--add-dir', conf.mainRepo, '--add-dir', conf.worktreeBase,
  ], { cwd: wt.worktreePath, stdin: prompt, env: { ...process.env, GIT_LFS_SKIP_SMUDGE: '1' } });

  const logText = (r.stdout || '') + (r.stderr || '');
  const parsed = parseResult(logText);
  log(`claude exited=${r.code} verdict=${parsed.verdict || '-'} inline=${parsed.inline_count}`);
  return {
    exit_code: r.code,
    log_tail: logText.slice(-8000),
    ...parsed,
  };
}

// 一次只跑一单，避免本机多个 claude 抢资源。
let busy = false;
const queue = [];
async function pump() {
  if (busy || !queue.length) return;
  busy = true;
  const job = queue.shift();
  let result;
  try { result = await runReviewJob(job); }
  catch (e) { result = { exit_code: 1, log_tail: `客户端异常: ${e.message}`, verdict: '', general_comment_url: '', inline_count: '?', result_line: '' }; }
  send({ type: 'review_result', job_id: job.job_id, ...result });
  busy = false;
  setImmediate(pump);
}

// ---------- WS 连接 ----------
let ws = null;
let hbTimer = null;
let reconnectDelay = 1000;
let connected = false, registered = false;
let identity = { open_id: null, name: null, recommended_version: null };

function send(obj) { try { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj)); } catch {} }

function connect() {
  log(`connecting ${cfg.serverUrl} …`);
  ws = new WebSocket(cfg.serverUrl);

  ws.on('open', () => {
    reconnectDelay = 1000;
    connected = true;
    // 不上报 open_id / name —— 由服务端按 token 解析并下发(防冒名)。
    send({
      type: 'register',
      token: cfg.token,
      hostname: os.hostname(),
      repos: Object.keys(cfg.repos),
      version: CLIENT_VERSION,
    });
    if (hbTimer) clearInterval(hbTimer);
    hbTimer = setInterval(() => send({ type: 'heartbeat' }), cfg.heartbeatMs);
  });

  ws.on('message', (data) => {
    let msg; try { msg = JSON.parse(data.toString()); } catch { return; }
    switch (msg.type) {
      case 'register_ack':
        registered = true;
        identity = { open_id: msg.open_id, name: msg.name, recommended_version: msg.recommended_version || null };
        log(`registered as ${msg.name} (${msg.open_id}) ✓  本机 v${CLIENT_VERSION}，服务端推荐 v${msg.recommended_version || '?'}`);
        if (msg.upgrade) {
          logErr('======================== 请升级客户端 ========================');
          logErr(`  当前 v${CLIENT_VERSION} → 推荐 v${msg.upgrade.recommended}` +
                 (msg.upgrade.below_min ? `（已低于最低要求 v${msg.upgrade.min}，可能不兼容）` : ''));
          if (msg.upgrade.message) logErr(`  升级方式：${msg.upgrade.message}`);
          logErr('=============================================================');
        }
        break;
      case 'register_reject':
        fail(`服务端拒绝注册: ${msg.reason}（检查 token / open_id）`);
        break;
      case 'review_job':
        log(`got review_job ${msg.job_id} pr=#${msg.pr_num} repo=${msg.repo} branch=${msg.branch}`);
        queue.push(msg);
        pump();
        break;
      case 'pr_closed':
        if (cfg.repos[msg.repo]) {
          const c = cfg.repos[msg.repo];
          removeWorktree(c.mainRepo, c.worktreeBase, msg.pr_num).catch((e) => logErr('removeWorktree:', e.message));
        }
        break;
      default:
        break;
    }
  });

  ws.on('close', () => {
    connected = false; registered = false;
    if (hbTimer) { clearInterval(hbTimer); hbTimer = null; }
    logErr(`disconnected; reconnecting in ${reconnectDelay}ms`);
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 30000);
  });

  ws.on('error', (e) => logErr('ws error:', e.message));
}

// ---------- 本机配置页(127.0.0.1, 编辑 ~/.lark-review-client.json)----------
const CONFIG_PAGE = path.join(__dirname, 'config-page.html');
// 运行日志路径(run-client.sh 会 export; launchd 走 StandardOutPath, 默认与之一致)。
const LOG_PATH = process.env.LARK_REVIEW_CLIENT_LOG || path.join(os.homedir(), '.lark-review-client.log');

// 读日志尾部(最多末 maxBytes 字节 / maxLines 行), 供配置页"日志"tab 展示。
function tailLog(maxBytes = 65536, maxLines = 500) {
  try {
    const st = fs.statSync(LOG_PATH);
    const start = Math.max(0, st.size - maxBytes);
    const fd = fs.openSync(LOG_PATH, 'r');
    const buf = Buffer.alloc(st.size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    fs.closeSync(fd);
    let lines = buf.toString('utf8').split('\n');
    if (start > 0 && lines.length) lines = lines.slice(1); // 丢弃可能被截断的首行
    return lines.slice(-maxLines).join('\n');
  } catch (e) {
    return `(暂无日志文件: ${LOG_PATH}\n${e.code || e.message}\n若是前台直接 node 运行, 日志在终端而非文件。)`;
  }
}

// 重启本进程。受 launchd/systemd 监管时直接退出(由其拉起); 否则自我 re-exec。
function doRestart() {
  if (process.env.LARK_REVIEW_CLIENT_SUPERVISED === '1') {
    log('restart: 退出, 由 launchd/systemd 自动拉起');
    setTimeout(() => process.exit(0), 300);
    return;
  }
  log('restart: 自我重启(re-exec)');
  try {
    const child = spawn(process.execPath, process.argv.slice(1), { detached: true, stdio: 'inherit', env: process.env });
    child.unref();
    const pidf = process.env.LARK_REVIEW_CLIENT_PID;
    if (pidf) { try { fs.writeFileSync(pidf, String(child.pid)); } catch { /* ignore */ } }
  } catch (e) { logErr('re-exec failed:', e.message); }
  setTimeout(() => process.exit(0), 500);
}

// 只写技术性字段; name / openId 归服务端下发, 永不写入本地配置。
function persistConfig(incoming) {
  let cur = {};
  try { cur = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf-8')); } catch { /* new */ }
  const next = {
    ...cur,
    serverUrl: String(incoming.serverUrl || '').trim(),
    token: String(incoming.token || '').trim(),
    claudePath: String(incoming.claudePath || 'claude').trim() || 'claude',
    reviewModel: String(incoming.reviewModel || 'claude-opus-4-8').trim() || 'claude-opus-4-8',
    worktreeMaxAgeDays: Number(incoming.worktreeMaxAgeDays) || 14,
    heartbeatMs: Number(incoming.heartbeatMs) || 15000,
    repos: incoming.repos && typeof incoming.repos === 'object' ? incoming.repos : {},
    // 提示词: 非空才覆盖, 空串/空白 → null(用内置默认模板)。
    promptOverride: (incoming.promptOverride && String(incoming.promptOverride).trim()) ? String(incoming.promptOverride) : null,
  };
  delete next.name; delete next.openId;   // 身份归服务端, 清掉历史遗留字段
  const tmp = CONFIG_PATH + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(next, null, 2) + '\n');
  fs.renameSync(tmp, CONFIG_PATH);
}

function reloadAndReconnect() {
  cfg = loadConfig();
  if (!configReady(cfg)) { log('配置仍不完整(缺 serverUrl/token/repos), 暂不连接'); return; }
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    log('config 已重载, 断开旧连接按新设置重连');
    try { ws.close(); } catch { /* close handler 会用新 cfg 重连 */ }
  } else {
    log('config 已就绪, 开始连接');
    connect();
  }
}

function startConfigServer() {
  const port = cfg.configPort || 8790;
  const srv = http.createServer((req, res) => {
    const u = (req.url || '').split('?')[0];
    const json = (code, o) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(o)); };
    if (req.method === 'GET' && u === '/') {
      try { res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); return res.end(fs.readFileSync(CONFIG_PAGE)); }
      catch { res.writeHead(500); return res.end('config page missing'); }
    }
    if (req.method === 'GET' && u === '/config') {
      return json(200, {
        serverUrl: cfg.serverUrl || '', token: cfg.token || '', claudePath: cfg.claudePath || 'claude',
        reviewModel: cfg.reviewModel || 'claude-opus-4-8', worktreeMaxAgeDays: cfg.worktreeMaxAgeDays || 14,
        heartbeatMs: cfg.heartbeatMs || 15000, repos: cfg.repos || {},
        promptOverride: cfg.promptOverride || '', defaultPrompt: DEFAULT_PROMPT_TEMPLATE,
      });
    }
    if (req.method === 'GET' && u === '/status') {
      return json(200, {
        client_version: CLIENT_VERSION, connected, registered,
        name: identity.name, open_id: identity.open_id, recommended_version: identity.recommended_version,
      });
    }
    if (req.method === 'POST' && u === '/config') {
      let b = ''; req.on('data', (c) => { b += c; });
      req.on('end', () => {
        let body; try { body = JSON.parse(b); } catch { return json(400, { ok: false, error: 'bad json' }); }
        if (!body.serverUrl || !body.token) return json(200, { ok: false, error: 'serverUrl 和 token 必填' });
        if (!body.repos || !Object.keys(body.repos).length) return json(200, { ok: false, error: '至少配一个 repo' });
        try { persistConfig(body); reloadAndReconnect(); return json(200, { ok: true }); }
        catch (e) { return json(200, { ok: false, error: e.message }); }
      });
      return;
    }
    if (req.method === 'GET' && u === '/logs') {
      return json(200, { path: LOG_PATH, log: tailLog() });
    }
    if (req.method === 'POST' && u === '/restart') {
      json(200, { ok: true });
      doRestart();
      return;
    }
    res.writeHead(404); res.end('not found');
  });
  // 端口被占(常见于自我重启时旧进程尚未释放)→ 1s 后重试, 最多若干次。
  srv.on('error', (e) => {
    if (e.code === 'EADDRINUSE') { logErr(`配置页端口 ${port} 占用, 1s 后重试…`); setTimeout(() => srv.listen(port, '127.0.0.1'), 1000); }
    else logErr('config server:', e.message);
  });
  srv.on('listening', () => log(`配置页: http://127.0.0.1:${port}`));
  srv.listen(port, '127.0.0.1');
}

startConfigServer();   // 配置页先起(无论是否已配置), 供首次填写 / 后续修改
if (configReady(cfg)) {
  connect();
} else {
  log(`尚未配置(缺 serverUrl/token/repos)。已仅启动配置页: http://127.0.0.1:${cfg.configPort} —— 填好保存即自动连接`);
}
setInterval(() => pruneStaleWorktrees().catch((e) => logErr('prune:', e.message)), 6 * 3600_000).unref();
pruneStaleWorktrees().catch(() => {});

process.on('SIGINT', () => { log('bye'); process.exit(0); });
process.on('SIGTERM', () => { log('bye'); process.exit(0); });

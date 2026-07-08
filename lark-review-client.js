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
const { spawn, execSync } = require('child_process');
const WebSocket = require('ws');

// 上报主机名: macOS 上 os.hostname() 常因网络反查返回 "bogon"(多台机器会撞名),
// 优先取用户在"系统设置"里设的稳定机器名 ComputerName, 取不到再回退 os.hostname()。
function detectHostname() {
  const h = os.hostname();
  if (process.platform === 'darwin' && (!h || h === 'bogon' || h === 'localhost')) {
    try {
      const n = execSync('scutil --get ComputerName', { encoding: 'utf8', timeout: 2000 }).trim();
      if (n) return n;
    } catch { /* 忽略, 回退 os.hostname() */ }
  }
  return h;
}

// 客户端版本：升级功能时手动 +1（与 package.json 保持一致）。服务端据此判断是否提示升级。
const CLIENT_VERSION = '1.3.0';

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
  if (!cfg.repos || typeof cfg.repos !== 'object') cfg.repos = {};   // repos 可为空: 先连上拿服务端清单再配
  cfg.reviewModel = cfg.reviewModel || 'claude-opus-4-8';
  cfg.heartbeatMs = cfg.heartbeatMs || 15000;
  cfg.worktreeMaxAgeDays = cfg.worktreeMaxAgeDays || 14;
  cfg.claudePath = cfg.claudePath || 'claude';
  cfg.configPort = cfg.configPort || 8790;   // 本机配置页端口
  return cfg;
}

// 配置是否完整到可以连接服务端(否则只起配置页, 不连)。
// repos 不再是硬性条件: 项目清单由服务端下发, 先连上才看得到可选项目——
// 没配 repo 也允许连接注册(只是不会被派单), 配置页据下发清单引导补齐。
function configReady(c) {
  return !!(c && c.serverUrl && c.token);
}

function ts() { return new Date().toISOString(); }
function log(...a)    { console.log('[client]', ts(), ...a); }
function logErr(...a) { console.error('[client]', ts(), ...a); }
function fail(msg)    { console.error('[client] FATAL:', msg); process.exit(1); }

let cfg = loadConfig();
log(`config ${CONFIG_PATH} loaded, repos: ${Object.keys(cfg.repos || {}).join(', ') || '(无)'} (身份由服务端按 token 下发)`);

// ---------- Mac 通知栏提醒(收到/执行中/完成/断连/重连); 非 macOS 或 cfg.notify=false 时跳过 ----------
function notify(title, message) {
  if (process.platform !== 'darwin' || cfg.notify === false) return;
  const esc = (s) => String(s == null ? '' : s).replace(/[\\"]/g, '\\$&').replace(/\n/g, ' ');
  const sound = cfg.notifySound ? ` sound name "${esc(cfg.notifySound)}"` : '';
  try {
    const c = spawn('osascript', ['-e', `display notification "${esc(message)}" with title "${esc(title)}"${sound}`], { stdio: 'ignore' });
    c.on('error', () => {}); c.unref();
  } catch { /* ignore */ }
}

// ---------- 每次 review 的完整 claude 输出, 存到本机 ----------
const REVIEW_LOG_DIR = process.env.LARK_REVIEW_CLIENT_REVIEW_LOG_DIR || path.join(os.homedir(), '.lark-review-client-logs');
try { fs.mkdirSync(REVIEW_LOG_DIR, { recursive: true }); } catch { /* ignore */ }

// 把一次 review 的完整输出(claude stdout+stderr)写入本机日志文件, 返回路径。
function writeReviewLog(job, code, parsed, logText) {
  try {
    const ts = new Date().toISOString().replace(/[:.]/g, '-');
    const file = path.join(REVIEW_LOG_DIR, `pr-${job.pr_num}-${ts}.log`);
    const header =
      `# PR #${job.pr_num}  repo=${job.repo}  branch=${job.branch}\n` +
      `# job=${job.job_id}  model=${job.review_model || cfg.reviewModel}  time=${new Date().toISOString()}\n` +
      `# exit=${code}  verdict=${parsed.verdict || '-'}  inline=${parsed.inline_count}  general_comment=${parsed.general_comment_url || '-'}\n` +
      `${'#'.repeat(64)}\n\n`;
    fs.writeFileSync(file, header + (logText || ''));
    return file;
  } catch (e) { logErr('writeReviewLog:', e.message); return null; }
}

// 清理超过 worktreeMaxAgeDays 天的 review 日志, 避免无限增长。
function pruneReviewLogs() {
  const cutoff = Date.now() - (cfg.worktreeMaxAgeDays || 14) * 86400_000;
  let ents; try { ents = fs.readdirSync(REVIEW_LOG_DIR); } catch { return; }
  for (const n of ents) {
    if (!/^pr-.*\.log$/.test(n)) continue;
    const p = path.join(REVIEW_LOG_DIR, n);
    try { if (fs.statSync(p).mtimeMs < cutoff) fs.unlinkSync(p); } catch { /* ignore */ }
  }
}

// ---------- 默认 review prompt 模板（与服务端原 worker.sh 一致）----------
// 可按项目用 repos[].prompt 覆盖；支持占位符 {{PR_NUM}} {{WORKTREE_PATH}} {{CI_STATUS}}。
const DEFAULT_PROMPT_TEMPLATE = `Run /pr-review {{PR_NUM}} fully autonomously and submit the result yourself.

HARD REQUIREMENTS:
1. Do NOT wait for CI. Give your review verdict NOW, based purely on reading the code and local verification. Never poll, watch, or block on CI under any circumstance. CI status is context only -- you may mention a failing check in the General Comment, but it must never delay or replace your verdict. Current CI status: {{CI_STATUS}}.
2. Submit the review YOURSELF, without asking. The user has pre-approved all submissions -- post the inline comments, the General Comment, and the review verdict directly to GitHub. Do NOT ask for confirmation at any step.

The worktree already exists at {{WORKTREE_PATH}}; skip Step 0 (worktree creation) and Step 5 (worktree cleanup).

IMPORTANT: this is a one-shot headless run. The process terminates the moment you stop producing output, so NEVER suspend, schedule background monitors, or promise to continue later -- any such follow-up will never run.

After completing, output a single final line in this exact format:
___RESULT___ verdict=<APPROVE|COMMENT|REQUEST_CHANGES> general_comment_url=<url-or-NONE> inline_count=<integer>`;

// Azure DevOps repo 的内置默认模板: 跑 /pr-review-azdo(需成员机器装好该 claude 命令,
// 见 docs/pr-review-azdo.md), 评论/投票提交到 ADO, 结果行契约与 GitHub 完全一致。
const DEFAULT_PROMPT_TEMPLATE_AZDO = `Run /pr-review-azdo {{PR_NUM}} fully autonomously and submit the result yourself.

The pull request lives on Azure DevOps: {{PR_URL}} (repo {{REPO}}).

HARD REQUIREMENTS:
1. Do NOT wait for CI. Give your review verdict NOW, based purely on reading the code and local verification. Never poll, watch, or block on CI under any circumstance. CI status is context only -- you may mention a failing check in the General Comment, but it must never delay or replace your verdict. Current CI status: {{CI_STATUS}}.
2. Submit the review YOURSELF, without asking. The user has pre-approved all submissions -- post the inline comment threads, the General Comment thread, and set your vote directly on the Azure DevOps pull request. Do NOT ask for confirmation at any step.

The worktree already exists at {{WORKTREE_PATH}}; skip worktree creation and cleanup steps.

IMPORTANT: this is a one-shot headless run. The process terminates the moment you stop producing output, so NEVER suspend, schedule background monitors, or promise to continue later -- any such follow-up will never run.

After completing, output a single final line in this exact format:
___RESULT___ verdict=<APPROVE|COMMENT|REQUEST_CHANGES> general_comment_url=<url-or-NONE> inline_count=<integer>`;

function renderPrompt(job, worktreePath, ciStatus, repoTmpl) {
  // 提示词按 client 各自按项目配置。优先级: 该项目的本机提示词(repos[].prompt) >
  // 服务端该 repo 默认(review_job.prompt_template 下发) > 按 provider 选内置默认模板。
  const builtin = job.provider === 'azdo' ? DEFAULT_PROMPT_TEMPLATE_AZDO : DEFAULT_PROMPT_TEMPLATE;
  const tmpl = (repoTmpl && String(repoTmpl).trim())
    ? repoTmpl
    : (job.prompt_template || builtin);
  return tmpl
    .replaceAll('{{PR_NUM}}', String(job.pr_num))
    .replaceAll('{{WORKTREE_PATH}}', worktreePath)
    .replaceAll('{{CI_STATUS}}', ciStatus)
    .replaceAll('{{PR_URL}}', String(job.pr_url || ''))
    .replaceAll('{{REPO}}', String(job.repo || ''));
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
async function ensureWorktree(mainRepo, worktreeBase, prNum, branch, provider) {
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
  // Azure DevOps 兜底: 按源分支名 fetch 失败(分支名带特殊字符/权限差异)时,
  // 改用 ADO 发布的 PR 合并引用 refs/pull/<id>/merge(等价 GitHub 的 pull/N/merge)。
  if (r.code !== 0 && provider === 'azdo') {
    log(`azdo fallback: fetch refs/pull/${prNum}/merge`);
    const f = await run('git', ['-C', mainRepo, 'fetch', 'origin', `refs/pull/${prNum}/merge`], { env });
    if (f.code === 0) {
      if (fs.existsSync(worktreePath)) {
        r = await run('git', ['-C', worktreePath, 'reset', '--hard', 'FETCH_HEAD'], { env });
        if (r.code === 0) await run('git', ['-C', worktreePath, 'clean', '-fd'], { env });
      } else {
        r = await run('git', ['-C', mainRepo, 'worktree', 'add', '--detach', worktreePath, 'FETCH_HEAD'], { env });
      }
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
  const wt = await ensureWorktree(conf.mainRepo, conf.worktreeBase, job.pr_num, job.branch, job.provider);
  if (!wt.ok) {
    return { exit_code: 1, log_tail: `worktree 准备失败:\n${wt.detail}`.slice(-4000),
      verdict: '', general_comment_url: '', inline_count: '?', result_line: '' };
  }

  const ciStatus = job.ci_failed_names
    ? `${job.ci_overall}; failed checks: ${job.ci_failed_names}`
    : job.ci_overall;
  const prompt = renderPrompt(job, wt.worktreePath, ciStatus, conf.prompt);
  const model = job.review_model || cfg.reviewModel;

  if (runningJob && runningJob.job_id === job.job_id) runningJob.stage = 'claude';
  send({ type: 'review_progress', job_id: job.job_id, stage: 'claude' });
  log(`running claude --print --model ${model} in ${wt.worktreePath}`);
  const r = await run(cfg.claudePath, [
    '--print', '--model', model, '--dangerously-skip-permissions',
    '--add-dir', conf.mainRepo, '--add-dir', conf.worktreeBase,
  ], { cwd: wt.worktreePath, stdin: prompt, env: { ...process.env, GIT_LFS_SKIP_SMUDGE: '1' } });

  const logText = (r.stdout || '') + (r.stderr || '');
  const parsed = parseResult(logText);
  log(`claude exited=${r.code} verdict=${parsed.verdict || '-'} inline=${parsed.inline_count}`);
  const savedLog = writeReviewLog(job, r.code, parsed, logText);
  if (savedLog) log(`review 完整日志已存: ${savedLog}`);
  return {
    exit_code: r.code,
    log_tail: logText.slice(-8000),
    ...parsed,
  };
}

// 一次只跑一单，避免本机多个 claude 抢资源。
let busy = false;
const queue = [];
let runningJob = null;                 // 当前执行中的 job(供 /status 菜单栏 + 重连上下文)
// 注: 重复派单的防护放在服务端(hub 掉线时保留在途 job + 派单去重), client 不做去重 ——
// client 信息太少易误拦(如合法的"再来一轮")。client 只负责: 重连 + 把真实结果发回。
async function pump() {
  if (busy || !queue.length) return;
  busy = true;
  const job = queue.shift();
  runningJob = { repo: job.repo, pr_num: job.pr_num, job_id: job.job_id, branch: job.branch, stage: 'worktree', since: Date.now() };
  notify(`⚡ 正在 Review PR #${job.pr_num}`, `${job.repo} · ${job.branch || ''} · 用你的账号在本机自动执行`);
  let result;
  try { result = await runReviewJob(job); }
  catch (e) { result = { exit_code: 1, log_tail: `客户端异常: ${e.message}`, verdict: '', general_comment_url: '', inline_count: '?', result_line: '' }; }
  // 结果照常发回 hub —— 即使中途断线, 重连后这条也会被 hub 接受(hub 掉线时保留了该 job)。
  send({ type: 'review_result', job_id: job.job_id, ...result });
  if (result.exit_code === 0 && result.verdict) notify(`✅ Review 完成 PR #${job.pr_num}`, `结论 ${result.verdict} · inline ${result.inline_count} · 已用你的账号提交`);
  else notify(`❌ Review 未完成 PR #${job.pr_num}`, `exit=${result.exit_code} ${(result.log_tail || '').slice(0, 80)}`);
  runningJob = null;
  busy = false;
  setImmediate(pump);
}

// ---------- WS 连接 ----------
let ws = null;
let hbTimer = null;
let reconnectDelay = 1000;
let connected = false, registered = false;
let everRegistered = false;   // 曾成功注册过 → 之后的断开算"重连", 用于通知/回 Lark
let pendingReconnect = false; // 断开后置真, 下次 register_ack 时视为重连(发通知 + 通知 hub)
let halted = false;   // 注册被拒(bad_token 等)时置真: 暂停自动重连, 但保活配置页供改 token
let identity = { open_id: null, name: null, recommended_version: null };
// 服务端受管 repo 清单 [{repo, prompt}], register_ack / repos_updated 下发。
// 配置页据此列出可参与的项目(用户只填本机路径), 不再手打 owner/repo。
let managedRepos = [];

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
      hostname: detectHostname(),
      repos: Object.keys(cfg.repos),
      version: CLIENT_VERSION,
    });
    if (hbTimer) clearInterval(hbTimer);
    hbTimer = setInterval(() => send({ type: 'heartbeat' }), cfg.heartbeatMs);
  });

  ws.on('message', (data) => {
    let msg; try { msg = JSON.parse(data.toString()); } catch { return; }
    switch (msg.type) {
      case 'register_ack': {
        registered = true;
        halted = false;
        // 重连成功: 弹本机通知 + 通知 hub(由 hub 回一条 Lark "已重新连接"消息)。
        if (pendingReconnect) {
          pendingReconnect = false;
          const midJob = busy && runningJob ? ` (PR #${runningJob.pr_num} 仍在本机继续)` : '';
          notify('🔁 已重新连接 hub', (busy ? 'Review 仍在继续' : '待命中') + midJob);
          send({ type: 'reconnected', was_busy: busy, repo: runningJob ? runningJob.repo : '', pr_num: runningJob ? runningJob.pr_num : '' });
        }
        everRegistered = true;
        identity = { open_id: msg.open_id, name: msg.name, recommended_version: msg.recommended_version || null, upgrade: msg.upgrade || null };
        if (Array.isArray(msg.managed_repos)) managedRepos = msg.managed_repos;
        log(`registered as ${msg.name} (${msg.open_id}) ✓  本机 v${CLIENT_VERSION}，服务端推荐 v${msg.recommended_version || '?'}`);
        // 对照服务端清单提示配置缺口: 本地多配的(不会被派单)、本地一个没配的。
        const managedNames = new Set(managedRepos.map((r) => r.repo));
        const extras = Object.keys(cfg.repos).filter((r) => managedNames.size && !managedNames.has(r));
        if (extras.length) logErr(`本地配置的 repo 不在服务端受管清单里(不会被派单): ${extras.join(', ')}`);
        if (!Object.keys(cfg.repos).length) {
          log(`尚未配置任何项目 —— 打开配置页 http://127.0.0.1:${cfg.configPort} 从服务端清单里选择并填本机路径`);
        }
        if (msg.upgrade) {
          logErr('======================== 请升级客户端 ========================');
          logErr(`  当前 v${CLIENT_VERSION} → 推荐 v${msg.upgrade.recommended}` +
                 (msg.upgrade.below_min ? `（已低于最低要求 v${msg.upgrade.min}，可能不兼容）` : ''));
          if (msg.upgrade.message) logErr(`  升级方式：${msg.upgrade.message}`);
          logErr(`  打开配置页一键更新: http://127.0.0.1:${cfg.configPort || 8790}/`);
          logErr('=============================================================');
          notify(`🆙 有新版本 v${msg.upgrade.recommended}`, `当前 v${CLIENT_VERSION}，打开配置页点「一键更新」`);
        }
        break;
      }
      case 'repos_updated':
        // 管理员在 hub 改了 Repo 规则 → 即时更新本地清单, 配置页刷新即可看到。
        if (Array.isArray(msg.managed_repos)) {
          managedRepos = msg.managed_repos;
          log(`服务端受管 repo 清单已更新: [${managedRepos.map((r) => r.repo).join(', ')}]`);
        }
        break;
      case 'register_reject': {
        // 不再 process.exit —— 那会连配置页一起杀掉, 用户就没法改 token 了(鸡生蛋)。
        // 改为: 停止自动重连 + 保活配置页, 引导用户去配置页改 token。
        halted = true;
        registered = false;
        const _cp = cfg.configPort || 8790;
        logErr('======================== 注册被拒 ========================');
        logErr(`  服务端拒绝注册: ${msg.reason}(token / open_id 不对)`);
        logErr('  已【暂停自动重连】, 但客户端仍在运行 —— 请打开配置页改 token:');
        logErr(`    http://127.0.0.1:${_cp}/`);
        logErr('  在页面填入新 token 保存(会自动按新配置重连)即可。');
        logErr('=========================================================');
        if (hbTimer) { clearInterval(hbTimer); hbTimer = null; }
        try { ws.close(); } catch { /* ignore */ }
        break;
      }
      case 'review_job': {
        log(`got review_job ${msg.job_id} pr=#${msg.pr_num} repo=${msg.repo} branch=${msg.branch}${msg.provider === 'azdo' ? ' provider=azdo' : ''}`);
        notify(`🟡 收到 Review PR #${msg.pr_num}`, `${msg.repo} · ${msg.branch || ''}`);
        queue.push(msg);
        pump();
        break;
      }
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
    if (halted) {
      logErr(`已暂停自动重连(等待改 token)。配置页: http://127.0.0.1:${cfg.configPort || 8790}/`);
      return;
    }
    // 曾注册过才算"掉线重连"(首次连不上不弹)。置 pendingReconnect, 重连成功后回 Lark。
    if (everRegistered && !pendingReconnect) {
      pendingReconnect = true;
      notify('⚠️ 与 hub 断开', '正在自动重连…' + (busy && runningJob ? ` (PR #${runningJob.pr_num} 仍在本机继续)` : ''));
    }
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

// repos 入库前收敛字段: {mainRepo, worktreeBase, prompt?}; prompt 空白则不落盘。
function sanitizeRepos(repos) {
  const out = {};
  if (!repos || typeof repos !== 'object') return out;
  for (const [name, rc] of Object.entries(repos)) {
    if (!rc || typeof rc !== 'object') continue;
    const e = { mainRepo: String(rc.mainRepo || '').trim(), worktreeBase: String(rc.worktreeBase || '').trim() };
    if (rc.prompt && String(rc.prompt).trim()) e.prompt = String(rc.prompt);
    out[name] = e;
  }
  return out;
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
    repos: sanitizeRepos(incoming.repos),
  };
  delete next.name; delete next.openId;          // 身份归服务端, 清掉历史遗留字段
  delete next.promptOverride;                    // 全局提示词已废弃: 提示词按项目配 repos[].prompt
  const tmp = CONFIG_PATH + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(next, null, 2) + '\n');
  fs.renameSync(tmp, CONFIG_PATH);
}

function reloadAndReconnect() {
  halted = false;   // 用户在配置页重新配置 → 解除暂停, 恢复正常(重连/后续断线自动重连)
  cfg = loadConfig();
  if (!configReady(cfg)) { log('配置仍不完整(缺 serverUrl/token), 暂不连接'); return; }
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    log('config 已重载, 断开旧连接按新设置重连');
    try { ws.close(); } catch { /* close handler 会用新 cfg 重连 */ }
  } else {
    log('config 已就绪, 开始连接');
    connect();
  }
}

// ---------- 客户端自更新(从 lark-review-client 仓库 git pull + 重启; 失败给手动步骤) ----------
const CLIENT_DIR = __dirname;
const UPDATE_REPO_URL = 'https://github.com/TommyZhao888/lark-review-client';
function manualUpdateSteps() {
  return [
    `cd "${CLIENT_DIR}"`,
    `git pull            # 若不是 git 克隆: 从 ${UPDATE_REPO_URL} 下载最新, 覆盖本目录文件`,
    'npm install --omit=dev',
    './run-client.sh restart    # 或重启客户端进程',
  ];
}
async function selfUpdate() {
  const chk = await run('git', ['-C', CLIENT_DIR, 'rev-parse', '--is-inside-work-tree']);
  if (chk.code !== 0 || String(chk.stdout).trim() !== 'true') {
    return { ok: false, manual: true, reason: 'not_git', detail: `客户端目录不是 git 仓库(${CLIENT_DIR})，无法自动更新。`, steps: manualUpdateSteps() };
  }
  const before = (await run('git', ['-C', CLIENT_DIR, 'rev-parse', 'HEAD'])).stdout.trim();
  const pull = await run('git', ['-C', CLIENT_DIR, 'pull', '--ff-only']);
  if (pull.code !== 0) {
    return { ok: false, manual: true, reason: 'pull_failed', detail: (pull.stdout + pull.stderr).trim().slice(-600), steps: manualUpdateSteps() };
  }
  const after = (await run('git', ['-C', CLIENT_DIR, 'rev-parse', 'HEAD'])).stdout.trim();
  if (before === after) return { ok: true, changed: false, message: '已是最新版本，无需更新。' };
  log(`self-update: ${before.slice(0, 7)} → ${after.slice(0, 7)}，npm install + 重启`);
  const npm = await run('npm', ['install', '--omit=dev'], { cwd: CLIENT_DIR });   // 依赖可能变; best-effort
  notify('🆙 客户端已更新', `${before.slice(0, 7)} → ${after.slice(0, 7)}，正在重启…`);
  setTimeout(doRestart, 800);   // 先把响应回给页面, 再重启
  return { ok: true, changed: true, before: before.slice(0, 7), after: after.slice(0, 7), npm_ok: npm.code === 0, message: '更新成功，正在重启客户端(几秒后自动重连)…' };
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
        defaultPrompt: DEFAULT_PROMPT_TEMPLATE,           // 供配置页「填入内置默认以编辑」(GitHub)
        defaultPromptAzdo: DEFAULT_PROMPT_TEMPLATE_AZDO,  // 同上(Azure DevOps 项目用)
        // 服务端受管 repo 清单(register_ack/repos_updated 下发): 配置页据此渲染项目列表。
        managedRepos,
      });
    }
    if (req.method === 'GET' && u === '/status') {
      return json(200, {
        client_version: CLIENT_VERSION, connected, registered,
        name: identity.name, open_id: identity.open_id, recommended_version: identity.recommended_version,
        outdated: !!identity.upgrade, upgrade: identity.upgrade || null,   // 有新版本时供配置页显示更新提示/按钮
        managed_repo_count: managedRepos.length,   // 配置页据此感知清单何时到位, 自动补渲染
        // 执行中/排队的 Review 任务(供菜单栏插件 lionreview 显示; 无防护/审计)。
        running: runningJob ? [{ repo: runningJob.repo, pr_num: runningJob.pr_num, branch: runningJob.branch, stage: runningJob.stage, since: runningJob.since }] : [],
        queued: queue.map((j) => ({ repo: j.repo, pr_num: j.pr_num })),
      });
    }
    if (req.method === 'POST' && u === '/config') {
      let b = ''; req.on('data', (c) => { b += c; });
      req.on('end', () => {
        let body; try { body = JSON.parse(b); } catch { return json(400, { ok: false, error: 'bad json' }); }
        if (!body.serverUrl || !body.token) return json(200, { ok: false, error: 'serverUrl 和 token 必填' });
        // repos 允许为空(先连上拿服务端清单再配), 但配了的必须两个路径齐全。
        for (const [name, rc] of Object.entries(body.repos || {})) {
          if (!rc || !String(rc.mainRepo || '').trim() || !String(rc.worktreeBase || '').trim()) {
            return json(200, { ok: false, error: `项目 ${name} 的 mainRepo / worktreeBase 都必须填` });
          }
        }
        try { persistConfig(body); reloadAndReconnect(); return json(200, { ok: true }); }
        catch (e) { return json(200, { ok: false, error: e.message }); }
      });
      return;
    }
    if (req.method === 'GET' && u === '/logs') {
      return json(200, { path: LOG_PATH, log: tailLog() });
    }
    if (req.method === 'GET' && u === '/review-logs') {
      let logs = [];
      try {
        logs = fs.readdirSync(REVIEW_LOG_DIR)
          .filter((n) => /^pr-.*\.log$/.test(n))
          .map((n) => ({ file: n, mtime: fs.statSync(path.join(REVIEW_LOG_DIR, n)).mtimeMs }))
          .sort((a, b) => b.mtime - a.mtime).slice(0, 50);
      } catch { /* dir 可能还不存在 */ }
      return json(200, { dir: REVIEW_LOG_DIR, logs });
    }
    if (req.method === 'GET' && u === '/review-log') {
      const f = (new URL(req.url, 'http://x').searchParams.get('file')) || '';
      if (!/^pr-[^/]+\.log$/.test(f)) return json(400, { error: 'bad file' });
      try { return json(200, { file: f, log: fs.readFileSync(path.join(REVIEW_LOG_DIR, f), 'utf8').slice(-200000) }); }
      catch (e) { return json(200, { file: f, log: '读取失败: ' + e.message }); }
    }
    if (req.method === 'POST' && u === '/restart') {
      json(200, { ok: true });
      doRestart();
      return;
    }
    if (req.method === 'POST' && u === '/self-update') {
      selfUpdate().then((r) => json(200, r))
        .catch((e) => json(200, { ok: false, manual: true, reason: 'error', detail: e.message, steps: manualUpdateSteps() }));
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
  log(`尚未配置(缺 serverUrl/token)。已仅启动配置页: http://127.0.0.1:${cfg.configPort} —— 填好保存即自动连接; 项目清单会在连上后由服务端下发`);
}
setInterval(() => { pruneStaleWorktrees().catch((e) => logErr('prune:', e.message)); pruneReviewLogs(); }, 6 * 3600_000).unref();
pruneStaleWorktrees().catch(() => {});
pruneReviewLogs();

process.on('SIGINT', () => { log('bye'); process.exit(0); });
process.on('SIGTERM', () => { log('bye'); process.exit(0); });

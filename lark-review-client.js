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
const CLIENT_VERSION = '1.7.0';

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
  // ---- 自动参与 + 自动 clone ----
  // autoRepos(默认开): 服务端下发的受管项目即使本机没配路径, 也自动参与(注册进 repos 列表);
  // 首个派到的 job 会按 repoBaseDir 自动 clone。显式设 false = 只参与本机 repos 里配置的项目(旧行为)。
  cfg.autoRepos = cfg.autoRepos !== false;
  // 默认克隆根目录: 未单独配置路径的项目 clone 到 <repoBaseDir>/<owner-repo>(配置页可改)。
  cfg.repoBaseDir = (cfg.repoBaseDir && String(cfg.repoBaseDir).trim()) || path.join(os.homedir(), 'LarkReviewRepos');
  // 全局 review 提示词: 对所有项目生效(单项目 repos[].prompt 优先)。留空 = 服务端该 repo 默认 > 内置模板。
  cfg.globalPrompt = (typeof cfg.globalPrompt === 'string') ? cfg.globalPrompt : '';
  cfg.reviewModel = cfg.reviewModel || 'claude-opus-4-8';
  cfg.heartbeatMs = cfg.heartbeatMs || 15000;
  cfg.worktreeMaxAgeDays = cfg.worktreeMaxAgeDays || 14;
  cfg.claudePath = cfg.claudePath || 'claude';
  cfg.configPort = cfg.configPort || 8790;   // 本机配置页端口
  // ---- Claude 额度(quota)相关 ----
  // 前瞻式: 读一个由 statusline 写的 rate_limits 快照(claude-hud 或本仓库 statusline-quota.sh)。
  // headless(--print)不触发 statusline, 故快照仅在本机【交互使用 Claude】时刷新; 限额是账号级的,
  // 交互产生的快照同样反映 headless review 的消耗。快照过期/缺失 → 退回反应式(命中限额才知道)。
  // 默认指向标准快照路径(自动启用前瞻式): 快照不存在/过期时读到 null → 上报无百分比(hub 显示 —),
  // 有 statusline 写入后自动出现百分比。显式设为 "" 可关闭前瞻式(仅留反应式)。
  cfg.quotaSnapshotPath = (cfg.quotaSnapshotPath != null) ? cfg.quotaSnapshotPath : path.join(os.homedir(), '.claude', 'lark-quota.json');
  cfg.quotaFiveHourThreshold = cfg.quotaFiveHourThreshold || 90;       // 5 小时窗已用 >= 此% 视为额度不足
  cfg.quotaSevenDayThreshold = cfg.quotaSevenDayThreshold || 95;       // 7 天窗已用 >= 此% 视为额度不足
  cfg.quotaSnapshotFreshnessMs = cfg.quotaSnapshotFreshnessMs || 900000; // 快照超过 15min 未更新视为过期(不采信)
  cfg.autoStatusline = cfg.autoStatusline !== false;                   // 自动把额度快照脚本配成 Claude statusLine(仅当你没配过 statusLine); false 关闭
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
log(`config ${CONFIG_PATH} loaded, repos: ${Object.keys(cfg.repos || {}).join(', ') || '(无)'}${cfg.autoRepos ? ' + 自动参与服务端受管项目' : ''} (身份由服务端按 token 下发)`);

// ==================== 项目路径解析 + 自动 clone ====================
// 服务端受管清单本地缓存: 重启/重连后首次 register 就能带上完整的自动参与列表
// (清单本体仍以 register_ack / repos_updated 下发为准, 收到即覆盖缓存)。
const MANAGED_CACHE = CONFIG_PATH + '.managed-cache.json';
function loadManagedCache() {
  try {
    const j = JSON.parse(fs.readFileSync(MANAGED_CACHE, 'utf8'));
    return Array.isArray(j) ? j.filter((r) => r && r.repo) : [];
  } catch { return []; }
}
function saveManagedCache(list) {
  try {
    const tmp = MANAGED_CACHE + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(list || [], null, 2) + '\n');
    fs.renameSync(tmp, MANAGED_CACHE);
  } catch (e) { logErr('saveManagedCache:', e.message); }
}

// 本客户端实际参与的项目名集合: 本机 repos 里配置的 ∪ (autoRepos 开启时)服务端受管清单。
function effectiveRepoNames() {
  const names = new Set(Object.keys(cfg.repos || {}));
  if (cfg.autoRepos) for (const r of managedRepos) if (r && r.repo) names.add(r.repo);
  return [...names];
}

// repo 目录名: owner/repo → owner-repo(全名替换分隔符, 避免不同 owner 的同名 repo 撞目录)。
function repoDirName(repoName) { return String(repoName).replace(/[\\/]+/g, '-'); }

// 解析某项目在本机的生效路径/提示词。配置了 mainRepo = 手动模式(完全沿用旧行为);
// 未配置 = 自动模式: <repoBaseDir>/<owner-repo>(worktreeBase 缺省 = mainRepo + "-worktrees", 两种模式同约定)。
function resolveRepoConf(repoName) {
  const rc = (cfg.repos || {})[repoName] || {};
  const manualMain = String(rc.mainRepo || '').trim();
  const mainRepo = manualMain || path.join(cfg.repoBaseDir, repoDirName(repoName));
  const worktreeBase = String(rc.worktreeBase || '').trim() || (mainRepo + '-worktrees');
  return { mainRepo, worktreeBase, prompt: rc.prompt || '', auto: !manualMain };
}

// 是否参与某项目(会接它的单): 本机配置过, 或 autoRepos 且在服务端受管清单里。
function repoParticipating(repoName) {
  if ((cfg.repos || {})[repoName]) return true;
  return !!(cfg.autoRepos && managedRepos.some((r) => r && r.repo === repoName));
}

// 从 review_job 推导仓库远端地址(自动 clone 用):
//   github → https://github.com/<owner/repo>.git (clone 走 gh 带鉴权, 此 URL 仅兜底/展示)
//   azdo   → 从 pr_url 剥掉 /pullrequest/<id> 得 .../_git/<repo>(即 ADO 的 git 远端地址)
function deriveCloneUrl(job) {
  if (job.provider === 'azdo') {
    const m = String(job.pr_url || '').match(/^(https?:\/\/.+\/_git\/[^/]+)\/pull[Rr]equest\/\d+/);
    return m ? m[1] : null;
  }
  return `https://github.com/${job.repo}.git`;
}

// 确保 mainRepo 是可用的 git clone; 不存在则自动 clone(仅自动模式的首个 job 会走到)。
// 失败时返回给用户可操作的提示(手动 clone 或到配置页配路径)。GIT_TERMINAL_PROMPT=0:
// headless 下 git 弹凭证输入会永久挂死, 宁可快速失败并把原因带回群里。
async function ensureRepoCloned(job, mainRepo) {
  if (fs.existsSync(path.join(mainRepo, '.git'))) return { ok: true, cloned: false };
  const url = deriveCloneUrl(job);
  if (!url) {
    return { ok: false, detail: `无法从派单信息推导 ${job.repo} 的远端地址(pr_url 缺失/异常)。请手动 clone 后在配置页为该项目填写本机路径。` };
  }
  const env = { ...process.env, GIT_LFS_SKIP_SMUDGE: '1', GIT_TERMINAL_PROMPT: '0' };
  try { fs.mkdirSync(path.dirname(mainRepo), { recursive: true }); } catch { /* clone 会再报 */ }
  log(`auto-clone ${job.repo} ← ${url} → ${mainRepo}`);
  send({ type: 'review_progress', job_id: job.job_id, stage: 'clone' });
  notify(`⬇️ 首次自动 clone ${job.repo}`, mainRepo);
  const rmPartial = () => { try { fs.rmSync(mainRepo, { recursive: true, force: true }); } catch { /* ignore */ } };
  let r;
  if (job.provider === 'azdo') {
    // 认证优先用 AZURE_DEVOPS_EXT_PAT(客户端前置要求, az CLI 同款 PAT; 兼容 AZDO_PAT):
    // 走 http.extraheader Basic, 绕开本机 credential helper(keychain 里存过坏凭证会让 clone
    // 恒失败且不询问)。没配 PAT 则回退 git 自身凭证链(已手动配好 git 凭证的机器照常可用)。
    const pat = process.env.AZURE_DEVOPS_EXT_PAT || process.env.AZDO_PAT || '';
    const authHeader = pat ? `AUTHORIZATION: Basic ${Buffer.from(':' + pat).toString('base64')}` : '';
    const authArgs = authHeader ? ['-c', `http.extraheader=${authHeader}`] : [];
    // --filter=blob:none 大仓库快得多; 老 ADO Server 不支持 partial clone 时服务端自动忽略。
    r = await run('git', [...authArgs, 'clone', '--filter=blob:none', url, mainRepo], { env });
    if (r.code !== 0) { rmPartial(); r = await run('git', [...authArgs, 'clone', url, mainRepo], { env }); }
    if (r.code === 0 && authHeader) {
      // 把认证头写进该 repo 本地配置: 之后的 fetch / worktree 操作(含 refs/pull/<id>/merge 兜底)
      // 同样免交互认证。PAT 在成员自己机器的 repo 配置里, 与其 shell profile 中的环境变量同级暴露。
      await run('git', ['-C', mainRepo, 'config', 'http.extraheader', authHeader], { env });
      log(`auto-clone: 已用 AZURE_DEVOPS_EXT_PAT 认证并写入该 repo 的 http.extraheader(后续 fetch 免交互)`);
    }
  } else {
    // github 优先 gh(用成员已登录的 gh 鉴权, 私有仓库无需另配凭证); 无 gh/失败再回退裸 git。
    r = await run('gh', ['repo', 'clone', job.repo, mainRepo, '--', '--filter=blob:none'], { env });
    if (r.code !== 0) { rmPartial(); r = await run('git', ['clone', url, mainRepo], { env }); }
  }
  if (r.code !== 0) {
    rmPartial();
    return { ok: false, detail: `自动 clone 失败(${url}):\n${((r.stdout || '') + (r.stderr || '')).slice(-1500)}\n` +
      `请确认本机对该仓库有访问权限(github 需 gh auth login; ADO 需 git 凭证), 或手动 clone 后在配置页为该项目填写本机路径。` };
  }
  log(`auto-clone ${job.repo} 完成`);
  return { ok: true, cloned: true };
}

// ==================== Claude 额度(quota)上报 ====================
// 目标: 额度用尽/接近用尽的人不再被派 review, 由服务端自动改派并在群里提示。
//  - 反应式(可靠底座): review 命中限额时 claude 输出里带 "You've hit your ... limit ... resets ...",
//    解析出重置时间 → 在此之前该 client 上报"额度不足", 服务端据此停派+换人+提示。
//  - 前瞻式(可选增强): 读 statusline 写的 rate_limits 快照, 5 小时/7 天窗已用 >= 阈值就提前上报,
//    连派单前就避开。快照过期/缺失则仅靠反应式。
// currentQuota() 汇总两者交给服务端; reset 到点自动恢复可用。

let reactiveQuotaBlock = null;   // {reason, reset_at(ms)} —— 命中限额后置; 到 reset_at 自动失效

// 从 claude 输出解析限额命中。命中→{reason, reset_at}; 未命中→null。
// 文案形如: "You've hit your session limit · resets 3:45pm" / "...weekly limit · resets Mon 12:00am"
//           "...Opus limit · resets ..."; API key: "Credit balance is too low" / "(429)"。
function detectQuotaHit(logText) {
  if (!logText) return null;
  const m = logText.match(/hit your\s+(\S+)\s+limit\b[^\n]*?\bresets?\s+([^\n.·]+)/i);
  if (m) {
    const kind = m[1].toLowerCase();               // session / weekly / opus / 5-hour...
    const resetText = m[2].trim();
    return { reason: `${kind}_limit`, reset_at: parseResetToEpoch(resetText, kind), reset_text: resetText };
  }
  if (/credit balance is too low/i.test(logText)) {
    return { reason: 'credit_low', reset_at: Date.now() + 6 * 3600_000, reset_text: '' }; // 无重置时间, 保守冷却 6h
  }
  return null;
}

// 把 claude 的重置文案(本机时区)解析成 epoch ms。解析不出用按类型的保守兜底冷却。
//   "3:45pm" → 今天/明天该时刻的下一次; "Mon 12:00am" → 下一个该星期几该时刻。
function parseResetToEpoch(text, kind) {
  const fallback = () => Date.now() + (/(week|7|seven|opus)/i.test(kind || '') ? 24 : 5) * 3600_000;
  if (!text) return fallback();
  const now = new Date();
  const tm = text.match(/(\d{1,2})(?::(\d{2}))?\s*(am|pm)?/i);
  if (!tm) return fallback();
  let hh = parseInt(tm[1], 10); const mm = tm[2] ? parseInt(tm[2], 10) : 0;
  const ap = (tm[3] || '').toLowerCase();
  if (ap === 'pm' && hh < 12) hh += 12;
  if (ap === 'am' && hh === 12) hh = 0;
  const wdMatch = text.match(/\b(sun|mon|tue|wed|thu|fri|sat)/i);
  const target = new Date(now);
  target.setHours(hh, mm, 0, 0);
  if (wdMatch) {
    const wds = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
    const want = wds.indexOf(wdMatch[1].toLowerCase());
    let add = (want - target.getDay() + 7) % 7;
    if (add === 0 && target.getTime() <= now.getTime()) add = 7;
    target.setDate(target.getDate() + add);
  } else if (target.getTime() <= now.getTime()) {
    target.setDate(target.getDate() + 1);   // 该时刻今天已过 → 明天(session 类通常在 5h 内, 仍是保守上界)
  }
  const epoch = target.getTime();
  return Number.isFinite(epoch) ? epoch : fallback();
}

// ---- 用 `claude -p /usage` 查额度(headless 可用, 零 token 消耗 ~1s, 自带重置时间)----
// 比 statusline 快照稳: 不依赖交互、不碰用户的 statusLine、纯跑 review 的机器也能查。
let usageQuota = null;            // { five_hour_pct, five_hour_reset_at, seven_day_pct, seven_day_reset_at }
let usageQuotaAt = 0;            // 上次成功查询时刻(ms)
const USAGE_POLL_MS = 600000;    // 每 10 分钟查一次(派活前还会再查一次拿最新值)
const USAGE_FRESH_MS = 1500000;  // 结果 25 分钟内视为新鲜(必须 > 轮询间隔, 且能容忍一次失败轮询), 否则值会在
                                 // 两次刷新之间被判过期 → hub 闪断显示 —。宁可短时展示稍旧值也一直显示到下次刷新。

// 把 /usage 的 "Jul 10 at 3pm" 这类文案(本机时区, 与 /usage 显示时区一致)解析成 epoch ms。
function parseUsageReset(s) {
  if (!s) return null;
  const m = String(s).trim().match(/([A-Za-z]{3,})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?/i);
  if (!m) return null;
  const months = { jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5, jul: 6, aug: 7, sep: 8, oct: 9, nov: 10, dec: 11 };
  const mon = months[m[1].slice(0, 3).toLowerCase()]; if (mon == null) return null;
  const day = parseInt(m[2], 10); let hh = parseInt(m[3], 10); const mm = m[4] ? parseInt(m[4], 10) : 0;
  const ap = (m[5] || '').toLowerCase();
  if (ap === 'pm' && hh < 12) hh += 12;
  if (ap === 'am' && hh === 12) hh = 0;
  const now = new Date();
  let d = new Date(now.getFullYear(), mon, day, hh, mm, 0, 0);
  if (d.getTime() < now.getTime() - 3 * 24 * 3600_000) d = new Date(now.getFullYear() + 1, mon, day, hh, mm, 0, 0);  // 跨年
  return d.getTime();
}
// 解析 /usage 文本: "Current session: N% used · resets ..."(=5 小时窗)/ "Current week (all models): M% used · resets ..."。
function parseUsageText(text) {
  if (!text) return null;
  const out = {};
  let m = text.match(/Current session:\s*(\d+)%\s*used(?:[^\n]*?\bresets\s*([^\n(]+))?/i);
  if (m) { out.five_hour_pct = parseInt(m[1], 10); out.five_hour_reset_at = parseUsageReset(m[2]); }
  m = text.match(/Current week \(all models\):\s*(\d+)%\s*used(?:[^\n]*?\bresets\s*([^\n(]+))?/i);
  if (m) { out.seven_day_pct = parseInt(m[1], 10); out.seven_day_reset_at = parseUsageReset(m[2]); }
  return (out.five_hour_pct != null || out.seven_day_pct != null) ? out : null;
}
// 跑 `claude -p /usage --output-format json` 并解析。成功→更新缓存; 失败/超时→不动(变旧后失效)。
// 返回 Promise(总 resolve, 不 reject), 供"派活前先查一次"await。
function pollUsage() {
  return new Promise((resolve) => {
    let done = false, stdout = '', child, to;
    const finish = () => { if (done) return; done = true; clearTimeout(to); resolve(); };
    // --dangerously-skip-permissions: 跳过 claude 沙盒/权限初始化, 避免它经 sandboxd 探测 Apple Music/
    // 媒体库等 → 免得给成员弹"访问媒体库"授权(那是 claude 行为被归因到本 app, 与 review 无关)。/usage 只读本地, 无副作用。
    try { child = spawn(cfg.claudePath, ['-p', '/usage', '--output-format', 'json', '--dangerously-skip-permissions'], { stdio: ['ignore', 'pipe', 'ignore'] }); }
    catch (e) { logErr(`查额度(/usage)启动失败: ${e.message}`); return resolve(); }
    to = setTimeout(() => { try { child.kill('SIGKILL'); } catch {} finish(); }, 25000);
    if (child.stdout) child.stdout.on('data', (d) => { stdout += d; });
    child.on('error', (e) => { logErr(`查额度(/usage)出错: ${e.message}`); finish(); });
    child.on('close', () => {
      let text = stdout;
      try { const j = JSON.parse(stdout); if (j && typeof j.result === 'string') text = j.result; } catch { /* 非 json 按纯文本 */ }
      const parsed = parseUsageText(text);
      if (parsed) { usageQuota = parsed; usageQuotaAt = Date.now(); sendQuota(); }   // 刷新后独立上报(不挂心跳)
      else logErr('查额度(/usage): 未解析出 session/week 百分比(claude 版本过旧?)');
      finish();
    });
  });
}

// 汇总当前额度状态给服务端。反应式(命中限额)优先; 否则用 /usage 的 5 小时/7 天窗判定, 并带出百分比与恢复时间。
// 默认 ok(拿不到 = 不拦, 交给反应式兜底; 管理页显示 —)。
function currentQuota() {
  const u = (usageQuota && Date.now() - usageQuotaAt < USAGE_FRESH_MS) ? usageQuota : null;
  const f5 = u && u.five_hour_pct != null ? u.five_hour_pct : null;
  const f5r = u && u.five_hour_reset_at != null ? u.five_hour_reset_at : null;
  if (reactiveQuotaBlock) {
    if (reactiveQuotaBlock.reset_at && Date.now() >= reactiveQuotaBlock.reset_at) reactiveQuotaBlock = null;
    else return { ok: false, reason: reactiveQuotaBlock.reason, reset_at: reactiveQuotaBlock.reset_at || null, five_hour_pct: f5, five_hour_reset_at: f5r };
  }
  if (u) {
    if (f5 != null && f5 >= cfg.quotaFiveHourThreshold) return { ok: false, reason: `five_hour_${f5}pct`, reset_at: f5r, five_hour_pct: f5, five_hour_reset_at: f5r };
    if (u.seven_day_pct != null && u.seven_day_pct >= cfg.quotaSevenDayThreshold) return { ok: false, reason: `seven_day_${u.seven_day_pct}pct`, reset_at: u.seven_day_reset_at || null, five_hour_pct: f5, five_hour_reset_at: f5r };
  }
  return { ok: true, reason: null, reset_at: null, five_hour_pct: f5, five_hour_reset_at: f5r };
}

// 清理旧版(1.3~1.5.5)对 Claude statusLine 的改动: 现在改用 `claude -p /usage` 查额度, 不再需要 statusLine。
// 若 statusLine 曾被我们设成/包装成额度脚本 → 还原你原来的 statusLine(inner-statusline.json)或移除我们加的,
// 并删掉临时脚本/inner, 保持你的 Claude 环境干净。
function cleanupOldStatusline() {
  try {
    const destDir = path.join(os.homedir(), '.lark-review-client');
    const innerFile = path.join(destDir, 'inner-statusline.json');
    const settingsPath = path.join(os.homedir(), '.claude', 'settings.json');
    let settings = null;
    try { settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8')); } catch { settings = null; }
    if (settings && settings.statusLine && typeof settings.statusLine.command === 'string'
        && settings.statusLine.command.includes('statusline-quota.sh')) {
      let inner = null;
      try { inner = JSON.parse(fs.readFileSync(innerFile, 'utf8')); } catch { inner = null; }
      if (inner && inner.command) settings.statusLine = { type: inner.type || 'command', command: inner.command };  // 还原原来的
      else delete settings.statusLine;                                                                              // 当初无 statusline → 移除
      const tmp = settingsPath + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify(settings, null, 2) + '\n');
      fs.renameSync(tmp, settingsPath);
      log('已还原此前为额度快照修改的 Claude statusLine(现改用 /usage 查额度)');
    }
    try { fs.rmSync(innerFile, { force: true }); } catch {}
    try { fs.rmSync(path.join(destDir, 'statusline-quota.sh'), { force: true }); } catch {}
  } catch (e) { logErr(`清理旧 statusline 配置失败(不影响 review): ${e.message}`); }
}


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
function writeReviewLog(job, code, parsed, logText, usage) {
  try {
    const ts = new Date().toISOString().replace(/[:.]/g, '-');
    const file = path.join(REVIEW_LOG_DIR, `pr-${job.pr_num}-${ts}.log`);
    const uLine = usage
      ? `# tokens: in=${usage.input_tokens ?? '?'} out=${usage.output_tokens ?? '?'} cache_read=${usage.cache_read_input_tokens ?? '?'} cache_write=${usage.cache_creation_input_tokens ?? '?'}  cost=$${usage.total_cost_usd ?? '?'}  turns=${usage.num_turns ?? '?'}\n`
      : '';
    const header =
      `# PR #${job.pr_num}  repo=${job.repo}  branch=${job.branch}\n` +
      `# job=${job.job_id}  model=${job.review_model || cfg.reviewModel}  time=${new Date().toISOString()}\n` +
      `# exit=${code}  verdict=${parsed.verdict || '-'}  inline=${parsed.inline_count}  general_comment=${parsed.general_comment_url || '-'}\n` +
      uLine +
      `${'#'.repeat(64)}\n\n`;
    fs.writeFileSync(file, header + (logText || ''));
    return file;
  } catch (e) { logErr('writeReviewLog:', e.message); return null; }
}

// ---------- Review token 用量统计(本机记账 + 上报服务端) ----------
// claude --print --output-format json 的信封含 usage/total_cost_usd 等; 老版 claude 无 json
// 输出时解析失败 → usage 为 null(照常跑, 只是无统计)。逐条落 usage.jsonl, 供本机展示与核对。
const USAGE_LOG_FILE = path.join(REVIEW_LOG_DIR, 'usage.jsonl');

// 解析 claude json 信封: 成功 → {text(最终文本), usage(用量摘要)}; 非 json/形状不对 → null。
function parseClaudeEnvelope(stdout) {
  try {
    const j = JSON.parse(stdout);
    if (!j || typeof j !== 'object' || typeof j.result !== 'string') return null;
    const u = j.usage || {};
    return {
      text: j.result,
      usage: {
        input_tokens: u.input_tokens ?? null,
        output_tokens: u.output_tokens ?? null,
        cache_read_input_tokens: u.cache_read_input_tokens ?? null,
        cache_creation_input_tokens: u.cache_creation_input_tokens ?? null,
        total_cost_usd: j.total_cost_usd ?? null,
        duration_ms: j.duration_ms ?? null,
        num_turns: j.num_turns ?? null,
      },
    };
  } catch { return null; }
}

function recordUsage(job, model, code, parsed, usage) {
  if (!usage) return;
  try {
    const rec = { ts: new Date().toISOString(), repo: job.repo, pr_num: String(job.pr_num),
      job_id: job.job_id, model, exit_code: code, verdict: parsed.verdict || '', ...usage };
    fs.appendFileSync(USAGE_LOG_FILE, JSON.stringify(rec) + '\n');
  } catch (e) { logErr('recordUsage:', e.message); }
}

// 汇总本机用量(今日/累计), 供 /status 与配置页展示。文件不大(每 review 一行), 直接全读。
function usageStats() {
  const zero = () => ({ reviews: 0, input_tokens: 0, output_tokens: 0, cost_usd: 0 });
  const today = zero(), total = zero();
  const dayKey = new Date().toLocaleDateString('sv');   // YYYY-MM-DD(本机时区)
  let lines = [];
  try { lines = fs.readFileSync(USAGE_LOG_FILE, 'utf8').split('\n'); } catch { /* 还没有记录 */ }
  for (const ln of lines) {
    if (!ln.trim()) continue;
    let r; try { r = JSON.parse(ln); } catch { continue; }
    const add = (t) => { t.reviews += 1; t.input_tokens += r.input_tokens || 0;
      t.output_tokens += r.output_tokens || 0; t.cost_usd += r.total_cost_usd || 0; };
    add(total);
    if (String(r.ts || '').length >= 10 && new Date(r.ts).toLocaleDateString('sv') === dayKey) add(today);
  }
  today.cost_usd = Math.round(today.cost_usd * 10000) / 10000;
  total.cost_usd = Math.round(total.cost_usd * 10000) / 10000;
  return { today, total };
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

CRITICAL RESULT CONTRACT — the run is ONLY counted as done if your very last output is the result line.
Regardless of outcome (approve / changes / error), your FINAL output MUST be exactly ONE line, on its own
line, plain text, with NOTHING after it — no summary, no markdown, no code fence, no closing remarks.
Do NOT end with a prose summary; the result line must be the last thing you print:
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

CRITICAL RESULT CONTRACT — the run is ONLY counted as done if your very last output is the result line.
Regardless of outcome (approve / changes / error), your FINAL output MUST be exactly ONE line, on its own
line, plain text, with NOTHING after it — no summary, no markdown, no code fence, no closing remarks.
Do NOT end with a prose summary; the result line must be the last thing you print:
___RESULT___ verdict=<APPROVE|COMMENT|REQUEST_CHANGES> general_comment_url=<url-or-NONE> inline_count=<integer>`;

// 结果行契约(独立于任何提示词): 服务端解析 review 结论只认这一行。用户自定义提示词【无需】
// 自带它 —— renderPrompt 检测到提示词里没有 ___RESULT___ 时自动在末尾【追加】本块(append-only,
// 明确声明不改变上方 review 要求的任何含义), 保证无论提示词怎么写, 服务端都能拿到确定的结论;
// 提示词已含契约(如内置模板)则不重复附加。
const RESULT_CONTRACT_SUFFIX = `

---
[Appended by lark-review-client — output format contract ONLY. It does NOT change, override, or
reinterpret ANY review instruction above; follow the instructions above exactly as written.]

CRITICAL RESULT CONTRACT — the run is ONLY counted as done if your very last output is the result line.
Regardless of outcome (approve / changes / error), your FINAL output MUST be exactly ONE line, on its own
line, plain text, with NOTHING after it — no summary, no markdown, no code fence, no closing remarks:
___RESULT___ verdict=<APPROVE|COMMENT|REQUEST_CHANGES> general_comment_url=<url-or-NONE> inline_count=<integer>
(If the instructions above did not ask you to post/submit anything, use general_comment_url=NONE and
inline_count=0; verdict must still reflect your actual review conclusion.)`;

function renderPrompt(job, worktreePath, ciStatus, repoTmpl) {
  // 提示词优先级: 该项目的本机提示词(repos[].prompt) > 本机全局提示词(globalPrompt, 对所有项目生效) >
  // 服务端该 repo 默认(review_job.prompt_template 下发) > 按 provider 选内置默认模板。
  const builtin = job.provider === 'azdo' ? DEFAULT_PROMPT_TEMPLATE_AZDO : DEFAULT_PROMPT_TEMPLATE;
  const globalTmpl = (cfg.globalPrompt && String(cfg.globalPrompt).trim()) ? cfg.globalPrompt : '';
  const tmpl = (repoTmpl && String(repoTmpl).trim())
    ? repoTmpl
    : (globalTmpl || job.prompt_template || builtin);
  let rendered = tmpl
    .replaceAll('{{PR_NUM}}', String(job.pr_num))
    .replaceAll('{{WORKTREE_PATH}}', worktreePath)
    .replaceAll('{{CI_STATUS}}', ciStatus)
    .replaceAll('{{PR_URL}}', String(job.pr_url || ''))
    .replaceAll('{{REPO}}', String(job.repo || ''));
  if (!rendered.includes('___RESULT___')) rendered += RESULT_CONTRACT_SUFFIX;
  return rendered;
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

// 定期清理超过 N 天没动过的 pr-* worktree(手动配置 + 自动参与的项目都扫; 目录不存在自然跳过)。
async function pruneStaleWorktrees() {
  const cutoff = Date.now() - cfg.worktreeMaxAgeDays * 86400_000;
  for (const repo of effectiveRepoNames()) {
    const conf = resolveRepoConf(repo);
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
// 容错: 容忍 ___RESULT___ 后带 **/空白、字段间任意空白(claude 偶尔加粗或换行)。
const RESULT_RE = /_{3}RESULT_{3}\**\s+verdict=\s*([A-Za-z_]+)\s+general_comment_url=\s*(\S+)\s+inline_count=\s*(\d+)/g;
function parseResult(logText) {
  let last = null, m;
  while ((m = RESULT_RE.exec(logText)) !== null) last = m;
  if (!last) return { result_line: '', verdict: '', general_comment_url: '', inline_count: '?' };
  return { result_line: last[0], verdict: last[1], general_comment_url: last[2], inline_count: last[3] };
}

async function runReviewJob(job) {
  // hub 已校验 repo，这里再防一手: 本机配置过, 或 autoRepos 下服务端受管即参与。
  if (!repoParticipating(job.repo)) {
    return { exit_code: 1, log_tail: `本机未配置且未自动参与 repo ${job.repo}`, verdict: '', general_comment_url: '', inline_count: '?', result_line: '' };
  }
  const conf = resolveRepoConf(job.repo);

  // 派活前先查一次最新额度: 不足就【拒接本单】(不跑 review), 交服务端改派给有额度的人。
  // 上报的 quota 也让 hub 立即记为额度不足 → 下一轮 pick 排除该人。
  await pollUsage();
  const q0 = currentQuota();
  if (q0.ok === false) {
    log(`派活前自查: Claude 额度不足(${q0.reason || '?'}), 拒接 PR #${job.pr_num}, 交服务端改派`);
    return { exit_code: 0, log_tail: `本机 Claude 额度不足(${q0.reason || ''}), 已拒接本单, 交由服务端改派给有额度的人`,
      verdict: '', general_comment_url: '', inline_count: '?', result_line: '', quota: q0, declined_quota: true };
  }

  // mainRepo 尚不存在(自动模式的首个 job, 或手动配了路径但还没 clone)→ 先从远端自动 clone。
  const cl = await ensureRepoCloned(job, conf.mainRepo);
  if (!cl.ok) {
    return { exit_code: 1, log_tail: `仓库准备失败(自动 clone):\n${cl.detail}`.slice(-4000),
      verdict: '', general_comment_url: '', inline_count: '?', result_line: '' };
  }

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
  // --output-format json: 信封里带 usage/total_cost_usd(token 统计用)。老版 claude 不认/输出
  // 非 json 时 parseClaudeEnvelope 返回 null → 按原始文本走老路径, usage 缺省为空, 零破坏。
  const r = await run(cfg.claudePath, [
    '--print', '--output-format', 'json', '--model', model, '--dangerously-skip-permissions',
    '--add-dir', conf.mainRepo, '--add-dir', conf.worktreeBase,
  ], { cwd: wt.worktreePath, stdin: prompt, env: { ...process.env, GIT_LFS_SKIP_SMUDGE: '1' } });

  const envlp = parseClaudeEnvelope(r.stdout);
  const usage = envlp ? envlp.usage : null;
  const logText = (envlp ? envlp.text : (r.stdout || '')) + (r.stderr ? '\n' + r.stderr : '');
  const parsed = parseResult(logText);
  log(`claude exited=${r.code} verdict=${parsed.verdict || '-'} inline=${parsed.inline_count}`
    + (usage ? ` tokens(in/out)=${usage.input_tokens}/${usage.output_tokens} cost=$${usage.total_cost_usd}` : ''));
  recordUsage(job, model, r.code, parsed, usage);
  // 反应式额度检测: 本次 review 若命中限额, 记下重置时间, 之后上报"额度不足", 服务端停派+换人。
  const qhit = detectQuotaHit(logText);
  if (qhit) {
    reactiveQuotaBlock = { reason: qhit.reason, reset_at: qhit.reset_at };
    log(`⚠️ 命中 Claude 限额(${qhit.reason}), 预计 ${qhit.reset_at ? new Date(qhit.reset_at).toLocaleString() : '?'} 恢复; 本机将上报额度不足`);
  }
  const savedLog = writeReviewLog(job, r.code, parsed, logText, usage);
  if (savedLog) log(`review 完整日志已存: ${savedLog}`);
  return {
    exit_code: r.code,
    log_tail: logText.slice(-8000),
    quota: currentQuota(),        // 让服务端立即知道本机额度状态(命中限额那次尤其关键)
    usage,                        // token 用量/成本(null = 本机 claude 不支持 json 输出), 服务端记账用
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
  // 结果经 pending 队列可靠投递: 断线窗口内完成 / 客户端重启都不丢, 重连后重发直至 hub ack。
  queueResult({ type: 'review_result', job_id: job.job_id, ...result });
  const uNote = result.usage && result.usage.output_tokens != null
    ? ` · ${result.usage.input_tokens ?? '?'}/${result.usage.output_tokens} tokens $${result.usage.total_cost_usd ?? '?'}` : '';
  if (result.exit_code === 0 && result.verdict) notify(`✅ Review 完成 PR #${job.pr_num}`, `结论 ${result.verdict} · inline ${result.inline_count}${uNote} · 已用你的账号提交`);
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
// 服务端受管 repo 清单 [{repo, prompt, provider}], register_ack / repos_updated 下发。
// 配置页据此列出可参与的项目; autoRepos 开启时它们即使未在本机配置也自动参与。
// 启动时先用本地缓存(上次下发的), 保证重启后首次 register 就带上完整自动参与列表。
let managedRepos = loadManagedCache();

function send(obj) { try { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj)); } catch {} }

// ---------- review 结果可靠上报(至少一次投递) ----------
// send() 是尽力而为: review 恰好在断线窗口内完成时结果会被静默丢弃 → hub 只能 20min 超时判失败
// 再改派(白跑一轮)。这里把结果(含 token 用量)先落磁盘 pending 队列再发送; 重连注册成功后重发,
// 收到 hub 的 review_result_ack 才删除 —— 跨断线、跨客户端进程重启都不丢。hub 侧幂等(job 已
// finish 的重复投递直接忽略并回 ack), 重发不会造成重复处理。旧 hub 不回 ack → 条目按 24h 过期
// 清理, 避免永久重发(升级 hub 后自然闭环)。
const PENDING_RESULTS_FILE = CONFIG_PATH + '.pending-results.json';
const PENDING_MAX_AGE_MS = 24 * 3600_000;
let pendingResults = (() => {
  try {
    const j = JSON.parse(fs.readFileSync(PENDING_RESULTS_FILE, 'utf8'));
    return Array.isArray(j) ? j : [];
  } catch { return []; }
})();
function savePendingResults() {
  try {
    const tmp = PENDING_RESULTS_FILE + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(pendingResults) + '\n');
    fs.renameSync(tmp, PENDING_RESULTS_FILE);
  } catch (e) { logErr('savePendingResults:', e.message); }
}
// 结果入队并立即尝试投递。payload = review_result 消息体(含 job_id/usage/...)。
function queueResult(payload) {
  pendingResults = pendingResults.filter((p) => Date.now() - (p.ts || 0) < PENDING_MAX_AGE_MS);
  pendingResults.push({ ts: Date.now(), payload });
  savePendingResults();
  flushPendingResults();
}
function flushPendingResults() {
  if (!registered || !ws || ws.readyState !== WebSocket.OPEN) return;
  const expired = pendingResults.filter((p) => Date.now() - (p.ts || 0) >= PENDING_MAX_AGE_MS);
  if (expired.length) {
    logErr(`丢弃 ${expired.length} 条超过 24h 未确认的 review 结果(hub 侧早已按超时处理)`);
    pendingResults = pendingResults.filter((p) => Date.now() - (p.ts || 0) < PENDING_MAX_AGE_MS);
    savePendingResults();
  }
  for (const p of pendingResults) send(p.payload);   // 全部重发; 以 hub 的 ack 逐条清除
}
function ackResult(jobId) {
  const before = pendingResults.length;
  pendingResults = pendingResults.filter((p) => !(p.payload && p.payload.job_id === jobId));
  if (pendingResults.length !== before) savePendingResults();
}

// 注册(hub 侧幂等: 同 open_id 重发 register 直接替换记录, 在途 job 由 hub 从全局重建, 不丢)。
// 不上报 open_id / name —— 由服务端按 token 解析并下发(防冒名)。
let lastSentRepos = [];   // 上次注册时上报的 repo 列表(判断清单变化后是否需要重注册)
function sendRegister() {
  lastSentRepos = effectiveRepoNames();
  send({
    type: 'register',
    token: cfg.token,
    hostname: detectHostname(),
    repos: lastSentRepos,
    version: CLIENT_VERSION,
    quota: currentQuota(),
  });
}
// 受管清单更新后(register_ack / repos_updated): autoRepos 下参与列表可能变了 → 重发 register
// 让 hub 立刻知道本机可接哪些项目(否则首次安装 repos 为空, hub 永远不会派单)。
function reRegisterIfReposChanged(reason) {
  const now = effectiveRepoNames();
  const changed = now.length !== lastSentRepos.length || now.some((r) => !lastSentRepos.includes(r));
  if (!changed) return;
  log(`参与项目列表变化(${reason}) → 重新注册: [${now.join(', ')}]`);
  sendRegister();
}

// Claude 额度独立上报(与心跳解耦): 心跳 ~15s 高频, 额度 10min 才刷一次, 不必每心跳重复带。
// 在 register_ack 后 + 每次 /usage 刷新后调用; ws 未连时 send() 自动 no-op。
function sendQuota() { send({ type: 'quota', quota: currentQuota() }); }

function connect() {
  log(`connecting ${cfg.serverUrl} …`);
  ws = new WebSocket(cfg.serverUrl);

  ws.on('open', () => {
    reconnectDelay = 1000;
    connected = true;
    sendRegister();
    if (hbTimer) clearInterval(hbTimer);
    // 心跳只保活(精简); 额度改走独立 'quota' 消息(register_ack 后 + 每次 /usage 刷新后发)。
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
        sendQuota();   // 注册后立即上报一次当前额度(心跳不再带 quota)
        flushPendingResults();   // 断线/重启期间攒下的 review 结果(含用量)重发, 收到 ack 才清
        identity = { open_id: msg.open_id, name: msg.name, recommended_version: msg.recommended_version || null, upgrade: msg.upgrade || null };
        if (Array.isArray(msg.managed_repos)) { managedRepos = msg.managed_repos; saveManagedCache(managedRepos); }
        log(`registered as ${msg.name} (${msg.open_id}) ✓  本机 v${CLIENT_VERSION}，服务端推荐 v${msg.recommended_version || '?'}`);
        // 对照服务端清单提示配置缺口: 本地多配的(不会被派单)。
        const managedNames = new Set(managedRepos.map((r) => r.repo));
        const extras = Object.keys(cfg.repos).filter((r) => managedNames.size && !managedNames.has(r));
        if (extras.length) logErr(`本地配置的 repo 不在服务端受管清单里(不会被派单): ${extras.join(', ')}`);
        if (cfg.autoRepos) {
          const autoOnes = [...managedNames].filter((r) => !cfg.repos[r]);
          if (autoOnes.length) log(`自动参与(未单独配路径, 派单时按需 clone 到 ${cfg.repoBaseDir}): [${autoOnes.join(', ')}]`);
        } else if (!Object.keys(cfg.repos).length) {
          log(`尚未配置任何项目 —— 打开配置页 http://127.0.0.1:${cfg.configPort} 从服务端清单里选择并填本机路径`);
        }
        // 首次安装/清单变化: 本次注册可能还没带上受管项目 → 按最新清单重注册(幂等)。
        reRegisterIfReposChanged('register_ack 下发清单');
        if (msg.upgrade) {
          const hard = !!msg.upgrade.below_min;   // 低于最低版本 = 硬拦(服务端已暂停派单); 否则软提示
          logErr('======================== 客户端版本提示 ========================');
          if (hard) {
            logErr(`  ⛔ 版本过低: 当前 v${CLIENT_VERSION} 低于最低要求 v${msg.upgrade.min}`);
            logErr('     服务端已【暂停给你派 review】, 升级后自动恢复。');
          } else {
            logErr(`  🆙 建议升级: 当前 v${CLIENT_VERSION} → 推荐 v${msg.upgrade.recommended}(当前仍可正常接单)`);
          }
          if (msg.upgrade.message) logErr(`  升级方式：${msg.upgrade.message}`);
          logErr(`  打开配置页一键更新: http://127.0.0.1:${cfg.configPort || 8790}/`);
          logErr('=============================================================');
          notify(hard ? '⛔ 版本过低，已暂停派单' : `🆙 有新版本 v${msg.upgrade.recommended}`,
                 hard ? `当前 v${CLIENT_VERSION} 低于最低 v${msg.upgrade.min}，请一键更新`
                      : `当前 v${CLIENT_VERSION}，建议更新(仍可接单)`);
        }
        break;
      }
      case 'repos_updated':
        // 管理员在 hub 改了 Repo 规则 → 即时更新本地清单, 配置页刷新即可看到。
        if (Array.isArray(msg.managed_repos)) {
          managedRepos = msg.managed_repos;
          saveManagedCache(managedRepos);
          log(`服务端受管 repo 清单已更新: [${managedRepos.map((r) => r.repo).join(', ')}]`);
          reRegisterIfReposChanged('repos_updated');   // autoRepos 下参与列表随清单联动
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
      case 'review_result_ack':
        // hub 确认收到某条 review 结果(含 job 已 finish 的幂等分支)→ 从 pending 队列清除。
        if (msg.job_id) ackResult(msg.job_id);
        break;
      case 'pr_closed':
        if (repoParticipating(msg.repo)) {
          const c = resolveRepoConf(msg.repo);
          if (fs.existsSync(c.mainRepo)) {
            removeWorktree(c.mainRepo, c.worktreeBase, msg.pr_num).catch((e) => logErr('removeWorktree:', e.message));
          }
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

// repos 入库前收敛字段: {mainRepo?, worktreeBase?, prompt?}。路径可留空(= 自动模式,
// 按 repoBaseDir 解析并自动 clone); 三个字段全空的条目不落盘(受管项目本就自动参与, 无需占位)。
function sanitizeRepos(repos) {
  const out = {};
  if (!repos || typeof repos !== 'object') return out;
  for (const [name, rc] of Object.entries(repos)) {
    if (!rc || typeof rc !== 'object') continue;
    const e = {};
    if (rc.mainRepo && String(rc.mainRepo).trim()) e.mainRepo = String(rc.mainRepo).trim();
    if (rc.worktreeBase && String(rc.worktreeBase).trim()) e.worktreeBase = String(rc.worktreeBase).trim();
    if (rc.prompt && String(rc.prompt).trim()) e.prompt = String(rc.prompt);
    if (Object.keys(e).length) out[name] = e;
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
    autoRepos: incoming.autoRepos !== false,
    repoBaseDir: String(incoming.repoBaseDir || '').trim() || path.join(os.homedir(), 'LarkReviewRepos'),
    globalPrompt: (incoming.globalPrompt && String(incoming.globalPrompt).trim()) ? String(incoming.globalPrompt) : '',
    repos: sanitizeRepos(incoming.repos),
  };
  if (!next.globalPrompt) delete next.globalPrompt;   // 空全局提示词不落盘
  delete next.name; delete next.openId;          // 身份归服务端, 清掉历史遗留字段
  delete next.promptOverride;                    // 旧版全局提示词字段(1.2 前)已废弃, 现为 globalPrompt
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
        autoRepos: cfg.autoRepos !== false,               // 自动参与服务端受管项目(默认开)
        repoBaseDir: cfg.repoBaseDir || '',               // 默认克隆根目录(自动模式的 clone 位置)
        globalPrompt: cfg.globalPrompt || '',             // 全局提示词(单项目 prompt 优先)
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
        usage: usageStats(),                       // 本机 review token 用量(今日/累计), 配置页展示
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
        // repos 的路径允许留空 = 自动模式(按默认克隆根目录解析并自动 clone); 不再强制两个路径齐全。
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

cleanupOldStatusline();        // 还原旧版为额度快照改过的 statusLine(现改用 /usage 查额度)
pollUsage();                   // 立即查一次额度; 之后每 2min 一次(headless, 零 token)
setInterval(pollUsage, USAGE_POLL_MS).unref();
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

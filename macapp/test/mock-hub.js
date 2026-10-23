#!/usr/bin/env node
// mock-hub — 本地模拟 review-hub 服务端，用于测试 mac app 客户端。
// 用法: node macapp/test/mock-hub.js  (在仓库根目录跑，复用现成的 node_modules/ws)
//
// stdin 交互命令:
//   job <repo> <pr> [branch]   派一个 review_job
//   azdo <repo> <pr> [branch]  派一个 provider=azdo 的 job
//   close <repo> <pr>          发 pr_closed
//   repos                      发 repos_updated（清单加一个新 repo）
//   reject                     发 register_reject (bad_token)
//   upgrade [ver]              下次 register_ack 携带 upgrade 块，可选指定 recommended 版本
//                              （默认 9.9.9；带 ver 参数时强制开启。立即断开触发重连即可见）
//   model [name]               服务端下发的 review 模型: 带 name = 设为该值并推 review_model_updated;
//                              不带 = 切换为"不下发"(下次 register_ack 不带 review_model, 模拟旧 hub)
//                              初始值取 env MOCK_REVIEW_MODEL(未设 = 不下发)
//   announce <title> [message] 推一条服务端公告(announcement; message 里 \n 表示换行),
//                              同时记入"有效公告", 之后的 register_ack 会补发(测离线补发/去重)
//   unannounce                 清空有效公告(模拟撤回/过期)
//   kill                       断开当前连接（测重连）
//   quit                       退出

const WebSocket = require('ws');

const PORT = Number(process.env.MOCK_HUB_PORT || 8788);
const wss = new WebSocket.Server({ port: PORT, host: '127.0.0.1' });

let current = null;
let withUpgrade = false;
let reviewModel = process.env.MOCK_REVIEW_MODEL || '';
let annSeq = 0;
const activeAnns = [];
let upgradeVer = '9.9.9';
let jobSeq = 0;

const MANAGED = [
  { repo: 'mock/alpha' },
  { repo: 'mock/beta', prompt: 'SERVER TEMPLATE for {{REPO}} PR {{PR_NUM}} at {{WORKTREE_PATH}} ci={{CI_STATUS}}' },
  { repo: 'mock/azdo-repo', provider: 'azdo' },
];

function log(...a) { console.log('[hub]', new Date().toISOString(), ...a); }
function send(obj) {
  if (current && current.readyState === WebSocket.OPEN) {
    current.send(JSON.stringify(obj));
    log('>>', JSON.stringify(obj).slice(0, 200));
  } else {
    log('!! no client connected');
  }
}

wss.on('listening', () => log(`listening ws://127.0.0.1:${PORT}`));

wss.on('connection', (ws) => {
  log('client connected');
  current = ws;
  ws.on('message', (data) => {
    let msg;
    try { msg = JSON.parse(data.toString()); } catch { log('<< (bad json)', data.toString()); return; }
    if (msg.type === 'heartbeat') { log('<< heartbeat'); return; }
    log('<<', JSON.stringify(msg));
    if (msg.type === 'register') {
      const ack = {
        type: 'register_ack',
        open_id: 'ou_mock_allen',
        name: 'Mock Allen',
        recommended_version: '2.0.0',
        managed_repos: MANAGED,
      };
      if (reviewModel) ack.review_model = reviewModel;
      ack.announcements = activeAnns;
      if (withUpgrade) {
        ack.upgrade = { recommended: upgradeVer, min: '1.0.0', below_min: false, message: '测试升级提示（mock）' };
      }
      send(ack);
    }
  });
  ws.on('close', () => { log('client disconnected'); if (current === ws) current = null; });
});

// 命令来源 1: stdin（交互跑）；来源 2: MOCK_HUB_CMD_FILE 追加行（后台跑，echo cmd >> file 驱动）
const CMD_FILE = process.env.MOCK_HUB_CMD_FILE;
if (CMD_FILE) {
  const fs = require('fs');
  try { fs.writeFileSync(CMD_FILE, ''); } catch {}
  let offset = 0;
  setInterval(() => {
    let st; try { st = fs.statSync(CMD_FILE); } catch { return; }
    if (st.size <= offset) return;
    const fd = fs.openSync(CMD_FILE, 'r');
    const buf = Buffer.alloc(st.size - offset);
    fs.readSync(fd, buf, 0, buf.length, offset);
    fs.closeSync(fd);
    offset = st.size;
    for (const line of buf.toString('utf8').split('\n')) {
      if (line.trim()) handleCommand(line);
    }
  }, 300);
}

process.stdin.setEncoding('utf8');
process.stdin.on('data', handleCommand);

function handleCommand(line) {
  const [cmd, ...args] = line.trim().split(/\s+/);
  switch (cmd) {
    case 'job':
    case 'azdo': {
      const [repo, pr, branch] = args;
      send({
        type: 'review_job',
        job_id: `mock-job-${++jobSeq}`,
        // 生产 hub（JS）实测把 pr_num 发成字符串，mock 保持一致以免掩盖类型兼容问题
        pr_num: String(pr || 1),
        repo: repo || 'mock/alpha',
        branch: branch || 'main',
        ...(cmd === 'azdo' ? { provider: 'azdo', pr_url: `https://dev.azure.com/x/pr/${pr || 1}` } : { pr_url: `https://github.com/${repo}/pull/${pr || 1}` }),
        ci_overall: 'passing',
        ci_failed_names: '',
        review_model: '',
        prompt_template: '',
      });
      break;
    }
    case 'close': send({ type: 'pr_closed', repo: args[0] || 'mock/alpha', pr_num: Number(args[1] || 1) }); break;
    case 'repos': send({ type: 'repos_updated', managed_repos: [...MANAGED, { repo: 'mock/new-' + Date.now() % 1000 }] }); break;
    case 'reject': send({ type: 'register_reject', reason: 'bad_token' }); break;
    case 'upgrade': {
      if (args[0]) { upgradeVer = args[0]; withUpgrade = true; }
      else withUpgrade = !withUpgrade;
      log('upgrade on next ack:', withUpgrade, withUpgrade ? `(recommended ${upgradeVer})` : '');
      break;
    }
    case 'model': {
      reviewModel = args[0] || '';
      if (reviewModel) send({ type: 'review_model_updated', review_model: reviewModel });
      log('review model:', reviewModel || '(不下发, 下次 ack 生效)');
      break;
    }
    case 'announce': {
      const a = { id: 'ann_mock_' + (++annSeq), title: args[0] || '测试公告', message: (args.slice(1).join(' ') || '公告正文').replace(/\\n/g, '\n'),
                  level: (args[0] || '').includes('重要') ? 'important' : 'info',
                  ts: new Date().toISOString(), expires_at: new Date(Date.now() + 86400000).toISOString() };
      activeAnns.push(a);
      send({ type: 'announcement', ...a });
      break;
    }
    case 'unannounce': activeAnns.length = 0; log('有效公告已清空'); break;
    case 'kill': if (current) current.terminate(); break;
    case 'quit': process.exit(0);
    default: if (cmd) log('unknown cmd:', cmd);
  }
}

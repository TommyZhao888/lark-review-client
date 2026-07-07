# lark-review-client

团队 PR Review 客户端。在**你自己的机器**上跑，连**你自己的 Claude**，由团队的 Lark 机器人驱动。

当有 PR 分配给你 review(或你被 `@` 指定、你自己在卡片里点触发)时，服务端就把这次 review 派给**你本人**的客户端执行：在你本机建 git worktree、跑 `claude /pr-review`、把 inline / general comment 提交到 GitHub（用你自己的 Claude 账号），结论回传给服务端由机器人发回 Lark 线程。你不在线时服务端则照常 `@` 你人工催办。

## 前置要求

本机已安装并登录好（与原单机版一致）：

- **Node.js 18+**
- **git**（能访问目标 repo 的 remote）
- **gh**（`gh auth login` 已登录，有目标 repo 权限）
- **claude**（`claude /login` 已登录，账号对 `reviewModel` 有权限）

> 新手直接看 [QUICKSTART.md](QUICKSTART.md) 跟着做即可。

## 安装

```bash
git clone https://github.com/TommyZhao888/lark-review-client.git
cd lark-review-client
npm install
```
然后 `./run-client.sh start` 启动, 打开 http://127.0.0.1:8790 在网页里配置(推荐);
或手动 `cp config.example.json ~/.lark-review-client.json` 再编辑。

## 配置（推荐用网页）

启动客户端后,浏览器开 **`http://127.0.0.1:8790/`** 就能在网页里配置 claude 路径、模型、
项目(repos)的本机 clone / worktree 目录、serverUrl、token、**review 提示词**(可一键填入默认模板再改)，
**保存即热重载**(自动按新配置重连)。
你的**姓名和 open_id 不用填**——连上服务端后由管理员在服务端设定并自动下发,网页上只读显示。

也可以手动编辑 `~/.lark-review-client.json`（字段见下表）。

## 配置字段（`~/.lark-review-client.json`）

| 字段 | 必填 | 说明 |
|------|------|------|
| `serverUrl` | ✅ | 服务端 review-hub 地址。生产环境用 **`wss://review.ilaot.com`**（经 Cloudflare 隧道，任意能上网的网络都能连，**不需要和服务器同一内网**）；本机自测才用 `ws://127.0.0.1:8788`。以管理员告知为准 |
| `token` | ✅ | 与你绑定的鉴权串，向管理员索取。管理员若重置了你的 token，按下方「注册被拒」在配置页换新值即可 |
| `repos` | ✅ | `"owner/repo": { mainRepo, worktreeBase }` 映射。`mainRepo` 是你本机的 clone 路径，`worktreeBase` 是放临时 worktree 的目录（会自动创建 `pr-<N>` 子目录）|
| `reviewModel` | | claude 模型，默认 `claude-opus-4-8`（必须你账号有权限）|
| `claudePath` | | claude 可执行路径，默认 `claude` |
| `configPort` | | 本机配置页端口，默认 `8790` |
| `promptOverride` | | 自定义 review prompt 模板，支持占位符 `{{PR_NUM}}` `{{WORKTREE_PATH}}` `{{CI_STATUS}}`。留 `null` 用默认模板 |
| `worktreeMaxAgeDays` | | 超过这个天数没动过的 worktree 自动清理，默认 14 |

> **`name` / `openId` 不用配**：连上服务端后按 token 自动下发，你也改不了（防冒名）。
> 你可以配置多个 repo；只有你配了的 repo，服务端才会把对应 PR 派给你。

## 运行（推荐用 run-client.sh）

`run-client.sh` 封装了启停/查看，省得自己记 nohup/pid：

```bash
./run-client.sh start     # 后台启动(默认读 ~/.lark-review-client.json)
./run-client.sh status    # 看是否在跑 + 最近日志
./run-client.sh logs      # tail -f 实时日志
./run-client.sh stop      # 停止
./run-client.sh restart   # 重启(改完配置后用)
# 指定别的配置: ./run-client.sh start /path/to/config.json
```

启动后日志里看到 `registered as <你的名字> ✓` 即成功，此时管理员在群里 `@机器人 在线` 能看到你。

也可不用封装，直接跑：
```bash
node lark-review-client.js [config.json]
```

### 注册被拒（`bad_token`，比如管理员重置了 token）

日志出现 `注册被拒: bad_token`（token 和服务端名单对不上）时，客户端**不会退出**，只是
暂停重连、保持运行。**直接打开配置页 `http://127.0.0.1:8790/`，把管理员给你的新 token
填进去保存**（会自动按新配置重连），无需重启进程。

### 开机自启（可选，重启后自动拉起）

- **macOS（launchd）**：照 `com.larkbot.review-client.plist.example` 的注释改好路径，
  `cp` 到 `~/Library/LaunchAgents/` 后 `launchctl load`。它用 `KeepAlive`，崩溃会自动重启。
- **Linux（systemd）/ 其它**：用 `run-client.sh fg` 作为前台命令挂到 systemd service / supervisor。
- 不想自启的话，`./run-client.sh start` 就够日常用（只是重启电脑后要手动再 start）。

## 它会做 / 不会做什么

- ✅ 在 `worktreeBase/pr-<N>` 建/更新 worktree（`GIT_LFS_SKIP_SMUDGE=1`，只拉源码）
- ✅ 跑 `claude --print --model … --dangerously-skip-permissions --add-dir <mainRepo> --add-dir <worktreeBase>`
- ✅ review 结果（verdict / inline 数 / general comment url）回传服务端
- ✅ PR 合并/关闭后自动删对应 worktree；定期清理过期 worktree
- ❌ 不碰 Lark、不写服务端状态——那些都在服务端做
- ❌ 一次只跑一单（本机串行，避免多个 claude 抢资源）

## 升级

服务端会记录「推荐客户端版本」。你的客户端连上时若版本偏低，启动日志会打印醒目的
`请升级客户端` 提示（含升级方式），管理员在 Lark `@机器人 在线` 也能看到你被标 `⚠️需升级`。
升级方式取决于分发形式（最常见：在客户端目录 `git pull && npm install` 然后重启）。

## 安全

- `token` 等同你的身份凭证，别泄露、别提交进 git。
- 客户端只外连服务端，不监听端口。

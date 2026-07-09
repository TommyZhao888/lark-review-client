# lark-review-client

团队 PR Review 客户端。在**你自己的机器**上跑，连**你自己的 Claude**，由团队的 Lark 机器人驱动。

谁在 Lark 里对 PR 卡片打 SLAP 表情 / 点「再来一轮」，服务端就把这次 review 派给**他本人**的客户端执行：在你本机建 git worktree、跑 `claude /pr-review`、把 inline / general comment 提交到 GitHub（用你自己的 Claude 账号），结论回传给服务端由机器人发回 Lark 线程。

## 两种客户端形态（二选一）

| | Node 版（本 README 主要内容）| 原生 Mac App（`macapp/`，推荐 macOS 用户）|
|---|---|---|
| 形态 | 后台 Node 进程 + 浏览器配置页 + SwiftBar 插件 三件套 | 一个纯菜单栏常驻 app（SwiftUI）|
| 协议/行为 | —— | 与 Node 版**逐字段对等**，配置/日志路径复用，可随时来回切 |
| 安装 | `npm install` + `run-client.sh`（见下文）| 本机**编译** `.app`（见下）|

> 同一时间只跑一个。macOS 用户**最省事**是下载现成 App（下节）；想跟源码/用菜单栏自更新就 clone 后编译；不想碰 Mac App 就用 Node 版。

## 下载安装 Mac App（免编译，推荐大多数人）

每次发版由 GitHub Actions 自动编译并发到 **[Releases](https://github.com/TommyZhao888/lark-review-client/releases)**：

1. 在 Releases 下载最新的 `LarkReviewClient-vX.Y.Z.dmg`。
2. 双击挂载 → 把 **LarkReviewClient** 拖进 **Applications**。
3. **首次打开**（仅一次）：在「应用程序」里**右键 App → 打开**（ad-hoc 签名未公证，Gatekeeper 会拦一次）；
   或先跑 `xattr -dr com.apple.quarantine /Applications/LarkReviewClient.app` 再双击。
4. 菜单栏点 🦁 → 设置… → 填 `serverUrl` 和管理员发的 `token` → 在「项目」tab 从服务端清单添加 repo 并填本机路径。

> 下载安装的版本**不带源码式自更新**（它不是 git 仓库）；有新版本时按同样步骤下载新 dmg 覆盖即可。
> 想要菜单栏「更新并重启」一键自更新，用下面的 **clone + 编译** 方式安装。

## 编译 Mac App（macapp）

**要求**：macOS 14+、Xcode 命令行工具（`xcode-select --install`，swift 5.9+）。

```bash
git clone https://github.com/TommyZhao888/lark-review-client.git
cd lark-review-client/macapp

make test      # 单元测试（协议编解码 / 配置读写 / 模板渲染）
make bundle    # 编译并组装 build/LarkReviewClient.app（swift build -c release + ad-hoc 签名）
make run       # bundle 后启动（= open build/LarkReviewClient.app）
```

- `make build` 只编译不打包；`make clean` 清理。
- 首次启动：菜单栏点 🦁 → 设置… → 填 `serverUrl`（`wss://…`）和管理员发的 `token` → 保存并应用
  → 连上后在「项目」tab 从服务端清单添加 repo 并填本机路径。
- 升级：有新版本时菜单栏显示 🆙，下拉点 **「更新并重启」** 自动 `git pull` + `make bundle` + 重启；
  或在设置里开「空闲时自动更新」。也可手动 `git pull` + `make bundle` 覆盖 `build/LarkReviewClient.app`。
- 更完整的说明（迁移、本地端到端测试、代码结构）见 **`macapp/README.md`**。

---

以下是 **Node 版** 的安装与使用。

## 前置要求

本机已安装并登录好（与原单机版一致）：

- **Node.js 18+**
- **git**（能访问目标 repo 的 remote）
- **gh**（`gh auth login` 已登录，有目标 repo 权限）
- **claude**（`claude /login` 已登录，账号对 `reviewModel` 有权限）

**参与 Azure DevOps 项目时额外需要**：

- 本机能访问公司 ADO Server（内网），clone 时 `origin` 指向 ADO 仓库地址
- PAT：`export AZURE_DEVOPS_EXT_PAT=<你的PAT>`（scope 至少 Code Read & Write），
  建议写进 shell profile；launchd 自启的把它加进 plist 的 EnvironmentVariables
- 安装 `/pr-review-azdo` claude 命令：`cp docs/pr-review-azdo.md ~/.claude/commands/pr-review-azdo.md`
  （见服务端仓库 docs/，向管理员索取）
- 可选：`az` CLI + `az extension add --name azure-devops`（命令里投票操作优先用它，没有则走 REST）

## 安装

**推荐 `git clone`**（这样才能用「一键自动更新」）：

```bash
git clone https://github.com/TommyZhao888/lark-review-client.git
cd lark-review-client
npm install
```

> 之后配置**推荐用网页**（见下节），不必手动建配置文件。若想手动：
> `cp config.example.json ~/.lark-review-client.json` 再编辑（字段见下表）。

## 配置（推荐用网页）

启动客户端后,浏览器开 **`http://127.0.0.1:8790/`** 就能在网页里配置 claude 路径、模型、
serverUrl、token，**保存即热重载**(自动按新配置重连)。

**项目(repos)由服务端清单驱动**：可参与的项目由管理员在服务端 hub「Repo 规则」里配置，
客户端连上后自动下发。首次使用只需先填 serverUrl + token 保存，连上后配置页的**下拉列表**
会列出服务端受管的项目——选择添加，填该项目在你本机的 clone 路径（worktree 目录留空自动按
`<clone路径>-worktrees` 补全）。**提示词按项目在本机单独配置**（只影响你自己的 client），
留空则依次回退：服务端为该项目配的默认 → 内置默认模板。
你的**姓名和 open_id 不用填**——连上服务端后由管理员在服务端设定并自动下发,网页上只读显示。

也可以手动编辑 `~/.lark-review-client.json`（字段见下表）。

## 配置字段（`~/.lark-review-client.json`）

| 字段 | 必填 | 说明 |
|------|------|------|
| `serverUrl` | ✅ | 服务端 review-hub 地址，向管理员索取（本机自测 `ws://127.0.0.1:8788`）|
| `token` | ✅ | 与你绑定的鉴权串，向管理员索取 |
| `repos` | | `"owner/repo": { mainRepo, worktreeBase, prompt? }` 映射。repo 名必须在服务端受管清单里（推荐直接在配置页从下拉列表添加）。`mainRepo` 是你本机的 clone 路径，`worktreeBase` 是放临时 worktree 的目录（会自动创建 `pr-<N>` 子目录），`prompt` 是该项目的本机提示词（可选，优先于服务端默认；支持占位符 `{{PR_NUM}}` `{{WORKTREE_PATH}}` `{{CI_STATUS}}`）。可先留空 `{}`，连上后再配 |
| `reviewModel` | | claude 模型，默认 `claude-opus-4-8`（必须你账号有权限）|
| `claudePath` | | claude 可执行路径，默认 `claude` |
| `configPort` | | 本机配置页端口，默认 `8790` |
| `worktreeMaxAgeDays` | | 超过这个天数没动过的 worktree 自动清理，默认 14 |

> **`name` / `openId` 不用配**：连上服务端后按 token 自动下发，你也改不了（防冒名）。
> 你可以启用多个 repo；只有服务端受管且你启用了的 repo，服务端才会把对应 PR 派给你。

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

### 开机自启（可选，重启后自动拉起）

- **macOS（launchd）**：照 `com.larkbot.review-client.plist.example` 的注释改好路径，
  `cp` 到 `~/Library/LaunchAgents/` 后 `launchctl load`。它用 `KeepAlive`，崩溃会自动重启。
- **Linux（systemd）/ 其它**：用 `run-client.sh fg` 作为前台命令挂到 systemd service / supervisor。
- 不想自启的话，`./run-client.sh start` 就够日常用（只是重启电脑后要手动再 start）。

### 菜单栏状态（可选，macOS）

装 [SwiftBar](https://github.com/swiftbar/SwiftBar) 后菜单栏常驻一个 🦁 图标，一眼看到在线/在跑/有新版本，并可一键更新：

```bash
brew install --cask swiftbar      # 首次打开 SwiftBar 会让你选一个"插件目录"
# 把插件软链进该插件目录（文件名保留 *.5s.sh = 每 5 秒刷新）：
ln -sf "$PWD/lionreview.5s.sh" "<SwiftBar 插件目录>/lionreview.5s.sh"
```

图标含义：🦁🟢 在线待命 · 🦁⚡N 在跑 N 单 · 🦁🔴 离线/未注册 · 🦁⚪️ client 没起；末尾带 **🆙 = 有新版本**。点开下拉能看正在 review 的 PR，以及 **「一键更新并重启」**。配置页端口非默认 `8790` 时，改插件里的 `PORT` 或设环境变量 `LARK_REVIEW_CLIENT_CONFIG_PORT`。

## 它会做 / 不会做什么

- ✅ 在 `worktreeBase/pr-<N>` 建/更新 worktree（`GIT_LFS_SKIP_SMUDGE=1`，只拉源码）
- ✅ 跑 `claude --print --model … --dangerously-skip-permissions --add-dir <mainRepo> --add-dir <worktreeBase>`
- ✅ review 结果（verdict / inline 数 / general comment url）回传服务端
- ✅ PR 合并/关闭后自动删对应 worktree；定期清理过期 worktree
- ❌ 不碰 Lark、不写服务端状态——那些都在服务端做
- ❌ 一次只跑一单（本机串行，避免多个 claude 抢资源）

## 升级 / 自动更新

服务端记录「推荐客户端版本」。你的 client 连上时若版本偏低，有三处提醒 + 两处可一键更新：

- **配置页**（`http://127.0.0.1:8790/`）顶部「客户端版本」卡显示 🆙 有新版本，点 **「一键更新并重启」** → 自动 `git pull` + `npm install --omit=dev` + 重启（几秒后自动重连）。
- **菜单栏**图标显示 🆙，下拉点 **「一键更新并重启」**，同效。
- **启动日志**打印醒目的 `请升级客户端`；管理员在 Lark `@机器人 在线` 也能看到你被标 `⚠️需升级`。

> **自动更新的前提**：客户端目录是 `git clone` 来的 git 仓库（能 `git pull`）。若不是（如手动复制的文件夹），一键更新会失败并**直接显示手动更新步骤**：
>
> ```bash
> cd <客户端目录>
> git pull            # 或从 https://github.com/TommyZhao888/lark-review-client 下载最新，覆盖本目录
> npm install --omit=dev
> ./run-client.sh restart
> ```

## 安全

- `token` 等同你的身份凭证，别泄露、别提交进 git。
- 客户端只外连服务端，不监听端口。

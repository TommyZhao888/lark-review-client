# Lark Review Client — mac 菜单栏 app（SwiftUI）

Node 版 `lark-review-client.js` 的原生 mac 重写：把「后台 Node 进程 + 浏览器配置页 + SwiftBar 插件」三件套合成一个纯菜单栏常驻 app。**协议与行为与 Node 版 v1.3.0 完全对等**，配置文件、日志路径也完全复用，两个版本可随时来回切换（同时只跑一个）。

## 与 Node 版的对应关系

| 能力 | Node 版 | mac app |
|------|---------|---------|
| 配置 | 浏览器配置页 127.0.0.1:8790 | 菜单栏 → 设置…（原生窗口） |
| 状态展示 | SwiftBar 插件 lionreview.5s.sh | 菜单栏图标（🦁⚡N / 🦁🟢 / 🦁🔴，🆙 有新版本） |
| 日志查看 | 配置页日志 tab | 菜单栏 → 日志…（运行日志 + Review 日志） |
| 开机自启 | launchd plist | 设置 → 开机自启（SMAppService 登录项） |
| 一键自更新 | git pull + 重启 | **菜单栏「更新并重启」**（从 GitHub Releases 下载新版 dmg **原地替换自己** + 重启，任意安装位置可用）；设置里可开「空闲时自动更新」 |
| 配置文件 | `~/.lark-review-client.json` | 同一个文件，未知键保留 |
| 运行日志 | `~/.lark-review-client.log` | 同一个文件 |
| Review 日志 | `~/.lark-review-client-logs/` | 同一个目录 |

客户端版本号与 Node 版一致（`Models/Config.swift` 的 `CLIENT_VERSION` + `Resources/Info.plist` 两处同步改；发版记得在仓库打 `vX.Y.Z` tag——服务端按最新 tag 判断是否提示升级，CI 按 tag 出 dmg 并自动 bump 仓库根的 Homebrew cask）。

## 安装（团队成员）

```bash
brew tap tommyzhao888/lark-review-client https://github.com/TommyZhao888/lark-review-client.git
brew install --cask lark-review-client
```

装完直接打开（cask 已自动剥离 quarantine）。也可从 Releases 手动下 dmg 安装（首次打开前需
`xattr -dr com.apple.quarantine /Applications/LarkReviewClient.app`）。

## 更新（自更新）

菜单栏检测到新版本会显示 🆙，下拉里点 **「更新并重启」** 即可：从 GitHub Releases 下载推荐版本的
dmg → 校验（bundle id / 版本 / 架构 / 签名）→ **原地替换正在运行的 app** → 自动重启。任意安装
位置均可用（/Applications、源码树 build/ …），无需本机编译工具链（有 review 在跑/排队时按钮禁用，
跑完再更；更新中途来了 review 会中止更新让 review 先跑）。设置 → 更新里可开 **「空闲时自动更新」**
（默认关）：连上服务端且空闲时检测到新版本自动执行。失败会在横幅提示原因，并提供「前往下载新版」
手动逃生口；「安装包还在构建中(CI 未完成)」属可重试失败，下次重连自动再试。

## 构建与运行

要求：macOS 14+，Xcode 命令行工具（swift 5.9+）。

```bash
cd macapp
make test     # 单元测试（协议编解码 / 配置读写 / 模板渲染）
make bundle   # 构建并组装 build/LarkReviewClient.app（ad-hoc 签名）
make run      # bundle 后启动
```

首次使用：菜单栏点 🦁 → 设置… → 填 serverUrl（`wss://review.ilaot.com`）和 token（向管理员索取）→ 保存并应用 → 连上后在「项目」tab 从服务端清单添加 repo 并填本机路径。

从 Node 版迁移：先停掉 Node 版（`./run-client.sh stop`，如有 launchd 记得 `launchctl unload`），直接启动 app 即可——配置无缝沿用。

## 本地端到端测试（不碰生产服务端）

```bash
# 终端 1：mock 服务端（复用仓库根目录的 node_modules/ws）
cd .. && node macapp/test/mock-hub.js
# 支持 stdin 命令: job <repo> <pr> [branch] / azdo … / close … / repos / reject / upgrade [ver] / kill / quit
# 后台跑时可用 MOCK_HUB_CMD_FILE=/path/cmds 指定命令文件，echo "job mock/alpha 1" >> /path/cmds 驱动

# 终端 2：用隔离配置直接跑 app 二进制（继承环境变量）
LARK_REVIEW_CLIENT_CONFIG=/tmp/test-config.json \
LARK_REVIEW_CLIENT_LOG=/tmp/test-client.log \
LARK_REVIEW_CLIENT_REVIEW_LOG_DIR=/tmp/test-review-logs \
./build/LarkReviewClient.app/Contents/MacOS/LarkReviewClient
```

测试配置里把 `claudePath` 指向 `macapp/test/fake-claude.sh`（假 claude，读完 stdin 睡几秒吐 `___RESULT___` 行；`FAKE_CLAUDE_MODE=fail|noresult` 模拟失败）。

测**自更新**（不碰真 GitHub）：临时把版本改成 9.9.9 后 `make dmg` 造假新版包，用
`python3 -m http.server` 本地伺服，mock-hub 里 `upgrade 9.9.9` 下发推荐版本，启动 app 时加
`LARK_REVIEW_UPDATE_DMG_URL=http://127.0.0.1:8000/LarkReviewClient-v9.9.9.dmg` 覆盖下载地址
（该环境变量仅为测试钩子，正常启动不受影响）。

## 代码结构

```
Sources/LarkReviewClient/
├── LarkReviewApp.swift        # @main：MenuBarExtra + Settings + 日志窗口
├── AppRuntime.swift           # 组装层：各模块接线到 AppState
├── AppState.swift             # @Observable，UI 唯一数据源
├── Models/                    # Config / WS 消息（与 Node 版逐字段对齐）
├── Core/
│   ├── WebSocketClient.swift  # 注册/心跳/指数退避重连/halted 状态机
│   ├── ReviewCoordinator.swift# 串行队列：worktree → claude → 解析 → 上报
│   ├── WorktreeManager.swift  # git worktree 序列（复刻 Node ensureWorktree）
│   ├── ProcessRunner.swift    # 子进程（管道排空 / stdin / 登录 shell PATH）
│   └── …                      # 配置、日志、通知、登录项、hostname
└── UI/                        # 菜单栏弹板 / 设置三卡 / 日志双 tab
```

行为基准是仓库根目录的 `lark-review-client.js`——改协议时两边对照。

# 快速开始 (lark-review-client)

团队 PR Review 客户端: 在你自己电脑上跑你自己的 Claude, 由团队 Lark 机器人驱动。
有 PR 分配给你 review 时, 机器人派给你本机的 client, 自动跑 `claude /pr-review` 并以你的
GitHub 账号提交 review; 你不在线时则照常 @ 你人工催办。

> 字段详解、Azure DevOps 额外配置、菜单栏图标含义见 **README.md**。

## 0. 前置(本机先装好并登录)
- Node.js 18+
- git(能访问目标 repo 的 remote)
- gh(`gh auth login` 已登录, 有目标 repo 权限)—— review 用你的 GitHub 账号提交
- claude(`claude /login` 已登录, 账号对 reviewModel 有权限)

## 1. 克隆 + 装依赖
```bash
git clone https://github.com/TommyZhao888/lark-review-client.git
cd lark-review-client
npm install
```
> **一定用 `git clone`**(别手动下载 zip): 之后才能用「一键自动更新」。

## 2. 启动(会把配置网页拉起来)
```bash
./run-client.sh start
```
第一次还没配置也没关系 —— 会以「仅配置页」模式起来, 不报错退出。
日志出现 `配置页: http://127.0.0.1:8790` 即可。

## 3. 找管理员要接入信息
向管理员索取: **serverUrl**(生产为 `wss://review.ilaot.com`, 经 Cloudflare 隧道, **任意能上网的网络都可连, 不用和服务器同一内网**)+ 你的 **token**。

## 4. 打开网页配置
浏览器开 **http://127.0.0.1:8790** , 填:
- **serverUrl**、**token**(管理员给的)
- **claude 路径**(默认 `claude` 即可, 不行填 `which claude` 的绝对路径)
- **项目**: 先只填 serverUrl + token 保存, 连上后**下拉列表**会列出服务端受管项目, 选择添加并填
  该项目在你本机的 clone 目录(worktree 目录留空自动补 `<clone路径>-worktrees`)
- (可选) review 提示词, 留空用默认

点「保存并应用」→ 自动按新配置连接。**姓名 / open_id 不用填**, 连上后由服务端下发并只读显示。
状态变 `已连接 · 已注册` 即成功。

## 常用命令
```bash
./run-client.sh status    # 是否在跑 + 最近日志 + 连接状态
./run-client.sh logs      # 实时日志
./run-client.sh restart   # 重启(网页保存会自动热重载, 一般不用手动)
./run-client.sh stop      # 停止
```

## 5. 菜单栏常驻(可选, macOS 强烈推荐)
装 SwiftBar 后, 菜单栏常驻 🦁 图标, 一眼看到在线/在跑第几单/有没有新版本:
```bash
brew install --cask swiftbar        # 首次打开会让你选一个"插件目录"
ln -sf "$PWD/lionreview.5s.sh" "<SwiftBar 插件目录>/lionreview.5s.sh"
```
图标: 🦁🟢 在线待命 · 🦁⚡N 在跑 N 单 · 🦁🔴 离线/未注册 · 🦁⚪️ client 没起; 末尾 **🆙 = 有新版本**。
点开下拉能看正在 review 的 PR, 以及**「一键更新并重启」**。

## 6. 升级(有新版本时)
client 连上服务端时若版本偏低, 会在**配置页顶部**和**菜单栏**提醒 🆙, 任选其一点
**「一键更新并重启」** 即自动 `git pull` + `npm install` + 重启(几秒后自动重连), 无需手动。

万一自动更新失败(比如目录不是 git clone 来的), 会**直接显示手动步骤**:
```bash
cd lark-review-client
git pull && npm install --omit=dev && ./run-client.sh restart
```
你的配置在 `~/.lark-review-client.json`(仓库目录之外), 升级不会动它。

## 7. 开机自启(可选)
照 `com.larkbot.review-client.plist.example` 注释改路径, 放到 `~/Library/LaunchAgents/`
后 `launchctl load`(macOS)。不弄也行, 开机手动 `./run-client.sh start`。

## 排查
- 连不上: serverUrl 用 `wss://review.ilaot.com`、token 没填错、本机能正常上网; 管理员 hub 开着。`./run-client.sh logs` 看报错。
- `注册被拒: bad_token`(token 被管理员重置): 客户端不会退出, 直接开 http://127.0.0.1:8790 填新 token 保存即可(自动重连)。
- **执行中断网**: 会自动重连, 重连后结果照常提交(去重在服务端做), **不会重复 review**; 中途会在 Lark 线程说明已重连。
- review 失败: 日志看 `claude exited=...`; 多半是 claude 未登录 / 模型无权限 / gh 没该 repo 权限。
- 字段详解、菜单栏、Azure DevOps 见 README.md。

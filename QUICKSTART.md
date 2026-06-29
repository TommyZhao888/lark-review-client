# 快速开始 (lark-review-client)

团队 PR Review 客户端: 在你自己电脑上跑你自己的 Claude, 由团队 Lark 机器人驱动。
有 PR 分配给你 review 时, 机器人派给你本机的 client, 自动跑 `claude /pr-review` 并以你的
GitHub 账号提交 review; 你不在线时则照常 @ 你人工催办。

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

## 2. 启动(会把配置网页拉起来)
```bash
./run-client.sh start
```
第一次还没配置也没关系 —— 会以「仅配置页」模式起来, 不报错退出。
日志出现 `配置页: http://127.0.0.1:8790` 即可。

## 3. 找管理员要接入信息
向管理员索取: **serverUrl**(hub 地址, 需和管理员同一办公网)+ 你的 **token**。

## 4. 打开网页配置
浏览器开 **http://127.0.0.1:8790** , 填:
- **serverUrl**、**token**(管理员给的)
- **claude 路径**(默认 `claude` 即可, 不行填 `which claude` 的绝对路径)
- **项目**: `mainRepo` = 你本机 repo 的 clone 目录; `worktreeBase` = 一个放临时 worktree 的空目录
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

## 升级
```bash
git pull && npm install && ./run-client.sh restart
```
你的配置在 `~/.lark-review-client.json`(仓库目录之外), `git pull` 不会动它。

## 开机自启(可选)
照 `com.larkbot.review-client.plist.example` 注释改路径, 放到 `~/Library/LaunchAgents/`
后 `launchctl load`(macOS)。不弄也行, 开机手动 `./run-client.sh start`。

## 排查
- 连不上: 确认和管理员同一办公网; token/serverUrl 没填错; 管理员 hub 开着。`./run-client.sh logs` 看报错。
- review 失败: 日志看 `claude exited=...`; 多半是 claude 未登录 / 模型无权限 / gh 没该 repo 权限。
- 字段详解见 README.md。

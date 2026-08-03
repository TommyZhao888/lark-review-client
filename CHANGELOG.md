# 更新说明

## v1.9.2 — 2026-08-03

> 两件事:①「一键更新」不再被本地改动卡死(Node 版);②修复「查额度(/usage)」永远失败——日志把原因
> 猜成"claude 版本过旧",实际另有两种成因,且非 claude 引擎下每 10 分钟白烧一轮 token。

### 一键更新不再被本地改动卡死(仅 Node 版; macapp 走 dmg 替换,不受影响)

- **改过客户端源码的人也能一键更新了**。此前 `selfUpdate()` 只跑 `git pull --ff-only`:
  只要你本地改过的文件正好被这次更新改到(而每次发版都会动 `lark-review-client.js`),git 就拒绝执行,
  一键更新从此永久报错。现在按三条不变量处理:**更新永远推进** / **本地改动永不丢失** / **更新后一定能跑**。
- 流程:工作区脏 → 先 `git stash -u` 暂存,并把改动**落盘成补丁**
  `~/.lark-review-client/patches/local-<时间戳>.patch`(含 untracked 文件,可直接 `git apply --3way` 复用)
  → 快进到新版本 → `git stash pop` 还原。还原冲突时**不留冲突标记**(那会让 node 直接语法错误、客户端起不来),
  而是回到干净的新版本并在配置页显式告警:改动仍在补丁 + `git stash list` 两份备份里。
- **本地有未推送的提交**时不再糊里糊涂失败,而是明确中止(工作区一个字节不动)并给出 `git pull --rebase` 步骤。
  网络/远端问题(`fetch_failed`)、没有跟踪分支(`no_upstream`)也各自单独报,不再统一糊成 `pull_failed`。
- 顺带提醒:**跟本机环境相关的东西(claude 路径、token、repo 路径…)本来就在 `~/.lark-review-client.json`,
  不在仓库里、不受更新影响。需要改行为请优先提配置项,别改源码**——改源码的代价就是每次更新都要自己解冲突。

### 额度查询(`/usage`)

- **额度查询不再假定 `claudePath` 就是 Claude Code**。新增可选 `quotaClaudePath`(默认 = `claudePath`):
  `/usage` 是 Claude Code 独有的 slash command,把 `claudePath` 指向别的引擎(或转发到别的引擎的适配脚本)后,
  它会把 `"/usage"` 当**普通提问跑一整轮**,25s 超时被 SIGKILL → 输出为空、额度永远查不到,
  而且每 10 分钟白烧一次模型调用。把 `quotaClaudePath` 指向真 claude 即可,review 仍走 `claudePath`。
- **失败日志给真原因,不再瞎猜"claude 版本过旧"**。现在按失败形态分别打印:超时被终止 / 退出码 + stderr /
  无输出 / 输出里没有百分比行,并附输出片段与可执行文件路径(Node 起也开始收 stderr,以前是丢掉的)。
  实测另一种成因:claude **OAuth token 过期且刷新失败**(或额度接口被限流)时,`claude -p /usage` 会照常
  退出 0、只打印"用量构成"而**不带** `Current session: N% used` 行 —— 与版本新旧无关。
- **macapp 的 `/usage` 调用补上 25s 超时**(此前 `timeoutMs: 0` = 不限时):非 claude 引擎会把这条轮询挂死。
- 解析逻辑不变:claude 2.1.220 的 `Current session: N% used · resets …` / `Current week (all models): …`
  与现有正则完全匹配(已实测)。

## v1.9.1 — 2026-08-03

> Mac App 自更新的下载阶段看得见进度了。仅 UI/展示改动,协议与 review 执行逻辑零变化。

- **「更新并重启」下载 dmg 时显示进度条**:百分比 + 线性进度条 + 已下载/总大小(如 `12.3 MB / 29.4 MB`)。
  此前整个下载过程只有一个不定进度的小转圈,几十 MB 的包在慢网下容易被当成卡死,进而反复点或
  直接退出 App 打断更新。其余阶段(查询版本 / 解包 / 安装 / 替换 / 重启)没有可算的分母,仍是小转圈 + 阶段文案。
- 运行日志新增两行事实记录:`安装包大小 …，开始下载` / `安装包下载完成 …`,事后排查下载慢/断在哪一步有据可查。
- 实现说明:进度依赖挂在 session 上的 `URLSessionDownloadDelegate`——实测 `download(from:delegate:)`
  的 per-task delegate 收不到 `didWriteData`(下载能成功但一次进度都不报),改回那个便捷 API 前请先验证进度还在。
- Node 版仅同步版本号(自更新是 `git pull + npm install`,无下载进度可言),代码未变。

## v1.9.0 — 2026-07-31

> 配合服务端"加权评分选人"改造:补充两类上报信号,让派单更公平、更透明。双端(Node + macapp)对齐。

- **额度上报补 7 天窗百分比**。此前只上报 5 小时窗已用%(`five_hour_pct`),7 天窗百分比虽已解析
  但只在超阈值时拼进 `reason` 字符串。现将 `seven_day_pct`/`seven_day_reset_at` 作为独立字段透出,
  供服务端选人时按额度余量连续降权(取 5h/7d 已用%较大者),而非只在耗尽时硬排除。
- **上报 24h 内 ws 重连次数**(`ws_reconnects_24h`,随 register/quota 消息)。作为网络稳定性弱信号,
  供服务端评分选人对频繁掉线者轻度降权。进程重启后计数从 0 起算(视为中性)。
- 纯增量:旧服务端忽略未知字段;本版不改任何 review 执行逻辑。升级后无新增权限、无行为变化,
  仅让服务端管理页的派单顺位表能显示你的额度余量/网络状况。

## v1.8.2 — 2026-07-23

> 紧急修复(仅 macapp):review 已完成、结果已发 GitHub,任务却永远显示"进行中",终止无效、后续任务全部排队卡死。

- **修复 `waitUntilExit` 永久悬挂导致任务不收尾**。claude 正常退出(结果已提交 GitHub)后,
  macOS Foundation 的 NSTask **终止通知偶发丢失**(mach 通知竞态/子进程被别处 reap):进程早已消失,
  `waitUntilExit` 却永远挂在 `mach_msg` —— 任务不上报、`busy` 不复位、队列全堵,点「终止」也无效
  (进程已死,terminate 是 no-op)。实测 2026-07-23 PR #636:review 已 APPROVE 到 GitHub,任务挂 20+ 分钟
  (`sample` 线程栈证实挂点)。与 v1.8.1 修的管道排空卡死是**两个不同层**的问题。
- **修法**:等退出改为双通道竞速 —— 正常 `waitUntilExit` 拿精确退出码;另起 `kill(pid,0)` 轮询兜底,
  发现进程已消失而通道1未醒,宽限 2s 后强制收尾(退出码不可得按 0 + stderr 注记;verdict 判定以
  stdout 结果行为准,不受影响)。正常路径行为与退出码完全不变。
- Node 客户端走 libuv 事件驱动,无此问题,本版仅同步版本号。

## v1.8.1 — 2026-07-13

> 紧急修复:review 任务卡死不收尾 / 点「终止」后卡在"终止中"。双端(Node + macapp)对齐。

- **修复 review 结束后任务永不收尾、以及点「终止」后按钮永久卡在"终止中"**。
  根因同一个:claude 派生的子进程(常见于 `~/.claude` 里配置的 MCP server)在 claude 主进程退出后
  **仍存活并占着 stdout/stderr 管道写端**,导致客户端排空输出时**永远等不到 EOF**——
  `ProcessRunner.run`(macapp)/ `run()`(Node)因此永久阻塞:任务不上报、队列不推进、
  `cancelling` 状态不复位,即使超时 SIGKILL 了 claude 也照样卡(残留子孙仍占管道)。
- **修法**:主进程退出后给管道排空一个 **3s 宽限**,到点仍未 EOF 就**强制关闭读端 / 销毁流**解除阻塞。
  主进程的输出在它退出前都已收妥,丢弃的只是残留子孙的无关输出。正常结束/超时/手动终止**都能及时收尾**。
- 新增回归测试:子进程泄漏管道时 `run` 仍在宽限内返回;终止带泄漏子进程的任务不再卡死。

## v1.8.0 — 2026-07-13

> 本版全部改动 **Node 客户端与原生 Mac App 完全对齐**。

### 可观测性与任务控制

- **claude 运行过程实时可见**：review 的 claude 调用改用 `--output-format stream-json --verbose`，
  边跑边把 claude 正在做什么喂进「运行日志」——`🔧 Bash gh pr diff …` / `🔧 Read app/x.ts` /
  `💬 助手文字摘要`。末尾 `result` 事件仍带最终结论 + token 用量(与旧 `json` 信封同字段，解析复用)。
  老版 claude(< 2.1.205)不支持 stream-json 时**自动回退** `--output-format json` 并记住(能力探测)。
- **查看日志按钮(Mac App)**：菜单栏「正在 Review」区新增「查看日志」直达按钮，一键打开日志窗口看实时进度。
- **运行心跳**：claude 长时间无事件(思考中)时「运行日志」每 30s 仍打一条 `review 进行中… 已 Ns` 兜底。
- **Review 超时**：单次 claude 执行超过阈值自动终止(先 SIGTERM，宽限 8s 再 SIGKILL)，按失败上报交
  服务端改派，避免卡死占住队列。默认 **30 分钟**，可在设置/配置页按分钟调整，**0 = 不限时**(旧行为)。
- **手动终止(Mac App)**：菜单栏「正在 Review」区新增「终止当前 Review」按钮，一键结束卡住的任务并释放队列。
- 超时/手动终止都会在 review 日志正文顶部标注并照常写盘 + 上报(解决"卡死 → 永远等不到日志")。

### 项目参与：服务端清单为权威

- 本机 `repos` 里残留的、**服务端未受管**的项目(历史示例/旧配置遗留)**不再被上报给服务端、也不会被派单**。
  有服务端清单时：`autoRepos` → 参与全部受管项目；关掉 → 参与"受管 ∩ 本机配置"。本机配置仅用于覆盖路径/提示词。
  无清单时(旧服务端/尚未收到)回退旧行为以兼容手动配置。
- Mac App 设置的「项目」页按「服务端受管 · 会参与派单」与「本地遗留 · 未受管」分区展示，未受管项可一键移除。

### 修复：Azure DevOps 结果提交

- ADO 单执行时把 `AZURE_DEVOPS_EXT_PAT` 注入 claude 子进程环境(Mac App 经登录 shell 解析，Node 从进程环境
  归一化，并把旧变量名 `AZDO_PAT` 一并映射)，让 `/pr-review-azdo` 能向 ADO 提交评论/投票。
  此前 GUI app 从登录项启动拿不到 shell 变量，ADO 提交因无凭证而失败。

## v1.7.0 — 2026-07-12

> 本版 **Node 客户端与原生 Mac App 功能完全对齐**：以下全部特性双端一致
> （自动参与/自动 clone、两级提示词、结果行契约、token 用量统计、断线可靠投递）。

### 新功能：项目零配置（自动参与 + 自动 clone）

- **自动参与服务端项目**：服务端下发的受管项目自动参与，不再需要逐个「添加项目 + 填路径」。
  首次安装只填 `serverUrl` + `token` 即可接单。不想全量参与可在配置页关掉「自动参与」开关。
- **自动 clone**：未配置本机路径的项目，在第一次被派到 review 时自动 clone 到
  **默认克隆根目录**（默认 `~/LarkReviewRepos/<owner-repo>`，配置页可改），worktree 自动放在
  旁边的 `…-worktrees`。
  - GitHub 项目走 `gh` 用你已登录的凭证 clone；
  - Azure DevOps 项目从派单的 PR 地址推导远端，优先用 `AZURE_DEVOPS_EXT_PAT`（az 同款 PAT，
    本就是 ADO 参与者的前置要求）认证，并写入该 repo 的 `http.extraheader`，后续 fetch 免交互——
    同时避开本机 keychain 中残留坏凭证导致的 clone 恒失败。
- **手动配置完全兼容**：某项目填了 `mainRepo` 就用你指定的路径（行为与旧版一致）；
  `worktreeBase` 留空 = `mainRepo + "-worktrees"`。每个项目仍可单独覆盖路径与提示词。
- **提示词两级配置**：新增**全局 Review 提示词**（对所有项目生效），单项目提示词优先。
  完整优先级：单项目 > 全局 > 服务端该项目默认 > 内置默认模板。提示词不预设，请按团队约定
  在配置页自行填写。

### 新功能：Review token 用量统计

- 每次 review 执行改用 `claude --output-format json`，从返回信封中取 **token 用量与成本**
  （input/output/cache tokens、`total_cost_usd`、耗时、轮数）。老版 claude 不支持 json 输出时
  自动回退纯文本，review 照常执行、仅无统计。
- **本机展示**：配置页顶部显示今日/累计用量；每条 review 日志头部带 tokens/cost；
  完成通知附带用量。逐条明细在 `~/.lark-review-client-logs/usage.jsonl`。
- **上报服务端**：用量随 review 结果上报 hub，服务端逐条记入 `state/review-usage.jsonl`
  （含人员/repo/PR/轮次），供后续做用量统计与任务分派平衡。

### 可靠性：自定义提示词也能拿到确定的 review 结论

- 服务端解析结论依赖输出末尾的结果行（`___RESULT___ verdict=…`），此前该约定只存在于内置
  模板——成员自定义提示词（全局/单项目）一旦没带它，review 明明执行了却会被判「未完成」。
- 现在客户端在渲染完提示词后，若检测到其中没有结果行约定，会在**末尾追加**一段独立标注的
  格式契约（明确声明**不改变、不覆盖上方任何 review 要求**，仅约定最终输出一行结论）；
  提示词已含约定（如内置模板）则不重复附加。**用户提示词本体永远不被修改。**
- 即使模型仍未按契约输出，结果上报本身也不会失败（exit code、完整输出尾部、token 用量
  照常上报），只是结论按「未完成」处理、可重试。

### 可靠性：review 结果(含用量)断线不丢

- 此前结果发送是尽力而为：review 恰好在断线窗口内完成时会被静默丢弃，hub 只能 20 分钟超时
  判失败再改派（白跑一轮）。现改为**至少一次投递**：结果先落磁盘 pending 队列再发送，
  重连注册成功后自动补投，收到 hub 回执（`review_result_ack`）才删除——跨断线、
  跨客户端进程重启都不丢；hub 侧幂等，重复投递不会重复处理。
- 需配套 hub 升级（回执 + 用量记账）；旧 hub 不回执时，队列条目 24h 自动过期，不影响使用。

### 说明：偶发的 macOS 权限弹窗（媒体库 / 文件夹访问等）

部分成员遇到过客户端运行期间 macOS 无缘由弹出权限请求（如「访问 Apple Music / 媒体库」
「访问桌面/文稿/下载文件夹」）。排查结论：

- 弹窗**不是本客户端直接请求的**，而是客户端周期性调用 `claude`（每 10 分钟查一次额度
  `claude -p /usage`，以及执行 review）时，claude 进程自身在 macOS 上触发的 TCC 权限探测，
  被系统归因到调用它的 App/终端上。
- 这是 **claude-code 的上游已知问题**：
  - [anthropics/claude-code#41297](https://github.com/anthropics/claude-code/issues/41297)
    —— claude 每次更新后 TCC 弹窗会重新出现，且会请求无关的 Apple Music 权限（已修复关闭）；
  - [anthropics/claude-code#61233](https://github.com/anthropics/claude-code/issues/61233)
    —— 无明显触发动作时请求桌面/文稿/下载/iCloud Drive 访问（仍在跟进中）。
- 客户端侧已做缓解：额度查询等 headless 调用带 `--dangerously-skip-permissions` 跳过
  claude 的沙盒/权限初始化，减少触发面。
- **遇到弹窗怎么办**：允许或拒绝都不影响 review 功能（review 只需要 git/gh/claude 的常规
  文件访问）；claude 升级后若再次弹属于上游 #41297 描述的已知行为，处理一次即可。

## v1.6.1 及更早

见 git 提交历史（`git log --oneline`）。

# 更新说明

## v1.7.0 — 2026-07-12

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

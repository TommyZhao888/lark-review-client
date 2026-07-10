# lark-review-client — 项目约定（给 Claude 及协作者）

团队 PR Review 客户端，跑在成员本机、连各自的 Claude，由团队 Lark 机器人（服务端仓库
`LarkBot`）驱动派单。本仓库含**两种对等形态**：

- **Node 版**：`lark-review-client.js` + `run-client.sh` + `config-page.html`（浏览器配置页）。
- **原生 Mac App**：`macapp/`（SwiftUI 菜单栏 app）。成员用 **Homebrew Cask** 安装
  （cask 文件在本仓库 `Casks/`，本仓库即 tap）；开发者 `make bundle` 本地编译。

两者**协议与行为逐字段对等**，共用同一份配置（`~/.lark-review-client.json`）与日志路径，
同一时间只跑一个。改协议/消息结构时两边必须对照改。

## 铁律

### 1. 改了客户端代码、提交后，必须打新版本 tag

服务端（`LarkBot` 的 review-hub）用 `git ls-remote --tags` 读本仓库的 tag 列表（每 15min 刷新），
作为「推荐客户端版本」的候选：管理页可选「跟随最新（自动 = 最新 tag）」或固定某个 tag。
**没打 tag，服务端就看不到新版本、成员不会收到升级提示——发版等于没发。** 所以：

> 注：这是**提示性**的版本管理（自动同步/可选跟随最新），**不是防篡改**——客户端自报版本仍可被本地改，
> 硬件证明（App Attest）在 macOS 不可用故做不到，也无需做（成员伪报只自损）。

- 每次改动客户端行为 → **bump 版本号 → 提交 → 打 `vX.Y.Z` tag 并 push tag**：
  ```bash
  git commit -am "..."           # 先提交代码
  git tag -a vX.Y.Z -m "..."     # 语义化版本
  git push origin main && git push origin vX.Y.Z
  ```
- 版本号有**四处，必须同步**（Node 与 macapp 版本保持一致）：
  - Node：`lark-review-client.js` 顶部 `CLIENT_VERSION` + `package.json` 的 `version`
  - macapp：`macapp/Sources/LarkReviewClient/Models/Config.swift` 的 `CLIENT_VERSION`
    + `macapp/Resources/Info.plist` 的 `CFBundleShortVersionString`/`CFBundleVersion`
- 第 **5** 处是 `Casks/lark-review-client.rb` 的 `version`/`sha256`，但它**由 CI 维护，禁止手工 bump**
  （tag push 后 release.yml 的 bump-cask job 自动改并推 main；手改会和 CI 撞。只有改 cask 其余
  stanza 结构时才手动编辑该文件）。
- 版本步进：改行为/修 bug → patch 或 minor；破坏协议兼容 → 至少 minor，并同步服务端。
- **纯文档改动**（README/QUICKSTART 等，不动代码/协议）**不需** bump/tag。
- **push tag 后的确认清单**：Actions 里该 tag 的 `build-dmg` + `bump-cask` 两个 job 全绿；
  Releases 页 `LarkReviewClient-vX.Y.Z.dmg` 存在；main 上出现 `chore(cask): bump …` 提交。
  **dmg asset 是 mac app 自更新的供给侧——asset 缺失，成员的自动更新会 404。**
- **发版后、下次开发前必须 `git pull`**：CI 会往 main 追加 cask bump 提交，本地 main 必然落后一格。

> 没打 tag，服务端就看不到新版本，成员不会收到升级提示——发版等于没发。

### 2. 提交推送前，先在本地把改动完整测试通过

- Node 版：`node --check lark-review-client.js`；能跑就 `./run-client.sh fg` 连 mock 或真实 hub 验证。
- Mac App：`cd macapp && swift build && swift test`（40+ 单测覆盖协议编解码/配置/模板/自更新）；
  必要时 `make bundle && make run` 手动验证 UI/交互。行为基准是根目录 `lark-review-client.js`。
- 端到端（不碰生产）：`node macapp/test/mock-hub.js` 起假 hub + `macapp/test/fake-claude.sh` 假 claude；
  测自更新用 `LARK_REVIEW_UPDATE_DMG_URL` 指向本地假 dmg。见 `macapp/README.md`。
- 改了 `Casks/lark-review-client.rb` 的 stanza（非 version/sha）：`brew style --cask` 校验
  （需在 tap 里跑，见 git 历史里的做法或临时 tap 本仓库）。
- 跑通、行为符合预期后再 `git commit` + `push`（+ tag）。

## 相关

- 服务端 / 部署 / 派单逻辑在 `LarkBot` 仓库（其 CLAUDE.md 有对应约定）。
- 客户端自更新（macapp）：菜单栏「更新并重启」= 从 GitHub Releases 下载推荐版本 dmg →
  校验（bundle id/版本/架构/签名）→ 原地替换自己 → 重启，**任意安装位置可用**；
  设置里可开「空闲时自动更新」。见 `macapp/README.md`。

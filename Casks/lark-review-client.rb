# 团队 Homebrew Cask（tap = 本仓库）。安装：
#   brew tap tommyzhao888/lark-review-client https://github.com/TommyZhao888/lark-review-client.git
#   brew install --cask lark-review-client
# version / sha256 由 CI 在每次发版后自动 bump（.github/workflows/release.yml 的 bump-cask job），
# 请勿手工改这两行；其余 stanza 才是人工维护的。
cask "lark-review-client" do
  version "1.8.0"
  sha256 "4751f6d8f78dfa76f4640d8fa7f595cd0799bc2e9412136eee45cf095f8247e0"

  url "https://github.com/TommyZhao888/lark-review-client/releases/download/v#{version}/LarkReviewClient-v#{version}.dmg"
  name "LarkReviewClient"
  desc "Team PR review client for Lark bot (menu bar app)"
  homepage "https://github.com/TommyZhao888/lark-review-client"

  livecheck do
    url :url
    strategy :github_latest
  end

  # app 自带从 GitHub Releases 下载 dmg 的自更新, 普通 brew upgrade 默认跳过本 cask
  auto_updates true
  depends_on macos: :sonoma        # 最低 macOS 14(Package.swift .macOS(.v14))
  depends_on arch: :arm64          # CI 产物为 Apple Silicon 单架构

  app "LarkReviewClient.app"

  # ad-hoc 签名、未公证: Homebrew 会给下载物打 com.apple.quarantine 并传播到 app,
  # macOS 15 起无「右键打开」旁路。自有 tap 装完即剥离, 成员免手动 xattr。
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/LarkReviewClient.app"]
  end

  uninstall quit: "com.larkbot.review-client-app"

  zap trash: [
    "~/.lark-review-client-logs",
    "~/.lark-review-client.json",
    "~/.lark-review-client.log",
  ]

  caveats <<~EOS
    团队内部工具, ad-hoc 签名(未公证), 安装时已自动移除 quarantine, 可直接打开。
    配置位于 ~/.lark-review-client.json; brew uninstall 不会删它(--zap 才会)。
    升级以 app 菜单栏自更新为主; brew 侧对齐用:
      brew upgrade --cask --greedy-auto-updates lark-review-client
  EOS
end

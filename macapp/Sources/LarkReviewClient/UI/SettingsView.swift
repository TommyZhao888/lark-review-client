import SwiftUI

/// 设置窗口：连接 / 本机环境 / 项目 三个 tab。
/// 编辑的是草稿副本，「保存并应用」时校验 → 落盘 → 热重载重连。
struct SettingsView: View {
    @Environment(AppState.self) private var state

    @State private var draft = Config()
    @State private var loaded = false
    @State private var saveError: String?
    @State private var saveOK = false

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                connectionTab
                    .tabItem { Label("连接", systemImage: "network") }
                environmentTab
                    .tabItem { Label("本机环境", systemImage: "gearshape") }
                ReposTab(draft: $draft)
                    .tabItem { Label("项目", systemImage: "folder") }
            }
            footer
        }
        .frame(width: 620, height: 520)
        .onAppear {
            if !loaded {
                draft = state.config
                loaded = true
            }
        }
    }

    // ---------- 连接 ----------

    private var connectionTab: some View {
        Form {
            Section {
                TextField("服务器地址", text: $draft.serverUrl, prompt: Text("wss://review.ilaot.com"))
                    .autocorrectionDisabled()
                SecureField("Token", text: $draft.token)
                Text("token 向管理员索取；身份（姓名 / open_id）由服务端按 token 下发，不在本地配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("当前身份（服务端下发，只读）") {
                LabeledContent("状态", value: state.connectionLabel)
                if let id = state.identity {
                    LabeledContent("姓名", value: id.name)
                    LabeledContent("open_id", value: id.openId)
                } else {
                    Text("尚未注册")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("客户端版本", value: "v\(CLIENT_VERSION)" +
                    (state.identity?.recommendedVersion.map { "（服务端推荐 v\($0)）" } ?? ""))
            }
        }
        .formStyle(.grouped)
    }

    // ---------- 本机环境 ----------

    private var environmentTab: some View {
        Form {
            Section("Claude") {
                TextField("claude 路径", text: $draft.claudePath, prompt: Text("claude"))
                claudePathStatus
                TextField("review 模型", text: $draft.reviewModel, prompt: Text("claude-opus-4-8"))
            }
            Section("运行") {
                TextField("心跳间隔 (ms)", value: $draft.heartbeatMs, format: .number)
                TextField("worktree / 日志保留天数", value: $draft.worktreeMaxAgeDays, format: .number)
            }
            Section("通知") {
                Toggle("桌面通知", isOn: $draft.notify)
                TextField("通知声音（留空默认）", text: $draft.notifySound, prompt: Text("如 Glass"))
            }
            Section("开机自启") {
                LoginItemToggle()
            }
            Section("更新") {
                Toggle("空闲时自动更新", isOn: $draft.autoUpdate)
                Text("连上服务端、且当前无 review 在跑/排队时，检测到新版本自动 git pull + 重新编译 + 重启。关闭则仅提示，手动在菜单栏点「更新并重启」。仅对 git clone 源码安装生效；下载(dmg)安装的版本请到 Releases 下新包（菜单栏会显示「前往下载新版」）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("客户端版本", value: "v\(CLIENT_VERSION)")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var claudePathStatus: some View {
        let resolved = ProcessRunner.resolveExecutable(draft.claudePath.isEmpty ? "claude" : draft.claudePath)
        if let resolved {
            Label("找到 claude @ \(resolved)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("未找到该命令，请检查路径或先安装 claude CLI", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // ---------- 底部保存 ----------

    private var footer: some View {
        HStack {
            if let err = saveError {
                Label(err, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if saveOK {
                Label("已保存并按新配置重连", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("放弃修改") {
                draft = state.config
                saveError = nil
                saveOK = false
            }
            Button("保存并应用") {
                saveError = AppRuntime.shared.saveConfig(draft)
                saveOK = saveError == nil
                if saveOK { draft = state.config }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(.bar)
    }
}

/// 开机自启 Toggle（SMAppService）。
private struct LoginItemToggle: View {
    @State private var enabled = LoginItemManager.isEnabled
    @State private var error: String?

    var body: some View {
        Toggle("登录时启动", isOn: $enabled)
            .onChange(of: enabled) { _, newValue in
                error = LoginItemManager.setEnabled(newValue)
                enabled = LoginItemManager.isEnabled
            }
        Text(error ?? LoginItemManager.statusText)
            .font(.caption)
            .foregroundStyle(error == nil ? Color.secondary : .red)
    }
}

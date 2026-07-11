import SwiftUI
import AppKit

/// 项目 tab：从服务端受管清单添加 repo，编辑本机路径与可选 prompt 覆盖。
struct ReposTab: View {
    @Environment(AppState.self) private var state
    @Binding var draft: Config

    @State private var manualRepoName = ""

    private var managedNames: Set<String> { Set(state.managedRepos.map(\.repo)) }
    /// 展示列表 = 受管项目全部常驻(autoRepos 下自动参与, 全空 = 全自动) + 本地多配的非受管项目。
    private var displayNames: [String] {
        var names = managedNames
        names.formUnion(draft.repos.keys)
        return names.sorted()
    }

    var body: some View {
        Form {
            Section {
                Toggle("自动参与服务端下发的全部项目（路径留空的项目首次派单时自动 clone 到默认目录）",
                       isOn: $draft.autoRepos)
                Text("清单由管理员在服务端配置并下发；实际是否派单给你由服务端候选池决定。每个项目的路径和提示词都可留空：路径留空 = 自动 clone 到默认克隆根目录；填了路径 = 用你指定的本机 clone（与旧版行为一致）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.managedRepos.isEmpty {
                    Text(state.isRegistered
                         ? "服务端暂无受管项目"
                         : "连上服务端后这里会显示可参与的项目清单")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // 旧服务端兼容：手动添加 owner/repo
                HStack {
                    TextField("手动添加（owner/repo）", text: $manualRepoName)
                        .autocorrectionDisabled()
                    Button("添加") {
                        let name = manualRepoName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, draft.repos[name] == nil else { return }
                        draft.repos[name] = RepoConfig()
                        manualRepoName = ""
                    }
                    .disabled(manualRepoName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            ForEach(displayNames, id: \.self) { name in
                Section {
                    RepoEditor(
                        name: name,
                        managed: state.managedRepos.first { $0.repo == name },
                        isManaged: managedNames.isEmpty || managedNames.contains(name),
                        autoPath: draft.resolveRepo(name).mainRepo,
                        repo: bindingFor(name),
                        onRemove: { draft.repos.removeValue(forKey: name) }
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private func bindingFor(_ name: String) -> Binding<RepoConfig> {
        Binding(
            get: { draft.repos[name] ?? RepoConfig() },
            set: { newValue in
                // 受管项目三项全空 = 全自动, 不落草稿(保存时也不落盘); 非受管保留占位以维持参与。
                if newValue.isEmpty, managedNames.contains(name) {
                    draft.repos.removeValue(forKey: name)
                } else {
                    draft.repos[name] = newValue
                }
            }
        )
    }
}

private struct RepoEditor: View {
    let name: String
    let managed: ManagedRepo?
    let isManaged: Bool
    let autoPath: String
    @Binding var repo: RepoConfig
    let onRemove: () -> Void

    @State private var showPrompt = false

    var body: some View {
        HStack {
            Text(name).font(.headline)
            if let managed {
                Text(managed.provider == "azdo" ? "服务端受管 · Azure DevOps" : "服务端受管 · GitHub")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.green.opacity(0.15), in: Capsule())
            } else if !isManaged {
                Text("⚠ 未受管，不会被派单")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
            }
            Spacer()
            if managed == nil || !repo.isEmpty {
                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(managed == nil ? "删除该项目" : "清除本机覆盖（回到全自动）")
            }
        }

        HStack {
            TextField("本机主仓路径 (mainRepo)，留空 = 自动", text: $repo.mainRepo,
                      prompt: Text("留空 = " + autoPath))
                .autocorrectionDisabled()
            Button("选择…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    repo.mainRepo = url.path
                }
            }
        }
        TextField("worktree 根目录（留空自动用 <mainRepo>-worktrees）",
                  text: $repo.worktreeBase,
                  prompt: Text("留空自动补全"))
            .autocorrectionDisabled()

        DisclosureGroup("本机提示词覆盖（可选）", isExpanded: $showPrompt) {
            TextEditor(text: Binding(
                get: { repo.prompt ?? "" },
                set: { repo.prompt = $0.isEmpty ? nil : $0 }
            ))
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 120)
            HStack {
                if let serverPrompt = managed?.prompt, !serverPrompt.isEmpty {
                    Button("填入服务端默认以编辑") { repo.prompt = serverPrompt }
                }
                Button("填入内置默认以编辑") {
                    repo.prompt = managed?.provider == "azdo" ? DEFAULT_PROMPT_TEMPLATE_AZDO : DEFAULT_PROMPT_TEMPLATE
                }
                Button("清空（用默认）") { repo.prompt = nil }
                Spacer()
            }
            .font(.caption)
        }
    }
}

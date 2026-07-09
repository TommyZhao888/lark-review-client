import SwiftUI
import AppKit

/// 项目 tab：从服务端受管清单添加 repo，编辑本机路径与可选 prompt 覆盖。
struct ReposTab: View {
    @Environment(AppState.self) private var state
    @Binding var draft: Config

    @State private var manualRepoName = ""

    private var managedNames: Set<String> { Set(state.managedRepos.map(\.repo)) }
    private var addableRepos: [ManagedRepo] {
        state.managedRepos.filter { draft.repos[$0.repo] == nil }
    }

    var body: some View {
        Form {
            Section {
                if state.managedRepos.isEmpty {
                    Text(state.isRegistered
                         ? "服务端暂无受管项目"
                         : "连上服务端后这里会显示可参与的项目清单")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !addableRepos.isEmpty {
                    Menu("＋ 从服务端清单添加项目") {
                        ForEach(addableRepos) { r in
                            Button("\(r.repo)\(r.provider == "azdo" ? "  (Azure DevOps)" : "")") {
                                draft.repos[r.repo] = RepoConfig(mainRepo: "", worktreeBase: "")
                            }
                        }
                    }
                }
                // 旧服务端兼容：手动添加 owner/repo
                HStack {
                    TextField("手动添加（owner/repo）", text: $manualRepoName)
                        .autocorrectionDisabled()
                    Button("添加") {
                        let name = manualRepoName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, draft.repos[name] == nil else { return }
                        draft.repos[name] = RepoConfig(mainRepo: "", worktreeBase: "")
                        manualRepoName = ""
                    }
                    .disabled(manualRepoName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            ForEach(draft.repos.keys.sorted(), id: \.self) { name in
                Section {
                    RepoEditor(
                        name: name,
                        managed: state.managedRepos.first { $0.repo == name },
                        isManaged: managedNames.isEmpty || managedNames.contains(name),
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
            get: { draft.repos[name] ?? RepoConfig(mainRepo: "", worktreeBase: "") },
            set: { draft.repos[name] = $0 }
        )
    }
}

private struct RepoEditor: View {
    let name: String
    let managed: ManagedRepo?
    let isManaged: Bool
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
            Button(role: .destructive) { onRemove() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }

        HStack {
            TextField("本机主仓路径 (mainRepo)", text: $repo.mainRepo, prompt: Text("/Users/you/code/repo"))
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
                  prompt: Text(repo.mainRepo.isEmpty ? "留空自动补全" : repo.mainRepo + "-worktrees"))
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

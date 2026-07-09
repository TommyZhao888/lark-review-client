import Foundation

// ---------- 默认 review prompt 模板（原文照搬 Node 版，与服务端原 worker.sh 一致）----------
// 可按项目用 repos[].prompt 覆盖；支持占位符 {{PR_NUM}} {{WORKTREE_PATH}} {{CI_STATUS}} {{PR_URL}} {{REPO}}。

let DEFAULT_PROMPT_TEMPLATE = """
Run /pr-review {{PR_NUM}} fully autonomously and submit the result yourself.

HARD REQUIREMENTS:
1. Do NOT wait for CI. Give your review verdict NOW, based purely on reading the code and local verification. Never poll, watch, or block on CI under any circumstance. CI status is context only -- you may mention a failing check in the General Comment, but it must never delay or replace your verdict. Current CI status: {{CI_STATUS}}.
2. Submit the review YOURSELF, without asking. The user has pre-approved all submissions -- post the inline comments, the General Comment, and the review verdict directly to GitHub. Do NOT ask for confirmation at any step.

The worktree already exists at {{WORKTREE_PATH}}; skip Step 0 (worktree creation) and Step 5 (worktree cleanup).

IMPORTANT: this is a one-shot headless run. The process terminates the moment you stop producing output, so NEVER suspend, schedule background monitors, or promise to continue later -- any such follow-up will never run.

After completing, output a single final line in this exact format:
___RESULT___ verdict=<APPROVE|COMMENT|REQUEST_CHANGES> general_comment_url=<url-or-NONE> inline_count=<integer>
"""

let DEFAULT_PROMPT_TEMPLATE_AZDO = """
Run /pr-review-azdo {{PR_NUM}} fully autonomously and submit the result yourself.

The pull request lives on Azure DevOps: {{PR_URL}} (repo {{REPO}}).

HARD REQUIREMENTS:
1. Do NOT wait for CI. Give your review verdict NOW, based purely on reading the code and local verification. Never poll, watch, or block on CI under any circumstance. CI status is context only -- you may mention a failing check in the General Comment, but it must never delay or replace your verdict. Current CI status: {{CI_STATUS}}.
2. Submit the review YOURSELF, without asking. The user has pre-approved all submissions -- post the inline comment threads, the General Comment thread, and set your vote directly on the Azure DevOps pull request. Do NOT ask for confirmation at any step.

The worktree already exists at {{WORKTREE_PATH}}; skip worktree creation and cleanup steps.

IMPORTANT: this is a one-shot headless run. The process terminates the moment you stop producing output, so NEVER suspend, schedule background monitors, or promise to continue later -- any such follow-up will never run.

After completing, output a single final line in this exact format:
___RESULT___ verdict=<APPROVE|COMMENT|REQUEST_CHANGES> general_comment_url=<url-or-NONE> inline_count=<integer>
"""

/// 提示词优先级: 该项目的本机提示词(repos[].prompt) >
/// 服务端该 repo 默认(review_job.prompt_template 下发) > 按 provider 选内置默认模板。
func renderPrompt(job: ReviewJob, worktreePath: String, ciStatus: String, repoTemplate: String?) -> String {
    let builtin = job.provider == "azdo" ? DEFAULT_PROMPT_TEMPLATE_AZDO : DEFAULT_PROMPT_TEMPLATE
    let tmpl: String
    if let t = repoTemplate, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        tmpl = t
    } else if let t = job.prompt_template, !t.isEmpty {
        tmpl = t
    } else {
        tmpl = builtin
    }
    return tmpl
        .replacingOccurrences(of: "{{PR_NUM}}", with: String(job.pr_num))
        .replacingOccurrences(of: "{{WORKTREE_PATH}}", with: worktreePath)
        .replacingOccurrences(of: "{{CI_STATUS}}", with: ciStatus)
        .replacingOccurrences(of: "{{PR_URL}}", with: job.pr_url ?? "")
        .replacingOccurrences(of: "{{REPO}}", with: job.repo)
}

/// 组装 CI 状态串：有失败 check 名时拼 "<overall>; failed checks: <names>"。
func ciStatusString(overall: String?, failedNames: String?) -> String {
    if let names = failedNames, !names.isEmpty {
        return "\(overall ?? ""); failed checks: \(names)"
    }
    return overall ?? ""
}

// ---------- 结果行解析 ----------

/// 从 claude 输出解析最后一个 ___RESULT___ 行（对齐 Node 的 RESULT_RE，取最后一次匹配）。
func parseResultLine(_ logText: String) -> (resultLine: String, verdict: String, generalCommentUrl: String, inlineCount: String) {
    let pattern = #"___RESULT___ verdict=([A-Z_]+) general_comment_url=(\S+) inline_count=([0-9]+)"#
    guard let re = try? NSRegularExpression(pattern: pattern) else {
        return ("", "", "", "?")
    }
    let ns = logText as NSString
    let matches = re.matches(in: logText, range: NSRange(location: 0, length: ns.length))
    guard let last = matches.last else { return ("", "", "", "?") }
    return (
        ns.substring(with: last.range(at: 0)),
        ns.substring(with: last.range(at: 1)),
        ns.substring(with: last.range(at: 2)),
        ns.substring(with: last.range(at: 3))
    )
}

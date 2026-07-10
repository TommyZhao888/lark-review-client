#!/usr/bin/env bash
# statusline-quota.sh -- Claude Code statusline 命令, 顺便把 rate_limits 额度快照落盘,
# 供 lark-review-client 前瞻式判断"额度快用完就别派我 review"。
#
# 背景: Claude Code 只在【交互】会话里把 rate_limits(5小时/7天 已用% + 重置时间)通过 stdin
# 传给 statusline 命令; headless(--print, review client 跑的)拿不到。所以把它做成 statusline,
# 你平时交互用 Claude 时就会刷新快照; 限额是账号级的, 该快照同样反映 review client 的消耗。
#
# 用法(在 ~/.claude/settings.json 里设为 statusLine 命令):
#   {
#     "statusLine": { "type": "command", "command": "bash ~/.lark-pr-bot-client/statusline-quota.sh" }
#   }
# 然后在 ~/.lark-review-client.json 里设:
#   { "quotaSnapshotPath": "~/.claude/lark-quota.json" }
#
# 已经在用 claude-hud 等 statusline 的人: 不必换 —— 改用该工具自带的"外部用量快照"(externalUsageWritePath)
# 写到同一路径即可, 本脚本只是给没有 statusline 的人的最简实现。
#
# 依赖: jq。无 rate_limits(非订阅/首个 API 响应前)时只输出状态行、不写快照。

set -uo pipefail

SNAP_PATH="${LARK_QUOTA_SNAPSHOT:-$HOME/.claude/lark-quota.json}"

IN="$(cat)"
[[ -z "$IN" ]] && { echo "lark-quota"; exit 0; }

if ! command -v jq >/dev/null 2>&1; then
  # 没有 jq 就只当普通 statusline(输出模型名兜底), 不写快照。
  printf '%s\n' "$(printf '%s' "$IN" | grep -o '"display_name":"[^"]*"' | head -1 | cut -d'"' -f4)"
  exit 0
fi

# 有 rate_limits 才写快照(订阅制 Pro/Max 且本会话已有首个 API 响应)。
HAS_RL=$(printf '%s' "$IN" | jq -r 'if .rate_limits then "1" else "0" end' 2>/dev/null || echo 0)
if [[ "$HAS_RL" == "1" ]]; then
  mkdir -p "$(dirname "$SNAP_PATH")" 2>/dev/null || true
  TMP="$SNAP_PATH.$$.tmp"
  printf '%s' "$IN" | jq -c '{
    updated_at: (now | todate),
    five_hour: { used_percentage: (.rate_limits.five_hour.used_percentage // null),
                 resets_at:       (.rate_limits.five_hour.resets_at // null) },
    seven_day: { used_percentage: (.rate_limits.seven_day.used_percentage // null),
                 resets_at:       (.rate_limits.seven_day.resets_at // null) }
  }' > "$TMP" 2>/dev/null && mv "$TMP" "$SNAP_PATH" 2>/dev/null || rm -f "$TMP" 2>/dev/null || true
fi

# 输出一行给 Claude Code 当状态栏(有额度就显示 5h/7d 已用%)。
printf '%s' "$IN" | jq -r '
  (.model.display_name // "claude") as $m |
  (.rate_limits.five_hour.used_percentage) as $f |
  (.rate_limits.seven_day.used_percentage) as $d |
  if $f != null then "\($m) | 5h \($f)% | 7d \($d // 0)%" else $m end' 2>/dev/null \
  || echo "claude"

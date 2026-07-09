#!/bin/bash
# fake-claude — 假 claude CLI：读完 stdin，睡几秒模拟耗时，吐结果行。
# 参数: FAKE_CLAUDE_MODE=fail 退出码 1；FAKE_CLAUDE_MODE=noresult 不输出结果行。
PROMPT=$(cat)
echo "fake-claude: got $# args: $*"
echo "fake-claude: prompt bytes: ${#PROMPT}"
echo "fake-claude: prompt head: $(printf '%s' "$PROMPT" | head -c 120)"
sleep "${FAKE_CLAUDE_SLEEP:-3}"
case "${FAKE_CLAUDE_MODE:-ok}" in
  fail)
    echo "fake-claude: simulated failure" >&2
    exit 1
    ;;
  noresult)
    echo "fake-claude: finished but forgot the result line"
    ;;
  *)
    echo "some review noise..."
    echo "___RESULT___ verdict=APPROVE general_comment_url=https://example.com/comment/1 inline_count=2"
    ;;
esac
exit 0

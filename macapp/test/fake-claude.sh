#!/bin/bash
# fake-claude — 假 claude CLI: 读完 stdin, 睡几秒模拟耗时, 按请求的 --output-format 吐结果。
#   FAKE_CLAUDE_MODE=fail      退出码 1
#   FAKE_CLAUDE_MODE=noresult  不输出结果行(测"忘了结果行")
#   FAKE_CLAUDE_SLEEP=N        睡 N 秒(默认 3; stream 模式事件之间也小睡)
# 输出格式随客户端传的 --output-format 自适应:
#   stream-json → 逐行 NDJSON 事件(system/assistant tool_use/assistant text/result), 模拟流式
#   json        → 单个 JSON 信封 {"result":...,"usage":...}
#   其它/未指定 → 纯文本(旧行为, 兼容既有手测)
PROMPT=$(cat)
ARGS="$*"

fmt=plain
case "$ARGS" in
  *stream-json*) fmt=stream ;;
  *"--output-format json"*|*"--output-format=json"*) fmt=json ;;
esac

RESULT_LINE='___RESULT___ verdict=APPROVE general_comment_url=https://example.com/comment/1 inline_count=2'
SLEEP="${FAKE_CLAUDE_SLEEP:-3}"

if [ "${FAKE_CLAUDE_MODE:-ok}" = "fail" ]; then
  echo "fake-claude: simulated failure" >&2
  exit 1
fi

case "$fmt" in
  stream)
    # 逐行 NDJSON, 事件之间小睡, 模拟真实流式(客户端应实时打出 🔧/💬 日志)。
    printf '%s\n' '{"type":"system","subtype":"init","model":"fake","tools":["Bash","Read"]}'
    sleep 1
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"开始 review 这个 PR"}]}}'
    sleep 1
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr diff 1"}}]}}'
    sleep 1
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"app/x.ts"}}]}}'
    sleep "$SLEEP"
    if [ "${FAKE_CLAUDE_MODE:-ok}" = "noresult" ]; then
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"跑完了但忘了给 result 事件"}]}}'
    else
      printf '{"type":"result","subtype":"success","result":"some review noise...\\n%s","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":3},"total_cost_usd":0.05,"num_turns":3}\n' "$RESULT_LINE"
    fi
    ;;
  json)
    sleep "$SLEEP"
    if [ "${FAKE_CLAUDE_MODE:-ok}" = "noresult" ]; then
      printf '%s\n' '{"result":"跑完了但没有结果行","usage":{"input_tokens":10,"output_tokens":20},"total_cost_usd":0.05,"num_turns":3}'
    else
      printf '{"result":"some review noise...\\n%s","usage":{"input_tokens":10,"output_tokens":20},"total_cost_usd":0.05,"num_turns":3}\n' "$RESULT_LINE"
    fi
    ;;
  *)
    echo "fake-claude: got $# args: $*"
    echo "fake-claude: prompt bytes: ${#PROMPT}"
    sleep "$SLEEP"
    if [ "${FAKE_CLAUDE_MODE:-ok}" = "noresult" ]; then
      echo "fake-claude: finished but forgot the result line"
    else
      echo "some review noise..."
      echo "$RESULT_LINE"
    fi
    ;;
esac
exit 0

#!/usr/bin/env bash
# run-client.sh — 启停/查看 lark-review-client 的小工具(随客户端分发, 任意机器可用)。
#
# 用法:
#   ./run-client.sh start  [config.json]   后台启动(nohup, 写 pid/日志)
#   ./run-client.sh stop                   停止
#   ./run-client.sh restart [config.json]  重启
#   ./run-client.sh status                 是否在跑 + 最近日志
#   ./run-client.sh logs                   tail -f 实时日志
#   ./run-client.sh fg     [config.json]   前台运行(给 launchd / systemd 调用)
#
# 默认 config: $LARK_REVIEW_CLIENT_CONFIG 或 ~/.lark-review-client.json
# 默认日志:   $LARK_REVIEW_CLIENT_LOG    或 ~/.lark-review-client.log
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/lark-review-client.js"
CONFIG="${2:-${LARK_REVIEW_CLIENT_CONFIG:-$HOME/.lark-review-client.json}}"
PIDFILE="${LARK_REVIEW_CLIENT_PID:-$HOME/.lark-review-client.pid}"
LOGFILE="${LARK_REVIEW_CLIENT_LOG:-$HOME/.lark-review-client.log}"

# 让 spawn 出来的 node / claude / gh / git 都能找到(launchd 下 PATH 很精简)。
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$PATH"
NVM_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | tail -1 || true)"
[[ -n "$NVM_BIN" ]] && export PATH="$NVM_BIN:$PATH"

find_node() { command -v node 2>/dev/null || true; }

is_running() {
  [[ -f "$PIDFILE" ]] || return 1
  local p; p=$(cat "$PIDFILE" 2>/dev/null || echo)
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null
}

do_start() {
  local node; node=$(find_node)
  [[ -z "$node" ]] && { echo "找不到 node, 请先装 Node.js 18+"; exit 1; }
  if is_running; then echo "已在运行 (pid=$(cat "$PIDFILE"))"; exit 0; fi
  if [[ ! -f "$CONFIG" ]]; then
    echo "⚠️ 配置 $CONFIG 不存在 —— 先以「仅配置页」模式启动,"
    echo "   启动后浏览器打开 http://127.0.0.1:8790 在网页里填写并保存即可。"
  fi
  nohup "$node" "$SCRIPT" "$CONFIG" </dev/null >>"$LOGFILE" 2>&1 &
  local pid=$!; echo "$pid" > "$PIDFILE"; disown "$pid" 2>/dev/null || true
  sleep 1.5
  if is_running; then
    echo "✅ 已启动 (pid=$pid)"; echo "日志: $LOGFILE"; tail -3 "$LOGFILE" 2>/dev/null || true
  else
    echo "❌ 启动失败, 看日志:"; tail -15 "$LOGFILE" 2>/dev/null; rm -f "$PIDFILE"; exit 1
  fi
}

do_stop() {
  if ! is_running; then
    echo "未在运行"; rm -f "$PIDFILE" 2>/dev/null || true
    pkill -f "lark-review-client.js" 2>/dev/null && echo "(已清理残留进程)" || true
    return 0
  fi
  local p; p=$(cat "$PIDFILE")
  echo "停止 pid=$p ..."; kill -TERM "$p" 2>/dev/null || true
  for _ in $(seq 1 10); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
  rm -f "$PIDFILE"; echo "✅ 已停止"
}

do_status() {
  if is_running; then echo "🟢 运行中 (pid=$(cat "$PIDFILE"))"; else echo "🔴 未运行"; fi
  echo "配置: $CONFIG"
  echo "日志: $LOGFILE"
  echo "--- 最近 5 行日志 ---"; tail -5 "$LOGFILE" 2>/dev/null || echo "(无日志)"
}

case "${1:-}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; sleep 1; do_start ;;
  status)  do_status ;;
  logs)    tail -f "$LOGFILE" ;;
  fg)      node=$(find_node); [[ -z "$node" ]] && { echo "找不到 node"; exit 1; }; exec "$node" "$SCRIPT" "$CONFIG" ;;
  *) echo "用法: $0 {start|stop|restart|status|logs|fg} [config.json]"; exit 1 ;;
esac

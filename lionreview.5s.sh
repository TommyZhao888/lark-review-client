#!/bin/bash
# SwiftBar / xbar 插件: 菜单栏显示 lark-review-client 状态 + 正在执行的 Review 任务 + 版本更新提醒。
# 数据来自 client 自身的 /status(它知道自己在跑什么), 不含任何防护/审计逻辑。
#
# 安装:
#   1) 装 SwiftBar(brew install --cask swiftbar) 或 xbar, 设一个插件目录。
#   2) 把本文件软链/复制进插件目录, 文件名保留 *.5s.sh(每 5 秒刷新):
#        ln -s ~/.lark-review-client/lionreview.5s.sh "<SwiftBar 插件目录>/lionreview.5s.sh"
#   3) chmod +x, 刷新 SwiftBar 即可。
#   配置页端口非默认时: 设环境变量 LARK_REVIEW_CLIENT_CONFIG_PORT, 或改下面 PORT。
#
# 菜单栏图标: 🦁⚡N=在跑 N 个 / 🦁🟢=在线待命 / 🦁🔴=离线或未注册 / 🦁⚪️=client 没起;
#            末尾带 🆙 = 有新版本(点开可一键更新)。
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
PORT="${LARK_REVIEW_CLIENT_CONFIG_PORT:-8790}"
BASE="http://127.0.0.1:$PORT"

S=$(curl -s --max-time 3 "$BASE/status" 2>/dev/null)
if [ -z "$S" ]; then
  echo "🦁⚪️"
  echo "---"
  echo "lark-review-client 未运行 | color=red"
  echo "打开配置页 | href=$BASE/"
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  IFS=$'\t' read -r CONN REG RUN QLEN NAME VER OUTD REC < <(echo "$S" | jq -r '[(.connected//false),(.registered//false),((.running|length)//0),((.queued|length)//0),(.name//""),(.client_version//""),(.outdated//false),(.upgrade.recommended//"")]|@tsv')
else
  CONN=$(echo "$S" | grep -o '"connected":[a-z]*' | head -1 | cut -d: -f2)
  REG=$(echo "$S" | grep -o '"registered":[a-z]*' | head -1 | cut -d: -f2)
  RUN=$(echo "$S" | grep -o '"pr_num"' | wc -l | tr -d ' '); QLEN=0; NAME=""; VER=""; OUTD=""; REC=""
fi

# 菜单栏标题
if [ "${RUN:-0}" -gt 0 ] 2>/dev/null; then T="🦁⚡$RUN"
elif [ "$CONN" = "true" ] && [ "$REG" = "true" ]; then T="🦁🟢"
else T="🦁🔴"; fi
[ "$OUTD" = "true" ] && T="$T🆙"
echo "$T"
echo "---"
echo "${NAME:-lark-review-client}${VER:+  v$VER} | size=12"
if [ "$CONN" = "true" ] && [ "$REG" = "true" ]; then echo "● 在线待命 | color=green"; else echo "● 离线 / 未注册 | color=red"; fi

# 版本更新提醒 + 一键更新(点击调 client 的 /self-update: git pull + 重启; 失败到配置页看步骤)
if [ "$OUTD" = "true" ]; then
  echo "---"
  echo "🆙 有新版本${REC:+ v$REC}(当前 v${VER:-?}) | color=#ffb454"
  echo "一键更新并重启 | bash=/bin/sh param1=-c param2=\"curl -sS -X POST $BASE/self-update >/dev/null\" terminal=false refresh=true"
  echo "打开配置页(看更新步骤) | href=$BASE/"
fi

if [ "${RUN:-0}" -gt 0 ] 2>/dev/null && command -v jq >/dev/null 2>&1; then
  echo "---"; echo "⚡ 正在 Review:"
  echo "$S" | jq -r '.running[] | "--PR #\(.pr_num)  \(.repo)  [\(.stage//"?")] | color=#d29922"'
fi
if [ "${QLEN:-0}" -gt 0 ] 2>/dev/null; then echo "--- "; echo "排队中: $QLEN | color=#8b93a3"; fi

echo "---"
echo "打开配置页 / 日志 | href=$BASE/"
echo "立即刷新 | refresh=true"

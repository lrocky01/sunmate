#!/usr/bin/env bash
# ==============================================================================
# ☀️ SunMate 专属 Hermes 智能体随身第二大脑一键接入与自启动程序
# 包含：
#  1. 核心 Skills 安装 (成长复盘、会议纪要分离、通知简报、情境记忆检索、全链路探活)
#  2. HTTP/SSE OpenAI 兼容网关后台守护启动 (0.0.0.0:8080)
#  3. 本机 IP 探测与配置信息自动输出 (供手机 App 直接填写)
# ==============================================================================

set -euo pipefail

HERMES_DIR="${HERMES_HOME:-$HOME/.hermes}"
TARGET_SKILLS_DIR="$HERMES_DIR/skills"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SOURCE_DIR="$SCRIPT_DIR/skills"
PORT="${1:-8080}"
TOKEN="${2:-sunmate_$(openssl rand -hex 4 2>/dev/null || echo 'sec8899')}"

echo "=========================================================="
echo "      ☀️ SunMate (阳光智伴) 专属 Hermes 接入配置向导"
echo "=========================================================="
echo "[1/4] 检查并配置 Hermes 技能目录..."

if ! mkdir -p "$TARGET_SKILLS_DIR" 2>/dev/null; then
  HERMES_DIR="$SCRIPT_DIR/.hermes"
  TARGET_SKILLS_DIR="$HERMES_DIR/skills"
  mkdir -p "$TARGET_SKILLS_DIR"
fi
echo "  目标技能目录: $TARGET_SKILLS_DIR"

# 1. 复制全套 5 大核心技能
for skill in lifelog-daily-review meeting-diarize-process notification-digest context-memory-query sunmate-doctor; do
  if [[ -d "$SKILLS_SOURCE_DIR/$skill" ]]; then
    cp -r "$SKILLS_SOURCE_DIR/$skill" "$TARGET_SKILLS_DIR/"
    echo "  ✓ 已挂载专属技能: $skill"
  fi
done

echo ""
echo "[2/4] 检查 Python 运行依赖 (fastapi, uvicorn)..."
if ! python3 -c "import fastapi, uvicorn" 2>/dev/null; then
  echo "  正在安装极简服务依赖 (fastapi uvicorn)..."
  pip3 install fastapi uvicorn -q 2>/dev/null || pip install fastapi uvicorn -q 2>/dev/null || true
fi
echo "  ✓ Python 依赖检查完成！"

echo ""
echo "[3/4] 启动 SunMate 直连网关后台守护进程 (端口: $PORT)..."

# 检查端口是否已被占用，若有旧实例则优雅重启
OLD_PID=$(lsof -ti :$PORT 2>/dev/null || true)
if [[ -n "$OLD_PID" ]]; then
  echo "  发现旧服务 (PID: $OLD_PID)，正在重启..."
  kill -9 $OLD_PID 2>/dev/null || true
  sleep 1
fi

export HERMES_TOKEN="$TOKEN"
nohup python3 "$SCRIPT_DIR/sunmate_hermes_server.py" --host 0.0.0.0 --port "$PORT" > "$HERMES_DIR/sunmate_gateway.log" 2>&1 &
NEW_PID=$!
sleep 2

# 验证探活
if kill -0 $NEW_PID 2>/dev/null; then
  echo "  ✓ 直连网关已成功在后台启动！(PID: $NEW_PID, 日志: $HERMES_DIR/sunmate_gateway.log)"
else
  echo "  ✗ 启动异常，请检查 $HERMES_DIR/sunmate_gateway.log"
  exit 1
fi

echo ""
echo "[4/4] 探测网络与端点配置..."

# 探测局域网 IP
LOCAL_IP=""
if [[ "$(uname)" == "Darwin" ]]; then
  LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")
else
  LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
fi

echo "=========================================================="
echo "🎉 Hermes 智能体接入配置完成！请将以下信息填入手机 App："
echo "=========================================================="
echo ""
echo "📱 局域网直连模式 (手机与电脑在同一 Wi-Fi):"
echo "  👉 Hermes 端点地址: http://${LOCAL_IP}:${PORT}/v1"
echo "  👉 安全访问 Token: ${TOKEN}"
echo ""
echo "🌐 外网/穿透模式 (在外随时随地使用):"
echo "  若使用 Cloudflare Tunnel、frp、cpolar 或 Nginx 反代，请将外部访问域名映射至本地端口 ${PORT}，"
echo "  并在手机 App 中填入: https://<你的公网域名>/v1"
echo ""
echo "=========================================================="

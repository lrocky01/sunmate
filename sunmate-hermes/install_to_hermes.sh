#!/usr/bin/env bash
set -euo pipefail

# SunMate 专属 Hermes Skills 一键安装脚本
HERMES_DIR="${HERMES_HOME:-$HOME/.hermes}"
TARGET_SKILLS_DIR="$HERMES_DIR/skills"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills"

echo "=========================================================="
echo "      SunMate (阳光智伴) 专属 Hermes 技能安装程序"
echo "=========================================================="
echo "目标 Hermes 目录: $HERMES_DIR"

if [[ ! -d "$HERMES_DIR" ]]; then
  echo "提示: 未检测到 $HERMES_DIR 目录，正在创建..."
  mkdir -p "$TARGET_SKILLS_DIR"
else
  mkdir -p "$TARGET_SKILLS_DIR"
fi

echo "正在安装 SunMate 核心能力 Skills 到 Hermes..."

# 1. 安装全天 24 小时随身时光机成长复盘技能
cp -r "$SOURCE_DIR/lifelog-daily-review" "$TARGET_SKILLS_DIR/"
echo " [✓] 已安装: lifelog-daily-review (全天随身录音+通知时光机画像)"

# 2. 安装 MOSS-ASR 说话人分离会议纪要技能
cp -r "$SOURCE_DIR/meeting-diarize-process" "$TARGET_SKILLS_DIR/"
echo " [✓] 已安装: meeting-diarize-process (MOSS-ASR 说话人分离会议纪要)"

# 3. 安装手机通知智能简报与洞察技能 (对齐 YoooClaw notification-summary)
cp -r "$SOURCE_DIR/notification-digest" "$TARGET_SKILLS_DIR/"
echo " [✓] 已安装: notification-digest (手机系统通知智能简报与待办提取)"

echo "----------------------------------------------------------"
echo "🎉 安装完成！你的本地 Hermes 智能体已具备 SunMate 全部技能！"
echo ""
echo "📡 如何启动供手机 App 直连的 API 服务？"
echo " 1. 如果你已有运行中的 Hermes API 服务，请直接将手机设置页指向对应端口 (例如: http://<你的IP>:8080/v1)"
echo " 2. 如果之前仅命令行运行，可直接运行随包附带的直连网关:"
echo "    python3 sunmate_hermes_server.py --port 8080"
echo "    (支持实时流式 SSE 打字对话与技能调用，无任何第三方中转)"
echo "=========================================================="

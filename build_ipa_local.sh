#!/usr/bin/env bash
set -e

echo "=== [SunMate] 开始本地 iOS 打包流程 ==="

# 检查 flutter 命令
if ! command -v flutter &> /dev/null; then
  echo "错误: 未检测到 flutter 命令，请先配置 Flutter SDK 环境。"
  exit 1
fi

# 检查 xcodebuild
if ! command -v xcodebuild &> /dev/null; then
  echo "错误: 未检测到 xcodebuild 命令，请先从 App Store 安装完整版 Xcode。"
  exit 1
fi

cd sunmate_app

echo "1. 获取 Flutter 依赖..."
flutter pub get

echo "2. 编译 iOS Release 工程 (无需开发者证书)..."
flutter build ios --release --no-codesign

echo "3. 封装为未签名 IPA 包..."
cd ..
rm -rf build_output SunMate.ipa
mkdir -p build_output/Payload
cp -r sunmate_app/build/ios/iphoneos/Runner.app build_output/Payload/
cd build_output
zip -r -q ../SunMate.ipa Payload
cd ..

echo "=== [成功] SunMate.ipa 生成完毕! ==="
ls -lh SunMate.ipa
echo "提示: 请打开 爱思助手 (/Applications/i4Tools.app) -> 工具箱 -> IPA 签名，导入 SunMate.ipa 并自签名安装到 iPhone!"

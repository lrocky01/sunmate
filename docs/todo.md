# iOS 蓝牙配对排查（2026-10-17）

- 目标：核对 YoooClaw APK 逆向结论，审查 SunMate 连接路径，明确原生配对与 ANCS 授权未出现的原因及可验证方案。
- [已完成] 原 APK REA 核对及三段 DEX 重建，定位旧逆向仅覆盖 30 个壳类；保留可复现脚本和哈希。
- [已完成] 核对官方 Telink / AiNote6095 两套 profile、命令编码、业务鉴权；发现 SunMate 把 OTA 当业务命令。
- [已完成] 审查 Flutter/iOS 连接路径，核查 Apple RequiresANCS 公开选项及插件实现。
- [已完成] 输出 docs/IOS_BLE_AUDIT_2026-10-17.md，列明错误结论、已确认缺陷、验证局限与下一版修改方案。
- 本次审查状态：已完成。用户已确认进入实现并推送 main，版本 1.0.11+12。
- [已完成] 在现有 HAL 内修正 profile 与收发边界、移除假鉴权、补充连接阶段与持久诊断；未知 profile、CCCD 失败、失败回执不能报告业务成功。
- [已完成] 固定 flutter_blue_plus 1.36.8 与本地 darwin 7.0.3 补丁，通过同一个原生 CBCentralManager 接入 RequiresANCS、授权状态和 NSError 信息。
- [已完成] 本地 Flutter 分析通过（仅 11 项已有弃用提示），25 项协议/连接/桥接/界面测试通过；版本和 CI 构建号统一为 1.0.11+12，保留 pubspec.lock。
- [已完成] 提交 1bd99a8 并推送 main；GitHub Actions #28 的分析、25 项测试、iOS 原生编译、IPA 打包上传全部通过。
- [已完成] 下载 IPA 并核对 Info.plist 为 1.0.11 / Build 12，以及二进制中 ANCS 原生桥接与授权回调标记；安装包位于忽略目录 build_output/SunMate-1.0.11+12.ipa。
- 本轮实现与交付状态：已完成。实体 iPhone 的弹窗、业务鉴权和稳定性由用户安装后测试，不能用模拟测试替代。
- 记录：实际首页为 lib/views/home_page.dart。反编译证据位于忽略目录 tools/ble_audit，重建脚本位于 docs/ble-audit。私有 ASR/Hermes 代码与端点设置未改。真机测试说明见 docs/IOS_BLE_TEST_1.0.11.md。没有合法业务密钥时保留待鉴权状态；本版不沿用未证实的录音/音频格式。

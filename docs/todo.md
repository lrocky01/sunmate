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

## 真实业务鉴权与录音（继续推进）

- 目标：沿官方代码确认首次验机、X25519 共享密钥和重连挑战；在现有 HAL 内接入可验证的真实流程，音频继续直连私有 MOSS-ASR / Hermes。
- [已完成] 核对验机 /check、账号 /homePage/pub/index 的 sharedSecret 恢复路径、X25519 / AES-CBC 和实时音频 8 字节长度头。部分登录调用者指令被清零，未猜登录参数。
- [已完成] 实现本地加密、严格鉴权状态机和 Keychain/KeyStore 保存；接入 Telink 物理实时录音和 Ogg/Opus，保持 HAL 与私有端点。
- [已完成] 候选源码检查：Flutter 分析无错误/警告（保留 11 个已有弃用提示），41 项测试通过；本机 FFmpeg 解码 Ogg/Opus 通过。用户真机已证实 Telink/verifyRequest/ANCS=true，仍缺账号材料。
- 记录：1.0.11+12 IPA 已下载并核验；后续打包递增为 1.0.12+13。实体稳定性尚未验证。

- [待推进] 用户确认官方 App 是否有 API Key / 设备资料导出入口后，验证自有账号恢复；没有恢复材料则需合法验机接口或受控正常登录运行时证据。不得冒用账号、绕过校验或把测试向量发给设备。
- [待推进] 取得真实材料后实体 iPhone 验证稳定连接、重连、录音和私有 ASR；当前整体目标未完成。新源码为 1.0.12+13，尚不发布不可完成首次鉴权的安装包。

- [已完成] 本地实现与证据保留在 codex/ble-real-auth 分支；未推送 main，未触发新的 iOS 包。等待账号入口信息期间不重复交付无法完成首次鉴权的版本。

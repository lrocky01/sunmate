# SunMate iOS 蓝牙配对与协议审查

审查日期：2026-10-17。对象为仓库提交 `9b7c8e7`、本地 YoooClaw 2.3.0 APK、SunMate 1.0.10+11。此次完成静态取证和修复方案，不修改 App 行为、不推送构建。

**结论：此前逆向不完整，协议文档存在关键错误。当前最先要修的是业务通道与握手判断；配对弹窗只是其中一层。** 官方 Android APK 明确把 `1913 / 2B15` 用作 OTA，把 Telink 业务放在 `1930 / 2B30–2B33`。SunMate 目前向 OTA 特征写业务 JSON、向命令特征订阅事件，并将事件通道当成音频。

同时，Apple 有公开的 `CBConnectPeripheralOptionRequiresANCS` 连接选项。当前 Flutter 插件连接路径没有设置它；项目自造的 `setAncsConfig` JSON 没有已核对的官方协议依据。该选项用于 ANCS 授权流程，不能替代外设安全配置或厂商业务鉴权，也不能保证任意外设必然出现两个弹窗。

## 逆向证据与覆盖范围

原 APK SHA-256：`e638958d143b518829a3db4d16cb4f8db1b19c64d49149458b98684c16e2137f`。根目录 `classes.dex` 与 APK 内同名文件逐字节相同。

现有 `decompiled`、`decompiled_apk`、`decompiled_full`、`decompiled_src` 各只有 30 个 Java 类，属于 `com.netease.nis.wrapper` 等加固壳。`decompiled_ble` 无 Java 文件。REA 对原 APK 的分析也只识别 30 个类，包名为 `ai.yidao.yoooclaw`，版本 2.3.0。**在这些产物上搜索类名字符串，不等于已经反编译出业务方法。**

已从壳后残留的结构中重建三段 DEX：利用仍在的 `map_list` 和 `string_data`，只重建头和受损的前 996 个字符串索引；每段从第 4096 字节起与原块逐字节相同。没有改写任何业务 code_item，也没有运行 APK。

| 段 | 原 classes.dex 起点 | 长度 | 类定义数 | 重建 SHA-256 |
| --- | --- | --- | --- | --- |
| 1 | `0xE344` | `0xC22611` | 9687 | `1fd5508f6e8fbcaf95aa7756c9430fb6c604e3264d1db907ba538a3a64676109` |
| 2 | `0xC30958` | `0xB5104F` | 11078 | `1bf0cc48f3306c06430634e07c99d253568bfb730e440875c04687a05de79b8b` |
| 3 | `0x17819A8` | `0x61BF5C` | 7198 | `0936ef3abeeab285cbae2dbcf2bf3eb9cfede7e63cb4054525c2f68ac83098af` |

这是分析副本，不能视为厂商原始 DEX 或可安装发行包。JADX 对部分复杂方法无法完整反编译：三段分别报告 59、32、6 个错误。对鉴权事件分发另外开启 `--show-bad-code`，其中错误控制流只能作为线索；本报告将简单、完整的方法和字段定义作为确定结论的主要依据。

可复现脚本：[recover_yoooclaw_dex.py](/Users/m/Documents/VS/sunmate/docs/ble-audit/recover_yoooclaw_dex.py)。脚本固定校验输入 SHA，拒绝覆盖已有输出目录，并验证 4096 字节后的原始数据不变。

```sh
python3 docs/ble-audit/recover_yoooclaw_dex.py 'YoooClaw 2.3.0.apk' /tmp/sunmate-yoooclaw-recovered
JAVA_HOME="$PWD/tools/jdk/Home" tools/jadx/bin/jadx --no-res -j 1 -d /tmp/sunmate-yoooclaw-source /tmp/sunmate-yoooclaw-recovered/recovered-2.dex
```

第二条命令可能因无关复杂方法反编译失败而返回非零，需结合日志检查，不能据此声称全量反编译成功。

REA 原 APK Evidence：`ev_e95a33ec23755b00aed266717101bfafb16d7f524444b5098afe1fadd121f872`。

REA 对重建分析容器的 `TelinkProtocolAdapter.encodeJsonRpc` Evidence：`ev_619c6d5db9ba3b676c7fca764507414eaf4ab06bb7b5cfb2f8ac8da8f79efebc`，方法体完整，无回退。**该记录的目标是重建容器，不是原 APK；其来源关系由上述重建脚本和哈希记录说明。**

本地证据保存在 [tools/ble_audit](/Users/m/Documents/VS/sunmate/tools/ble_audit)，该目录沿用仓库 tools 的忽略规则，不提交第三方大体积反编译产物。

## 官方实际支持两套不同协议

### Telink 协议

完整 UUID 共同前缀为 `00010203-0405-0607-0809-0a0b0c0d`，下表只缩写最后四位。

| 用途 | 服务 | 特征 | SunMate 当前映射 |
| --- | --- | --- | --- |
| 业务命令 APP_COMMAND | `1930` | `2B30` | 错当成事件 |
| 设备事件 DEVICE_EVENT | `1930` | `2B31` | 错当成音频 |
| 音频 STREAM | `1930` | `2B32` | 未绑定 |
| 文件 FILE | `1930` | `2B33` | 错标扩展调试 |
| 固件升级 OTA | `1913` | `2B15` | 错当成业务命令 |

证据：[UuidInfo.java](/Users/m/Documents/VS/sunmate/tools/ble_audit/decompiled-2/sources/com/telink/ota/ble/UuidInfo.java:11)，[TelinkDeviceProfile.java](/Users/m/Documents/VS/sunmate/tools/ble_audit/decompiled-2/sources/com/yoootek/yooolib/blemanage/plugin/telink/TelinkDeviceProfile.java:41)。后者实际引用上述 UUID 建立端点，排除了“只是未使用常量”的疑问。业务命令及 OTA 均配置 WITHOUT_RESPONSE。

`TelinkProtocolAdapter.encodeJsonRpc` 对 UTF-8 JSON 加 `TelinkWireProtocol.customJson` 前缀；该前缀明确为 **`11 30`**。这是 Telink 业务帧，不是此前文档所称的 4 字节 TLV，也不是纯 JSON。

证据：[TelinkProtocolAdapter.java](/Users/m/Documents/VS/sunmate/tools/ble_audit/decompiled-2/sources/com/yoootek/yooolib/blemanage/protocol/telink/TelinkProtocolAdapter.java:94)，[TelinkWireProtocol.java](/Users/m/Documents/VS/sunmate/tools/ble_audit/decompiled-2/sources/com/yoootek/yooolib/blemanage/protocol/telink/TelinkWireProtocol.java:12)。例如查询状态的编码形式是 `11 30` 后接 `{"version":"1.0.0","method":"getStatus","params":{}}`。

**本次没有向设备发送任何测试包，更没有向 2B15 写入二进制。** 交接中的“不要写 2B15”应继续保留为操作约束；“因为 2B15 的 cJSON 越界”则没有固件或崩溃证据支撑。

### AiNote6095 协议

官方 `AI_NOTE_6095` 是另一套独立 profile，不能与 Telink 视为同一个协议别名。

| 用途 | UUID |
| --- | --- |
| 服务 | `e2c1a300-7f4b-5e9d-bc23-1a2f3e4d5c6b` |
| 音频 | `e2c1a301-7f4b-5e9d-bc23-1a2f3e4d5c6b` |
| 命令 | `e2c1a302-7f4b-5e9d-bc23-1a2f3e4d5c6b` |
| 事件 | `e2c1a303-7f4b-5e9d-bc23-1a2f3e4d5c6b` |
| OTA / 文件 / 日志 | 同后缀的 `e2c1a304` / `305` / `306` |

该 profile 的业务命令是 WITH_RESPONSE，OTA 才是 WITHOUT_RESPONSE；JSON 使用 `FC 01 + UInt16 大端长度 + payload` 首片、`FC 88 + payload` 续片。此前“2 字节小端类型 + 2 字节小端长度”描述也不符合这份实现。

证据：[AiNote6095Profile.java](/Users/m/Documents/VS/sunmate/tools/ble_audit/decompiled-2/sources/com/yoootek/yooolib/blemanage/plugin/AiNote6095Profile.java:33)，[AiNote6095ProtocolAdapter.java](/Users/m/Documents/VS/sunmate/tools/ble_audit/decompiled-2/sources/com/yoootek/yooolib/blemanage/protocol/ainote6095/AiNote6095ProtocolAdapter.java:289)，[AiNote6095NotifyDecoder.java](/Users/m/Documents/VS/sunmate/tools/ble_audit/decompiled-2/sources/com/yoootek/yooolib/blemanage/protocol/ainote6095/AiNote6095NotifyDecoder.java:10)。

因此，必须用手机实际发现的完整 service/characteristic UUID、属性和广播 manufacturer data 判断 C·ONE-4552 属于哪一套。设备外壳名称或广告名称不足以定型。当前服务摘要取 UUID 的第 4–8 位，会把上述 Telink 私有服务都显示成 `0203`，恰好丢掉关键的 `1913/1930`。

## 交接说明中需要撤回或降级的结论

| 原结论 | 审查结果 |
| --- | --- |
| 已完整还原官方协议 | 不成立；旧反编译只有加固壳，现文档混合了至少两套协议 |
| 1913 / 2B15 为业务命令 | 与 APK 中被实际引用的 profile 明确矛盾，属于 OTA |
| 所有命令必须是纯 JSON | 与 APK 两套编码器均矛盾；目前不能扩大到未知固件变种 |
| 必须全部 withoutResponse | Telink 业务适用；官方 AiNote6095 业务明确 WITH_RESPONSE |
| setAncsConfig 会触发系统配对 | APK 全部重建 DEX 字符串中没有该方法名；未找到官方编码路径，不能继续当成已知命令 |
| bindRequest 的 isIos=true 触发配对 | 官方 bindRequest 编码没有该字段；已找到的是 verifyResult 内可选的数值 isIos。Android AiNote profile 配置为 0，不能猜测 iOS 对应值或作用 |
| verifyIdentity 是发送 token | 官方使用随机挑战加密后的 encrypted 字段，且按 profile 编码 |
| 约 10 秒后因 MCU 鉴权看门狗断开 | 现场现象成立，具体原因未证实；APK 不含下位机固件运行证据。官方 App 自身有 120 秒鉴权看门狗，另有 10 秒认证后订阅超时，均不能混称为 MCU 看门狗 |
| 系统配对后永不掉线 | 配对保留密钥，不保证无线链路永不掉线 |

官方首次业务验证存在 `verifyRequest → externalDeviceBindCheck → verifyResult(encrypted_random, public_key, 可选 isIos)` 路径；配对结果携带的设备公钥用于 X25519 共享密钥协商。重连时 `verifyIdentityRequest` 的随机挑战使用保存的 32 字节共享密钥进行 AES/CBC/PKCS5Padding 加密，再返回 `verifyIdentity`。

证据：[完整的 verifyResult 生成方法](/Users/m/Documents/VS/sunmate/tools/ble_audit/decompiled-2/sources/com/yoootek/yooolib/blemanage/BleIdentityAuthentication$$ExternalSyntheticLambda0.java:42)，[鉴权事件分发的部分反编译结果](/Users/m/Documents/VS/sunmate/tools/ble_audit/BleDeviceEventHandler-debug.java:363)。后者有反编译控制流警告，因此精确分支仍应结合字节码或抓包确认；云校验调用、加密算法和密钥长度均有明确代码线索，不支持假 token 替代。

“业务数据直连私有 MOSS-ASR/Hermes”可以继续保持。但若设备首次绑定确实要求厂商签发 HMAC，完全脱离厂商完成首次绑定需要供应商开放协议或合法的独立鉴权方案。拉起 Apple 配对框不会自动解决这个前提；不能用猜测签名绕过。

## 为什么现在没有系统弹窗

需要区分三层：系统 SMP 配对及 bond、ANCS 通知授权、厂商应用层鉴权。它们相关，但相互不等价。

Apple 从 iOS 13 起提供 `CBConnectPeripheralOptionRequiresANCS`；WWDC19 说明，可在连接支持 ANCS 的附件时设置该选项，并通过 `didUpdateANCSAuthorizationForPeripheral` 与 `ancsAuthorized` 获得授权变化和状态。[Apple API](https://developer.apple.com/documentation/corebluetooth/cbconnectperipheraloptionrequiresancs)，[WWDC19 官方说明](https://developer.apple.com/videos/play/wwdc2019/901/?time=1115)。

SunMate 的 `device.connect(autoConnect:false, timeout:12s)` 没有 ANCS 参数。`pubspec.yaml` 为 `flutter_blue_plus: ^1.34.0`，仓库没有 pubspec.lock；实际 CI 解析版本未留证。据当前 pub.dev 元数据，1.x 最高为 1.36.8。已核查 1.34.0 原生实现和 1.36.8 对应 darwin 7.0.3，两者连接 options 都没有 RequiresANCS。

本地插件证据：[1.34.0 的连接 options](/Users/m/Documents/VS/sunmate/tools/ble_audit/dependency-sources/1.34.0/ios/Classes/FlutterBluePlusPlugin.m:382)，[darwin 7.0.3 的连接 options](/Users/m/Documents/VS/sunmate/tools/ble_audit/dependency-sources/darwin-7.0.3/darwin/flutter_blue_plus_darwin/Sources/flutter_blue_plus_darwin/FlutterBluePlusPlugin.m:383)。公开包来源：[1.34.0](https://pub.dev/packages/flutter_blue_plus/versions/1.34.0)，[1.36.8](https://pub.dev/packages/flutter_blue_plus/versions/1.36.8)。

当前只尝试读取电池，既没有已证实的受保护特征访问，也没有同一个原生 central manager 的 ANCS 连接选项；错误通道又使官方业务交互不能正确发生。因此，未出现弹窗有明确的实现缺口。**仍不能仅凭静态检查判断官方 iOS App 当场用了哪个触发机制，也不能保证加一个连接选项就消除断开。** APK 是 Android 版本，无法证明 iOS CoreBluetooth 调用或连接后前 500ms 的实际包序。

访问受加密保护的特征时由系统进行安全协商，是另一条有效路径；普通 Read 属性不能证明该特征要求加密，遍历读取也不保证弹窗。ANCS 的服务端在 iPhone，附件是通知消费者；在录音卡 GATT 上寻找 iPhone 的 ANCS 服务方向不对。[Apple ANCS 规范](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Specification/Specification.html)。

Info.plist 已包含蓝牙说明与 bluetooth-central 后台模式，没有证据表明缺少一个 plist 权限文字是本次根因。

## SunMate 当前实现的问题

1. **通道与数据格式混用，最高优先级。** `ainote_6095_driver.dart:231` 按 UUID 子串匹配，失败后按“第一个可写/可通知”兜底，可能选到 OTA 或其它无关服务。必须改成 profile 下完整服务与完整特征匹配，未知固件只报告，不盲写。
2. **鉴权是占位实现且仍在活动路径。** `ainote_6095_driver.dart:576` 收到 verifyIdentityRequest 就调用默认 token=`sunmate_auth` 的方法。`ble_json_rpc.dart:88` 也保留假签名/用户 ID 的 bindRequest 构造器。当前连接主流程并未调用该 bindRequest，不能声称它已经完成首次绑定。
3. **握手错误被吞掉。** Notify 失败继续走、写失败重试再吞掉，ANCS 配置没有应答确认也打印完成；600ms 后 `device.isConnected` 为真就持久化 ID 并报告握手成功。业务鉴权没有成功门槛。
4. **bindResult 文本出现就当成功。** `ainote_6095_driver.dart:579` 未校验结构或 success=false，甚至可能把失败事件当成功并发送灯控。
5. **收发缺少协议边界和分片重组。** 通过字符串 contains 查验回执、将错误通道按自拟 4 字节音频头剥离，无法承接官方两个 profile 的实际消息结构。
6. **断开原因没有记录。** 插件已有 `device.disconnectReason`，驱动只打印 manual 状态。应保存断开时间、连接耗时、阶段、错误码与描述，必要时在原生侧补 NSError.domain。CoreBluetooth 错误码不能直接套成 HCI `0x13 RemoteUserTerminatedConnection`；即便记录到断开，也未必足以证明是哪一端主动发起，需 HCI/PacketLogger 佐证。
7. **连接生命周期容易竞争。** 构造器自动连接与用户点击没有共享互斥，异常处理用字符串 contains('connected') 放行，会误包含 'disconnected'；清理监听不等于断开旧设备。自动重连函数虽存在，但断开回调没有调用它。
8. **其它架构事实。** HAL 和 AiNote6095Driver/PhoneMicDriver 分层可保留；PhoneMicDriver 当前发送的是静音模拟 PCM，尚非真实手机拾音；OpusStreamReceiver 将裸包直接拼接，尚非可播放 Ogg Opus。MOSS-ASR/Hermes 直连与本次弹窗缺口没有直接因果关系，不建议连带重构。

## 建议的下一版修改范围

按上级 [AGENTS.md](/Users/m/Documents/VS/AGENTS.md)，“涉及……权限……安全策略”须先计划再确认；本次先提交以下可审查方案，尚未改动配对或鉴权逻辑。

1. 在现有 HAL 内修正 profile 识别和 UUID 常量；先完整记录服务、特征属性与广播，不向 OTA 写业务数据。用实际发现的 profile 决定编码、订阅与写响应模式，不能仅凭广告名决定。对应 `ble_constants.dart`、`ainote_6095_driver.dart`、`ble_json_rpc.dart`。
2. 固定现有兼容的 Flutter 蓝牙依赖，针对同一个 CBCentralManager 增加 ANCS 连接选项、授权状态读取及回调桥接。优先小范围本地插件补丁，不创建第二个蓝牙管理器抢占连接、不使用私有 API 或运行时 swizzle。仅在用户选择录音卡连接时启用，不给所有扫描到的设备要求 ANCS。
3. 移除假 token/假签名活动路径和没有协议依据的自动 setAncsConfig。将“传输已连接、系统授权、业务验证”分开记录；收到设备实际事件再推进。若没有合法业务密钥，明确显示待鉴权，不宣称成功，也不关闭校验。
4. 必要订阅/写入错误向上传递；完整记录时间轴与 disconnectReason。业务成功必须基于结构化、明确成功的设备回执；短暂物理连接只显示链路已建立。更新首页诊断文案。
5. 版本严格递增到 `1.0.11+12`，更新实际首页 `sunmate_app/lib/views/home_page.dart`。交接里的 `lib/features/home/home_page.dart` 不存在。当前 CI 会用 github.run_number 覆盖 IPA 的 build number；若要求 IPA 也固定为 +12，需另审 CI 调整，不能只改 pubspec 后声称包号一致。

第一版目标是消除已确认的协议错误，并拿到真实的系统授权/断开证据；不能在尚无设备测试时命名为“彻底修复断连版”。不改 MOSS-ASR/Hermes 端点，不改 HAL 接口，不自动解绑/重置硬件。

真机验收：使用该版本连接 C·ONE-4552，保存完整 GATT 和时间轴；核对系统是否已保留旧 bond/通知授权；分别验证新绑定与保留绑定重连、通知允许/拒绝、前台至少 60 秒及一次后台恢复；确认业务鉴权成功后再测录音与音频帧。旧 bond 可能使配对弹窗不再显示，因此“没弹窗”本身不能作为失败判据。需要新配对场景时由用户在系统设置操作，测试代码不自动抹除绑定。

若仍断开，用原生 NSError 与 PacketLogger 对照，区分 ATT 操作失败、连接超时和断开事件。没有 HCI 证据时不把通用 peripheralDisconnected 强行解释成精确 HCI 原因。

## 本次验证

- 原 APK 与 classes.dex 比对通过，固定 SHA-256。
- 重建脚本在独立新目录运行通过，三段输出哈希与人工取证产物一致；代码区原样保留。
- REA CLI 使用工作区已有 JDK/JADX 成功检查原 APK 和重建容器中的指定方法，未改 MCP 配置、未安装新工具。
- 已审查连接调用链、HAL、iOS 入口、plist、依赖和构建工作流；未执行 App 构建或 Flutter 分析，因为当前 PATH 无 Flutter/Dart，本机只配置 Xcode CommandLineTools。
- 尚无本次 iPhone GATT/HCI 日志与官方 iOS IPA；未进行硬件发包、配对或端到端稳定性验证。

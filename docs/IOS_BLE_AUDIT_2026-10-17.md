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

## 续查：真实业务鉴权与实时录音（1.0.12+13 源码候选）

### 真机已经把断点缩小到业务验机

用户提供的 1.0.11+12 日志证实：完整 Telink `1930/2b30/2b31/2b32/2b33` 存在，事件和音频 CCCD 均成功；连接约 1634ms 时收到 `verifyRequest`，约 7672ms 时断开，iOS 报 `CBErrorDomain` code 7，`ANCS=true`。因此现在有直接设备证据支持该 profile，当前缺口是验机答复。`ANCS=true` 可以是此前官方 App 已授予的授权，不能据此证明 SunMate 本轮弹出了新的系统窗口；code 7 也不能直接换算为 HCI 的远端终止原因或证明固件看门狗实现。

### 已定位的三段身份流程

1. 首次验机：`BleDeviceEventHandler.handle(VerificationRequested)` 将设备上报的 `encrypted/mac/sn` 分别作为 `checkContent/mac/sn`，调用 `POST /api/device/toc/externalDeviceBind/check`。`BleApiService` 声明了该路径；`BaseRetrofitFactory` 为正常业务请求添加账号 Authorization、UserId 等信息。服务端返回的 `ExternalDeviceBindResult.hmac` 经非空检查后，作为 `verifyResult.params.encrypted_random` 发给设备，同时携带本机 X25519 原始公钥的 Base64。Telink profile 的 `verifyResultIsIosValue=null`，因此不额外编造 `isIos`。HMAC 的具体计算及服务端密钥没有从这些调用中恢复；不能用账号密码、SN 或自造 token 代替。
2. 共享密钥：`SecretManager.generateSharedSecret` 接收 `pairingResult.public_key` 的原始 32 字节 X25519 公钥，与本机私钥做 X25519，直接得到 32 字节共享密钥，所见路径未使用 HKDF。官方手机密钥对在进程内懒生成，业务共享密钥随后保存在 `BleSavedDevice.key`。手机公钥发出到 `pairingResult` 之间中断的恢复，仍需按实际固件行为验证。
3. 重连：`verifyIdentityRequest.params.random` 是 Base64 挑战；共享密钥为 AES-256 key，IV 为 16 个零字节，算法 `AES/CBC/PKCS5Padding`（AES 分组对应 PKCS7），加密结果 Base64 放进 `verifyIdentity.params.encrypted`。Telink 不带 timestamp；AiNote6095 重连编码带秒级时间戳字符串。只有本次挑战应答之后的布尔 `verifyIdentityResult.success=true`，且通道初始化已完成，才能报告业务就绪。

### 自有官方账号恢复绑定：发现路径，但尚未接通

官方不只在本机保存共享密钥。`POST /api/device/toc/externalDeviceBind/bind` 的 `ExtInfo` 包含 `mac/sharedSecret/uuid`；`POST /api/device/toc/homePage/pub/index` 返回 `BleHomePageBean.deviceList`，其中每项含 `externalDeviceId/externalDeviceName/deviceType/extInfo`。`BleDeviceStore` 的账号同步回调读取 `extInfo.sharedSecret` 并构造 `BleSavedDevice`。这说明官方已有“从自己的账号恢复既有设备身份”的客户端路径，是避免重新绑定的优先方向。

REA 对 `BleDeviceStore$$ExternalSyntheticLambda6.invoke` 的补充结果保存于忽略目录 `tools/ble_audit/rea-owned-device-sync.json`，Evidence `ev_83133406815da5003ca038190f86ed3407abded959915c0d8d8f9fe32802e719`。它是重建分析副本上的静态证据，不能证明当前服务器一定返回可用密钥、用户账号有该设备记录、API Key 有相应权限，或 iOS 已绑定的设备会接受跨客户端恢复。

用户目前只有自己的官方 App 账号，没有 SDK 授权。尚未取得合法可用的账号会话或设备资料导出入口，也未对真实账号发起登录、验证码、验机、绑定或解绑请求。不能声称账号同步已经实现或真机鉴权已通过。

登录仍有分析盲区：账号 API 接口可见 `sendLoginSms/loginOrRegister`，但部分调用者的 DEX code_item 指令已被保护器清零。直接检查重建副本中 `LoginCodeInputActivity.initListener` 的 code_item（0x6aae20，65 条指令），指令区为零；所有 4096 字节之后的内容与原包保持一致，所以这不是本次 DEX 头重建丢失的代码。不能根据空 Java 方法或零条静态引用推断登录参数、服务器免鉴权或原 APK 没有实现。原包还含 `libnesec.so/assets/nedata.db`；未解开这部分保护，也未执行 APK 采集登录运行时。已有 API Key 或导出入口是否可用，需用户确认，不要求在聊天发送凭据。

### 已落地的本地部分与边界

- `recorder_authentication.dart`：X25519 / AES 挑战应答、严格鉴权状态机、取消后禁止晚到的答复发包；共享密钥使用 iOS Keychain（ThisDeviceOnly）或 Android KeyStore 保护的安全存储。增加 `cryptography 2.7.0` 与 `flutter_secure_storage 9.2.4`，不是自写密码算法。默认没有厂商验机 provider，不会假装调用成功；账号同步入口尚未接入，所以当前安装不能凭空获得已有官方共享密钥。
- 驱动按真实保存密钥跳过 `bindRequest`，响应设备随机挑战；没有材料则保持失败/待鉴权。新增 provider 只是合法签发层的接缝，不是已实现的官方登录服务；AiNote6095 的 iOS 首次绑定参数不明，明确拒绝尝试。
- 音频：官方 `TelinkProtocolAdapter` 在 `voiceCmd start` 后把 stream 通知原样交给 `BleStreamReceiver`；`OpusFrameAssembler` 使用两个 uint32 长度（Opus 长度与扩展长度），优先 LE、否则 BE，跨通知组帧。每段长度上限 8192，与旧自拟四字节 session/seq 头不同。官方 `nativeCreate` 参数为 1 声道、16000Hz、pre-skip 312；`nativeWritePacket` 的 granule 增量 960。对应实现已替换旧接收器，生成带 CRC 的 Ogg/Opus，物理按键 `start/release` 会话才采集，`abort`、断线或空/截断帧取消转写。
- 保留 HAL 的 `AiNote6095Driver/PhoneMicDriver`。对 Telink 的 App 主动开始/暂停/恢复录音，官方 adapter 对应方法没有可用编码，继续明确提示使用物理按键；没有发明远程录音指令。长录音、文件下载与 AiNote6095 音频不在本次已验证实现内。
- MOSS-ASR / Hermes 客户端、私有端点及路由未改；没有新增厂商音频上传或第三方中转。
- 源码版本与可见版本更新为 `1.0.12+13`。这是待完成账号材料接入的源码候选，尚非新的可安装 IPA，也没有推送 main 冒充完整修复。已交付的 IPA 仍为 1.0.11+12。

### 验证与后续终点

已用 RFC 7748 公开向量核对 X25519，用独立 OpenSSL 结果核对 AES-CBC 填充；模拟 GATT 已走通“预存密钥→随机挑战→真实算法应答→成功回执”的流程，验证不再发 bindRequest；生成的 Ogg/Opus 已用本机 FFmpeg 解码。测试向量及模拟服务只在 test/ 内，不能被当作真实设备材料。本次最终测试结果记录于 docs/todo.md。

上述为 1.0.12+13 本地候选阶段记录，新的账号恢复进展见下一节。实体 iPhone 的鉴权成功、至少 10 分钟稳定连接、重复重连、物理按键完整录音及私有 ASR 转写仍是整体任务终点。

## 续查：正常官网账号恢复（1.0.13+14）

用户已确认首次官方绑定需联网，绑定成功后关闭网络仍可 BLE 连接、收到长按响应；失败的是官方在线 ASR。这支持“首次验机联网、已有共享密钥后本地重连”的判断，不能据此推导首次也可离线。包装仅有 App 下载二维码，没有可验证的工厂 sn/sign 绑定材料。

### 找到普通账号入口，无需预先提供 API Key

官网 [正常登录页](https://www.yoooclaw.com/login) 公开前端模块 2652 定义：`POST /api/auth/send-sms` 请求 `{phone,channel:6}`；`POST /api/auth/login` 请求 `{phone,smsCode,channel:6}`，页面限制 4 位验证码。响应 `data.jwtToken/data.id` 用于账号会话，客户端去除 Bearer 前缀。所用公开脚本：

- [账号 API 模块](https://www.yoooclaw.com/_next/static/chunks/e696518a1a997015.js)，SHA-256 `d7252610e39f4d299e866eadaf645e4aa4188d446b08d49ea640a9d39467c406`。
- [登录界面模块](https://www.yoooclaw.com/_next/static/chunks/0e4e3085115ed518.js)，SHA-256 `639afea092ef1f04fdc06a1557878dfea99b0a45f0c429d9a49df4da655ee35e`。

REA 对原始脚本快照目录的静态证据为 `ev_e538dc5a4d125d16e76f64b1ee1b201649be814fd31d5b813f43fddcc162f5ab`，本地原始证据位于忽略目录 `tools/ble_audit/official-downloads/rea-web-auth-directory.json`。未填写真实账号、未发送短信、未执行登录，也未观察该用户会话的后端响应；Turbopack 的动态引用不代表完整调用图。Android accountChannel 为 3，官网为 6，跨渠道设备记录权限尚未知，未猜改渠道。

APK 的 DistributionConfig 中公开产品标识 `app_key` 为 `yoooclaw`，不是账号密钥，也不是 channel=3。账号设备列表请求使用正常会话 Authorization、UserId/user_id；不会将登录密码或短信验证码当成设备签名。

### 当前官方 APK 复核与纯本地边界

官网公开 `/api/android-release` 指向 [当前 Android 包](https://apk.yoooclaw.com/package/yoooclaw.apk)。2026-10-17 下载包为 75,671,880 字节，SHA-256 `c1382fe1bc55eb80ebc8a9d4ed76394e712032f6cc075e07cb7423f4f4edb5de`，与用户提供包并非逐字节相同。重新提取三段 DEX，核对 12 个鉴权/绑定/存储相关类；10 个去除来源注释后相同，另外两个仅见合成 lambda 编号变化，不能因此声称全包相同。重新绑定、身份挑战、Telink 编码路径没有观察到新增离线首次绑定方式。分析副本、哈希和比较结果在忽略目录 `tools/ble_audit/official-downloads/`。

QR 解析器接受带 sn/sign 和可选 confirm_code 的激活地址，重新绑定流程可将相应字段放进 bindRequest；这不证明 sign 可绕过后续 verifyRequest。部分登录代码仍被保护器清零，native provider 当前不可用，未恢复完整保护逻辑；没有固件和实际 HCI 抓包，不能排除所有可能的本地首次绑定路径。

### 本轮落地与实机局限

`yoooclaw_account.dart` 与账号页面接入上述正常短信登录，并尝试读取自己的 `/api/device/toc/homePage/pub/index`。所有账号测试使用内存 HTTP adapter，没有对真实用户发出短信或绑定请求。未知协议、缺失/无效共享密钥、重复 SN/协议记录均拒绝猜选；恢复要求与当前卡实际 SN 和 GATT 协议匹配，不自动覆盖不同旧密钥。Token、手机号、验证码不写偏好或诊断，页面关闭后清除内存会话。仅所选共享密钥写入 Keychain/KeyStore；然后重连，仍须设备身份验证成功才报告就绪。

这是可供手机验证的账号恢复接入，并非已证实跨渠道登录可用，也并非纯本地首次绑定完成。官网会话被拒、列表为空或缺少共享密钥时，页面给出脱敏结果，不改权限、不伪造签名、不自动解绑。私有音频及智能体路由未改。真机步骤见 [1.0.13 测试说明](IOS_BLE_TEST_1.0.13.md)。

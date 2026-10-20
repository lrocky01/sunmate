# SunMate 已核对的录音卡 BLE 协议

2026-10-17 修订，账号恢复请求格式修复版源码为 1.0.14+15。此前版本混合了 Telink 与 AiNote6095，并把 OTA 端点误作业务命令，已撤回。完整取证过程见 [审查报告](docs/IOS_BLE_AUDIT_2026-10-17.md)。

本规范来自指定 YoooClaw 2.3.0 APK 的静态实现，用户真机日志已经确认 C·ONE-4552 的 Telink GATT 与 verifyRequest；密码流程仍需真实材料与抓包验证。型号名称不能决定 profile；只按完整服务与特征组合选择，未知或同时匹配多个 profile 时不写入。

## Telink

完整 UUID 前缀为 `00010203-0405-0607-0809-0a0b0c0d`。

| 用途 | 服务尾号 | 特征尾号 | App 操作 |
| --- | --- | --- | --- |
| 业务命令 | 1930 | 2B30 | Write Without Response |
| 业务事件 | 1930 | 2B31 | Notify |
| 音频 | 1930 | 2B32 | Notify |
| 文件 | 1930 | 2B33 | Notify |
| OTA | 1913 | 2B15 | 本 App 业务路径禁止访问 |

JSON 下行帧为 `11 30 + UTF-8 JSON`，不是纯 JSON，也不是通用四字节小端 TLV。该编码器没有定义 JSON 应用层分片，单次写入长度必须满足协商后的 MTU。不能把长命令任意切碎或换写 OTA。

已核对的查询：

```json
{"version":"1.0.0","method":"getCapabilities"}
{"version":"1.0.0","method":"getStatus","params":{}}
```

JSON 上行事件由 `AA 55 30` 开头，JSON 负载从第 5 字节后开始。按完整 JSON 对象的 `method` 和 `params` 处理，不能搜索字符串就宣告成功。

RTC 下行为 `11 29 + UInt32 小端 Unix 秒`。官方 Telink adapter 没有实现 App 发起开始、暂停和恢复录音的通用命令，不能套用 AiNote6095 或自造 `startRecord`。

## AiNote6095

服务 UUID 为 `e2c1a300-7f4b-5e9d-bc23-1a2f3e4d5c6b`，特征共享 `-7f4b-5e9d-bc23-1a2f3e4d5c6b` 后缀。

| 用途 | 特征开头 | App 操作 |
| --- | --- | --- |
| 音频 | e2c1a301 | Notify |
| 业务命令 | e2c1a302 | Write With Response |
| 事件 | e2c1a303 | Notify |
| OTA | e2c1a304 | 本 App 业务路径禁止访问 |
| 文件 | e2c1a305 | Notify |
| 日志 | e2c1a306 | Notify |

JSON 首片为 `FC 01 + UInt16 大端负载总长度 + payload`，续片为 `FC 88 + payload`。仅按该 profile 的边界组装，拒绝孤立续片和越界长度。RTC 为 `E5 + UInt32 大端 Unix 秒 + UInt32 大端毫秒余数`。

## 配对与业务验证

系统 SMP/bond、ANCS 授权与厂商业务鉴权分别记录。Apple 公开连接选项 `CBConnectPeripheralOptionRequiresANCS` 在现有 CBCentralManager 上设置，结果由 `ancsAuthorized` 及授权变化回调读取。不能将其解释为通用 requestPairing，也不保证任意固件出现两个弹窗。

厂商 `verifyRequest` 路径将 encrypted/mac/sn 提交至官方 `/api/device/toc/externalDeviceBind/check`，使用返回的 hmac 构造 verifyResult，并交换 32 字节原始 X25519 公钥。共享密钥直接取 X25519 结果，无已观察到的 HKDF。`verifyIdentityRequest.params.random` 先 Base64 解码，用共享密钥做 AES-256-CBC、16 字节全零 IV、PKCS7 填充，再将密文 Base64 放入 verifyIdentity.params.encrypted；Telink 不附 timestamp。

官方账号的设备列表存在 extInfo.sharedSecret 恢复代码路径。官网渠道 6 的真实登录成功后访问设备列表仍为 401；2026-10-18 用户通过 App 同源渠道 3 正常验证码登录，profile 与设备列表均已返回 200 / 000000。1.0.15+16 据此切换到已验证的 App 登录/短信契约。当时唯一匹配目标 SN 的记录 extInfo 为对象，但没有 sharedSecret 字段。用户随后通过 Android 官方 App 正常连卡并收到按键响应；后续1.0.17+18账号设备页也由用户确认「账号未返回共享密钥」，因此当前仍不能声称已恢复。恢复材料必须与实际卡上报的 SN 和已发现的协议匹配，随后存入安全存储并由设备挑战验证；已有不同密钥不自动覆盖。没有真实材料时明确失败，不发送假 token、假签名或伪造 user_id。纯本地首次绑定尚未证实。

1.0.16+17 改为先登录、选择自有账号设备，再扫描连接；收到实际首次挑战后才调用 /check。pairingResult 成功后安全保存 X25519 结果，并调用 /api/device/toc/externalDeviceBind/bind，正文为 deviceId=SN、deviceName、extInfo(mac, sharedSecret, 可选的账号既有 uuid)。官方代码先保存本机再同步账号；本版在同步成功后仅自动重连一次，验证新的 AES 身份挑战后才就绪。/check、/bind 本账号真实服务接受结果仍待手机验证。若已有合法旧密钥且设备请求重连身份验证，则不执行新协商。

1.0.18+19 补齐官方 Telink 无本地密钥分支：事件/音频通道就绪后发送一次正常 bindRequest。订阅瞬间先收到 verifyIdentityRequest 而无 key，不伪造 AES 答复；有真实验机会话时继续等正常 verifyRequest。提前身份挑战不能代替厂商挑战，也不能抑制 bindRequest；已经收到厂商挑战则不重复绑定。已有本机密钥或账号恢复成功则沿用挑战验证，不重新协商。设备拒绝即停止，不发送解绑或重置；鉴权等待使用共享120秒界限。本分支已有离线回归，真实卡片是否接受仍待测试。

1.0.13+14 用户已确认验证码登录成功、设备列表请求被拒；该版移除 Bearer 后直接发送裸 Token 的实现存在格式缺口。设备接口公开的未认证响应声明 `WWW-Authenticate: Bearer`，1.0.14+15 因此按 `Authorization: Bearer <登录所得 Token>` 发送且只保留一个前缀。APK 的 `Raw` 表示保留已有格式，不等于要求裸 JWT。请求诊断区分步骤、HTTP 401/403 和数字业务码，不再把所有拒绝归为“没有权限”；仅加 Bearer 未解决官网渠道问题，App 同源登录已由后续真实结果验证。

`bindResult`/`pairingResult` 不是完整业务验证成功；`success:false` 必须失败。仅在本次挑战应答之后收到 `verifyIdentityResult` 且 `params.success` 为布尔 true，并完成事件和音频通道初始化，才记录业务验证成功。写队列完成、物理连接仍在、灯亮、ANCS 允许都不是替代条件。

未确认 `setAncsConfig` 或自定义 ANCS 事件码，不发送这些指令。Telink 实时音频有两个事件入口：JSON voiceCmd 的 start/release/abort 与 session_id，以及二进制 AA 55 01/02 的录音开始/停止，不能只实现 JSON。二进制开始至少12字节：第4字节为1表示 LONG，否则为 REALTIME，offset4起8字节为大端会话；停止第4字节为类型，缺省时沿用活动类型。2026-10-19 本卡按住说话实测 AA 55 01 00 / AA 55 02 00，期间收到393个有效Opus帧，无主机ATT启动应答。1.0.24+25尚漏二进制入口并在无活动会话时忽略音频，详见[音频链路调查](docs/IOS_BLE_AUDIO_LINK_AUDIT_2026-10-19.md)。流内容使用两个 uint32 长度字段（Opus 长度、扩展长度），再跟 Opus 与扩展数据，可跨通知；优先 LE，否则按官方 plausibility 规则尝试 BE，单段长度各不超过 8192。不是旧四字节 session/seq 头。候选实现输出单声道 Ogg/Opus，输入采样率 16000、pre-skip 312、每包 granule 增量 960；空、截断、取消的会话不提交转写。长录音与 App 主动开始/暂停/恢复仍未核实，不假造命令。

## 诊断与真机测试

### 2026-10-19 新确认：iOS ANCS 通知正文回传（Telink）

本轮官方iPhone App的HCI对照已经确认：**卡片将iPhone的ANCS通知属性，经1930服务的2B31事件特征回传给App，使用二进制`AA 55 41`帧，不是`AA 55 30` JSON。** 原“未确认自定义ANCS事件码”是此前调查状态，此处以新运行证据更新；仍不发送自造的ANCS启用命令。

| 偏移 | 长度 | 本轮确认的内容 |
| --- | --- | --- |
| 0 | 3 | `AA 55 41` |
| 3 | 2 | UInt16小端payload长度，等于完整帧长减5 |
| 5 | 8 | iPhone ANCS Notification Source原始事件，逐字节相同 |
| 13 | 剩余 | iPhone ANCS Data Source完整响应，逐字节相同 |

8字节Notification Source由EventID、EventFlags、CategoryID、CategoryCount和4字节小端NotificationUID组成，**不是8字节时间戳**。Data Source响应为`CommandID=0 + NotificationUID(4) + 属性TLV`；TLV为`AttributeID(1) + Length(2,LE) + Value(Length)`。Source与Data Source的UID必须一致。已观察AppIdentifier(0)、Title(1)、Subtitle(2)、Message(3)、MessageSize(4)、Date(5)；未知属性须按长度跳过，本卡实际返回了多个id255、长度0的属性，不能使其污染后续解析。没有通知正文原文写入规范或诊断。

HCI窗口22:19:24—22:23:24，文件SHA-256为`92d91e3bacf8cbed9190318ac5b767fc74f72bc1b66415dd7bbc914e0aa75c43`。22:22:59.916与22:23:13.206的两次微信Data Source响应，均在59ms后出现130字节2B31帧；两帧可解出用户测试标记A01/A02，且整个Data Source及对应Notification Source与iPhone输出完全一致。另有第三帧做了相同结构比对，未输出原始内容。此样本不存在通知封装内的额外正文加密；不等于空口BLE链路未加密。

采样时SunMate驱动仅分流录音0x01/0x02及JSON0x30，尚无0x41通知解码。随后按用户授权，已在本地补齐`TelinkNotificationFrame/Decoder`，于JSON解码前独立分流，调用`onIosAncsNotificationPosted`；只接受当前真实AES验证完成且GATT通道就绪的新增通知。标题、副标题、正文与应用标识保留；Date严格按本地时间解析，无效或缺失则使用接收时间，不能解释成UTC。

本地重组限制为首片至少含`AA5541`类型头、顺序续片、5秒接收期限及65540字节协议上界；遇到新的其它`AA55`事件立即丢弃半帧，不吞鉴权/录音事件。这个上界来自u16字段，不代表实测固件容量；无头续片交错、跨GATT长通知仍待实卡验证。校验长度、UID一致性、TLV边界及UTF-8；未知属性跳过，重复的已知属性拒绝。仅处理EventID=0，修改/移除不伪装成新增。

同一连接最多缓存256个UID的正文摘要用于去重，不保存正文副本；相同UID但不同正文/日期可接收，断连和身份失败清缓存。鉴权前不重放通知；通知解析/管理器异常不破坏已有AES状态。诊断增加已接收/忽略/无效计数，不记录标题、正文、UID或异常原始内容。通知管理器只发布本地事件，本次未接ASR/Hermes、可靠落库或应用采集策略，也未改HAL、绑定、密钥、端点、版本或打包推送。

边界：本轮仅确认单个完整帧、EventID=0通知；跨GATT分片、修改/删除事件、断线缓存重放尚未实测。成功会话初始化还观察到`11 2B`，用途及是否是回传必要条件未确证，不向SunMate盲加。采样最终成功会话发生在用户自行官方解绑重绑之后，不能当作旧绑定普通重连成功；旧身份应答此前失败11次。新绑定包含X25519协商，SunMate旧密钥未改，后续必须重新核验身份材料，不自动覆盖。

详细证据、时间线及工具验证见[通知交付报告第9节](docs/OFFICIAL_HERMES_NOTIFICATION_FLOW_2026-10-19.md)。

保存完整广播、service/characteristic UUID 与属性、每步耗时、业务事件方法名及原生 NSError domain/code/description；不保存挑战、密钥、签名或通知正文。断开日志跨 App 重启保留，可从首页“蓝牙状态与诊断日志”复制。

CoreBluetooth 错误码不能直接套用 HCI 原因码。没有 PacketLogger/HCI 证据，不把数秒断开定性为 MCU 鉴权看门狗、固件 JSON 崩溃或对端主动断开。

最新无密钥分支的依据及验收步骤见 [1.0.18 手机测试说明](docs/IOS_BLE_TEST_1.0.18.md)，原生授权排查另见 [1.0.11 手机测试说明](docs/IOS_BLE_TEST_1.0.11.md)。

2026-10-18 1.0.18+19实体反馈：链路/GATT成功，正常bindRequest后设备返回bindError，尚未进入verifyRequest或/check。官方bindError详情依次取error/reason/message/status；1.0.19+20补安全摘要，不从87字节包长猜原因，不自动执行解绑。账号服务器字段与页面来源的完整边界见 [数据映射](docs/IOS_BLE_ACCOUNT_DATA_MAP_2026-10-18.md)。

2026-10-18恢复路径续查：官方retryBindFromLocalDevice是用当前本机key补上传/bind，非密钥恢复读取接口；入口位于OpenClaw SN资格检查。两版connectToDevice原始跳转明确拒绝Telink携带非空bindSign/confirmCode/rebindSign，这些入口参数仅AI_NOTE_6095接受，不能仅凭通用JSON构造器的可选字段给Telink补签名。完整依据与首次接入方案见 [续查报告](docs/IOS_BLE_BOUND_KEY_RECOVERY_2026-10-18.md)。


2026-10-19 验证更新：1.0.24+25 用户日志已确认保存密钥的真实 verifyIdentity 挑战成功并保持超过5分钟；本轮只读HCI另确认按键实时Opus传输及离线解码成功。上文早期版本的“仍待真实材料验证”是当时状态，不代表当前仍未通过AES；当前App端录音入口缺口见音频链路调查。


2026-10-19 本地修复更新：已授权补齐二进制实时事件独立解码、事件/音频有序处理和安全统计，保留JSON及真实AES；11项新增回归、180项全量通过。未升级版本或打包推送，已安装1.0.24+25仍需后续包才包含该补丁。按键、维护页、灯效及首次授权边界见[设备能力记录](docs/RECORDER_CAPABILITIES_2026-10-19.md)。


2026-10-19 长录静态核对与用途选择更新：已确认Telink的文件列表`11 22`、文件读取`11 26 + UTF-8文件名`（均十六进制），文件数据独立走2B33；官方以OPS分段串行获取、临时文件完整提交、停止后补扫尾段再合成音频。失败段整段重读，不是任意offset续传；官方自动删除源段的策略不照搬。详见[长录文件与分段流程报告](docs/RECORDER_LONG_RECORDING_FLOW_2026-10-19.md)。本轮本地补齐会议/随身记录用途、开始时固定和同SN/session重连恢复，未实现完整文件下载/合成，不将本机会话元数据当作音频已保存；真实AES、旧密钥、HAL和端点保持，仍1.0.25+26，未打包推送。

2026-10-19 后续本地实现：已补齐AA5508目录、AA5505大端正int32大小和AA5506完成事件分流，2B33串行文件接收，size+完成信号+完整字节三者满足才提交；超时/污染锁住文件通道至新连接，不发offset/删除/猜测停止命令。仅卡片明确空闲、真实AES verified且文件通道就绪时读取；当前不边录边拉。严格OPS/大小/SHA校验、内容摘要段恢复、尾段多轮目录/锚点确认、流式Ogg和本地归档已实现。iOS使用原生完整解码生成WAV，并在每次播放前校验摘要证明和样本数；失败保留OPS/Ogg，不假报保存成功。没有接ASR/Hermes、改HAL/密钥/端点、实卡操作或打包推送。实现、资源界限、验证和仍待实卡确认的无wire传输ID/最终段数限制详见上述报告第7节。

2026-10-20 录音期间同步更新（替代上一条仅停止后读取的限制）：会议和随身记录共用闭合段增量同步。当前真实AES连接的closed(p)只证明p；activePart未知只读明确闭合集合，已知时只读part<activePart，冲突时等待新状态，当前写入段不读。activePart推断基于顺序单活动段语义，尚非已确证的官方筛选或固件落盘保证。stop时不打断当前read，提交后排尾扫并按原完整性链归档；录音中保存OPS，不合成整场或假报完整。未知/新会话/回退/断连撤销闭合证明，超时隔离至新连接。新增38项本地回归，最终全量411项通过，原生11项通过；不打包推送，版本不变，无解绑/删除源段/ASR/Hermes/密钥改动。官方新增依据和实际边界见上述报告第8节。

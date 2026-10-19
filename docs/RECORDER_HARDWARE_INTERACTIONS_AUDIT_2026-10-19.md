# C·ONE 硬件页面、按键、灯效与通知交互核对

本次按用户要求使用 REA 续查官方 APK，与 SunMate 当前本地源码对照。结论先行：**卡片负责识别物理手势、执行录音与驱动灯珠；App 可以设置部分固件行为，并接收已经判定的事件、处理音频及业务；官方智能灯效还涉及服务器规则。不能把它们全部当成 App 内任意动作映射。**

本轮只静态分析及离线检查既有抓包，没有执行官方 App、请求账号服务器、连接或写入卡片，没有读取/导出真实业务密钥；未修改 SunMate 运行源码、版本、HAL、私有端点或密钥存储，没有构建/推送。前轮本地补丁全部保留。

## 工件与证据边界

- 原始 `YoooClaw 2.3.0.apk` SHA-256：`e638958d143b518829a3db4d16cb4f8db1b19c64d49149458b98684c16e2137f`。原包有保护层，普通类库存只有壳类，不代表业务只有这些类。
- 2.3.0 既有 DEX 重建分析副本 SHA-256：`cdaf78f1abb2bdbc57430eb8b54b82e00ed264099c0f12ddc26814de1f3a7318`。与前次记录及本次读取相符。副本用于分析，不能称为厂商原始未加固 APK 或可安装发行物。
- 当前 REA MCP 的 Android provider 缺少 `REA_JADX_MCP_JAR`；本轮改用已安装 REA 6.5.0 CLI，命令级指定工程已有 JAR/JDK，未修改全局配置或安装新组件。直接 DEX 输入被工具格式检查拒绝后，使用已有分析 APK，不重复同一失败调用。
- 新证据位于忽略目录 `tools/ble_audit/hardware-capabilities-20261019/{page,button,light}/`。Java 反编译失败时，REA 保留的 smali 是本轮设置命令的重要依据。静态代码能说明编码、条件及调用方向，不能证明卡片现场接受、保存了指令。
- 多个硬件设置 UI 方法仍是保护后的空体。空体意味着当前恢复不完整，不能据此认定官方没有功能；本轮从更低层命令路由补出了此前漏掉的设置与 RGB 命令。

## 本卡实际报告的能力

复用既有官方 iPhone 首次连接抓包，按原 `inspect_target_gatt` 解析器的系统 UUID、广播 SN/地址及连接句柄匹配，仅白名单提取 `reportCapabilities/reportUserSettings/reportStatus` 的安全字段。没有输出鉴权载荷、地址、通知正文或原始 ATT 数据。

三次 `reportCapabilities` 都是 **`[1002, 2001, 3001]`**：

| ID | 本轮可确认的含义 | 边界 |
| --- | --- | --- |
| 2001 | 官方主键多击次数写入的必要 gate | 设置值仅2/3，录音中禁止改。 |
| 3001 | 官方 `RecordingSettingsSupport.supportsLedSettings` 直接接受的能力 | 对应长录音指示灯设置支持；不是“全部RGB灯效实测通过”。 |
| 1002 | 本卡确实报告 | 尚未找到足够明确的业务映射，保持原始ID，不命名猜测。 |
| 4002 | 本抓包未报告 | 官方屏幕开关以它为 gate；不应给本卡直接开放这些功能。 |

既有抓包还有 `reportStatus` 的 battery、recording、version 字段；本次没有 `reportUserSettings`，因此不能知道这张卡当前保存的多击次数、灯开关或长按模式原值。来源 SHA-256：`bcf6f901cae49ecd168e8d4c244ed1e0b6eb0341c4985244cfbb93bcdb0b9704`；提取脚本及结果为 `page/read_safe_capability_capture.py`、`page/safe-card-capabilities.json`。这是历史实卡观察，不是本轮新采样或 REA 动态执行记录。

SunMate 当前会发送 `getCapabilities` 并记录 `reportCapabilities` 方法名，但没有保存/应用 ID 集合；`reportUserSettings` 和 `keyEvent` 也没有接入。当前只从 `reportStatus` 提取电量，版本及更多状态没有完整展示。

## 按键：固件手势与 App 动作不是同一层

### 已确认的出站设置

官方2.3.0混淆命令路由 `com.huawei.hms.framework.network.grs.a$b.handle` 的完整 smali 中：

1. `GetUserSettings`：当前 profile 支持长录，或能力集合含2001/3001/4002任一时，发送 `getUserSettings`，params为空对象。
2. `MainKeyMultiClick(count)`：检查2001、count为2/3、当前未录音后，发送 `setUserSettings.params.mainKeyMultiClick`。
3. `LongRecordingLed(enabled)`：检查长录能力条件后，发送 `setUserSettings.params.longRecordingLedEnabled`。
4. `longPressMode`：已确认回报解析，未在此完整设置路由发现可写分支或取值定义；暂只适合只读原值。

这些 JSON 经命令发送器和当前 profile 编码后发给设备。对本卡，仍使用正确的 Telink业务通道1930/2B30、无响应写入，帧为 `11 30 + UTF-8 JSON`；不能退回最初交接中错误的 OTA 2B15 业务写法。

多击设置证据证明的是“选择一个2击或3击的固件参数”。**没有三套独立 single/double/triple 动作编号、任意动作表或下载脚本的证据。** 参数控制的具体固件动作仍需设置页说明资源、固件或受控实卡对照确认，不能把它擅自解释成“双击一定开始会议录音、三击一定开全天记录”。

### 已确认的入站事件

- Telink `keyEvent.params.type` 变成 `KeyEvent`；官方事件处理器仅在长录活跃且type为 `click/longPress` 时追加录音标记。
- `voiceCmd(start/release/abort,session_id)` 以及 `AA55 01/02` 二进制开始结束事件，是设备已经判定后的录音会话语义。App 接它们启动/结束收流，接收 Opus、生成Ogg，再交给转写/后续业务。
- 用户此前不运行官方操作、连续点击5次后卡片蓝灯闪烁并可连接，支持“进入可配对状态由卡片自身执行”。尚未分析固件内部按键计数算法，也不推广所有手势在所有固件上的精确定义。

由命令方向和事件语义可较强推断，物理多击识别及硬件录音动作主要在固件中，App提供配置和业务响应；此项是接口推断，不冒充固件反汇编结论。

SunMate现有四种动作下拉菜单是本地 App 策略，`updateConfig`只改内存，没有持久保存或下发主键次数。驱动目前只从录音会话生成pressDown/release/cancel，不能因枚举有single/double/triple就称实卡已上报。应区分“硬件交互设置”和“已知事件的SunMate动作”，按实际可上报事件收窄选项。

## 灯光：至少四类控制来源

| 类型 | 已确认机制 | 可以下的结论与限制 |
| --- | --- | --- |
| 配对等设备状态灯 | 用户五击后卡片自身蓝灯闪烁的既有实测 | 无需App画灯效。没有固件证据时，不编造其它状态的全部颜色表。 |
| 长录指示灯正常/低打扰 | `setUserSettings.longRecordingLedEnabled`，官方存在normal/low_disturbance说明及Boolean回调；3001使支持判断成立 | App设置、固件执行；与任意RGB调色不同。当前值需get/reportUserSettings回读。 |
| 语音处理结果灯 | `lightCtrl`，params `mode=4, success=boolean` | App报告业务成功/失败，固件解释预设灯效；不是录音启动ACK，不应虚报业务成功。具体颜色映射未由此确定。 |
| RGB控制 | 底层Light路由确有 `mode=7,r,g,b` 真实JSON发送分支 | 明确纠正此前“无RGB参数”的不完整判断。已确认官方编码可发送，尚未确认本卡接受、颜色范围或反馈；该分支只排除INT_MIN哨兵，不能据此认定固件允许任意整数。 |
| App定时提醒 | `OpenClawDisconnectAlertHelper.flashBoardLight`检查已配对后发mode5亮灯payload，协程5000ms后发灭灯payload | 至少一类提醒时序由App控制；不能把所有灯都说成固件固定状态，也不能推广所有重要通知都5秒后灭。 |
| 智能通知/规则灯效 | 官方 LightRule API、preview/evaluate 与mode5/payload转发链 | 一部分由App/服务器选择效果，最终由固件驱动灯珠；完整payload编码、节奏/亮度/时长仍需核实。 |

RGB路由直接取mode/r/g/b后发送，本分支没有找到Telink限定或3001 gate；因此不能把“能走通编码”升级为“当前卡已声明RGB支持”。还未恢复可核对的RGB颜色选择UI与Intent解析调用全链。不能把屏幕4002的unreadBadge/priorityMessage/agentTask三个开关当成这张无屏卡的通用通知灯设置。

`mode5`的字段名虽然是 `payloadHex`，路由对上游字符串实际做UTF-8/Base64处理，不能按名称直接拼任意十六进制。更不能自行猜亮度、频率、RGB打包或循环次数的二进制布局。

## 通知路径与平台差异

Android官方存在系统通知Listener、应用选择/过滤、事件处理、规则API及BLE灯效发送能力。这条路径里：通知由Android系统提供，App负责采集和策略，服务器可参与规则评估，卡片执行灯效；不是卡片自己连接互联网或运行App的智能体。部分Listener/上传/选择器方法仍受保护，不能称端到端执行和全部过滤参数已完整恢复。

已恢复的 `NotificationUploadTrigger.drainEvaluateBatch` 从本机Room记录组装通知指纹、应用包名/名称、标题、正文和时间，提交 `LightRuleRepository.evaluate` 对应 `/api/notification-intelligence/light-rules/evaluate`。这说明存在正文参与官方服务器评估的路径，不是只发“有新通知”布尔；它受采集总开关、网络、已配对和多类上传/评价门闩影响，也不能说所有通知都会上传或亮灯。该请求返回 `Response<Void>`，本轮没有证明服务器返回体直接携带灯序列，更未恢复云结果到重要灯turnOn的全部中间通道，不编造WebSocket/SSE。

LightRule DTO主要是名称、标题、描述、类型、重复次数、启用与时间元数据；创建提交ruleText，preview调用后端POST。没有由此得到一个可直接下发卡片的完整RGB/亮度/闪烁模型。按应用禁用灯效的本地缓存、系统通知读取权限、云规则enabled、4002屏幕开关是不同设置，应分别建模。

iPhone当前核对的是ANCS：iPhone是通知提供方，附件作为客户端接收；这一角色划分也见[Apple ANCS规范](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Introduction/Introduction.html)。此前本卡HCI中已观察到ANCS订阅。**允许卡片接收iPhone通知，不等于SunMate已经收到其它App通知正文。** 若要把卡片收到的内容交给SunMate，还需要确认卡片向App回传的具体协议；本轮未确认这一步，不能照抄Android的通知监听页来承诺iOS同等能力。

SunMate现有通知管理器有接收方法，但尚无已确认的卡片通知回传分支或Android原生监听接线；ANCS选项目前保存的是连接请求偏好和展示授权属性。官方云规则不应直接接入SunMate私有ASR/Hermes链路；未来可在已确认协议下由本地或私有端点制定策略。

## 页面与交互清单：哪些需要对应实现

| 官方页面/协议能力 | 归属 | SunMate当前与建议 |
| --- | --- | --- |
| 名称、SN、连接、电量、版本 | 名称有账号元数据，SN/状态来自卡片/账号核验 | 已有基础只读页，补真实固件版本/状态；云改名不能等同BLE广播改名。 |
| 主键2/3击、长录指示灯 | App写固件参数，卡片保存执行 | 应补能力解析、get/reportUserSettings、受限写入和回读确认；尚未实现。 |
| 长按即时语音 | 固件事件→App收流→后续业务 | 已有真实音频捕获证据；本地补丁已接二进制与JSON。ASR/Hermes是收到音频后的独立阶段。 |
| 长录、录音标记、文件列表/下载 | 固件录音与存储，App同步与管理 | Telink profile声明LONG_RECORDING/RECORD_MARK/FILE_RESUME；不能等同当前卡文件内容实测。SunMate未实现完整长录文件管理。 |
| 停止录音 | Telink编码器明确有11 21命令 | 可作为单独后续适配项；不能从通用HAL有pause/resume方法推导Telink支持暂停/继续。 |
| RGB、语音结果灯、通知规则灯 | App/固件/服务器各有分工 | 分为可核实命令和待验证payload，不能只加调色盘并假报成功。 |
| 可采集应用 | Android通知权限与App策略；iOS需独立ANCS/回传核对 | 页面应按平台实际能力展示，不跨平台照抄。 |
| 固件升级、设备离线日志 | 独立OTA或文件协议 | Telink profile声明，App尚未接入完整流程；不在此调查写OTA或下载真实日志。 |
| 解绑 | 账号解绑、卡片业务状态、系统SMP是不同操作 | 保留现有手动确认/旧密钥保护，不自动“清卡”。 |
| Wi-Fi传输、暂停/继续、屏幕设置 | 官方支持多型号的通用能力 | 本Telink profile不声明Wi-Fi和PAUSE_RESUME，本卡未报告4002；不能直接移植。 |

建议实施顺序是：先解析本卡实际能力与设置回报；再补主键2/3及长录指示灯的写入—回读—失败反馈；随后处理keyEvent/长录打标、独立验证RGB/通知回传，最后另做文件管理/OTA。每一步都保持真实AES和业务就绪门槛。此处为后续实现依据，本轮没有修改这些功能。

## REA证据索引（核心）

| 事项 | Evidence ID / 位置 |
| --- | --- |
| 命令服务类成员 | `ev_5b69c4269a99e52760dc0dcc212e048d7eeedb6a2d96fda973a8e85788182b19`；page/command-class.json |
| RecordingSettingsActivity字段/方法库存 | `ev_f7e3cd573ca49e73f4629aaba634bfe3c25efa09d7860bc608724f370ca2a48d`；page/recording-settings-class.json |
| Telink profile | `ev_e429083be6ad3a949f66fbd1624dd323b466e2e0f19ae4e3a18b5fae85e3c2f9`；page/telink-profile.json |
| 完整设置/Light命令路由（smali） | `ev_5756af562affe64ac376ca7195356ebda4ed40caa64576ce38a5b2a9abbaf9a9`；button/rea-command-router-dollar-handle.json |
| 动态能力集合判断 | `ev_7eb97fa12e48280d81a2b0904ca4126ba9744b236c17c22fa0d87dbbff01dc02` |
| 主键/设置回报解码 | `ev_5b1f7ac832cbe346415e81cb6e051d62a3c530184786e4c3e56dc8f2ca99852c` |
| 事件handler与录音打标 | `ev_02e3943ab14e82ec7f0b749d1137b2898636b9ef2eb3ee7a8e2fe86ed8c2e591` |
| LONG_RECORDING readiness | `ev_1f5cb955bc3feb3daadf83348614e1bffb50825d58855827c1fae561eb84fc8b` |
| 3001长录灯设置支持判断 | `ev_027ba231ca2a30057132f80f6df58632e6b89a32560ecfadd8efde1e016bcdc7`；light/supports-led.json |
| 语音结果灯mode4 | `ev_b8fbaaaea591786bba252cdeac5443825a3d4b961fced1583364e95aee8bea47` |
| mode5 sink入口 | `ev_fdc6733e99bec937ec64c3be71c48eb839da593c1f4b5610fad56c4edd8c4007` |
| App定时亮灭 | `ev_2506f6c7920dd7b9d8515192ba9f2b5eb9cd7e07e6576cc5be49e24cfaf67333` |
| 通知标题/正文云评价组装 | `ev_35bc572b0f37c0c96903ca76f4dd4c91d7a90a303faf9af27592061aa98d7e92` |
| 云评价Repository | `ev_012f9c1e02a000a0ea6fbab50fcbc23d96ac2a987b63c15460b934192491e28a` |
| 仍受保护的UI回报处理 | `ev_9650fe6b68bc2bc520d565e987fc652fb43bdbfed91f6f37e4bfa2f0b5b84975` |

按键独立完整索引和逐项来源见本机 `button/evidence-index.json`、`button/findings.md`；灯光/通知的补充来源见同级light目录。早期2.2.2记录仅作版本对照，不能替代上述2.3.0证据。

## 补充：SunMate 已连接状态的双击／三击实卡对照

以下是上述静态调查之后另行进行的会话内被动采样，不应与前文“本轮没有设备操作”的静态范围混读。用户保持现有 SunMate 连接，按开始信号操作卡片；没有写设置、切换官方 App、解绑、改密钥或接入 ASR/Hermes。官方设置页当前选择未回读，不能把测试表现冒充 `reportUserSettings.mainKeyMultiClick=2` 的实际回报。

| 操作 | 用户观察 | HCI安全元数据 |
| --- | --- | --- |
| 双击一次，等待后再双击 | 像开始后又结束录音 | 16:17:14.422 LONG开始，16:17:22.761 LONG结束，间隔8.339秒；12/4字节录音事件各一条；另有两条3字节控制事件，opcode均248（0xF8），含义未确认。 |
| 三击一次，等待约5秒再三击 | 没有明显反应 | 有效120秒窗口记录1721条PacketLogger记录；既有业务事件、实时音频、文件通道上均未捕获对应通知。 |

双击窗口没有实时音频或文件通知，不等于卡片录音失败。官方 LONG 路由走独立长录会话和分段文件同步；SunMate 目前没有完整长录文件同步，不能把它套用为长按 REALTIME 收流。两个0xF8控制事件值相同，不能据此构造双击与三击的不同动作；本轮官方decode已恢复的分支也未给它命名。

当前可下结论：**当前配置下双击能启停长录；三击操作未观察到可供 App 独立映射的事件。** 结合官方仅有 `mainKeyMultiClick=2/3` 选择，倾向于长录触发方式二选一，而不是两套独立动作。尚未回读配置、切换为3后再对照，亦无固件反汇编，不能宣称所有固件永远不支持独立双/三击。若要继续验证，应先实现/受控核对设置回读，再另行批准设置变化；本次未改变它。

证据范围：沿用此前同卡GATT的2B31/2B32/2B33属性句柄，双击录音形状及用户同步操作吻合。采样起点链路已建立，无本轮新地址/SN到连接句柄的独立证明；三击“未见通知”是本窗口观察，不能扩展成固件全部路径都无事件。PacketLogger旧设备元信息可能携带历史时间，分析基线改为首条HCI记录，设备墙钟单列，不标为UTC。

原始数据仅在本机忽略目录，未输出音频、凭据、地址或会话值：

- 双击：`tools/ios_ble_capture/captures/20261019T081633Z-d0c263/`；原始SHA-256 `03c022ba8470cab58c2c41164a0710f31722b69d2057a635e02754506111a221`。
- 有效三击：`tools/ios_ble_capture/captures/20261019T082150Z-6fdc39/`；原始SHA-256 `4427201ff1ababd9810bc946ee8854508dca5e48ba79d7e07cdf766691f68b7c`。
- `20261019T081912Z-9cee62` 的75秒窗口在操作信号前已结束，已告知用户并重新采样，不作为三击结论证据。
- 本机 `inspect_button_recording.py` 只输出长度、已知类型、控制opcode、计数及时间；两轮HCI/ACL重组均无损坏、无未完成分片，摘要SHA/事件顺序/8.339秒差及通知计数离线断言通过。未改App源码、版本或协议配置，不重复Flutter回归、不构建推送。

## 原始问题完成情况与缺口

- 已回答：能否以官方硬件页为对应功能依据、物理手势与App动作的分界、设置和灯的控制方向、当前卡实际能力、SunMate现有缺口。
- 部分回答：RGB编码与下发路径已恢复，具体本卡效果/参数范围尚未实测；智能通知云规则和BLE入口已确认，完整payload/监听处理链有保护缺口。
- 未解决：mainKeyMultiClick所选择的固件具体动作、longPressMode值含义、原官方UI写后匹配/超时策略、卡片ANCS正文是否及如何回传SunMate。这些不能用猜测或假开关补齐。
- 检查：原包/分析副本SHA复核、REA完整Java/smali及对应引用核对、历史抓包按目标归属白名单提取、SunMate源到字段/事件处理对照。未改运行代码，未为静态调查重复执行Flutter测试或构建。

## 后续本地实现：会议录音设置（未打包）

用户随后明确授权补齐会议录音双/三击与呼吸灯开关的本地实现和回归。此前正文中“尚未实现”的设置链现已在本地源码补齐，版本仍1.0.24+25；这不改变前文静态观察和实卡测试的历史范围。

- `recorder_hardware_settings.dart`：可选HAL接口与设备设置状态机；不扩展PhoneMicDriver必需接口。当前Telink连接真实AES完成后，读取能力、录音状态及当前设置；2001开放主键次数，3001开放长录灯。没有当前有效值或录音状态未知时不允许写入，不猜默认双击或默认开灯。
- `AiNote6095Driver`：复用已识别profile/命令通道和无响应写入；自动读取不写配置，修改只发送`setUserSettings`的单个已确认字段，再发送`getUserSettings`。`reportUserSettings`只在当前连接、主动回读窗口内接受；ATT完成、通用成功回执、提前/迟到回报不当作保存成功。二进制LONG开始/结束纳入录音状态锁，不将长录文件伪装成实时流。
- `DeviceNotifier`和现有管理页：提供会议录音触发次数二选一、会议录音呼吸灯开关、当前值、重新读取和保存/超时反馈。页面在HAL切至手机麦克风时仍订阅BLE设置状态变化。新字段加入安全诊断，仅记录设置值/确认状态，不记录凭据。
- 默认5秒截止；保存值不匹配、回报不完整、通信失败、录音竞争或断连均返回失败。写入可能已被卡片接受，失败时将设置标为未确认，要求用户重新读取；不自动重写、回滚卡片、清密钥或解绑。一次仅允许一项设置操作。
- 协议没有已确认的设置请求ID，因此“回读确认”指当前连接发出读取后收到匹配字段；无法声称具有固件事务ID提供的严格响应关联。断开/新连接会清空能力、当前值和待确认操作，旧异步续步不能推进新操作。

验证：新增状态机20项、真实驱动状态机/GATT6项、Widget6项，全量253项通过；包括AES测试挑战、目标业务特征及withoutResponse、单字段写入、无提前确认、缺字段/类型、超时/录音竞争/断连和旧密钥无写入。静态分析无error/warning，仅11条既有弃用info；差异检查通过。360×640、390×844当前设置截图及加载/错误交互检查均为合成Widget夹具，不冒充实卡或原生iPhone验收。

旧官方HCI白名单补查确认`recording.is_recording`及`is_long_recording`确为布尔字段（上述bcf6f9…来源），与解析一致；未读取密钥。本轮无真实卡片写入，具体双/三击切换效果、呼吸灯关闭范围和重启后持久性仍待后续用户明确要求打包后的实卡验收。真实AES、旧密钥保护、HAL多驱动及私有端点保持；未构建或推送。

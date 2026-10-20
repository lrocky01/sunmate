# C·ONE 设备能力与本地录音修复记录

2026-10-19，源码基线为1.0.24+25。按用户要求仅补实时录音和本地回归，不解绑、不改密钥、不接ASR/Hermes、不升级版本、不打包或推送。设备设置和按键扩展本轮只调查，不直接新增写硬件功能。

## 已完成的本地修复

- ble_protocol.dart 增加独立 TelinkRecordingEvent，识别已实测12字节开始和3/4字节停止；使用大端64位会话ID，拒绝零/负会话、未知类型、短帧和额外长度。官方代码允许开始长度至少12字节，本实现保守只接收本卡实测12字节。
- AiNote6095Driver 在 JSON 解码前分流二进制录音，不将二进制事件当鉴权或拼入未完成JSON。仅在本次真实AES、通道和连接就绪后启动实时会话，保留现有 JSON voiceCmd。
- 开始、音频及结束共用连接代次保护的有序队列，解决同一轮回调中首包先于异步开始处理完成而丢失的问题。完成后仍通过原HAL的音频和按键事件输出完整Ogg，未新增服务调用。
- 区分 REALTIME/LONG；长录音不混入实时音频，当前提示未支持分段流程，不伪造开始指令。拒绝孤立/类型不匹配的停止，重复开始不清空当前音频；JSON取消及断连丢弃未完成录音。
- 增加通知数、接收字节、会话外忽略数、最近完整帧数的安全诊断，不打印原始音频、密钥或通知正文。

停止协议边界：二进制停止帧自身没有会话ID，只能按当前连接代次、二进制活动会话和录音类型关联；无法从协议中恢复不存在的ID，因此不承诺能鉴别同一连接上任意延迟的同类型旧停止。不会凭空添加字段或向设备索要猜测ACK。

新增11项回归（telink_recording_test.dart）：大端布局/非法帧、同轮连续通知完整Ogg、重复开始/结束、错误类型隔离、长录音隔离、JSON分片交错、JSON成功/取消兼容、空音频、截断音频、鉴权前拒绝、断连后真实AES重连。与原有测试合计180项通过；flutter analyze --no-pub --no-fatal-infos退出0，无error/warning，11条既有deprecated info。git diff --check通过。

初轮新测试的“无额外写入”断言碰到原有异步RTC同步；核对TX内容后让测试等待RTC完成再计数，未删除RTC或放松鉴权，最终回归通过。实际HCI证据与独立解码见 [音频链路调查](IOS_BLE_AUDIO_LINK_AUDIT_2026-10-19.md)。手机当前安装包仍是未含补丁的1.0.24+25，不能把本地模拟回归当作新包真机验收。

## 按键：App动作与固件设置分别核对

当前SunMate的 ButtonActionConfig / settings_page 已有单击、双击、三击、长按动作选项，ButtonActionNotifier 会在收到对应HAL事件时执行动作。但：

1. AiNote6095Driver 尚未将官方 keyEvent 映射为实际单/双/三击HAL事件；simulateButtonEvent只是本地模拟入口，不是硬件上报证据。
2. updateConfig目前只更新内存状态，没有持久化，也没有发送固件设置命令；不能将UI配置当作卡片已设置成功。
3. TelinkProtocolAdapter.decode 确认 keyEvent.params.type；官方 BleDeviceEventHandler.handle 明确处理click/longPress，在长录音活动时追加标记。尚未证明当前卡会分别上报doubleClick/tripleClick等名称，不猜字符串或把任意二进制字节映射成点击。
4. reportUserSettings包含longPressMode、longRecordingLedEnabled和mainKeyMultiClick，以及unreadBadge/priorityMessage/agentTask。官方对mainKeyMultiClick仅保留2或3，说明存在双击/三击交互设置，不能据此推导出三个动作都可任意写入固件。
5. RecordingSettingsActivity存在requestUserSettings/setLongRecordingLedEnabled/requestButtonInteractionChange，以及pending/previous状态与3秒确认超时字段；这些受保护方法在当前2.3.0重建容器为真实空体，未恢复其完整下行参数，不能补一条猜测setUserSettings。

因此可以做App动作自定义，但需要先把真实按键事件、配置持久化、可执行动作和固件回读接通；不能把“会议录音”下拉项视作已核实的Telink App主动录音控制。本轮只补用户授权的实时录音入口。

## 官方设备页与数据来源

| 项目 | 已确认来源/流程 | SunMate实施边界 |
| --- | --- | --- |
| 名称和SN | 账号设备记录externalDeviceName/externalDeviceId，配合广播和设备事件核验 | 名称可作为App别名；不能据updateName接口声称已修改广播名 |
| 改名 | BleApiService.updateDeviceName：/api/device/toc/externalDeviceBind/updateName | 官方云账号元数据更新；蓝牙改名指令未证实 |
| 连接/电池/固件/录音状态 | 原生链路、reportStatus；官方有battery、version/currentVersion/firmwareVersion、recording等兼容字段 | 可统一只读显示；缺失字段显示未知，不能伪造 |
| 实时录音 | 2B31控制、2B32音频；两类事件入口 | 本地补丁已修，本轮不实现长录音文件管理 |
| 长录音与文件 | mode1，分段协调；2B33文件通道；11 22列表、11 26读取、11 24删除（均十六进制）；AA55 05/06元信息/结束，AA55 08文件列表 | 后续本地实现已补目录/分段/恢复/尾扫/校验合成及WAV播放入口；2026-10-20新增两用途录音期间闭合段同步，stop后完整归档；不读取当前写入段，不删除卡片源段，实卡验收待后续安装包，详见长录流程报告第7/8节 |
| 录音灯/交互 | reportUserSettings返回相应状态，设置页有待确认/超时状态 | 写入参数尚有保护缺口，待独立核对，不直接开放硬件开关 |
| 结果灯 | BleDeviceCommandService.voiceCommandUploadResult：lightCtrl，mode4，success | 完整静态命令已确认，不能假报上传成功，也不是录音启动ACK |
| 自定义灯效入口 | BleAsrWiring$sink$1.lightCtrl转发LIGHT_CTRL，mode5、payload_hex、可选title | 有入口不等于已恢复RGB/亮度/节奏编码，尚不能任意发hex |
| 通知灯效规则 | LightRuleApiService提供/api/notification-intelligence/light-rules 的list/create/import/patch/delete/preview/evaluate；模型有标题、规则文本、启用、重复次数等 | 包含服务器规则逻辑，并非全是卡片内设置；可研究私有端点等价实现，不直接引入厂商规则云 |
| 可采集应用 | AppReadPermissionHelper包含应用包名/图标、黑名单同步等App侧管理 | Android特有采集与iPhone ANCS需分别核对，不能直接照抄APK页面视作iOS已支持 |
| 固件升级 | /api/ota/client/check-update、upgrade-status-report，Telink OTA独立端点/SDK | 依赖适配固件与完整升级校验；本轮不实现、不测试、不向OTA写业务命令 |
| 解绑 | 账号解绑、系统SMP和卡内业务key是不同状态 | 保留现有手动账号解绑确认，不自动清卡、系统配对或key |

建议有独立“录音卡管理”页，将当前设置与诊断统一为：设备身份/连接、电池固件、真实AES状态、录音和音频统计、本机配置、诊断、明确的手动账号操作。先提供已核实的只读信息和本地动作；写固件项目需明确范围、回执和回读后再启用。截图用于功能核对，本轮未复制UI或新增未经证实的开关。

## 密钥与后续授权

本次已经走完真实厂商验机、X25519协商、安全保存与云绑定，且1.0.24+25用户日志有verifyIdentityRequest→真实AES应答→verifyIdentityResult success=true。因此当前不是缺少合法共享密钥。

- 日常同设备重连：本机安全存储密钥回答卡片AES挑战，不需要每次短信、官方App或厂商/check；autoReconnectLastDevice直接连接并loadKey，不依赖每次账号登录。
- 本机资料丢失但账号仍有sharedSecret：使用本人账号匹配真实SN/GATT恢复，再让卡片挑战验证；已有不同本机key仍拒绝覆盖。
- 清卡、重置或重新协商：旧key可能不再对应。当前已核对的首次流程仍需要官方真实/check签发材料；不能把旧key或自行生成的key当厂商首次授权。
- “自己授权”若指已配对卡的本地身份验证，SunMate已实现；若指完全取代厂商首次验机，目前没有已证实的纯本地方案。不能据蓝牙无需网络推导固件没有业务验证，也不预先认定必须申请SDK。
- 系统蓝牙“忽略设备”清的是SMP记录，不等于账号解绑或删除业务key。本轮无需再次解绑。

## 证据与未恢复范围

2.3.0静态工件SHA与REA Evidence ID沿用音频链路调查。设置方法证据位于tools/ble_audit/device-settings-20261018/：requestUserSettings ev_c8f988b04541e1fdedb096ff77f985c8f0188d6fc7e5cd519fc8e95785a55753；setLongRecordingLedEnabled ev_4793544b9ce7e8aacdf23d0e542084e47c8b2989ee7ac87766aaaff8d840e851；requestButtonInteractionChange ev_9d09fb2f58d9d5f5bf709a04b7d64895d41730f5ec09b1a998d66f330e2d94d0。这些记录确认空体，不能作为完整写入实现的证据。

续查读取同一批recovered-1.dex/recovered-2.dex的LightRuleApiService、LightRuleMeta、BleApiService、BleAsrWiring$sink$1、BleUserSettings与官方完整decode/handler；没有执行官方App/服务请求、没有重新绑定或读出真实密钥值。反编译的可见配置、方法体、实际HCI证据已区分，未宣称APK全部解密或全部设置已验证。


## 后续：启动自动重连已在本地补齐

用户随后要求修复关闭后重开App没有自动连接。main增加RecorderConnectionLifecycle桥接，DeviceNotifier监听前台状态和已授权设备的蓝牙on事件。底层增加已验证材料预检与受控重连，匹配v2上次设备、previouslyVerified路由和本机密钥，接入后仍通过既有SN/GATT匹配及真实AES，不调用账号接口，不重绑。仅有待验证key、损坏元数据或缺key时保留手动入口，旧安装需要先完成一次手动验证产生可靠路由。

同一时间仅有一个自动流程；手动断开/取消在本次App会话内抑制自动连接，明确手动连接可恢复；前台恢复、蓝牙重新开启时可再尝试，未新增定时无限重试。后台、正在连接、已连接及手机麦克风模式不新发起自动连接。生命周期回调注销，异步读取后的连接意图守卫避免手动取消后迟到启动，provider释放后不更新状态。

新增14项回归，与录音补丁合计194项全量通过；静态分析退出0，无error/warning，11条既有info；diff检查通过。App版本仍1.0.24+25，未打包推送、无真实设备状态操作。现有基础设置与诊断入口保持，尚未实现截图所示完整维护页；新启动行为需后续包真机验收。

## 后续：截图式管理页已在本地补齐

首页“录音卡设置与诊断”现进入独立分组管理页。显示BLE专用设备名称、可复制SN、连接/验证状态和电量，接入现有通知连接偏好、录音状态与音频统计、App按键设置、账号恢复与手动解绑入口、蓝牙诊断。通知偏好下次连接生效，不等于系统已授权或灯效已下发；录音信息不依赖ASR/Hermes。设备名称当前只读，改名、硬件灯效、应用筛选及OTA仍明确标示未接入，没有伪造开关或新增未经核实的写入。

新增6项Widget回归，全量200项通过；分析退出0，无error/warning，11条既有info；diff检查通过。360×640与390×844的管理页及下半部截图使用合成数据，已逐张核对；独立只读复核结论ship，范围仅为此次Widget页面和导航，不代表真机安全区、大字号、深色模式或硬件发布验收。截图保存在忽略目录build_output/recorder-management-local/。

## 文件备份可行性与当前实现边界

当前RecorderBindingBackupStore只在安全存储内保存并读回验证归档，没有文件导出、导入或分享入口。日常同密钥重连已经使用本机AES验证，不需每次官网或短信登录。

可行后续方案是用用户密码派生密钥及认证加密封装版本、SN、协议和业务共享密钥，使用随机盐和nonce，不包含手机号、验证码、账号Token、系统SMP密钥或私有服务凭据；密码不随文件保存。具体算法参数尚未选定或实现。导入需验证完整性与格式、匹配真实SN/GATT，不覆盖不同旧密钥，并在卡片真实AES挑战通过后才标记已验证。

备份不能迁移iOS系统蓝牙配对或保证跨手机UUID相同；系统配对仍需正常建立。卡内密钥未变化时，可用备份恢复而不重新登录官方账号；重置或重新绑定产生新密钥后，旧备份不能替代新绑定。完全取代厂商首次验机的纯本地方案仍未证实。本轮只核对方案，未实现文件导入导出、未导出真实密钥、未变更安全策略。

本轮保持真实AES、旧密钥保护、HAL/多驱动和私有端点，保留已有录音及自动重连补丁。版本仍1.0.24+25，未提交、推送、打包或操作真实设备/账号/密钥；手机现有安装包尚无本轮管理页。

## 后续：密码加密文件备份与离线导入已在本地实现

用户随后明确要求实现文件导出和导入，因此上节“尚未实现”仅是前轮状态。现有管理页的“本机密钥与恢复”进入实际备份页：选择已完成AES的本机卡片，设置并再次确认密码，通过系统文件选择器保存`.sunmate`密文文件；选择文件、输入原密码并确认SN后，将材料存入本机安全存储。导入后保留独立的连接验证入口，重启App仍可读取，不要求手机号或账号Token。

### 文件与存储边界

- 固定v1格式，PBKDF2-HMAC-SHA256派生256位文件密钥，600000轮，16字节安全随机盐；AES-256-GCM使用12字节随机nonce、16字节认证标签及固定AAD。参数与版本导入时严格匹配，不接受文件提供的任意计算成本。计算在独立isolate执行，避免阻塞UI。
- 加密载荷仅包含格式版本、SN、设备名、Telink协议及32字节业务共享密钥。不导出手机号、验证码、账号Token、旧手机UUID、系统SMP资料或私有服务凭据；密码不写入文件或本机存储。当前仅开放已验证的Telink卡片备份，不声称已适配其它协议。
- 密码至少12个字符，导出二次确认；忘记密码无法解密。文件最大16KB、密文字段最大4096字节，读取流另做累计限长；错误密码、密文/nonce/盐/标签修改以及不支持格式均拒绝。
- 文件插件只接收密文；不创建明文临时文件，不写剪贴板，不记录密钥/密码。系统选择器可能缓存密文。Dart不可变字符串和垃圾回收不提供严格内存擦除保证；不声称完全消除了进程内暂存。
- 导入时检查该SN已有身份与活动密钥，以及独立导入存储内旧备份；不同密钥拒绝覆盖。导入成功只表示资料在本机安全存储中，不能作为卡片身份已通过的证据。原账号解绑归档保持独立，没有读取或导出用户真实资料。

### 离线恢复与鉴权

备份页独立扫描，仅展示匹配SN的真实广播；连接时要求新鲜可连接广播，再在完整GATT识别后匹配SN及协议，将备份密钥映射到当前手机扫描出的UUID。已有不同UUID活动密钥或身份冲突则失败，旧手机UUID不用于跨手机路由。此能力复用既有连接状态机，明确标为离线备份会话，不发bindRequest、厂商/check或云/bind，也不接受卡片首次验机请求来重协商。

映射后继续原本真实AES挑战。仅收到本次verifyIdentityResult success=true且事件/音频通道就绪才记录已验证和自动重连资料；失败保留待验证材料，不自动解绑、清卡或重协商。卡内密钥不变时，日常连接或用备份换机恢复可以不登录官方服务器；系统SMP配对仍是手机与卡片正常建立的独立步骤。重置或重新绑定更换业务密钥后，旧备份失效，不能替代新的真实首次绑定。

### 本地验证与未覆盖范围

新增21项回归（11项实际密码/存储/驱动，4项文件边界，6项Widget），全量221项通过。包含生产600000轮加密往返/随机性、密码和篡改拒绝、限长/KDF参数约束、旧密钥冲突、不同手机UUID映射、AES拒绝与首次验机拒绝、取消/输入/原生选择器错误反馈、重启后资料读取和独立SN搜索入口。静态分析无error/warning、仅11条既有弃用info；diff检查通过。

新增固定`file_picker: 10.3.10`及两个传递依赖，未升级现有依赖。已核对其已安装iOS实现：saveFile以密文字节写入后调用系统文档导出，pickFiles以文档导入返回文件流；资料来源为包源码及[包API说明](https://pub.dev/packages/file_picker/versions/10.3.10)。项目现有iOS15部署目标保持，没有增加媒体权限。

两种手机尺寸的空态/导入态，以及390×844导出密码与离线搜索截图仅使用合成测试资料，存于忽略目录`build_output/recorder-backup-local/`。这些Widget截图不包含真机键盘/系统文件选择器，不能代替iOS原生插件、文件提供方或实卡恢复验收。真实设备AES协议、HAL、PhoneMic、多驱动及私有端点保持；版本仍1.0.24+25，未提交、推送、打包、真实解绑或导出真实密钥。

独立页面复核唯一P2是部分取消操作静默结束；已补导出密码、选择文件、导入密码和导入确认取消反馈及测试，重采截图并复核原P2为resolved、disposition ship（仅页面范围）。更改后全量221项与分析再次通过，未以截图或模拟设备替代原生文件提供方/实卡验收。

## 后续：REA硬件设置与灯效续查纠正

用户再次要求沿官方硬件页面确认交互归属。本轮从2.3.0完整底层命令路由补出了此前UI保护空体之外的证据：`getUserSettings`、`setUserSettings.mainKeyMultiClick=2/3`（2001且未录音）、`longRecordingLedEnabled`，以及`lightCtrl mode7,r,g,b`的实际编码发送。因此上文“写入参数未恢复”“不能任意RGB”的早期状态应细化为：这些明确参数已恢复；硬件当前取值、执行回执、RGB范围和复杂payload仍需确认，不能假报已实现或实测。

既有官方iPhone抓包经目标归属白名单提取，本卡实际报告`[1002,2001,3001]`三次；2001是多击次数设置，3001直接使长录灯设置支持判断成立，1002业务含义未可靠映射。4002未报告，不能把它对应的屏幕开关算给这张卡。多击参数不等于单/双/三击各自任意动作映射；从接口方向判断手势识别与硬件录音主要在固件，App配置并处理语义事件。

灯效同时有固件状态灯、App设置的长录正常/低打扰、App上报处理成功/失败的mode4、App定时mode5与RGB mode7；官方智能通知规则还有服务器评估，后半上传链确实可含通知标题/正文。ANCS系统授权不能等同卡片已向SunMate回传通知正文。详细能力表、证据ID与未解决项见[硬件交互调查](RECORDER_HARDWARE_INTERACTIONS_AUDIT_2026-10-19.md)。本轮仅调查与文档，无App代码、设备或服务器状态变更，不打包推送。

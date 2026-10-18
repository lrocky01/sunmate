# 官方设备设置页与 iOS 连接 pending 核对

## 当前结论

用户确认 Android 官方 App 登录后能看见保存设备，系统配对后可保持一分钟且按键有响应。说明这张卡当前有可工作的官方 Android 路径；不能由此证明 iPhone 的系统配对状态正常，也不能证明每次账号设备接口都返回共享密钥。

随后用户补充：**同一台 iPhone 的官方 App 也连不上**。因此本轮现象不只发生在 SunMate；当前排查优先级转为 iPhone 与卡片的系统连接/配对状态，不再把补登录字段当作已确定的解决办法。旧 bond、卡片切换主机后的状态等仍是候选原因，尚无 HCI 或明确设备错误予以证实。已请求只读查看 iPhone 蓝牙列表归属和状态，不要求忽略设备或解绑。

SunMate 1.0.16+17 的明确日志为：11:20:09 发出 connect_requested，CBPeripheral=connecting；随后 90 秒没有 connected/GATT，App 截止后发 cancel_requested，系统返回 disconnected、error=nil。每 10 秒重复的 nativeTime 是读取最后事件快照，不是重复 connect。用户反馈「仅录音连接」仍失败，但尚未提供显示 RequiresANCS=false 的该次完整日志，不能当作已观测到的精确状态。

**当前先卡在 iOS 系统连接。账号信息缺少共享密钥可能阻塞后续业务验证，但目前没有证据表明它造成这次 GATT 前的 pending。**

## 三类资料不能混淆

| 资料/状态 | 用途 | 不能据此推出 |
|---|---|---|
| 账号设备名称、SN、MAC、类型 | 找到自己的设备、选择已保存记录 | 当前蓝牙已连接 |
| 业务 sharedSecret | 回答录音卡 AES 身份挑战 | iOS SMP 系统配对已完成 |
| 手机系统保存的 BLE bond、通知授权 | 蓝牙链路安全、ANCS 通知许可 | App 的业务鉴权已通过 |

官方 BleSavedDevice 包含 macAddress/deviceName/key/snCode/uuid/deviceType/autoScan/savedAtMs，是本地模型。不能把本地字段存在推导成手机号登录响应一定有所有字段。此前两次真实 App 渠道查询中 extInfo 缺 sharedSecret；那些是 Android 后续正常连卡之前的结果，不复用为新的查询结论。

## APK 中的连接与配对证据

- BleConnectionCommands 对 Connect/Reconnect 分支构造设备选择，再交给 BleGattSessionController.connectToDevice。后者解析本地设备地址、选择插件/profile、停止扫描、准备通知计划并启动 GattConnection；当前方法反编译有控制流警告，不能把其所有条件视为完整源代码。
- Telink GattConnection.connect$1 调用 Android device.connectGatt(context, false, callback, TRANSPORT_LE)。它是实际系统 GATT 连接入口，不是云服务替手机建立蓝牙。
- BleBondPlatform.createBondForCurrentDevice 调用 Android BluetoothDevice.createBond()；getRequiresSystemBond 由 profile 的 SYSTEM_BOND 能力决定。iOS 没有可直接移植的 createBond API。
- 该方法的静态 incoming references 找到 BleDeviceEventHandler.handle 中三个直接调用；2.2.2 的已保留方法内容可见 BindAcknowledged 成功分支、BondRepairRequested 和 BondInvalidated 分支。它们已在处理设备事件，不能解释 iOS 尚未 GATT 时缺少哪条设置指令。静态引用不保证覆盖所有动态调用。
- 未取得官方 iOS 包或本次 HCI/空口记录。不能确认本次是否为旧系统 bond、可连接广播/射频、系统服务接入或其它平台问题，也不据 manufacturer 字节变化猜固件白名单。

根目录忽略区中的可复查证据：

| 文件 | Evidence |
|---|---|
| tools/ble_audit/rea-20261018-connect-device.json | ev_f935bdc006e6fa1b810b0cc9724672889e87f31a10e74b4c5365ad40d1dd9707 |
| tools/ble_audit/rea-20261018-create-bond.json | ev_d02771b7dcc99bf3ccfe73695622b5526da0ec92f4d2bf02ccbcbc735e0e2ae6 |
| tools/ble_audit/rea-20261018-bond-callers.json | ev_6a07b3284e628b8b8d956970764b61905df894497c67ed328be832cb8a3807af |
| tools/ble_audit/android-live-2.2.2/rea-first-connect-handler.json | ev_1c8077e16e82dec6baab27073157a1475ffa1e80a74ff346d5149b5f2d82af9b |

2.3.0 分析副本 SHA-256 cdaf78f1abb2bdbc57430eb8b54b82e00ed264099c0f12ddc26814de1f3a7318；2.2.2 从用户平板提取的原 APK SHA-256 d0544afdfee9ede59fbe669b24729a48b00d921c28e435fe07c40e997e7ff9fd。重建分析副本用于恢复代码，不安装到用户设备。

## 官方设置页实际内容与限制

官方 DeviceSettingsSection 的入口在有 BleSavedDevice 时进入 BleDeviceManagerActivity，否则进入账号设置。管理页 binding 有名称、SN、连接状态、灯效、录音、屏幕、应用读取权限、固件和解绑入口。非空 Compose/导航代码证明：

- 电量仅在 Connected 时显示。
- 录音设置要求 LONG_RECORDING 能力且业务 isPair。
- 屏幕设置行要求屏幕能力，打开也需 isPair；不能在无屏幕 Telink 卡上直接照抄。
- 灯效跳转 LightRuleListActivity；应用读取权限跳转 AppReadPermissionActivity，不能等同于 iOS ANCS。

完整性限制：2.2.2/2.3.0 分析副本中的管理 Activity 多个 init/render 方法为空体；requestUserSettings、setLongRecordingLedEnabled、requestButtonInteractionChange 也为空体。能确认入口和部分门控，不能声称全部还原，不能由名字造灯效、按键或 OTA 命令。

上述 REA JSON 已保留在 tools/ble_audit/device-settings-20261018/：

| 文件 | Evidence |
|---|---|
| sunmate-device-settings-open.json | ev_b863ea4787d611058a0849ea679554e4214f4d66142a9b132daf1479db6bf80c |
| sunmate-settings-link-4.json | ev_6f845cb28a10d99501426d9f45fb29a72203aaafa41748c697494b713f08497b |
| sunmate-settings-navigator-recording.json | ev_0e988151c6900a10eb35f09090b173190cd0cebdbd3989de61ef66f7c6ea3002 |
| sunmate-settings-navigator-screen.json | ev_040093a0d16375d6531cb5d16bb9fcbc06d8ffdc551163e65ed03e53e7f15613 |
| sunmate-manager-renderConnectionStatus.json | ev_816f9114007ee9d5eca84f7439c944d7a8a5bef8a8c7ceec51968b3979e9bbfe |
| sunmate-recording-settings-0.json | ev_c8f988b04541e1fdedb096ff77f985c8f0188d6fc7e5cd519fc8e95785a55753 |

## SunMate 1.0.17+18 的对应处理

沿用现有 HAL 与账号连接入口，新增真实状态展示，不复制没有实现依据的设置项：

- 账号设备页展示 SN、账号类型、是否返回 MAC、共享密钥可恢复/未返回/格式不匹配；不显示密钥值，不发新的账号接口请求。
- 搜索页可展开设备资料、明确选择是否请求 iPhone 通知；错误和设置都能在小屏滚动，避免顶掉设备列表。
- 录音卡设置与诊断页分别展示链路、GATT、设备身份、录音通道；本轮身份尚未加载不被写成「本机没有密钥」。验证失败后也不被写成「从未执行验证」。
- 原生只读快照新增 central_state、connection_pending 和 system_connected_match；只查询 HID/两个已知录音服务并返回所选 UUID 的布尔匹配，不导出其它设备列表。Apple 说明系统列表可能包括其它 App 已连接的外设，但仍需本 App 调 connect 才可操作。[Apple API](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveconnectedperipherals(withservices:))
- 广播日志新增 connectable、RSSI 和扫描结果时间差；不把扫描到名称当作当前一定可连接。周期快照标记为 snapshot lastEvent，避免误认为重复事件。
- 不修改协议、SMP 安全配置、厂商鉴权规则或私有 ASR/Hermes，不自动清系统 bond、解绑或重置卡片。本版用于缩小范围，未证明修复实体 pending。

## 下一步对照

关闭 Android 蓝牙后，先测试同一台 iPhone 的官方 App 能否保持一分钟并响应按键；若提示解绑/重置则停止。若官方也失败，先调查 iPhone/卡片系统连接；若官方成功，再退出官方 App，用 SunMate 对照新原生快照。保留 RequiresANCS=false 的完整失败日志。只有进入 GATT 后，才用新的账号资料状态和实际 /check /bind /AES 回执判断业务材料是否缺失。

本次官方 iPhone 对照已反馈失败，接着查看「设置→蓝牙」的目标卡是否在我的设备/其它设备、是否已连接。可先按原厂正常方法关机再开机、确认 App 蓝牙权限；Apple 的常规排查也先列出这些步骤。[Apple 支持](https://support.apple.com/zh-cn/111804)。不根据猜测要求恢复出厂或清除 Android 的现有成功绑定。

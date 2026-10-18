# 官方录音卡页面、服务器资料与 SunMate 字段对照

2026-10-18。此表区分静态APK结构、SunMate源代码和用户实机结果，不能把其中任一种证据替代另两种。

## 回答范围

能确认设备页结构、部分显示条件、账号设备列表模型及共享密钥使用链；尚未完整恢复全部页面和设置操作。没有官方iOS安装包或当前官方Android会话的完整网络抓包。因此不能宣称「官方实际收到了哪些全部字段和值已经查清」，也不能用模型字段数充当服务器本次响应的字节数或字段实填数。

## 服务器设备列表：4个一级字段，6个叶子字段

入口为POST `/api/device/toc/homePage/pub/index`，官方 `BleHomePageBean` 的业务字段为 `deviceList`。不计通用返回封装code/data/message等，每条 `BleDeviceInfoBean` 声明4个一级字段，其中extInfo再含3项，即3个一级标量+3个嵌套标量，共6个叶子字段。

| 字段 | 官方用途 | SunMate如何读取 |
| --- | --- | --- |
| externalDeviceId | 设备SN，保存到本机snCode | 校验SN、账号设备选择及真实卡SN匹配 |
| externalDeviceName | 设备名称，本机deviceName | 账号设备名、同步绑定时使用 |
| deviceType | TELINK/AiNote等profile类型 | 摘要显示、恢复材料与实际GATT协议匹配 |
| extInfo.mac | 本机记录的设备地址 | 检查是否返回；iOS连接使用CoreBluetooth UUID，真实验机仍用卡片上报MAC |
| extInfo.sharedSecret | 本机key，回答AES挑战 | 校验Base64原始32字节；匹配后安全保存，仍需本次挑战验证 |
| extInfo.uuid | 设备已有标识 | 验证格式；真实新绑定同步时保留合法原有值，不编造 |

2.2.2和2.3.0的BleDeviceInfoBean一级字段一致。已检查2.2.2具体类源码，字段无另一套SerializedName别名。官方云同步回调直接读取extInfo.getSharedSecret并放入BleSavedDevice.key，没有证据显示存在忽略的隐藏密钥解密步骤。模型字段均可为空，不保证服务器填满。

SunMate不是只取名字和SN：上述6项均有读取点。没有旧密钥时，完整登录本身也无法计算AES答复，必须取得旧共享密钥或被卡片接受的真实新协商。

用户最近明确反馈「账号未返回共享密钥」。按当前实现，该状态表示extInfo是对象、其中不含sharedSecret键；若扩展不是对象、键已返回但格式无效，显示的是另外的状态。尚不能由该摘要判断整个响应共有几个额外字段，也不能推出官方App本机没有缓存旧key。

## 设备页并非全部由这个接口填充

| 页面内容或入口 | 已确认来源 | 尚未恢复的部分 |
| --- | --- | --- |
| 名称、SN | 账号资料可同步到本地BleSavedDevice；蓝牙事件也可上报SN | 管理页renderDeviceInfo为空体，不能声称完整显示赋值已复原 |
| 连接状态、状态圆点 | 本机BLE状态；Compose非空代码读取sharedScanState | 管理页实际render方法为空体 |
| 电量 | BLE状态batteryLevel；Connected时显示并限制0至100 | 未证明管理页另有电量控件 |
| 录音设置 | 设备能力、isPair、BleUserSettings | requestUserSettings、灯光及多击修改方法为空体；不造指令 |
| 屏幕设置 | 设备能力和isPair | 无屏Telink不照抄，修改时序未完整恢复 |
| 通知灯效 | 存在LightRuleListActivity及加载/新建/删除/预览入口 | 规则数据、请求和BLE执行尚未完整追通，不能认定都来自设备列表 |
| 固件更新 | 另有OTA服务和OtaFileInfo模型 | 版本展示、比较、下载与升级UI时序尚未完整恢复 |
| 应用读取权限 | Android权限功能入口 | 具体权限全流程未恢复，也不能等同iOS ANCS |
| 解绑 | 页面有确认/同步相关成员；另有设备及云解绑命令 | 管理页触发/确认空体，不据此自动执行解绑或重置 |

## 已找到的设备服务接口边界

BleApiService本次库存共8个方法：设备列表、批量绑定状态、验机check、同步bind、解绑unbind、改名、OTA检查、OTA状态上报。批量绑定状态模型item含sn/bound/sign；sign不是sharedSecret，且本次incoming引用未恢复调用者（0个JADX using node不等于运行时不会调用）。本轮未据此发实际请求、未擅自把sign加到当前卡的绑定包。

/check的hmac来自真实设备encrypted/mac/sn挑战，属于验机答复；X25519的32字节共享密钥由双方公钥协商而来，后续可保存到本机并经/bind上传账号。不能把hmac、sign、jwtToken、SN、uuid互相替代。

## 最新日志的边界与下一步

1.0.18+19于721ms连接、1558ms完成GATT、1677ms写入正常bindRequest、1736ms收到bindError。没有verifyRequest，因此还没进入云/check。本次不是服务器已经拒绝HMAC，也不再是系统连接pending。

官方bindError解码取error→reason→message→status；事件处理记录原因并stopPairingAttempt。SunMate原先丢弃了这些原因。1.0.19+20补失败详情的安全摘要；仅保留有限描述词/数字状态码，未知文字隐藏，不序列化整个响应。账号诊断同时显示原始响应字段数量、6个已知字段的缺失/null/空/非空及额外字段数量，最多前5条；额外名称和值不输出。

新版只补证据，不声称修复了卡片拒绝。保留现有系统/业务绑定，等卡片具体原因再确定恢复或由用户确认迁移流程，不自动清系统bond、不自动发unbind、不重置卡片。HAL及私有MOSS-ASR/Hermes直连保持不变。

## 本地证据索引

以下文件在忽略目录，未提交APK、真实账号响应或凭据：

| 证据 | 位置 |
| --- | --- |
| ev_d6cada4ae276abf61c7f07d8b18ff2749e99a0bb6f38684e2d6f394c31f5064b | tools/ble_audit/android-live-2.2.2/rea-account-device-fields.json |
| ev_931e9b9e85be3200dcf1440cdc8319329b66070062208288c4b78e73288302a3 | tools/ble_audit/android-live-2.2.2/rea-account-home-fields.json |
| ev_ce2c6d76163a5d5df9ab211602cc73f59876aeda464ed317ede13c42819ffd72 | tools/ble_audit/rea-account-device-fields-230.json |
| ev_90dbed30bb7496bb8eb52bd96b6cdcab1e90cf819dc4af9727b9e4cc9d037eee | tools/ble_audit/keylookup-20261018/sunmate-keylookup-ext.json |
| ev_4bdb2bf1a9f98824d93339b39c55aca69545695796ec620265c60167ce82f4cc | tools/ble_audit/keylookup-20261018/sunmate-keylookup-sync-result.json |
| ev_c17e6d1c02f66c3c553632a5145e70f2319bba7a9e3e610538d38a4dd6e3ead3 | tools/ble_audit/android-live-2.2.2/rea-binderror-decode.json |
| 常量补核error/reason/message/status | tools/ble_audit/android-live-2.2.2/binderror-decode-literals.java（JADX --no-replace-consts） |
| ev_ca8bd1de82f76e8bb4da739195fc666e906724a714fc4746f52aca9f73e3847e | tools/ble_audit/android-live-2.2.2/rea-binderror-unbind-contract.json；仅静态契约，未执行 |
| ev_0cc6822c8d3a7b979de993770573f97566aec38da2a3bcf0f8b7eda2f391a06a | tools/ble_audit/android-live-2.2.2/rea-account-batch-callers.json |
| 页面结构/来源/空体边界 | docs/IOS_BLE_DEVICE_SETTINGS_AUDIT_2026-10-18.md及其device-settings-20261018证据 |

## 继续核对结果

后续找到官方本地key补上传入口，并用两版原始跳转确认sign类参数仅AI_NOTE_6095入口接受；新增接口、存储/回滚和实际Android页面核对见 [已绑定缺key续查](IOS_BLE_BOUND_KEY_RECOVERY_2026-10-18.md)。该补上传不是读回旧key，尚未执行。

# 安卓官方 App 连接取证：现场状态与日志路径

2026-10-18。前半轮记录官方真实连接，取得系统诊断包但包中没有所需连接报文。随后用户确认新账号已返回可恢复密钥，并明确同意定点修复广播SN匹配、检查后构建1.0.20+21；实现与验证见[1.0.20说明](IOS_BLE_TEST_1.0.20.md)。以下系统采样记录不代表已取得握手，未代操作解绑或重置。

## 实际观察

- Android USB/ADB 在线；安装的是官方 2.2.2，先前提供的 2.3.0 仅用于静态对照。
- 用户确认关闭 iPhone 蓝牙，并将卡片放在 Android 旁边。
- 初始系统 resumed activity 先为官方 `LoginActivity`，随后为 `LoginCodeInputActivity`；用户自行处理登录，不读取输入框、验证码或账户凭据。
- 针对官方单进程及有限 BLE tag 读取已有 logcat，命令成功，但没有可保留事件。没有清空日志。这不能证明没有执行过业务鉴权，也不能恢复过往连接的完整报文。
- 用户随后确认已开启 HCI 日志并重开蓝牙。但标准 snoop 属性、settings 和蓝牙 dumpsys 仍未显示完整 snoop 开启；不能仅根据配置读取断言用户未操作，也不能仅根据用户开启证明已取得 payload。
- 17:40 和 17:42，REA 截图均确认官方 `BleDeviceManagerActivity` 的 C·ONE 设置页显示目标 SN、已连接、电量 85%。这是两次页面观察，不是全程逐秒监听，也不能替代实际 AES 回执。
- 用户明确此次使用**新账号并重新绑定**，不是原账号无 key 恢复。成功绑定可用于首次协商对照；不能由此宣称原账号的丢失 key 已找回。卡片密钥是否改变仍需协议证据，但不能继续假定此前 Android/iPhone 的旧材料有效。
- 17:47 通过设置 UI 层级核对 HCI 开关确实 checked=true；未由代理改动该开关。说明标准属性未显示开启不能用于否定用户操作。
- REA 正常 `adb bugreport` 完成，耗时约397秒，ZIP 8,384,236字节、7399个条目。完成后检查全部条目，未发现独立 Bluetooth HCI/BTSnoop/BTSnooz 或 bt/hci 命名的厂商候选日志；唯一名称含 bluetooth 的条目是蓝牙音频HAL调试文本，不能替代GATT报文。
- 包内主文本42,715,892字节，BTSNOOP_LOG_SUMMARY/BTSnooz段为0；六个目标业务方法名计数也均为0。没有据此推断实际未执行这些方法。未向外上传整包或打印原始系统日志。
- 常见公开日志路径不存在，系统日志目录普通ADB访问被拒；未尝试提权读取。随后通过正常启动入口返回官方MainActivity，未打开未知调试/反馈/激活入口。

## 本次采样能做与不能做的结论

已确认这台设备的HCI开关在UI开启、官方新账号重新绑定后两次页面观察均保持连接。**采集系统诊断包成功不等于采集协议成功**：本包没有可用于还原握手的HCI记录，无法给出真实TX/RX顺序或此前bindError的具体原因。具体日志保存位置及该机型系统导出为何没有收录仍未确认，不将其称作确定的系统故障。

用户随后只读查询新账号，明确返回“可恢复，仍需卡片验证”。已获得格式/协议可恢复的材料，但仍须新鲜AES挑战验证后才能认为恢复成功。续查发现现有驱动忽略广播SN，导致无SN身份挑战跳过恢复；已离线复现并在用户确认后定点修复，不将它冒称为本次系统抓包所得结论。

## 为何普通 logcat 不够

REA 静态核对两版 XLogUtils：`ensureLogDir()` 使用 `getFilesDir()/xlog`，即 App 内部私有目录；不是普通 ADB 可读的外部存储。`initMarLog()` 明确 `setConsoleLogOpen(false)`，只看到这一处设置调用。

`exportLogZip()` 调用 flush 后，原样将目录压缩到 `getCacheDir()/exports/app_log_<timestamp>.zip`；没有解码或脱敏。找到的调用者是反馈日志收集器。没有实际进入反馈、打包或上传日志。DebugSettingsActivity 有导出/分享相关方法名，但方法体未恢复，不能据此断言当前可见页面有导出按钮。

`appenderOpen` 的公钥参数为空，不足以证明 `.xlog` 是明文。FileProvider 未公开导出，也不意味着能凭 URI 读取任意私有文件。本轮没有尝试绕过私有目录访问控制。

## 下一次采样的具体步骤

1. 用户自行完成官方正常登录；本次已完成，并明确换了账号及重新绑定。后续保留当前账号绑定和系统配对。
2. 在 Android 开发者选项开启蓝牙 HCI 日志，重开 Android 蓝牙；用户已确认完成，实际 payload 是否留存待检查。Android 官方文档明确要求重开蓝牙使日志生效，见[验证和调试蓝牙](https://source.android.com/docs/core/connect/bluetooth/verifying_debugging?hl=en)。
3. 记录连接前、连接结果和保持一分钟的时间点；仅操作正常连接，不点击解绑、重置或未知激活流程。若出现重新绑定要求，先保留提示。
4. 本次系统bugreport未包含所需蓝牙日志，不重复收集同样的大包。原始文件只留本机忽略目录。AOSP 提供 [btsnooz.py](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/refs/heads/main/system/tools/scripts/btsnooz.py) 提取内存日志，但本包连对应摘要段也没有，不能声称可由脚本恢复缺失报文。
5. 只在报告保留相对时间、目标通道、指令名、回执类型和必要的错误原因；不打印共享密钥、HMAC、随机挑战、账号令牌、手机号或录音数据。采样后关闭本轮开启的 HCI 日志。

## 哪些结果才能回答当前问题

| 观察到的实际报文 | 能支持的结论 | 仍不能据此推断 |
| --- | --- | --- |
| identity 挑战 → 官方应答 → 成功回执 | 官方本机或其正常恢复流程取得了当前有效 key | 不能仅凭成功断言 key 来自云端 |
| 无 key 后 bindRequest → bindError 及实际 reason | 这次绑定被卡片拒绝的具体原因 | 不能只凭方法名确定“已绑定”或“用户不匹配” |
| bindRequest → verifyRequest → 真实验机 → pairingResult | 官方实际进入首次协商路线 | 静态有此代码不证明本次执行 |
| AES 成功后云同步，再新查询出现 sharedSecret | 有效本机 key 补上传后可被正常账号取回 | 只有界面连接成功不足以证明已同步 |

蓝牙 HCI 只能记录蓝牙侧数据，不能直接证明 HTTPS 的请求体、响应或服务端决策。设备通道与云端恢复要分别验证。此前已有的详细静态结论见 [已绑定缺密钥恢复报告](IOS_BLE_BOUND_KEY_RECOVERY_2026-10-18.md)。

## 证据索引

原始静态结果和脱敏现场记录位于忽略目录 `tools/ble_audit/runtime-official-20261018/`，没有提交真实日志或凭据。

- `logcat-baseline-sanitized.json`：命令成功、可保留事件为空。
- 设置页：17:40 `ev_46b8c6b2f1b406dc8010641d9efab33c153824ed95d6a4ff4519254aaff8ef42`；17:42 `ev_4c6c88e304591b07d92785f81fa9fcd68c5b8e10455c7994487a2985a19e7bc7`。
- 系统包 `ev_95535d9d7ebc6e646a4889dbd9ec3d44a4d2bfc0d4705880bdb1590b84987e19`；ZIP SHA-256 `4c1f653bc41d3b1f3ccda61f248219c72ee7b2148f4c48ea611b17192be2dcfe`；脱敏覆盖记录 `bugreport-inventory-sanitized.json`、`bugreport-bluetooth-coverage-sanitized.json`、`bugreport-vendor-log-coverage-sanitized.json`。
- HCI开关UI记录 `hci-ui-state-sanitized.json`；只保留布尔状态及层级内容SHA，不保存/输出设置页其它字段。
- 正常返回官方入口 `ev_be4e57297d8e463006aebe1f2e77ab00517e318fb0291f14ccda9513992bb121`。
- `xlog-evidence-index.json`：本轮全部 REA 静态调用及 Evidence ID。
- 日志目录：2.2.2 `ev_470c58ec4cc0f1fa5c3dd8491864a976f072f14b49e05d51d4c18dd6ce9ed004`；2.3.0 `ev_332089d63f3d76afffc8f5410ac64b332ba307ee78fc6b1d9680871e3e2c7022`。
- 导出实现 `ev_9e57356e2d7991244b70532cea93c678b470430b422822b04399ba18ff0d6b34`；反馈调用方 `ev_7fbae9ac9bba54306fe0d923a1cafa3ee05dbeca3b0f1514ac46ca3081874209`。
- 控制台开关引用 `ev_d7f5133764f03bab7597e8cf79b4638895431a4fa8a021f43db797c1c719b3c1`；调试页初始化 `ev_2837cab5cf2da819202791e36400ab7bc56e20b12bdd43d71d6bbeb1b2739f49`。

当前结论：已观察到新账号重新绑定后连接状态保持，且新账号返回可恢复密钥材料；系统包未取得握手。广播SN缺口的修复已通过90项本地测试，待1.0.20+21实体AES和录音验收。没有把缺失日志当作协议结论，也未宣称已在实体卡完成恢复。

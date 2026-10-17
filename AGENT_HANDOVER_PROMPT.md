# 2026-10-17 审查更正

本文下方是历史交接，UUID、纯 JSON、假鉴权、ANCS 命令及断开原因的部分结论已被代码取证推翻。接手时优先阅读 [已核对协议](BLUETOOTH_PROTOCOL_SPEC.md)、[审查报告](docs/IOS_BLE_AUDIT_2026-10-17.md) 和 [任务记录](docs/todo.md)。1.0.11+12 使用同一原生蓝牙管理器请求 ANCS，不向 OTA 写业务指令，不伪造凭证。不要重新应用下方历史“修复”结论。

---

# SunMate (阳光智伴) 硬件录音卡 (AiNote 6095 / C·ONE) 跨智能体接续与深度技术排查交接说明

> **致接手智能体的一封信**：
> 本项目为随身第二大脑与个人成长智能体 **SunMate (阳光智伴)**，已完成全套核心架构、HAL（硬件抽象层）、私有端点直连（MOSS-ASR + Hermes）、UI 与交互系统。当前面临的**唯一致命卡点**为：**在 iPhone (iOS) 上对接物理硬件录音卡 (AiNote 6095 / C·ONE-4552) 时，无法触发 iOS 原生系统蓝牙配对与通知授权弹窗，导致连接在 5~10 秒后被录音卡固件主动切断**。
> 请立足**第一性原理 (First Principles)** 与 **KISS 原则**，阅读本说明后直接切入核心排查。

---

## 1. 项目定位与架构全景

* **项目名称**：SunMate (阳光智伴)
* **工程路径**：`/Users/m/Downloads/yoooclawREA/sunmate_app`
* **技术栈**：Flutter (Dart) 跨平台开发、`flutter_blue_plus` (BLE 蓝牙协议栈)
* **核心硬件设备**：
  * **型号**：AiNote 6095（官方广播名形如：`C·ONE-4552`）
  * **芯片方案**：Telink (泰凌微电子) 低功耗蓝牙 BLE SoC
  * **物理特性**：磁吸随身录音卡、单物理多功能按键、三色 LED 指示灯、内置麦克风、Opus 硬件实时编码
* **私有服务端点架构**（纯端侧直连，无第三方中间云）：
  * **MOSS-ASR 端点**：基于 MLX 加速的私有语音识别服务（兼容 Whisper/MOSS API），负责 Opus/PCM 流转文字。
  * **Hermes 智能体端点**：私有 Agent 大模型端点，提供 `/v1` 兼容接口，负责日程提取、第二大脑反思与任务派发。

---

## 2. 核心痛点与问题现象 (Current Blocker)

### 用户现场复现现象
1. 用户在 iPhone (iOS) 打开 SunMate App，点击主界面的【连接录音卡】卡片；
2. 扫描到 `C·ONE-4552`，点击连接；
3. 连接握手弹窗顺利走完 6 步握手（扫描 -> 建立 GATT -> 发现服务 -> 校验设备 -> 挂载 HAL -> 订阅音频/事件通道），提示“连接成功”并自动关闭弹窗；
4. 进入主界面后，**仅维持约 5~10 秒**，连接即自动断开，主界面恢复为“未连接硬件”，硬件录音卡亮起蓝灯重新回到待机广播状态。

### 与官方 App (YoooClaw 2.3.0) 的关键差异对比
官方 App 在点击连接该硬件卡片时，iOS 系统会**立刻弹出两个原生系统级弹窗**：
1. **【蓝牙配对请求】：“C·ONE-4552”想与你的 iPhone 配对。[取消] [配对]**
2. **【允许 C·ONE-4552 接收你的 iPhone 通知？】[不允许] [允许]** (即 iOS ANCS 授权)

* **官方 App 行为**：用户点击“配对”和“允许”后，硬件卡在 iPhone 系统的“设置 -> 蓝牙 -> 我的设备”中会**永久记录为已配对**，此后无论怎么重连都能长期保持稳定连接。
* **SunMate 当前表现**：**这两个系统级弹窗完全没有被触发**。根据 BLE 规范，下位机固件在建立链路后若等待 10 秒未完成 SMP 安全配对/鉴权，其看门狗会判定为主机未授权连接，从而主动发送 `LL_TERMINATE_IND` 切断 BLE 链路！

---

## 3. 已完成的工作与技术积淀 (What Has Been Done)

1. **深度逆向官方安装包与协议还原**：
   * 对官方 `YoooClaw 2.3.0.apk` / `classes.dex` 进行了反编译与逆向分析；
   * 输出了详细的协议规范文档 [`BLUETOOTH_PROTOCOL_SPEC.md`](file:///Users/m/Downloads/yoooclawREA/BLUETOOTH_PROTOCOL_SPEC.md)；
   * 确认核心 GATT UUID：
     * **主服务 Service UUID**：`00010203-0405-0607-0809-0a0b0c0d1913`
     * **命令发送通道 (Write without response)**：`00010203-0405-0607-0809-0a0b0c0d2b15`
     * **按键与事件上报 (Notify)**：`00010203-0405-0607-0809-0a0b0c0d2b30`
     * **音频数据流通道 (Notify)**：`00010203-0405-0607-0809-0a0b0c0d2b31`
     * **标准电池服务**：`0000180F-0000-1000-8000-00805F9B34FB` / `00002A19`
2. **硬件抽象层 (HAL) 落地**：
   * 位于 `sunmate_app/lib/core/hardware/`：
     * `hardware_device_driver.dart`：定义标准硬件驱动接口；
     * `ainote_6095_driver.dart`：AiNote 6095 实体蓝牙录音卡驱动，包含按键判定（单击/双击/三击/长按）、Opus 语音流组帧、电量解析；
     * `phone_mic_driver.dart`：手机内置麦克风备用驱动（用于无卡场景）；
     * 实现了官方序列号规则自动派生：`C·ONE-4552` -> `SZ12001261804552`。
3. **iOS 关键配置与死锁修复**：
   * [`Info.plist`](file:///Users/m/Downloads/yoooclawREA/sunmate_app/ios/Runner/Info.plist)：已配置 `NSBluetoothAlwaysUsageDescription`、`NSBluetoothPeripheralUsageDescription`、以及后台保活 `UIBackgroundModes: [bluetooth-central, audio]`；
   * 修复了蓝牙未开启时的扫描死锁（增加 `BluetoothAdapterState.on` 监听）；
   * 修复了写指令死锁（iOS 下必须采用 `withoutResponse: true`，下位机不发 Write Response）；
   * 修复了指令封包格式（去除了错误的二进制 TLV 头，保证为纯文本 UTF-8 JSON）。
4. **自动化构建流水线 (CI/CD)**：
   * 配置了 GitHub Actions（位于 `.github/workflows/`），每次 Push 到 `main` 分支会自动构建 iOS IPA 并在 Release 中输出供测试安装。

---

## 4. 关键排查事实与踩坑避雷 (Lessons Learned & Pitfalls Avoided)

> [!WARNING]
> **请务必仔细阅读以下已经由真实硬件验证过的结论，切勿重蹈覆辙：**

1. **绝对不要向 2B15 下发带 TLV 二进制魔数的指令**：
   * 固件底层使用 cJSON 库直接读取字符串并寻找 `{`；下发非 JSON 的二进制字节会导致固件 JSON 解析器内存非法访问，直接触发看门狗软重启断开连接。
2. **写入 2B15 必须使用 `withoutResponse: true`**：
   * Telink 固件端该特征值仅支持 Write Without Response。若传入 `withoutResponse: false`，iOS CoreBluetooth 会挂起等待下位机回复，5 秒超时后 iOS 会强行中断连接。
3. **不要下发伪造的 `bindRequest` 签名**：
   * 逆向显示，固件内部有 Flash 密钥校验机制，下发假的 App 校验码会被下位机直接拒配。目前空载连接能握手完成，但缺的是 iOS 系统的认证。
4. **iOS 蓝牙配对弹窗的第一性原理机制**：
   * 在 iOS CoreBluetooth 框架中，**App 无法通过任何显式 API 代码直接呼出“蓝牙配对请求”或“通知授权”系统弹窗**（即不存在类似 `CBCentralManager.requestPairing()` 的公开接口）。
   * **iOS 弹出配对框的唯一触发条件**：
     * **条件 A（外设主动）**：外设在连接后向 iOS 发起 SMP `Security Request`，或者外设主动以 GATT Client 身份尝试发现并订阅 iOS 系统的 ANCS 服务（`7905F431-B5CE-4E99-A40F-4B1E122D00D0`）；
     * **条件 B（主机特征值读取触发）**：App 读取或写入了外设上**声明了安全加密权限 (`CBCharacteristicPropertyRead` 且底层需要 `Encryption Required / Authenticated`) 的特征值**。当 iOS 尝试读取并收到外设返回的 `ATT_ERR_INSUFFICIENT_ENCRYPTION` (0x0F) 错误码时，iOS 协议栈会被动拦截该错误，并立即向 iPhone 屏幕弹出原生配对请求框！配对成功后，iOS 自动重新读取该特征值。

---

## 5. 接手智能体的最高优先级行动指南 (Actionable Next Steps)

请接手的新智能体立足以上机制，重点从以下几个切入点开展排查与攻坚：

### 🎯 突破点 1：主动触发 iOS 系统的 SMP 配对机制（强制读取受保护特征值）
* **原理**：录音卡上必然存在某些需要加密权限的特征值。
* **排查动作**：
  在 `ainote_6095_driver.dart` 或 `device_connect_dialog.dart` 的 `discoverServices` 完成后，**遍历并尝试主动读取下位机的所有可读特征值**：
  1. 设备信息服务 (`0x180A`) 下的特征值：`0x2A24` (Model Number)、`0x2A25` (Serial Number)、`0x2A26` (Firmware Revision)、`0x2A28` (Software Revision) 等；
  2. 私有服务 (`0x1913`) 下的其他特征值（如 `0x2B32`、`0x2B33` 或私有广播服务 `0x1930`）。
  * 一旦命中受加密保护的特征值，iOS 就会立刻弹出配对框。

### 🎯 突破点 2：深入逆向官方 App 的 ANCS 订阅与握手初期时序
* **原理**：官方 App 弹出的第 2 个弹窗是【允许接收 iPhone 通知】（ANCS）。
* **排查动作**：
  在工作区中直接解压查看或反编译 `classes.dex`：
  * 搜索类：`AiNote6095Profile`、`BleGattConnector`、`ancs_add_keyword`、`AncsService` 等；
  * 查明官方 App 在连接建立后的**前 500 毫秒内**，究竟向录音卡发送了什么初始化指令？是否发送了开启通知同步的指令（例如 `ancs_sync`、`enable_ancs`、或下发了一条特定的 RPC 方法）？
  * 如果录音卡需要收到特定的指令后才会去请求 iOS 的 ANCS 服务，我们只需在连接建立后立刻向 2B15 写入该指令即可引爆 iOS 系统的双弹窗！

### 🎯 突破点 3：捕获连接断开的原生精确原因
* **排查动作**：
  在 `FlutterBluePlus` 监听到 `BluetoothConnectionState.disconnected` 时，打印详细的断开原因（或通过 iOS 原生日志/Console.app 观察 CoreBluetooth 的 `didDisconnectPeripheral` 错误对象：是 `CBErrorConnectionTimeout`、还是 `CBErrorPeripheralDisconnected`，抑或是外设发起的鉴权超时）。

---

## 6. 环境与开发操作规范

1. **工作区目录**：`/Users/m/Downloads/yoooclawREA/`
   * 应用代码主目录：`/Users/m/Downloads/yoooclawREA/sunmate_app`
   * 官方 APK 与 Dex：`/Users/m/Downloads/yoooclawREA/classes.dex`、`YoooClaw 2.3.0.apk`
2. **Git 仓库**：
   * 远程仓库：`https://github.com/lrocky01/sunmate.git`
   * 当前分支：`main`，最新提交 Commit：`90b3ad9` (版本 `1.0.10+11`)
3. **版本号管理规范 (强制约束)**：
   * **每一次**涉及代码修复并准备交付测试时，**必须递增 `sunmate_app/pubspec.yaml` 的版本号**（例如下一次构建必须为 `1.0.11+12`）；
   * 同时请同步更新 `sunmate_app/lib/features/home/home_page.dart` 中 AppBar 标题的版本标识，确保用户安装后在手机顶部能一眼识别最新构建；
   * 修改后通过 Git 提交并 `git push origin main`，GitHub Actions 会自动编译 iOS IPA 安装包。
4. **沟通与原则**：
   * 恪守 KISS 原则与第一性原理，拒绝过度设计与无事实依据的猜测；
   * 全程使用中文进行思考、分析与任务输出。

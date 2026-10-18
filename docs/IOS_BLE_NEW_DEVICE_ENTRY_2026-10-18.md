# 官方新设备入口与当前 iPhone 连接停滞

## 本轮结论

用户补充：此前成功的是 **iPhone 官方 App**；先在设备界面解除设备，再「忽略此设备」，随后从新设备入口连接并出现配对框。这是用户描述，未取得该次 iPhone 运行时调用或报文。该成功同时改变了账号/设备绑定、系统配对和扫描路径，不能只归因于新页面，也不能确定其中哪个操作必需。

1.0.20+21 的本次失败发生在系统连接阶段，尚未进入 GATT 或共享密钥验证。继续补账号字段无法直接解释这次 pending。新账号曾显示「可恢复，仍需卡片验证」，仍需真正进入 GATT 后检验。

## 安卓连接分支已核对的差别

官方 Android 2.2.2 的 `BleConnectionCommands.handle`，REA Evidence `ev_a8bbd42596dc964459da81d9f625eee86ffa747dcced70fe8ad7afea600f63b6`：

| 命令 | 静态代码行为 |
| --- | --- |
| Scan | 取消自动重连扫描截止，启动扫描 |
| Connect | 建立选中设备模型，设置目标地址和自动连接，清除当前本地设备记录，以 `user_pairing` 进入连接层并传递配对参数 |
| Reconnect | 建立设备模型、设置目标和自动连接，以 `auto_reconnect` 进入同一连接层，不传上述配对参数 |
| CancelConnect | 取消自动重连，断开、调用 `unpairDevice`，重新扫描 |

`BleBondPlatform.unpairDevice` 的指令转储还显示清空本地设备 key、保存记录、解除 Android Companion 关联，并尝试反射 `removeBond`。这不是 SunMate 应直接照搬的取消策略，会影响现存材料。Android 特有的系统解绑不能据此当作 iOS 公共接口。

两种连接最终经过同一 GATT 层；Telink 的真实业务鉴权仍在链路建立之后。新入口的状态初始化与重连不同，不能将这种不同直接写成「新页面在连接前从服务器获取特殊配对钥匙」。已知账号恢复与首次协商需要分别处理。

官方 `BleDeviceUnbindCoordinator.requestUnbind` 还存在正常云解绑调用：从本地设备取得 SN/deviceId 与 MAC，检查联网，调用 `externalDeviceUnbind`，并设置事务及截止。成功后的全部合并回调顺序本轮未完整恢复，不能把用户的「解除设备」缩减为只删本机列表。未实际调用解绑接口。

## 新设备 Activity 的明确缺口

2.2.2 的 `AddDeviceActivity` 有 `handleDeviceSelected`、`startDevicePairing`、`startScanAttempt`、`currentSystemBondState` 等声明，但原始 DEX 中这些关键方法的指令区全为零。`initData` 仍有调用 `startScanAttempt` 的有效指令。

已核对原始安装 APK 对应区域同样为零，排除仅因分析用 DEX 重建造成；simple/fallback 两种反编译也没有恢复主体。包内另有 `assets/nedata.db` 与 `libnesec.so`，但尚未恢复被保护的函数，不能仅凭文件名推断保护算法或页面完整行为。

因此目前**没有完全还原新设备页面**。页面字段名、空方法体或安卓连接层实现都不能替代官方 iOS 运行时证据。分析期间曾仅根据 code_item 非零长度过早判断有完整指令，已逐字节核对并更正。

本地忽略目录 `tools/ble_audit/runtime-official-20261018/` 保留：

- `add-device-class-2.2.2.json`：REA `ev_1a2cb9df8375d338905c387d15f29e09ab75feeb95fde49f0f153063a9d3f3da`。
- `add-device-raw-code-inventory-2.2.2.json`、`add-device-protection-derived-evidence.json`：原始方法区域核对。
- `add-device-simple-2.2.2.java`、`add-device-fallback-2.2.2.java`：不同反编译模式的覆盖边界。
- `connection-command-entry-2.2.2.json`：上述命令分支完整 Evidence。
- `unpair-device-2.2.2.json`：REA `ev_b54a0504da36985aff75513fea817f63bab5cf30c1a6789cd57cc90f6ea5d42a`；清本地 key 与系统解绑尝试的补证。地址空值分支存在反编译警告，未以该分支的 Java 重建文本代替原始指令判断。

## 1.0.20+21 本次现场日志的含义

- 18:20:58 请求连接，`RequiresANCS=false`；原生 peripheral 持续 connecting，90 秒内没有 connected、GATT 或业务事件。
- 18:22:28 由 App 的 90 秒截止取消，随后 disconnected/error=nil。这不是已记录到 CoreBluetooth 原生超时原因，也不是密钥拒绝回执。
- `ANCS=true` 只是授权属性，不能说明本次出现了弹窗或已连接。
- 点击时 `scanAgeMs=95674`，约 95.7 秒。connectable/RSSI 均来自该旧记录，不能证明点击当时可连接。
- SunMate 扫描 15 秒后保留列表，未对过期行禁止连接，这是已确认的界面缺口；尚不能证明它是本次系统 pending 的根因。
- 当前广播 SN 恢复在 GATT 后读取最多 30 秒内的扫描记录；若系统配对耗时较长，可能错过本次本来新鲜的广播。属于另一个待设计验证的时间窗口问题，本轮未修改。

## 下一次对照与改动边界

先用现有包重新扫描，在目标卡重新出现后数秒内连接，查看日志扫描年龄是否降至数秒以及能否进入 GATT；这样只改变广告新鲜度。保留当前账号、共享密钥及卡片绑定，不再次官方解绑。若新鲜扫描仍 pending，再单独核对 iPhone 对该卡的系统配对记录；旧系统 bond 与安卓重新绑定后的卡片状态不一致是候选解释，尚未证实。

本轮仅记录调查结果，未修改 App、版本、HAL、私有端点或配对/鉴权策略，未重新构建。Android ADB 本轮不在线，未将静态结论称为新的运行时抓包结果。稳定连接和实体录音目标仍未完成。

文档 `git diff --check` 通过；本轮未修改应用代码，未重复运行 Flutter 测试或构建。

## 18:43 新扫描对照：仍停在系统连接

用户补充第二次 1.0.20+21 日志：18:43:20 点击，广播年龄 8270ms、RSSI -34、可连接标记 true；RequiresANCS=false。90秒始终 connecting，无 connected、connect_failed、GATT 或业务事件；18:44:50 App 主动取消后 disconnected/error=nil。与前次95.7秒旧记录对比，缩短扫描年龄没有改变结果，旧记录不足以解释全部现象，停止重复同一刷新试验。

再次检查 SunMate 原生连接路径：保留 peripheral 强引用、设置 delegate 后调用 connectPeripheral；centralManager 为保存的实例，delegate 回调分别记录 connected/connect_failed/disconnected。本轮未发现可以根据这份日志直接确认的引用释放或遗漏 connected 回调的实现缺陷；静态检查不能证明系统/无线链路状态正常。

下一步仅隔离系统配对变量：若 C·ONE-4552 在 iPhone「我的设备」中，由用户只在系统选择忽略，再从现有 SunMate 扫描连接；保留官方账号/卡片业务绑定，不再次官方解除设备。若没有忽略入口则停在该状态，不将其伪称为已清 bond。已发起该项用户对照，结果待回。该方向与 [Apple 的已配对配件连接排查步骤](https://support.apple.com/zh-cn/111804) 一致，但该通用支持文档不能证明此卡一定存在旧 bond 失配或单主机白名单。

## 系统忽略后仍失败；广播状态映射补齐

用户确认已经在 iPhone 系统忽略该卡，再从 SunMate 连接，仍一直 connecting。该操作不足以恢复链路；不继续重复忽略/刷新测试，不将旧 iPhone bond 作为已确定根因。未收到这一次操作后的完整新日志，不能自行断言广播字节或原生错误码发生了什么变化。

本轮静态续查补齐了此前缺失的映射。`BleEventAssemblyKt$$ExternalSyntheticLambda4.invoke` 中扫描结果分支，将 `ParsedBleAdvertisement.deviceStatus` 与字节17、-1比较：

| 广播状态 | 官方模型 |
| --- | --- |
| `0x11`（17） | `BleDeviceBindingState.BoundNeedsReset` |
| `0xFF`（byte -1） | `BleDeviceBindingState.Ready` |
| 其它或缺失 | `Unknown` |

2.2.2 与 2.3.0 的 fallback 指令转储均确认这一映射。Telink 解码已证实 payload[1] 为该 status；用户18:43已提供的 `01 11 1d 2c ...` 因此映射为 `BoundNeedsReset`。这能证实官方如何命名当前已收到的状态，不能单凭名称证明控制器启用了白名单、卡片必须恢复出厂、或每次连接均被无线层拒绝。

找到的列表选择谓词同时接纳 `Ready` 与 `BoundNeedsReset`，因此不能把 `0x11` 理解为官方列表绝对禁止选择。设备行渲染使用名称/SN并受统一 `interactionEnabled` 控制；关键选择/配对 Activity 仍有保护缺口，不能由这段谓词补出完整按钮流程。

另一个容易误读的名称是 `BleResetDialogCoordinator`。扫描自动重连代码在**已有目标却看到非 AiNote 设备的 Ready 广播**时可投递该对话框；本轮从原始2.2.2资源表核对，其标题为「配对失败」，正文为「配对失败，设备被重置或取消配对」。它是检测到重置/取消配对的失败提示，不能因类名含Reset就当成已找到主动重置卡片的步骤。未点击该对话框或任何重置按钮。

新增证据均保留在上述忽略目录：

- 状态引用 `binding-state-refs-2.2.2.json`，REA `ev_072bdb3bab812cf78498f26f9e8a4e4808dfc077737b7a4b7f2d1492c36de031`。
- 状态方法2.2.2 `binding-state-map-invoke-2.2.2.json`，REA `ev_e7fd1e076d22dee2050e96bee0c128cd0721b698eb700476ffeac3368394652b`。
- 状态方法2.3.0 `binding-state-map-invoke-2.3.0.json`，REA `ev_1f49d9d21c5ecd0ef29a993825b68acfde79ba18eaae5e148817c8981852ca0f`。
- `binding-map-event-2.2.2.java`、`binding-map-event-2.3.0.java`：保留fallback分支转储，避免复杂合并lambda的结构化Java重建失真。
- `binding-map-url-utils-2.2.2.java`、`add-device-adapter-2.2.2.java`：列表选择与渲染。
- `reset-dialog-2.2.2.java`、`reset-dialog-resources-derived-2.2.2.json`：资源ID 0x7f130212/0x7f13020a，直接解析原APK标准资源表的默认与英文值，记录entry偏移及资源SHA-256。先前资源提取目录中的同名文件不是有效资源表，未使用它推断界面文字。

Android ADB仍无在线设备。已请用户仅在同一台iPhone官方App对已有卡片做一次普通连接，保留当前账号/卡绑定；若要求解绑、重添或重置则停止。这用于取得**系统忽略之后的同期官方对照**，不复用先前不同账号/绑定状态下的成功或失败。结果待回；无证据前不发新包或调整鉴权。

## 同期官方也失败；用户明确指认官方业务解绑入口

用户确认当前同一iPhone官方App普通连接也一直失败。当前问题不只在SunMate出现，但这不能排除SunMate另有缺陷。用户随后提供官方「C·ONE设置」截图，设备状态「未连接」，底部按钮为「解绑设备」，说明之前所指成功前置操作是该入口，而非仅取消弹窗或系统忽略。截图与文字不等于本轮已经再次执行解绑，不擅自推断状态已改变。

### 本轮补齐的安卓云解绑成功后处理

2.2.2实际类名经方法结果发现后继续追查（不同版本R8别名不能混用）：

1. `BleDeviceUnbindCoordinator.requestUnbind$default` 用当前SN/MAC调用 `externalDeviceUnbind`。
2. 正常成功回调经 `BleDeviceStore$$ExternalSyntheticLambda6` 的case6进入事务提交；`RealWebSocket$$ExternalSyntheticLambda2.invoke` 将ACTIVE改为COMMITTED并执行后处理，过期generation不继续。
3. `PlazaTabWebViewKt$$ExternalSyntheticLambda3.invoke` 的case7解除Android Companion关联、启动蓝牙服务UNBIND，随后安排停止服务和关闭页面。
4. `com.huawei.hms.framework.network.grs.a$b.handle` 的UNBIND分支先处理待完成回滚，正常路径关闭自动连接/扫描、清协议持久状态；若当前连接且isPair则调用设备`unbindRequest`；若未连接则调用`unpairDevice`。最后清当前本地设备记录。

**未连接分支没有在此处发送设备解绑报文。** 因此不能说截图中的操作一定通过蓝牙清了卡内密钥，或服务器能直接控制没有网络的卡；安卓静态实现只能证实云解绑和本机清理，卡片实际状态变化以及iOS对应实现仍需运行时证据。

原始2.2.2资源表还包含通用解绑提示：尝试同步现存数据，解绑后设备本地数据被清空。该资源不能替代特定型号/断开分支的实际擦除结果，但足以说明不应把解绑做成失败自动重试。没有代用户执行云解绑、卡片命令或系统清理。

REA证据：

- 协调器 `ev_4e28827be9b80a4b439d317e3473521dd6098a0063d402f89e258aad408a9e89`。
- 事务提交 `ev_c52e70a1b9146a1fb8541d75ca5ac3c26b0ae589517dbeb06467be0063f38d8a`。
- 服务后处理 `ev_c66b05d00fa3b95e83eae177840f88b6708b3c9b8eaac4ae42aedbe56f4e678e`。
- 控制器调用者 `ev_bbab3e02ea4dda41a609357b009ecf63a22000d756d5f831e12fb784377171a0`。
- 运行时命令分发器静态方法 `ev_1ae69e98208d8e0ef37d8fcb0583bb7aeff0f778058ce19385beb198435bf5ad`；同名 `unbind-runtime-dispatcher-2.2.2.java` 保留fallback分支，不能把函数名含runtime当成现场执行证据。
- `pairing-help-resource-strings-2.2.2.json`：从原始资源表14104个全局字符串筛选配对/解绑/重置文字，含资源SHA与索引。未找到即可直接确认适用于该卡的无损重新开放配对指令；资源范围的搜索不能证明不存在这类功能。

### SunMate已确认的首次添加入口缺口

`lib/views/home_page.dart` 的连接弹层只有在 `onSelectDevice` 选中 `AccountRecorderDevice` 后才启动扫描，选择来源是账号设备列表。`lib/views/recorder_account_sheet.dart` 登录后遍历该列表生成「选择并搜索」，没有列表外「添加新录音卡」分支。

`lib/core/ble/yoooclaw_account.dart:sessionForDevice` 的 `ensureCurrent` 除账号登录/revision/SN外，还要求SN存在于 `_devices`。这对恢复已有设备合理，但官方解绑后若云列表为空，不能用它完成真正的新设备首次绑定。当前已有底层验机/协商实现不等于用户能走通首次添加入口。

此缺口会阻止「官方解绑后直接由SunMate首次绑定」的完整对照；它不能单独解释本次发生在GATT之前的connecting。

### 最小修复方案（待确认，尚未实现）

1. 保留「恢复已有账号设备」，另外提供登录后的「添加新录音卡」，允许账号设备列表为空时启动新扫描。
2. 新增独立的首次绑定会话：绑定当前登录会话版本与所选卡的严格广播SN，实际GATT确认后才能处理设备挑战；它不依赖预先存在云设备记录。已有设备恢复会话继续保留原列表匹配限制，不全局放宽 `ensureCurrent`。
3. 复用HAL中真实 `/check`、X25519/AES及 `/bind` 链路。已有本地/账号密钥走恢复路径；不自动覆写不同旧key，不发假应答，不自动解绑或重置。首次成功须以真实卡片回执为准，完成后再核对正常重连。
4. 补首次账号空列表、登录会话失效、广播/SN冲突、设备拒绝、云绑定失败和旧密钥保护的回归；扫描身份在点击时取可信快照，避免配对等待后才因30秒窗口失去SN。

涉及登录与鉴权会话边界，按上级AGENTS.md先确认再改。本轮仅完成证据核对与方案，未改App、未升级版本或新构建；HAL与私有端点保持不变。即使实现该入口，也不能提前保证解决当前iPhone系统连接停滞。

## 用户确认后的本地实现与验证

用户明确选择「补齐首次绑定流程并本地检查」，授权范围不含解绑、推送或打新包。以下已在本地完成，前述「待确认、未实现」为历史阶段记录。

### 实现

- `sunmate_app/lib/views/recorder_account_sheet.dart`：登录后可「添加新录音卡」，空列表有对应说明；已有设备选择保留；本机已验证身份重连在登录前后均可用。
- `sunmate_app/lib/views/home_page.dart`：复用现有连接弹层，增加首次添加模式与返回账号设备按钮，返回保留本次登录；选择卡片后创建独立首次绑定会话，显示广播SN；扫描失败/结束的空状态不再一直写「正在搜索」。
- `sunmate_app/lib/core/ble/ble_protocol.dart`：新增不可变 `RecorderScanIdentity`，只接受已确认的完整Telink厂商广播、可连接标记及30秒内时间戳。此身份仅为待设备挑战验证的选择依据，不等于认证成功。
- `sunmate_app/lib/core/ble/yoooclaw_account.dart`：新增 `sessionForNewDevice`，要求登录且成功读取过账号列表；锁定会话revision及所选SN，已有或重复SN拒绝进入新绑定。已有设备的列表成员检查继续保留。两类会话复用原真实 `/check`、`/bind` 请求实现，新入口不依赖SN预先存在于云列表。
- `sunmate_app/lib/core/ble/recorder_authentication.dart`：会话携带首次选择快照，密码算法与成功判定未改变。
- `sunmate_app/lib/core/hardware/ainote_6095_driver.dart`：在提交系统连接前捕获同一remoteId的新鲜SN，在实际GATT识别后匹配；不会在漫长配对等待后才重新读取可能已失效的扫描缓存。首次选择与外设/profile不符时拒绝；本机已有密钥时保留原key并引导已验证身份重连，不从新入口重新协商。

HAL接口、多驱动关系、原生CoreBluetooth连接选项及私有MOSS-ASR/Hermes端点均未修改。没有新增自动解绑、清密钥或重置操作。

### 验证

1. 新增空账号Widget回归，先在旧代码复现登录后找不到添加入口；实现后通过。
2. 最终 `flutter test --no-pub --reporter expanded`：**104项通过**，比原90项增加14项。覆盖空账号新增、未登录/未读取/过期选择、已有或重复SN、账号资料变化时迟到的验机答复、验机拒绝与关闭、完整广播限制、选错外设、旧本地key、设备拒绝和云绑定失败。
3. 新增整合用例使用内存HTTP适配器与模拟GATT对端，运行真实X25519/AES算法：空列表→设备挑战→模拟正常签发答复→公钥协商→云绑定桩→一次身份验证重连→再一次免账号重连。它验证实现契约和算法，不代表厂商服务器或实体卡接受了流程；测试未发送真实短信或厂商请求。
4. 新增扫描快照回归：连接等待期间替换缓存后，仍用点击时的SN匹配恢复并完成对端挑战。测试最初在平台串行调用被连接占用时尝试重扫，造成测试自身等待，已改为直接模拟缓存被替换；不把该测试问题当成新的实体连接根因。
5. `flutter analyze --no-pub --no-fatal-infos`：退出0，无错误/警告，11条既有弃用info。`git diff --check`通过。
6. 360×640与390×844两种尺寸各核对账号空列表与首次搜索状态，第二轮确认返回、按钮与空状态文案无溢出；临时截图测试已删除，永久Widget回归保留。截图位于忽略目录 `first-binding-ui-360-account.png` / `first-binding-ui-360-scan.png` 及390对应文件，使用本机字体的Widget渲染，不是实体iPhone截图。

### 当前交付边界

代码保留本地未提交；未推送main、未构建IPA、未改版本（仍1.0.20+21）。本次授权的入口与本地验证已完成。若之后准备打包，按既定规范再递增版本并同步首页/诊断文本。

实体卡的系统connecting、官方解绑后实际状态变化、真实账号/check和/bind接受、AES回执与稳定录音仍待实测，不能用本次104项离线测试替代这些结果。当前没有让用户再操作解绑。

# 已绑定但本机缺密钥：恢复路径与首次接入方案

2026-10-18。本轮不等验证码，检查2.2.2和2.3.0分析副本。未请求厂商接口、未上传或读取实际共享密钥、未操作卡片解绑/重置；源码保持1.0.19+20，HAL及私有端点不变。

## 本轮新增结论

找到之前没有追到入口的官方补上传步骤 `retryBindFromLocalDevice()`。它将官方App现有本地设备记录中的key原样提交已有`/bind`接口，不会从服务器取回key，不生成新key，也不重新配对。可用于“官方本机有当前有效key、服务器未返回key”的情形；实际上传是否成功、服务器后续是否愿意返回sharedSecret仍未验证。

该入口不是设备设置页的通用同步按钮。它位于OpenClaw连接选择页的SN激活资格检查链，满足EntryChoice、provider设置Idle、有SN、功能开关开启等条件时，可能自动补上传。静态2.2.2的DefaultConnectSystem.getSnActivationFeatureEnabled固定返回true；不能据此推断当前官方iOS也有相同页面。不要在未核对当前有效key前盲目触发。

## 三种密钥情况

| 状态 | 已确认的官方处理 | SunMate后续 |
| --- | --- | --- |
| 账号有旧key、本机没有 | 设备列表extInfo.sharedSecret读入BleSavedDevice.key，再应答本次AES挑战 | 已实现匹配SN/协议的恢复和挑战验证 |
| 官方本机有当前有效key、账号缺少 | 正常连接仍能做AES；另有本机记录补上传/bind路径 | 优先验证官方正常补上传，再检查账号是否可恢复 |
| 本机和账号都无key、卡已绑定 | 无本地key时普通bindRequest；若卡回bindError则停止；未找到本链自动取回key的步骤 | 不伪造AES或HMAC，不能因有SN/账号就宣告验证成功 |

“Android此前连接成功”不等于它现在还持有本卡当前key；用户之后做过iPhone解绑重绑，可能改变业务密钥。恢复来源必须通过当前卡的新挑战验证。是否真的发生密钥变化尚未观测，不能把旧缓存直接上传当作解决方案。

## 本地保存和所谓历史恢复

- BleDeviceStore使用固定MMKV `openclaw_ble_device`、`current_device`，只保存一个当前设备；未发现多账号命名空间或历史key列表。
- 加载先看内存，再读当前JSON；若存在pending rollback会先返回null。序列化字段为macAddress/deviceName/key/snCode/uuid/deviceType/autoScan/savedAtMs。
- 账号退出会停止BLE并清当前记录，不应为继续排查主动退出已登录客户端。
- 云同步若收到设备但没有sharedSecret，会构造key=null的新记录；saveCurrentDevice不替它补用旧key。服务器空设备列表还有清当前设备分支。这是静态实现，不能推断用户本次是否执行过覆盖。
- rollback记录只有keyFingerprint，没有完整key；指纹为密钥字符串的SHA-256。restoreCloudBindRollback恢复失败清理状态，不还原业务密钥。回滚journal某些合并类仍未被完整解析，结论限定已确认模型/恢复链。

## 官方补上传的完整入口

```text
OpenClaw连接选择页的协程
  provider stage == Idle
  → runSnEligibilityCheck(SN)
    screen == EntryChoice + feature enabled + SN非null
    → awaitCloudBindReady()，最多5秒
      Unknown且有本地SN，或Failed
      → DefaultConnectSetupGateway.retryBindFromLocalDevice()
        loadCurrentDevice()
        → /api/device/toc/externalDeviceBind/bind
          deviceName、deviceId=SN
          extInfo={mac, sharedSecret=现有key, uuid}
        → 仅将云绑定状态标成Succeeded/Failed
    → backend.checkSnActivation(SN)
```

实现仅检查本地设备对象是否存在，没有显式验证key非空；所以“函数可以被调用”不代表上传的材料有效。它不是重新生成或读回key的接口。连接页协程已观察到Idle时执行检查，但外层Compose的全部调度和实际用户路径尚未完整恢复；不能给出未经现场核对的按钮教程。本轮没有进入该页或执行上传，也没有触发官方智能体激活。

## bindError 的处理链

```text
Telink解码 error / reason / message / status
  → BindingFailed(reason)
  → 记录失败、stopPairingAttempt
  → 禁用自动连接、清自动连接目标、断开GATT、停扫描、状态Failed
```

这条链没有发现密钥恢复、自动unbind或factory reset。disconnect取消当前鉴权/云绑定请求、清会话，未直接删除持久key或调用云解绑；Telink driver的onDisconnected为空。

云绑定失败回滚是另一条链：只有真正执行`/bind`后，网络异常或业务拒绝、且当前generation标记失败成功，才调用beginCloudBindRollback。用户1.0.18+19在卡片bindError处停止、尚未到/check，不属于这条云失败回滚路径。

## sign/confirmCode 不是本张Telink漏发的字段

对两版BleGattSessionController.connectToDevice补查JADX simple/fallback原始跳转：bindSign、confirmCode、rebindSign归一化后只要任一非空，入口要求deviceType==AI_NOTE_6095。Telink会走invalid bind credentials并在GATT前return。

onTransportReady里自动“签名解绑→等待unbindCleared→重新绑定”的路径也明确要求AI_NOTE_6095。虽然通用命令构造器能拼出可选字段，不能把它当作Telink连接入口接受它们的证据。本轮修正此前关于QR/sign可用于重绑的宽泛描述，不能移植到本张卡。

## 有没有漏掉接口

新增检查设置层BleDeviceApiService、BleHomeSyncApiService、MineApiService：分别为App/灯效配置、积分/待办/重要消息同步、消息/反馈/文件功能，未发现业务共享密钥读取方法。

另检查两版各3份DEX中的`/api/`字符串常量：2.2.2共93条唯一路径、2.3.0共97条。其中2.3.0新增设备文件上传任务路径；未发现显式secret/recover类设备密钥恢复路径。`/api/message/deviceBinding/bind`在Account/JPush接口中明确是bindPush/bindJPushInfo，不是录音卡BLE绑定。`/api/auth/api-keys/*`为账号ApiKey管理声明，未找到将这些值作为Telink共享密钥的调用证据。

batchBindStatus确实声明sn/bound/sign，但恢复的interface incoming为0、请求模型只有API声明引用；AddDeviceActivity的handleDeviceSelected/bindScannedDevice/startDevicePairing为空体。不能声称已恢复该接口的实际触发、权限及sign用途，亦不能据0引用认定运行时不会调用。

以上是明文常量、恢复代码和模型范围内的搜索，不覆盖服务器未公开实现、动态拼接、保护器内代码或官方iOS。没有找到不等于证明绝不存在。

## SunMate应补的首次接入向导

用户提出“第一次连接成功后保存有效密钥，以后正常连接”，方向正确。关键是状态机和真实材料，而非复制一个页面。

当前已有：真实/check答复、X25519、本机Keychain/Keystore保存、/bind同步、一次重连AES证明；已有key时走本地挑战。当前缺口是入口仅接受账号已列出的AccountRecorderDevice，sessionForDevice也要求该SN仍在_devices，缺少完整的新设备添加路线。

建议入口/验收：

1. 选择「添加新录音卡」或「连接/恢复已有录音卡」。已有本机验证身份可直接重连。
2. 新卡路径：登录自己的正常账号→扫描并确认物理卡和SN→发现实际GATT与协议→订阅真实挑战。账号尚未列出这张卡本身不能阻止真实首次验机；仍由账号服务和设备真实回执决定是否接受。
3. 首次verifyRequest包含的SN必须与用户所选卡一致；/check返回真实HMAC后交换X25519公钥，pairingResult成功才保存真实key并同步账号。
4. 只有新的AES挑战应答成功、音频通道就绪后，才显示「连接完成」。写入成功或云设备记录出现不是替代条件。
5. 已绑定但缺key：优先账号恢复；否则明确进入恢复/迁移决策，不伪装成新卡，不在bindError时自动解绑。迁移真实绑定需用户明确确认，且新设备添加入口应先完成，不能先删账号记录再发现入口不可用。
6. 用户后续正常使用优先读本机安全存储、回答新挑战，不要求每次短信登录；ASR/Hermes仍直连私有端点。账号同步失败和设备身份验证失败分别展示。

本轮没有为了未证实的固件恢复命令再发测试包；生产代码/版本保持1.0.19+20。真正稳定连接及录音仍待实际key恢复或合法首次协商完成。

## 当前安卓的只读观测

用户重新连接USB后，adb确认device；系统resumed activity为官方AddDeviceActivity。REA截图显示“添加设备/未发现设备”，有重新搜索和C·ONE/C·ONE Pro型号选择。未点击任何按钮，不能从此页面判定账号会话或本机key状态。窗口工具返回null焦点，仅记录其局限，不把null视为App未运行。

## 主要证据

除下列索引外，raw API常量清单位于tools/ble_audit/recovery-20261018/root-api-string-inventory.json，含两版APK和每个DEX的SHA-256、字符串索引与偏移。fallback派生清单failure-gate-derived-evidence.json保留工具及输入/输出SHA。APK均为分析副本，不安装。

| 内容 | Evidence ID / 本地文件 |
| --- | --- |
| 本机key补上传 | ev_52e8cb5466720b81fd16d26db7561d69c848a70959a7f612d83cf085979639af；retry-local-2.2.2.json |
| 云状态等待 | ev_cd6860e89eb4018b003fceb0a275ed647b8063b7154a84d6046ce4e50c3d472c；retry-await-2.2.2.json |
| 5秒界限 | ev_e1cf36a92e2c6d38ca4d7f3350ab61df660b79dc0d5e8b17dd176bf4a234c28a；await-entry-2.2.2.json |
| SN检查gate | ev_6f965a3c5e45cf9db3e0afab3c88dc772480a23de58197761d5ce1531a1aa862；sn-eligibility-2.2.2.json |
| provider Idle协程 | ev_8c141e8f237c977b61511fc814f9aa8ce0ace881fcd40ff9e6ac830d768d60c6；root-entry-choice-effect.json |
| 静态feature=true | ev_311ab0ed9819e2eaaeb1ed3b20a3fdfbe8bde1bde1a26a0de8ae1459cb4a9866；root-system-sn-flag.json |
| 后续checkSnActivation | ev_201b2ae213a571fb45ebf70066e7c9b3c4fb5c9d2349e0da82985b37936419ed；root-sn-check-api.json |
| 本机JSON读取 | ev_2257192be71af7e85284a1fec6d43211aa42b36a28649d50611a54e5e8085c63；store-load-storage-2.2.2.json |
| pending rollback/内存加载 | ev_16cf98b17a61d5b36685abf4f64cfd16d12ca8f591754fe20e750bf6e938b087；store-load-2.2.2.json |
| 回滚模型/指纹 | ev_aeaceae9a999178a1d5fa8f8b25f06d831f31ab8baf7d16c1dfd5b3bca934a5e；ev_5bc9f0fd129a4a16e73f9a7db39474f9c8f289d34fbc2fe631921fcecd77e48e |
| 停配对/断开 | ev_430f325b7d159325793c263641970d71238529b0e37dab955c5e6ab5d05c88f1；ev_dee6094f023771ec4befb30ba5bd56a135c159977e719b8b5cec8350b2d5422f |
| 2.3.0失败对照 | ev_573c088a4bc0c60b5c7fa065719b6f269f4af15853b8da13ecc65835937cda9b |
| 云失败回调/回滚refs | ev_27f80acfd5f5eafcd096b8210de3ef28cb9e3f6b5bd524ca7db6c2eee16b93b4；ev_f20d73bb14629145c1bb915726e64b905badcbbc95278c204b940a350501def5 |
| sign入口及原始跳转补核 | ev_e62d43cc493ed9b2b023711edddcdfbcaaa2843e173aac811343f040e736ec99；failure-connect-fallback-222.java及230对照 |
| 设置/首页/个人接口库存 | ev_94686b13f7316a3a812b61a3f008eb8b302e575398010f95073f7e25ca1dee47；ev_9a8ecaa8753f2d03df046a2b44bd0452bbf6d7d684626f3101be5f1b0c6d4037；ev_6a8e2713b97a0b46e280d004b52f5e3805e1442406d435c6a125645dd54c891b |
| 实际添加设备页 | ev_3e87f89a111301b6680d000f64ed0d80df7ea22ed08a1eeb12dc7ecbccfaf0a2；root-live-screen.json及PNG（忽略目录） |

除文档外本轮未改App，不运行与静态报告无关的Flutter重测。后续实际进入官方补上传流程属于真实账号写入，须先核对当前有效身份及用户的具体授权。

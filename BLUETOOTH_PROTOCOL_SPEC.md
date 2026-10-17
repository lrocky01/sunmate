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

官方账号的设备列表存在 extInfo.sharedSecret 恢复路径。1.0.13+14 已接入官网正常手机号与 4 位短信验证码登录（channel=6），随后用该会话读取账号设备列表；官网会话能否访问 Android App 的既有绑定，仍待用户手机实测。材料必须与实际卡上报的 SN 和已发现的协议匹配，随后存入安全存储并重新连接，由设备挑战验证；已有不同密钥不自动覆盖。没有真实材料时明确失败，不发送假 token、假签名或伪造 user_id。纯本地首次绑定尚未证实。

1.0.13+14 用户已确认验证码登录成功、设备列表请求被拒；该版移除 Bearer 后直接发送裸 Token 的实现存在格式缺口。设备接口公开的未认证响应声明 `WWW-Authenticate: Bearer`，1.0.14+15 因此按 `Authorization: Bearer <登录所得 Token>` 发送且只保留一个前缀。APK 的 `Raw` 表示保留已有格式，不等于要求裸 JWT。新的请求诊断区分步骤、HTTP 401/403 和数字业务码，不再把所有拒绝归为“没有权限”；实体账号权限及恢复仍待验证。

`bindResult`/`pairingResult` 不是完整业务验证成功；`success:false` 必须失败。仅在本次挑战应答之后收到 `verifyIdentityResult` 且 `params.success` 为布尔 true，并完成事件和音频通道初始化，才记录业务验证成功。写队列完成、物理连接仍在、灯亮、ANCS 允许都不是替代条件。

未确认 `setAncsConfig` 或自定义 ANCS 事件码，不发送这些指令。Telink 实时音频通过 voiceCmd 的 start/release/abort 和 session_id 控制。流内容使用两个 uint32 长度字段（Opus 长度、扩展长度），再跟 Opus 与扩展数据，可跨通知；优先 LE，否则按官方 plausibility 规则尝试 BE，单段长度各不超过 8192。不是旧四字节 session/seq 头。候选实现输出单声道 Ogg/Opus，输入采样率 16000、pre-skip 312、每包 granule 增量 960；空、截断、取消的会话不提交转写。长录音与 App 主动开始/暂停/恢复仍未核实，不假造命令。

## 诊断与真机测试

保存完整广播、service/characteristic UUID 与属性、每步耗时、业务事件方法名及原生 NSError domain/code/description；不保存挑战、密钥、签名或通知正文。断开日志跨 App 重启保留，可从首页“蓝牙状态与诊断日志”复制。

CoreBluetooth 错误码不能直接套用 HCI 原因码。没有 PacketLogger/HCI 证据，不把数秒断开定性为 MCU 鉴权看门狗、固件 JSON 崩溃或对端主动断开。

最新账号恢复验收步骤见 [1.0.14 手机测试说明](docs/IOS_BLE_TEST_1.0.14.md)，原生授权排查另见 [1.0.11 手机测试说明](docs/IOS_BLE_TEST_1.0.11.md)。

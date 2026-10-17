# SunMate 已核对的录音卡 BLE 协议

2026-10-17 修订，适用于 1.0.11+12。此前版本混合了 Telink 与 AiNote6095，并把 OTA 端点误作业务命令，已撤回。完整取证过程见 [审查报告](docs/IOS_BLE_AUDIT_2026-10-17.md)。

本规范来自指定 YoooClaw 2.3.0 APK 的静态实现，尚不能替代 C·ONE-4552 真机 GATT 和抓包验证。型号名称不能决定 profile；只按完整服务与特征组合选择，未知或同时匹配多个 profile 时不写入。

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

厂商 `verifyRequest` 路径涉及签发验证材料，`verifyIdentityRequest` 路径需要已协商的真实共享密钥。当前测试版没有此密钥接入，收到挑战时明确显示等待合法业务鉴权，不发送假 token、假签名或本地伪造 user_id。

`bindResult`/`pairingResult` 不是完整业务验证成功；`success:false` 必须失败。仅收到明确的 `verifyIdentityResult` 且 `params.success` 为布尔 true 时记录设备报告的业务验证成功。写队列完成、物理连接仍在、灯亮、ANCS 允许都不是替代条件。

本版没有确认 `setAncsConfig`、自定义 ANCS 事件码和旧四字节 Opus 音频头，不再自动使用这些假设。录音与音频导出保留 HAL 接口，在格式与鉴权未验证前返回明确的不可用状态，避免向私有 ASR 发送误解包的数据。

## 诊断与真机测试

保存完整广播、service/characteristic UUID 与属性、每步耗时、业务事件方法名及原生 NSError domain/code/description；不保存挑战、密钥、签名或通知正文。断开日志跨 App 重启保留，可从首页“蓝牙状态与诊断日志”复制。

CoreBluetooth 错误码不能直接套用 HCI 原因码。没有 PacketLogger/HCI 证据，不把数秒断开定性为 MCU 鉴权看门狗、固件 JSON 崩溃或对端主动断开。

验收步骤见 [1.0.11 手机测试说明](docs/IOS_BLE_TEST_1.0.11.md)。

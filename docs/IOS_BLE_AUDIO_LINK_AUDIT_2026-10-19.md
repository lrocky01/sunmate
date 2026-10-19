# 1.0.24+25 按键实时音频链路调查

2026-10-19。用户授权对照官方按键录音及启动应答；不接 ASR/Hermes、不解绑、不改密钥、不打包。App 源码基线 `6b6d6021f415e46cbbc2c647ff2e9407ef3369fc`，未修改运行代码。

## 本轮结论

官方 Telink 存在两种实时录音事件入口：JSON voiceCmd，以及 AA 55 二进制 RecordingStarted/Stopped。SunMate 仅处理前者。用户按住说话、松开结束的本轮 iPhone HCI 采样实际出现后者，录音类型为 REALTIME，期间收到连续有效 Opus 数据。App 未建立 voiceSession，随后在音频回调入口直接忽略数据。这是已复现的实现缺口，和 ASR、Hermes、账号或密钥无关。

原先把 Telink 实时录音启动只描述为 voiceCmd 不完整。本轮不再以“CCCD 成功”或“12/4 字节长度”替代有效录音证据，而是核对实际帧、数据通道和离线解码。

## 官方静态实现

工件复核：原始 YoooClaw 2.3.0.apk SHA-256 `e638958d143b518829a3db4d16cb4f8db1b19c64d49149458b98684c16e2137f`；重建分析容器 `cdaf78f1abb2bdbc57430eb8b54b82e00ed264099c0f12ddc26814de1f3a7318`；recovered-2.dex `1bf0cc48f3306c06430634e07c99d253568bfb730e440875c04687a05de79b8b`。重建容器不是厂商可安装包，未执行它。

本轮 REA MCP 会话没有配置 JADX provider；复用此前保留的 REA 完整方法证据及本地反编译结果，没有安装工具或修订 MCP 配置，也没有把失败的旧 REA 调用当作成功证据。

| 问题 | 官方实现及证据 |
| --- | --- |
| 二进制开始 | TelinkProtocolAdapter.decode 的 DEVICE_EVENT 分支：AA 55 01，至少12字节；第4字节为1时 LONG，否则 REALTIME；offset4起8字节按大端有符号Long解析会话。保存 activeStreamIsLong/SessionId，产生 RecordingStarted。 |
| 二进制结束 | AA 55 02，第4字节为录音类型；若省略则沿用活动类型，使用先前会话并清活动状态，产生 RecordingStopped。 |
| JSON兼容 | voiceCmd start/release/abort 独立解析，并更新相同的流状态。不能为修二进制破坏此入口。 |
| 实时音频 | STREAM 对应1930/2B32；activeStreamIsLong=false时产生 RealtimeVoiceAudioData，经 BleRecordingEventRouter.route 交给活动 ShortRealtimeCaptureCoordinator，再进入 BleStreamReceiver.pushData。 |
| 开始应答 | RecordingStarted(REALTIME) 路由直接启动本地 receiver；voiceCmd start 同样如此。已跟踪路径没有通用强制启动ACK。文件通道被占用时可拒绝或中断传输；不能把这种仲裁命令当每次必发的启动应答。 |
| 灯效结果 | voiceCommandUploadResult 调用 lightCtrl(mode4, success)，是上传处理结果灯效，不是开启音频传输的启动ACK。 |
| 长录音 | mode1交给 LongRecordingSessionOwner/分段文件同步；不能将 mode1 不加区分地套入本轮实时语音路径。 |

保留证据位于 ignored 的 tools/ble_audit/recovery-20261018/：

- protocol-voice-230.json / .txt：`ev_5cd1a07086ee80174a7e983c70d826cfe935b20a4deb8a47a0fd1d9797575955`，TelinkProtocolAdapter.decode；完整方法有 JADX 控制流告警，本轮二进制条件与真实帧进一步互证，不宣称所有分支完全还原。
- protocol-record-router-230：`ev_c8fc98fba281fb8ffe70269234d6bd77010270a9faa105b36bd01f7b0cb7f683`，BleRecordingEventRouter.route。
- protocol-handler-230：`ev_218ff4a80b4c3ff2ecd32ed5dd858ffa612a7b3fe110f1b90d29e170a0e04322`，BleDeviceEventHandler.handle，JSON voiceCmd路由。
- protocol-opus-start-230：`ev_7a88cffb6b43d3118ff959ee1a17e87331adeac0136e22fe4579f0692e283976`，BleStreamReceiver.start；配合 ShortRealtimeCaptureCoordinator.start 的现有完整反编译代码核对。
- protocol-short-finish-230：`ev_449cc5a8fd930a6c6e940ac2643c4d8223f98ac867e6f24196134c5da1899aa4`，接收结束后才进入处理/ASR阶段。
- protocol-uuid-230：`ev_7fd5bc58a2406d27d4aba9ca99f9682a5099c89439f8ad544fdad944d5966b75`，2B31事件、2B32流、2B33文件。

## 本次 iPhone 实测

USB只读 probe 确认唯一可信iPhone，已有日志配置下HCI服务可用。180秒 observe_current 采样已完成，先确认有效记录再给用户开始信号。用户确认按住说话、松开结束，全程使用现有SunMate，不切换官方App，不改绑定。原始数据只保存在 ignored 本机目录，未输出音频、凭据或地址。

| 项目 | 结果 |
| --- | --- |
| 设备时钟开始/结束 | 13:52:50.971 / 13:52:58.891 |
| 开始/结束事件 | AA 55 01 00 + 8字节会话 / AA 55 02 00 |
| 类型 | REALTIME，非长录音；会话值非零且不输出 |
| 按键会话长度 | 7.920秒 |
| 音频通知 | 393条，17,380字节；首条在开始事件后30ms |
| 同链路主机ATT包 | 开始至结束期间0条，ATT写入0条；卡片在无启动应答情况下持续发送 |
| 现有OpusStreamReceiver离线回放 | 393个有效Opus帧，完整Ogg/Opus 25,365字节；空帧/截断检查通过 |
| 独立FFmpeg检查 | ffprobe识别Opus单声道；ffmpeg完整解码成功，转16k单声道125,656样本，约7.8535秒；未导出音频文件或转写 |
| HCI/L2CAP解析 | 0损坏记录、0未完成分片 |

采样SHA-256：`e369dbe35fe1220de967f91c3cf5190fff603a4ea8dc076129af17b1251effbb`。安全派生统计在 tools/ble_audit/audio-link-20261019/recording-metadata.json。分析将现有 Dart OpusStreamReceiver 生成的Ogg经本机内存管道送FFmpeg，不保存第二份可播放音频，也不调用网络服务。

归属边界：本轮开始采样时物理链路已连接，没有新的成功LE建立事件用于重新证明地址到connection handle的对应。采用此前同卡官方HCI明确发现的2B31/2B32属性句柄、唯一匹配的二进制录音会话、有效Opus流及用户同步操作归属本次测试；没有将其他外设的失败LE事件当作目标连接，也没有宣称本轮取得新的独立地址绑定证据。此前官方样本是GATT属性映射证据，不是本轮官方按键操作抓包。

## SunMate 精确缺口及离线检查

- lib/core/ble/ble_protocol.dart 的 RecorderEventDecoder.feed 在Telink分支只识别AA 55 30 JSON；AA 55 01/02在没有JSON续片时返回null。
- lib/core/hardware/ainote_6095_driver.dart 的 _voiceSession 只由_handleVoiceCommand(JSON)建立；音频回调遇_voiceSession==null立即返回，未打印丢弃计数。因此诊断只有12/4字节长度，没有音频条数，不能据此断言卡片没有发送。
- 使用实际当前decoder回放明确标记的合成mode0/mode1二进制帧，均未产生开始/停止事件；JSON voiceCmd控制组仍可识别。此回放不构造凭据，不连接设备，未修改App测试或运行文件。
- 再使用本轮真实音频数据直接回放当前OpusStreamReceiver并独立解码成功，说明本次无需先改音频分帧、鉴权、UUID或发送猜测指令。

## 修复范围建议与未决项

优先补齐经过验证的Telink二进制实时开始/停止分支，保留独立录音类型/会话及现有JSON入口；只在真实AES完成、当前连接代次有效时进入采音。结束必须匹配活动会话，拒绝孤立/短帧/错误类型，long明确分流或提示未支持。增加音频接收/丢弃计数，不输出原始音频或凭据。不要为补录音而降低鉴权、改密钥、重绑或新增启动ACK。

还需后续实现及回归：事件与首条音频异步顺序、重复/取消/断连/重连、非法帧和长录音隔离，确保不再漏掉完整Ogg头尾。离线存储/回放和ASR/Hermes属于后续功能，本轮不接入；业务UI是否收到最终音频仍需修复后真机验收。

本轮调查完成，未修改App、版本、HAL、私有端点、密钥或账号状态，未提交、推送、打包。原始抓包和分析工具不提交。


## 后续已授权本地修复

用户随后明确授权补齐二进制开始/结束和本地回归，现已完成，详见[修复与设备能力记录](RECORDER_CAPABILITIES_2026-10-19.md)。此前“未修改App”描述针对调查阶段；当前本地源码含补丁，但版本仍1.0.24+25，未打包或推送，手机旧包不含补丁。

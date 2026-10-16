# YoooClaw 硬件录音卡 (AiNote 6095) 蓝牙通信协议全景规范

> 本文档通过对 `YoooClaw 2.3.0.apk` 的第一性原理逆向分析生成，完整还原了硬件录音卡与 App 之间的 GATT 服务架构、底层帧封装格式、全部控制命令字（Opcode）、数据传输协议及音频流管道。

---

## 一、 硬件与通信总体架构

* **硬件芯片平台**：Telink（泰凌微电子）低功耗蓝牙主控芯片平台（内部产品代号：`AiNote 6095` / `ATW6095` / `AI_NOTE_6095`）。
* **通信信道划分**：
  1. **BLE 控制信道**：负责设备扫描、连接鉴权、状态轮询、录音启停、时间校准、参数下发、按键打标事件上报。
  2. **BLE 实时流信道**：负责边录边传时的 **Raw Opus** 音频帧分片传输。
  3. **BLE/WiFi 双模文件拉取信道**：
     * 小文件/离线索引：通过 BLE 特征值分片读取。
     * 大录音文件：App 可通过 BLE 发送 `SetDeviceWifi` 与 `AttachDeviceWifiNetwork` 指令，使录音卡启动 Wi-Fi 模块与手机建立局域网 TCP 连接（QuickTransfer），以数 MB/s 的速度完成高速批量传输，传输完毕后断开 Wi-Fi 恢复 BLE 低功耗。

```
+-----------------------------------------------------------------------+
|                        YoooClaw Android App                           |
+-----------------------------------------------------------------------+
     |                    |                      |                  |
     | (GATT Write)       | (GATT Notify)        | (GATT Notify)    | (TCP Socket: Wi-Fi)
     v                    v                      v                  v
+----------+       +---------------+      +--------------+    +---------------+
| 命令下发 |       | 状态/事件上报 |      | 实时音频数据 |    | 高速文件同步  |
| 2B15     |       | 2B30          |      | 2B31         |    | QuickTransfer |
+----------+       +---------------+      +--------------+    +---------------+
     |                    |                      |                  |
+-----------------------------------------------------------------------+
|                      AiNote 6095 硬件录音卡                            |
+-----------------------------------------------------------------------+
```

---

## 二、 GATT 服务与特征值定义 (UUID)

| 类别 | 名称 | UUID | 属性 (Properties) | 作用说明 |
| :--- | :--- | :--- | :--- | :--- |
| **主通信服务** | **OPUS_SERVICE_UUID** | `00010203-0405-0607-0809-0a0b0c0d1913` | - | 录音卡私有主业务服务 |
| **特征值** | **OPUS_APP_CMD** | `00010203-0405-0607-0809-0a0b0c0d2b15` | Write / Write Without Response | **App -> 硬件**：下发控制命令、参数、查询等 |
| **特征值** | **OPUS_DEVICE_EVENT**| `00010203-0405-0607-0809-0a0b0c0d2b30` | Notify / Indicate | **硬件 -> App**：主动上报状态变更、按键事件、命令应答 |
| **特征值** | **OPUS_DATA** | `00010203-0405-0607-0809-0a0b0c0d2b31` | Notify | **硬件 -> App**：实时音频流（Raw Opus 语音帧）上报 |
| **特征值** | **FILE_TRANSFER_DATA** | `00010203-0405-0607-0809-0a0b0c0d2b32` | Notify / Read | **硬件 -> App**：离线文件块分段数据读取通道 |
| **特征值** | **EXTENDED_DEBUG** | `00010203-0405-0607-0809-0a0b0c0d2b33` | Write / Notify | 扩展诊断、指令交互通道 |
| **电池服务** | Battery Service | `0000180F-0000-1000-8000-00805F9B34FB` | - | 蓝牙标准电池服务 |
| **特征值** | Battery Level | `00002A19-0000-1000-8000-00805F9B34FB` | Read / Notify | 硬件电量百分比（1 字节，0~100%） |
| **描述符** | CCCD | `00002902-0000-1000-8000-00805F9B34FB` | Read / Write | 写入 `0x0001` 打开 Notify，写入 `0x0000` 关闭 |
| **OTA 服务** | Telink OTA Service | `0000d0ff-3c17-d293-8e48-14fe2e4da212` | - | 泰凌微官方固件 DFU 服务 |
| **OTA 特征值**| Telink OTA DFU | `0000ffd4-0000-1000-8000-00805f9b34fb` | Write Without Response / Notify | 固件升级数据块下发与确认通道 |

---

## 三、 协议数据帧封装规范

硬件通信支持两层协议：
1. **底层物理分片与 TLV 封装**（`BleTlvMessage`）
2. **应用层协议通道**：
   * **JSON-RPC 通道**：用于设备能力协商、复杂参数配置和状态轮询。
   * **二进制控制命令集**：用于快速精准的录音启停、时间校准和硬件直控。

### 1. 底层 TLV 帧结构 (`BleTlvMessage`)

```
+------------+------------+--------------------+
|  Type/Tag  |   Length   |       Value        |
|  (2 Bytes) |  (2 Bytes) |     (N Bytes)      |
+------------+------------+--------------------+
```
* **Type (Tag)**：小端 16 位整型，标识报文业务类型。
* **Length**：小端 16 位整型，表示有效数据负载 Value 的长度。
* **Value**：实际命令帧、JSON 文本或音频数据。
* **分包规则（MTU 适配）**：当 Value 超过当前连接协商的 MTU（通常为 244 字节）时，由 `BleTlvReassembler` 自动拆包传输并在对端重组。

### 2. JSON-RPC 应用层指令规范

在设备绑定、鉴权与高层交互时，Value 负载直接使用标准 JSON-RPC 2.0 格式：

#### (1) 设备能力查询 (`getCapabilities`)
* **App 发送**：
  ```json
  {"version":"1.0.0","method":"getCapabilities"}
  ```
* **硬件返回**：
  ```json
  {
    "version": "1.0.0",
    "result": {
      "firmware": "v2.3.0_6095",
      "model": "ATW6095",
      "codecs": ["opus_16k_40B", "opus_32k_80B"],
      "storage_total": 33554432,
      "battery": 95,
      "charging": false
    }
  }
  ```

#### (2) 状态查询 (`getStatus`)
* **App 发送**：
  ```json
  {"method":"getStatus"}
  ```
* **硬件返回**：
  ```json
  {
    "result": {
      "recording_state": 0, // 0: 空闲, 1: 录音中, 2: 暂停
      "battery": 88,
      "charging": false,
      "storage_free": 28419200,
      "gain0": 24,
      "gain1": 24
    }
  }
  ```

#### (3) 设备绑定与鉴权 (`bindRequest` / `verifyIdentity`)
* **App 绑定**：
  ```json
  {"method":"bindRequest","params":{"appId":"yoooclaw","timestamp":1728987654}}
  ```
* **身份校验**：
  ```json
  {"method":"verifyIdentity","params":{"token":"..."}}
  ```
* **硬件回复**：`{"result":{"verified":true}}`

#### (4) 用户配置与硬件控制
* **读取配置**：`{"method":"getUserSettings"}`
* **更新配置**：
  ```json
  {
    "method": "setUserSettings",
    "params": {
      "longPressMode": 1,        // 长按按键模式
      "ledEnabled": true,        // 指示灯开关
      "gain0": 24,               // 主麦克风增益 (dB)
      "gain1": 24,               // 辅助降噪麦增益 (dB)
      "vor": false               // 声控录音开关
    }
  }
  ```
* **关机**：`{"method":"powerOff"}`
* **灯效控制**：`{"method":"lightCtrl","params":{"mode":1,"color":"#FFFFFF"}}`

---

## 四、 核心二进制控制命令集 (`AiNote6095CommandEncoder`)

App 端底层编码器针对核心控制场景提供了标准编码接口：

| 方法名称 | 作用说明 | 典型报文字节构造逻辑 |
| :--- | :--- | :--- |
| `encodeStartRecording` | **开始录音** | 下发开始录音指令，录音卡指示灯变红闪/红常亮，启动编码芯片 |
| `encodeStopRecording` | **停止录音** | 停止录音，硬件将本次录音写入 SD/Flash，生成新音频文件名 |
| `encodePauseRecording` | **暂停录音** | 暂停录音采集，保持文件句柄 |
| `encodeResumeRecording` | **恢复录音** | 从暂停状态继续追加录音 |
| `encodeSetTime` | **RTC 时间校准** | 携带 4 字节当前 Unix 时间戳（大端/小端秒数），确保录音文件元数据正确 |
| `encodeRecordGain` | **麦克风增益** | 携带 `gain0` 与 `gain1`（数值范围 0~48dB） |
| `encodeReadAudioFileList` | **获取文件列表** | 读取卡内已录制的全部音频文件名称、大小与时间戳目录 |
| `encodeReadFile` | **分块拉取文件** | 请求指定文件名、起始偏移（Offset）和分片长度（Length） |
| `encodeStopFileTransfer` | **终止文件拉取** | 立即终止当前正在传输的文件数据流 |
| `encodeDeleteFile` | **删除录音文件** | 携带文件名，删除卡内已上传的录音文件 |
| `encodeClearDevice` | **格式化卡** | 清空硬件存储介质，恢复初始存储空间 |
| `encodeSoftwareReboot` | **软重启** | 触发 Telink MCU 软件看门狗复位 |
| `encodeSetWifi` | **下发 Wi-Fi** | 下发 SSID 与 Password，让录音卡启动 Wi-Fi 芯片建立传输链路 |

---

## 五、 声学算法控制命令

录音卡内嵌了专用硬件 DSP 音频增强算法，支持通过调试命令进行精细化调节：
1. **AEC（回声消除）**：`ainote6095_debug_algo_aec_enable`（0: 关闭, 1: 开启）
2. **AGC（自动增益控制）**：
   * `ainote6095_debug_algo_agc_enable`
   * `target_dbfs`：目标电平（如 -3 dBFS）
   * `max_gain_db` / `far_max_gain_db`：近场与远场最大补偿增益
   * `limiter_threshold_dbfs`：防爆音限幅阈值
   * `speech_hold_ms`：人声保持时长
3. **NS（降噪）**：`ainote6095_debug_algo_ns_enable` 与 `ns_level`（0~3 级降噪强度）
4. **工作模式切换**：`ainote6095_debug_usb_on` / `usb_off`（切换为 USB 声卡/U 盘大容量存储模式）

---

## 六、 音频传输与组包流程 (Opus Pipeline)

1. **音频采集与编码**：
   * 麦克风采集 16kHz 单声道音频，通过硬件 Opus 编码器编码。
   * 采用固定帧长：**20ms 一帧**。
   * 码率档位：
     * **16 kbps 模式**：每帧 Opus 净荷刚好为 **40 字节**。
     * **32 kbps 模式**：每帧 Opus 净荷刚好为 **80 字节**。
2. **GATT 传输封装 (`AiNote6095FramedVoiceData`)**：
   * 硬件通过 `00010203-0405-0607-0809-0a0b0c0d2b31` 特征值以 Notify 形式连续发送数据包。
   * 每包包含：
     * **Header**：Session ID（会话标识）+ Sequence Number（包序号，用于丢包校验）
     * **Payload**：40 字节或 80 字节的 Raw Opus 音频数据
3. **手机端解包与合成 (`OpusFrameAssembler` -> `OggOpusMuxer`)**：
   * App 端由 `OpusFrameAssembler` 检查包序号连续性，若有丢包进行 PLC 补偿。
   * 剥离头部后，调用本地原生库 `libogg_opus_muxer.so`，追加生成标准的 Ogg 页面（加入 `OpusHead` 8 字节魔数头部及采样率元信息），最终封装保存为 `.opus` 标准音频文件供本地播放和云端 ASR 语音转文字识别。

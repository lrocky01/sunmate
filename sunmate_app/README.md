# SunMate（阳光智伴）- 伴随式第二大脑与成长智能体

> **项目定位**：基于第一性原理打造的轻量级跨平台随身 AI 助理系统。通过统一**硬件抽象层（HAL）**彻底解耦底层硬件，既能无缝驱动当前的 **AiNote 6095（Telink 芯片方案）蓝牙录音卡**，也支持**手机原生麦克风兜底模式**，更预留了未来新型智能硬件（胸针/双麦棒/戒指）的即插即用能力。

---

## 一、 系统架构设计（硬件抽象层 HAL 解耦）

为了实现“未来随意更换硬件外设而上层业务零改动”的目标，SunMate 采用了分层解耦架构：

```
                ┌──────────────────────────────────────────────┐
                │        SunMate 表现层 (Flutter Views)         │
                │  - AI 对讲机 (Push-to-Talk)                  │
                │  - 会议录音与纪要提炼 (Action Items)         │
                │  - 随身时光机与全天画像复盘 (Daily Review)     │
                │  - 按键自定义与声学设置                      │
                └──────────────────────┬───────────────────────┘
                                       │
                ┌──────────────────────▼───────────────────────┐
                │          业务状态层 (Riverpod Providers)       │
                │  - DeviceProvider (设备生命周期管理)          │
                │  - ButtonActionProvider (按键事件路由器)     │
                │  - ChatProvider (智能体对话流)               │
                │  - TimelineProvider (时光轴与通知融合引擎)    │
                └──────────────────────┬───────────────────────┘
                                       │
                ┌──────────────────────▼───────────────────────┐
                │     硬件抽象层接口 (HardwareDeviceDriver HAL) │
                │  - 按键事件流: Stream<DeviceButtonEvent>      │
                │  - 音频数据流: Stream<AudioDataPacket>        │
                │  - 状态变化流: Stream<DeviceStatus>           │
                │  - 控制契约: start/stop/pause/syncTime        │
                └───────┬──────────────────────────────┬───────┘
                        │                              │
        ┌───────────────▼───────────────┐ ┌────────────▼───────────────┐
        │       AiNote 6095 蓝牙卡驱动   │ │     手机原生麦克风兜底驱动    │
        │  (Telink GATT 0x1913/2B15/    │ │  (无外设模式，支持屏幕软按键  │
        │   2B30/2B31 Raw Opus 16kHz)   │ │   与系统麦克风即按即说)     │
        └───────────────────────────────┘ └────────────────────────────┘
                        │
        ┌───────────────▼───────────────┐
        │       未来新型外设驱动扩展      │
        │  (智能胸针 / 双麦降噪棒等)    │
        └───────────────────────────────┘
```

---

## 二、 三大核心业务场景

### 1. 实体键自定义与 Push-to-Talk 对讲
* **自由映射**：物理按键（单击、双击、三击、长按）可自由绑定到【对讲通话】、【会议录音】、【灵感打标】、【电量查询】。
* **即按即说**：长按设备物理键或屏幕软按钮说话，音频流实时送入 ASR 语音识别引擎，松开自动触发智能体深度思考与流式回答。

### 2. 会议录音与智能纪要提炼
* 支持本地会议长时间高质量收音。
* 录制结束后一键调度 ASR 引擎完成带时间戳的高精度转写。
* 驱动智能体提炼输出：
  1. 会议核心背景与决议共识；
  2. 关键讨论要点（议题维度）；
  3. Action Items 明确行动待办清单（含负责人建议与落实动作）。

### 3. 全天随身时光机与个人成长画像
* **声控 VOR 低功耗控制**：在安静无声时不上传音频，硬件芯片降频待机，全天 12 小时录音仅占用几十兆存储，超长续航。
* **时空对齐**：将口头对话/自言自语切片与手机通知消息（钉钉、微信、邮件等）按时间轴融合。
* **每日成长复盘**：夜间由智能体进行全天认知与决策分析、沟通表现与情绪得失复盘、时间精力分布评估，并输出针对性的个性化能力提升建议。

---

## 三、 工程目录结构

```
sunmate_app/
├── pubspec.yaml                  # 跨平台依赖配置 (包名已更名为 sunmate_app)
├── README.md                     # 本架构与使用文档
├── lib/
│   ├── main.dart                 # 应用入口与 SunMate 阳光橙主题配色
│   ├── core/
│   │   ├── hardware/             # 【核心】硬件抽象层 (HAL)
│   │   │   ├── hardware_device_driver.dart  # 统一设备抽象接口与事件规范
│   │   │   ├── ainote_6095_driver.dart      # AiNote 6095 蓝牙录音卡驱动
│   │   │   ├── phone_mic_driver.dart        # 手机内置麦克风兜底驱动
│   │   │   └── hardware_device_factory.dart # 驱动切换与管理中心
│   │   ├── ble/                  # Telink 芯片底层 GATT 协议实现
│   │   │   ├── ble_constants.dart           # UUIDs (0x1913, 2B15, 2B30, 2B31)
│   │   │   ├── ble_tlv_packet.dart          # TLV 封包与解包器
│   │   │   └── ble_json_rpc.dart            # JSON-RPC 2.0 控制协议
│   │   ├── audio/
│   │   │   └── opus_stream_receiver.dart    # 16kHz Opus 帧重组与裸流提取
│   │   └── ai/
│   │       ├── asr_service.dart             # 语音识别引擎服务 (支持本地/云端)
│   │       └── agent_client.dart            # 智能体流式对话、纪要提炼与复盘 Prompt 管道
│   ├── models/
│   │   ├── button_action_config.dart        # CustomActionBehavior 按键行为枚举
│   │   ├── device_status.dart               # 设备电量与连接状态模型
│   │   ├── meeting_record.dart              # 会议录音与纪要模型
│   │   └── timeline_entry.dart              # 时光轴流水与成长画像报告模型
│   ├── providers/
│   │   ├── device_provider.dart             # HAL 设备状态机 (Riverpod)
│   │   ├── button_action_provider.dart      # 按键事件调度与路由器
│   │   ├── chat_provider.dart               # 对讲机与智能体会话控制器
│   │   └── timeline_provider.dart           # 随身时光机与成长画像控制器
│   └── views/
│       ├── home_page.dart                   # 首页：设备卡片、驱动源指示、录音快捷控制
│       ├── chat_page.dart                   # 对讲机页面：软/硬按键 Push-to-Talk 交互
│       ├── meeting_page.dart                # 会议纪要：转写文本与 Action Items 待办
│       ├── timeline_page.dart               # 时光机：VOR 录音 + 通知融合与每日成长复盘
│       └── settings_page.dart               # 设置：HAL 驱动源切换、按键行为自定义映射
```

---

## 四、 编译与运行

在已配置好 Flutter 环境的系统上运行：
```bash
cd sunmate_app
flutter pub get
flutter run
```
在 iOS 或 Android 真机上调试时，请确保开启系统的“蓝牙”与“麦克风”权限。

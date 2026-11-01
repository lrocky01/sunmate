# Apple Watch 本地原型

2026-11-01：用户已确认语音三模式及健康只读，当前处于原型阶段。独立Watch及iPhone伴侣已按授权推送，通过云端真实SDK编译和嵌入产物校验；签名、安装和真机验收尚未完成。版本沿用 1.0.34+35，未生成IPA、签名或部署。用户暂缓本机大型工具下载，本轮只在云端准备固定Flutter及依赖，不在本机下载SDK或引擎。

## 本轮实现

- `SunMateWatch.xcodeproj` 保留独立 SwiftUI 目标；Runner已通过跨项目依赖及标准Embed Watch Content接入，workspace包含两端工程。完整编译、实际嵌入、签名及真机验收分别记录，不以单独Watch编译代替伴侣验收。
- 手表前台由用户开始对讲、会议或随身录音。三者复用存储协议、保留用途；对讲最多两分钟，长录每两分钟闭段，正常结束封尾，中断/异常恢复不标为完整。
- 原型先用 16kHz、单声道 PCM16/WAV 验证样本连续性。保留原始 PCM 与封装 WAV，磁盘占用约为单份音频的两倍；这不是全天续航或存储优化方案。压缩格式需在真机验证后决定。
- WatchConnectivity 发送不可变闭段与结束清单。手机先核对大小、格式、SHA、样本连续性并落盘，才回应用层回执；系统传输结束不等于已送达。缺段清单落盘等待补齐，不删除音频。
- iPhone 新入口：设置 → Apple Watch 与健康只读；支持逐段播放，短语音需显式确认交给现有 ASR/Hermes 对讲。HAL 增加 Apple Watch 驱动，保留旧驱动及数据。
- HealthKit 仅申请所选心率、静息心率、SDNN HRV、睡眠与步数的读取；缺样本不显示零。健康数据仅在本机视图，无压力评分、写入健康或外发路径。
- 接收、录音、自动文件同步和健康读取均默认关闭。不自行启用麦克风、解绑、重新协商或覆盖旧密钥。

## 尚待完成，不能视为已可交付

1. 安排签名身份/权限及设备安装验证、补齐分发所需资源。两端SDK编译和真实Watch嵌入已通过，但不能据此宣称已签名或可直接安装。
2. 真机验证 30/60 分钟熄屏、手机不在旁、系统中断、空间不足、强退恢复、样本完整性及耗电。原型通过后再铺开上层处理。
3. 会议整场播放/逐字稿/纪要与随身时间线接入，手表回复回传，以及 Watch 音频原生后台上传和服务器版本适配。当前服务器 v1 的 Ogg/Opus 契约不接受 WAV，不可直接套入卡片 OPS 流程。
4. 手表健康画面、后台健康更新和趋势仍待后续；不通过伪造运动会话维持录音或连续心率。

## 不需下载的本地检查

共享存储核心可用本机 Swift 与 macOS AVFoundation 编译；`test/native_watch/main.swift` 用合成 PCM 检查样本连续性、尾段、中断、乱序/缺段、校验拒绝与持久回执。Flutter 测试只用已有缓存，网络地址指向不可用回环端口，禁止自动下载；完整 SDK 验证暂缓。

历史 IPA 由 GitHub Actions 的 Mac 编译，本机没有完整 Xcode 也能改 Flutter 代码。未来 Watch 云端构建需单独核对 SDK 和签名，不能认为原 iPhone 工作流已自动支持手表。

## 手表云端无签名编译检查

已新增 `.github/workflows/check_watchos.yml`，只接受手动 `workflow_dispatch`。用户已授权将独立手表原型及检查推到默认分支后手动执行，实际结果见`docs/todo.md`。入口为 GitHub Actions → **Check SunMate watchOS (Unsigned)** → **Run workflow**。手机HAL/UI/健康桥接源码已在后续伴侣整合中接入，但不代表已完成签名、安装或真机验收。

- 运行环境固定 `xcode-27`；显式选择预装 `/Applications/Xcode_27.2.app/Contents/Developer`（当前镜像清单中为27.2 RC别名），核对实际27.2及`watchos27.2` SDK版本和目录。没有就报错，不回退默认版本、不下载工具或SDK。
- `.github/scripts/check_watchos.sh` 仅对独立 `SunMateWatch` 真机目标执行 Debug `build`，禁用签名、清空团队/profile设置、关闭自动包解析与更新；目前不允许给该原型引入Swift包依赖。不运行Flutter、CocoaPods、归档、IPA导出或Apple上传。
- 编译产物只留在runner临时目录；GitHub artifact仅保存`check.log`、`build.log`及`status.log`文字日志，保留7天，编译失败也收集已有日志。`pipefail`保留真实编译退出码；成功不等于已完成手机嵌入、签名或真机验收。
- 本地验证：`bash -n .github/scripts/check_watchos.sh`及`python3 .github/tests/test_watchos_check.py -v`。后者用临时模拟编译器检查成功、失败退出码、缺Xcode/版本不符/缺SDK拒绝、手动触发和仅日志保留；不访问Apple、不运行真实编译器、不下载组件。不能把该测试通过当成watchOS SDK编译通过。
- `build_ios.yml`已按用户授权改为仅手动触发，main/master推送及标签均不再自动生成IPA。本次只手动运行Watch检查，不启动iPhone发布工作流；后续iPhone发布仍需单独确认工具链迁移和打包。

### 已验证的云端结果

源提交`ae3222c50058447fc57684cff589ed817ed6efc2`、[Actions 41271687258](https://github.com/lrocky01/sunmate/actions/runs/41271687258)成功。实际Xcode27.2（27B48）、watchOS27.2 SDK，arm64/arm64_32均完成编译和链接；`BUILD SUCCEEDED`、退出0、签名关闭。日志有9条非阻断诊断：3处非Sendable对象捕获及旧录音权限API各按两种架构报告，加1条无AppIntents依赖的元数据提示。未为消除警告关闭编译检查，也未将其当成真机并发/熄屏行为已验证。

artifact13069267423仅含`check.log`、`build.log`、`status.log`，ZIP CRC与GitHub SHA256摘要968a3e2f35d96f9985da56661c447e22e3b3698fffc4a632a42e9adafcea9680一致；没有IPA或可安装包。核对该源提交仅出现本次手动Watch运行，未触发旧iPhone发布工作流。本机验收报告位于忽略目录`build_output/verification-watch-2026-11-01/result.json`，不提交原始云端日志。

## iPhone／Watch 伴侣编译检查

手动入口：GitHub Actions → **Check SunMate iPhone + Watch (Unsigned)**。`.github/workflows/check_companion.yml`先核对预装iPhoneOS/watchOS27.2 SDK、独立编译Watch，再只在云端准备Flutter3.35.7及锁定的Dart依赖，完成分析/回归、无签名的配置生成和Runner Debug `build`。不执行archive、IPA导出、签名或Apple上传；产物留在临时runner，仅保留文字日志。

Runner通过远程目标/产品代理引用原Watch工程，在Flutter Thin Binary之前嵌入`Runner.app/Watch/SunMateWatch.app`，避免Info.plist/复制阶段形成依赖环。两端版本经构建变量保持一致，iOS部署目标与Podfile既有15一致，Watch保持10；未改变有效App版本或原业务协议。

编译后的校验器直接读取两端Info.plist和真实二进制：验证SDK、Bundle ID、WKCompanionAppBundleIdentifier、版本/构建号、设备架构，以及根目录无签名资料；缺Watch或关系/版本不符直接失败，不能只凭两次编译成功报告伴侣整合成功。本地结构和失败分支检查为`python3 .github/tests/test_companion_check.py -v`，不代替云端真实产物验证。

### 伴侣整合验收结果

[Actions 41280552914](https://github.com/lrocky01/sunmate/actions/runs/41280552914)成功，源提交`943a6cd27dee1a195b7e5e2977404bd794b35104`。修正前首次运行41279913114因Flutter Thin Binary与Watch复制阶段依赖环失败；只调整嵌入阶段顺序并补回归后，两端编译、嵌入及严格产物校验均通过，没有绕开任何验证。

实际结果：手机`iphoneos27.2 / arm64`，手表`watchos27.2 / arm64+arm64_32`；手机内存在`Watch/SunMateWatch.app`，两端标识关联有效、版本1.0.34/35一致，未带根目录签名资料/profile。手机原生接收和健康桥、共享存储/传输代码均参与本次iPhone SDK编译。

本地693项Flutter回归通过；云端692项通过、1项按环境跳过；分析无error/warning、11条弃用info；本地工程图/失败分支与旧CI共13项检查通过。最终伴侣编译日志按诊断行计77条非阻断警告（包含第三方旧API/指针写法、Watch并发捕获和旧录音权限API等），保留原文，不通过关闭诊断或升级无关依赖消除提示。

artifact13072319662仅7份文字日志，148,555字节；CRC和GitHub SHA256摘要`360fe33f8fba16989dd904e3a574e76cbd08caa0b078e604476bc83b28960ef5`均通过。本机报告及日志位于忽略目录`build_output/verification-companion-2026-11-01/`。未生成IPA、签名、上传Apple、下载本机大型工具、操作真实设备或改动私有节点/密钥；原有iPhone IPA工作流仍仅手动。

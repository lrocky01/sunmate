# SunMate Apple Watch 迁移方案（已确认，原型阶段）

实施状态：用户已确认首期“语音三模式＋健康只读”。本机缺完整 Xcode，用户暂缓大型工具下载；本轮只推进现有工具可验证的离线原型，未打包、推送。原型现状及尚未完成事项见 `sunmate_app/apple_watch/README.md`。以下保留方案制定时的范围与通过条件。

最新进展：用户随后授权推送并运行云端编译门槛。2026-11-01源提交ae3222c的独立Watch目标已通过Xcode27.2/watchOS27.2真实编译；旧iPhone发布已改为手动，未生成IPA/签名/上传Apple。详情见原型README和todo。此前“不推送/不运行”描述均是对应历史阶段的边界，不代表已完成完整伴侣安装及真机验证。

日期：2026-11-01。目标设备：Apple Watch Series 10 GPS，用户报告 watchOS 27.2。本轮只做源码只读核对、官方资料核对及方案记录；不修改运行代码、版本、CI、服务器或设备状态，不打包、推送或部署。

## 1. 目标及范围

- 保留现有 Flutter 手机端、HAL、多来源录音处理、私有 MOSS-ASR / Hermes 地址和原资料库。新增原生 SwiftUI watchOS 伴侣 App，经 iOS 原生桥接接入业务层。
- 首期重点：短语音问答、会议长录、主动开启的随身记录、熄屏继续录音、离线安全保存、系统允许时后台补传及前台结果恢复。
- 健康能力独立：经 HealthKit 授权读取已有心率、HRV（SDNN）、静息心率、睡眠及活动数据；先本机展示和个人趋势。健康授权失败或缺数据不阻断语音功能。
- 不依赖 YoooClaw 账号、卡片密钥或固件。保留旧驱动、密钥和历史资料，不自动删除或迁移它们。Apple Watch 按正常应用签名及苹果系统权限接入，不伪装成 BLE 录音卡。
- 不承诺全天隐蔽录音、固定全天续航、永远在线或实时读取其它 App 通知；不为后台常驻或连续心率而伪造运动会话。

## 2. 用户操作与三种录音用途

| 用途 | 手表入口 | 保存与处理 | 手机呈现 |
| --- | --- | --- | --- |
| 短语音对讲 | 屏幕按住说话、松开提交；同时提供点击开始/结束，方便操作 | 松手先闭合并落盘；在线走私有短语音 ASR 后续接 Hermes 同一对话；离线显示待处理 | 对讲录音条、转写、完整工具查询后回复、连续追问 |
| 会议 | 明确选择会议，点开始/结束 | 一个会话连续采集、底层分段；闭段可传，停止并确认尾段齐全后完成整场归档/纪要 | 整场播放、完整逐字稿、纪要；内部片段放详情 |
| 随身记录 | 选择随身用途，主动开始/结束，可打标 | 按时间段落盘及同步；同会话用途不随设置变化；复盘按选定范围 | 时间段音频/转写、合法导入事件、可选健康概况；手动或明确开启的自动复盘 |

- 长录初始建议约 2 分钟封段，停止立即封尾段；最终参数由 Series 10 续航、边界音质和 ASR 测试决定。切段不能靠停止/重开录音制造缺口，完整性按音频样本/分段序号校验。
- 状态包含倾听中、音频已保存、等待手机、等待网络、同步中、转写中、工具处理中、已完成和可重试失败；没有服务器回执不显示已同步。
- 首版对讲是短录结束后识别并答复，不承诺熄屏下持续实时语音流或唤醒词。文字回复优先；语音播放可选，不要求用 Siri 或苹果云识别替换私有 ASR。
- Series 10 的表冠/侧键不作为任意可重映射的录音卡按键。采用 App 大按钮和表盘入口；快捷指令/App Intents 的具体支持在原型后评估。

## 3. 熄屏、中断、离线和空间

- 用户在前台明确启动录音，通过合法音频会话继续熄屏录音；熄屏和强制结束 App 是不同状态。
- 来电、麦克风占用、系统终止、掉电及低电量分别记录中断原因。保留已完成段，尽可能闭合当前段；异常退出不承诺救回最后一个未完成编码缓冲区，不把有缺口录音标完整。
- 手表本地文件是首份持久副本，使用适当文件保护；分段闭合、校验后写索引，重开按索引恢复。索引和文件提交间的崩溃要能对账。
- 无手机、无网络时仍可录音；远端 ASR 和 Hermes 需要能到达私有服务器的网络。GPS 版可以使用可用 Wi-Fi，不必购买蜂窝版。
- 每段记录来源安装ID、会话ID、用途、序号、原始格式/实际采样率、样本偏移、起止时间及时区、时间可信度、大小、SHA、处理策略及回执。设备安装ID不是硬件SN，重装/换表需显式恢复来源关系。
- 原音频不因传输完成自动删除。显示手表/手机待同步量和可用空间，空间不足暂停并提示；以后若增加清理，由用户预览确认，不以自动覆盖保证全天录音。
- RTC/墙钟变化与音频单调样本时钟分开；不对没有样本覆盖的时间填造录音或健康事件。

## 4. 后台同步和结果回传

默认主链：Watch 原生录音与持久队列 → WatchConnectivity → iPhone 原生安全落盘 → 后台 URLSession → 原私有归档服务 → 原私有 ASR/Hermes → 结果索引 → 手机/手表。

- 即时状态/短消息只在 counterpart reachable 时使用 sendMessage；文件走 transferFile 持久后台通道。系统排队没有固定秒级时效；已配对、已连接、可即时通信及服务器在线分开显示。
- iOS 接收文件后先在原生回调有效时间内移到本机受保护目录并核对，再确认手机落盘回执，不依赖 Flutter/Dart 必须常驻。大音频封装/ASR 放服务器，减少手机唤醒时间内的计算。
- 分别保存手表闭段、手机落盘、服务器提交、转写完成、正式总结完成状态；同来源版本幂等，超时未知先核回执，不用重复模型提交掩盖失败。
- 只上传闭合段；完整清单、尾段与全部转写确认后生成完整纪要。录音未结束时可出现部分文字，不宣称整场完成。
- 默认关闭自动音频上传、自动转写、自动总结；按用途独立开启并在录音开始时固定快照。默认不追溯旧录音、不自动发离线短问，恢复网络后由用户确认待发送的过期对讲问题。
- iPhone / Watch 被用户强退后的行为单独测试，不承诺后台自行重启；重新打开对账恢复。已送达服务器的任务继续，未送达数据继续保留本地。
- 第一阶段结果通过 App 活跃时取回和正常 WatchConnectivity 更新；不开 APNs 也可验收，不承诺服务端即时唤醒手表。
- 后续可选 Watch 有 Wi-Fi 时直接走同一私有归档入口，绕过 iPhone，但需额外完成 watchOS URLSession、受限手表凭据、网络可达、耗电及双路去重验证；默认关闭，不作为首轮成功前置。不把 iPhone 上的 VPN 可用等同手表能直连私网。

## 5. HAL、音频格式和服务器适配缺口

只读依据：现有 HardwareDeviceDriver 为输入抽象，工厂只有卡片及手机麦克风；长录资料处理可以复用，但存在卡片专用来源/格式假设。

- 新增 Apple Watch 设备类型/适配器和可选的文件录音能力，保留旧 HAL 路径。录音操作确认要区分命令已发、手表已接受及实际收音；离线不能假报启动。ANCS 等不适用能力显式显示不支持，不能伪造成功。
- watchOS 使用原生音频能力；初始以系统支持的单声道 AAC/M4A 评估长录功耗和存储，实际采样率由设备协商，不冒充卡片 Opus。短问必要时在手机转换成既有 ASR 接受的 WAV。
- 现有音频归档 v1 严格验证 OggS，且部分字段/上下文服务于录音卡 Opus；直接上传 M4A 会失败。后续实现需新增明确协商的音频协议版本，包含来源、编码、采样率、有效样本/编码首尾修剪和时间证据；服务器验证容器后用已有 ffmpeg 转成私有 ASR 所需 WAV。
- 保留旧 v1 Ogg 校验及旧调用兼容性，不把 M4A 改后缀冒充 Ogg，不静默放宽所有文件类型。分段编码延迟、静音、边界丢字/重复、重采样时长和跨段说话人身份均需专门回归。
- 私有 ASR 的短语音 /v1/audio/transcriptions、长任务 /v1/jobs 和 Hermes 对话地址保持不变。仅扩展自有资料协议/来源适配，不新增官方云或 Relay，不把卡片共享密钥带进手表链路。

## 6. 通知替代与资料融合

- 标准第三方 watchOS App 没有跨 App 通知收件箱权限。苹果手表系统显示微信/短信，不代表 SunMate 能读取正文。
- 新 Accessory Notifications 面向特定配件转发，有地区、账号和扩展条件，官方说明客户设备需处于欧盟且账号地区为欧盟；不能将其视为普通 Apple Watch App 的通用解法。本方案不依赖它。
- 可做的来源：用户主动分享文字/截图后本机OCR；授权日历/提醒事项；邮件/业务系统/企业协作产品各自允许的API；用户主动语音记录。接口有无、权限和内容范围逐个确认，不假定企业微信接口能读取个人微信。
- 保留独立通知/消息简报功能，但标明“导入/授权来源消息”，不能声称覆盖全部手机通知。已经保存且仍允许使用的历史通知继续保留来源信息。
- 会议纪要、消息简报、随身复盘独立；随身复盘融合所选时间范围内已保存/允许使用的来源。无消息或健康数据时显示缺失及覆盖范围，不补造。
- 不将快捷指令、截图OCR或邮件接口包装成全局实时通知监听。

## 7. 心率、HRV及压力线索

Series 10 的光学心率、电心率及温度传感器和 HRV 功能有官方资料。GPS版不影响这些传感能力。原始传感器能力、Apple健康样本和本App获授权可读数据是不同层。

| 数据 | 拟接入方式与首期边界 |
| --- | --- |
| 心率、静息/步行平均心率 | 经授权读取 HealthKit 已有样本；显示实际测量时间、来源及新鲜度，不许诺秒级实时或全天连续 |
| HRV | 读取实际 SDNN 样本和毫秒单位，展示个人趋势及覆盖；不冒充 RMSSD 或连续心电 |
| 睡眠、步数、活动/运动 | 读取用户允许的数据作为个人恢复背景，跨设备去重，不自行补记一次不存在的运动 |
| 呼吸频率、夜间腕温等 | 作为可选后续项，依实际样本/授权/地区功能而定；腕温不是随时的核心体温读数 |
| 血氧/心电等 | 不作为首期依赖，按地区、系统可用性、用户操作和明确授权另行评估；不因硬件有传感器就宣称可连续读 |
| 压力 | 首期不输出0—100“实测压力”；提供个人主观紧张度打标及有依据的恢复/负荷线索。后续有足够个人基线再评估推断指标，必须标为推测 |

- 首期优先通过 iPhone HealthKit 读取苹果健康里已同步的样本，独立于录音模块。这样不要求 SunMate 为每次会议开传感器常驻。
- 健康后台交付是样本更新机会，不是固定频率采样器；手机锁定或受保护数据不可访问时延后读取。缺样本不能区分没授权/尚未测量/尚未同步等所有原因，显示“暂无可用数据”，不填0。
- 不为会议长录或压力看板虚构 HKWorkoutSession。真实运动功能若以后加入，单独设计运动生命周期和用户授权。
- 心率升高或HRV下降也可能与运动、睡眠、疾病、咖啡因等因素有关；不能据此判定焦虑/疾病、谎言、会议因果或他人的情绪。定位是个人身心恢复观察，不作医疗诊断。
- 原始样本带测量时间和质量/来源；语音段按时间窗口关联现有样本，并明确时间关联不等于因果或该段持续监测。
- 所有健康功能默认关闭、按类型只读授权，不请求无关健康写入权限。读取、本机分析、发送私有服务器、供Hermes健康复盘使用是分别的许可；同意读HealthKit不等于同意上传。
- 健康数据不混入普通会议纪要或默认通用智能体检索库。仅在用户明确开启个人身心复盘且满足苹果健康数据使用要求后，传最小必要概况到健康用途的受控资料范围；原始样本默认留本机，关闭授权不破坏语音功能。
- UI保留实际数值/数据来源和算法解释，不能让Hermes自由编造压力分。用户可查看、导出或清除本App派生资料；原HealthKit数据不自动删除，任何删除另行确认。

## 8. 开发顺序与通过条件

1. 技术验证：先核对iPhone型号/iOS、配对状态、开发签名团队及匹配的Xcode/watchOS SDK。当前本机xcode-select指向CLT，原CI为macos-14，不能沿用旧环境便宣称支持watchOS27.2；升级工具链/CI须在用户确认实施范围后做。
2. 原型：手表短录、连续长录熄屏、离线闭段、真实音频文件与原生接收回执。至少30分钟/60分钟熄屏录音、离开手机、来电中断、停止封尾、强退后恢复及空间不足，记录实际耗电/温度/文件完整性；原型未通过不铺开上层页面。
3. 对讲：接入既有私有ASR/Hermes，保留完整工具结果和追问上下文，验证手机锁屏/后台及离线待问恢复；不靠手表小屏始终前台维持任务。
4. 两种长录：闭段后台传输、格式验证、断网/未知回执/幂等、补齐尾段及实际播放。会议整场展示，随身按段展示；自动开关默认关闭，完整档案才自动总结。
5. 健康只读：逐项授权、缺样本/锁定延后、时间窗/来源去重、撤销授权及本机趋势，不开启远端健康归档。
6. 资料融合：用户确认后接入合法消息来源、个人健康概况及受控Hermes身心复盘。Watch直传、健康外发、APNs后续按需确认，不列为首轮默认开启项。

本轮交付是待确认方案，不表示上述新能力已实现或在手表实测通过。只更新方案文档和任务记录，不修改现有App或安装包。

## 官方依据（2026-11-01只读核对）

- watchOS27.2发布：https://developer.apple.com/news/releases/?id=10262026g
- Xcode/SDK要求：https://developer.apple.com/xcode/system-requirements
- Series10规格：https://support.apple.com/en-la/121202
- 连接方式：https://support.apple.com/en-in/109319
- 录音后台规则：https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/iPhoneOSKeys.html
- WatchConnectivity：https://developer.apple.com/documentation/watchconnectivity/wcsession
- 后台网络：https://developer.apple.com/documentation/watchkit/wkurlsessionrefreshbackgroundtask
- 本App通知范围：https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getdeliverednotifications(completionhandler:)
- 配件通知地区条件：https://developer.apple.com/documentation/accessorynotifications
- HealthKit/隐私：https://developer.apple.com/documentation/healthkit/ ，https://developer.apple.com/documentation/healthkit/protecting-user-privacy
- 读取授权边界：https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data
- HRV SDNN：https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn
- 健康后台交付：https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:)
- 运动会话：https://developer.apple.com/documentation/healthkit/running-workout-sessions

## 补充：GitHub Actions 云端编译与安装方案（2026-11-01，只读核对）

用户已确认只有普通 Apple 账号／免费自签。本次只制定方案，不改工程/CI/版本，不启动 Actions、打包或推送，不下载大型工具，不读取或配置真实签名凭据。

### A. 已核对的环境与工程缺口

- GitHub 的 `xcode-27` 是已正式可用的 arm64 托管镜像。20261026.0314.1 软件清单列出默认 Xcode 27.1，以及 Xcode 27.2（27B48，路径带 Release_Candidate）；后者包含 iPhoneOS/watchOS 27.2 SDK。这是镜像文档证据，尚未在本仓库真正启动 runner 验证，也未核对本账号配额/权限。
- 不使用随时间漂移的默认 Xcode。未来作业开头先检查预装路径，再设 DEVELOPER_DIR，打印 Xcode/Swift/SDK/镜像版本；缺失就失败退出，不执行下载 SDK、模拟器或系统更新。设备系统版本、构建 SDK、最低支持系统是三件事；不能仅凭设备为27.2就认定所有分发必须用27.2 SDK。候选工具链先用于编译检查，TestFlight 分发要选择当时 App Store Connect 接受的版本。
- 现有 `.github/workflows/build_ios.yml` 使用 `macos-14`、仅构建 Runner 且禁用签名，再手工 ZIP 成 IPA。GitHub 已公告该镜像2026-11-02退役；这也影响旧 iPhone 工作流，但本轮不代改。
- Watch 目前是独立原型工程。Runner 未引用/嵌入 Watch 产品，也没有匹配的真实签名团队。需补跨工程依赖、标准 Embed Watch Content、共享归档配置和图标资源；不能只把一个 Watch.app 塞进 ZIP 就宣称可安装。
- 当前源码标识为 iPhone `com.sunmate.app`、Watch `com.sunmate.app.watchkitapp`，WKCompanionAppBundleIdentifier 指向前者；真实自签工具可能改写标识，后续应以实际安装身份为准。两端必须保持苹果要求的关联及同一签名团队。首期继续是有 iPhone 伴侣的手表 App；离开手机仍能本地录音不等于要切成 watch-only 产品。
- 新工具链下需核对 Flutter3.35.7/CocoaPods及插件兼容，不顺便升级依赖。Podfile已为iOS15，但Runner部分配置还写13，未来需明确统一受支持的部署目标；本轮不静默改兼容范围。

### B. 实施顺序（每阶段按授权推进）

1. **无签名 SDK 编译门槛**：未来新增仅手动触发的 Watch 检查工作流，不接 main push。使用预装 Xcode 编译原型 Watch 真机目标，禁用签名，只保留编译日志/结果；不 archive、export、生成 IPA 或向 Apple 上传。此阶段不需要 Apple 账号或签名私钥。模拟器只用已预装 runtime，缺失则报告，不自动下载。先查清真实平台类型/API/链接错误。
2. **伴侣工程整合门槛**：上一步通过后，在单独变更中接入 Runner 的标准 Watch 依赖/嵌入、图标、版本及 ArchiveAction；完整编译 iPhone 和 Watch，核对产物架构/关联标识。保留 HAL、原 AES/旧密钥和私有端点，云端测试仅用合成资料。
3. **免费账号真机验证（当前路线）**：等用户网络方便，再在本机安装匹配 Xcode。用户自行登录同一 Apple Account/Personal Team；连接配对 iPhone，按系统要求开启手机及手表 Developer Mode，注册并选择这块手表，从 Xcode 签名运行。首次先验证启动、麦克风、短录及手机落盘回执，再做30/60分钟熄屏/离线/中断。Personal Team描述文件有7天期限，须按期重新签名/安装，不能承诺一次安装长期免维护。此阶段目前暂缓，不索取密码/验证码或代启用安全设置。
4. **后续云端签名分发（可选，不要求现在购买）**：若用户以后已有付费开发者资格，可用 TestFlight 内部测试或注册设备的 Ad Hoc。前者需 App Store Connect 记录、分发签名和上传权限；后者需 iPhone/Watch设备注册及相应 profiles。不能把 App Store Connect API Key 当作代码签名私钥的替代品。

### C. 签名与安装路线对照

| 路线 | 前提 | 手机／手表安装 | 当前结论 |
| --- | --- | --- | --- |
| 云端无签名编译检查 | GitHub可用runner/配额 | 不能直接安装 | 免费账号也能推进，推荐先做 |
| 本机Xcode Personal Team | 普通Apple账号、完整Xcode、设备开发模式/配对 | 用户登录后从Xcode运行到手表及配对手机 | 当前可采用的官方个人测试路线，工具下载暂缓 |
| 云端签名→TestFlight | 付费开发者资格、正确App ID/profiles/分发证书及上传权限 | 配对iPhone装TestFlight，先装iOS版，再在App详情中安装可用的Watch版 | 暂不适用于当前账号；单构建最多测试90天 |
| 云端签名→Ad Hoc | 付费开发者资格、注册phone/watch设备、分发证书及对应profiles | 标准导出包，经Apple支持的设备安装工具；按要求开启Developer Mode | 可选，不等于旧IPA重签路径已通过 |
| 云端未签IPA→爱思/Sideloadly免费重签 | 工具须支持Watch嵌套目标、两端profiles/标识/权限 | 必须另外实测 | 不列为已验证交付方案。Sideloadly当前0.71.0公告Watch支持针对付费账号，免费支持仍标为后续版本；爱思教程未证明当前Watch目标可安装 |

### D. 健康与历史资料边界

- Apple当前iOS能力表的HealthKit在普通Apple Developer列也标为支持；不能声称读健康必然要求付费会员。实际仍需 profile 匹配 entitlement、用户逐项读取许可和真机验证。首期仅iPhone目标读HealthKit，Watch不为读取健康额外申请权限。
- 云端编译不需要也不发送卡片密钥、ASR/Hermes Token、健康样本或真实录音；签名材料与业务凭据完全不同。未来若采用云端签名，用户自行将签名材料放入受保护的GitHub Secrets，作业临时钥匙串导入并清理，不输出或打入 artifact；当前不创建任何 secrets。
- 覆盖安装前核对现有 App 的 Bundle ID、App ID prefix/Team 与钥匙串组。切换签名身份可能使原钥匙串不可访问，即使 Bundle ID 文本相同也不能保证凭据延续。不得为装Watch卸载旧App；若身份无法保持，先单独确认隔离测试及合法备份/迁移方案，保留原音频和旧App。
- 云端编译通过只证明构建可用，不代表后台熄屏录音、WatchConnectivity调度、耗电或健康读取已在Series10实测通过。

### 本次官方依据

- Xcode 27镜像正式可用：https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/
- 镜像预装清单：https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md
- macOS14退役：https://github.blog/changelog/2026-10-01-github-actions-macos-14-runner-image-retirement/
- Xcode/SDK/部署目标：https://developer.apple.com/xcode/system-requirements/
- Personal Team限制：https://developer.apple.com/help/account/basics/about-your-developer-account
- iOS健康能力：https://developer.apple.com/help/account/reference/supported-capabilities-ios
- TestFlight手表安装：https://testflight.apple.com/
- Ad Hoc及注册设备：https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile
- 标准导出和安装：https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices
- 云端签名材料：https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications
- 钥匙串身份变化：https://developer.apple.com/library/archive/qa/qa1726/_index.html
- 自签工具发布者说明：https://sideloadly.io/changelog

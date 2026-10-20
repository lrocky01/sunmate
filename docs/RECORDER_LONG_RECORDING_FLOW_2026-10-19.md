# 长录文件、分段同步与用途选择核对（2026-10-19）

## 结论与本轮范围

官方会议长录是「卡片分段文件 → 蓝牙目录/读取 → 本地分段提交 → 停止后的尾段补扫 → 按序合成音频」；它与按住说话的实时音频通道不同。本地保存算法不要求接入 ASR 或 Hermes。2026-10-20已在本地补齐会议/随身记录的录音期间闭合段同步，最新规则及验收边界见第8节；第7节保留此前仅停止后下载的实现记录。

首轮完成 APK 静态主链核对、用途选择和会话元数据。随后用户授权补齐文件闭环，现已本地实现目录、串行分段下载、断连/进程重启恢复、尾段补扫、严格OPS校验、Ogg封装、iOS原生完整解码为WAV及本地播放入口。**本地回归通过与手机实卡验收分开：尚未安装新包、实卡下载或在iPhone扬声器播放。** 保持版本1.0.25+26，不打包推送、不操作真实卡片/账号/密钥、不接ASR/Hermes。首轮范围和证据保留如下，新增实现见第7节。

## 分析工件与证据边界

- 原 APK：`YoooClaw 2.3.0.apk`，SHA-256 `e638958d143b518829a3db4d16cb4f8db1b19c64d49149458b98684c16e2137f`。
- REA 查询使用已有恢复 DEX 重建的 `tools/ble_audit/reconstructed-analysis-only.apk`，SHA-256 `cdaf78f1abb2bdbc57430eb8b54b82e00ed264099c0f12ddc26814de1f3a7318`。它是分析副本，不是厂商未加固原包、原始源码或可安装发行物。
- 详细方法、REA Evidence ID 与摘录索引在本机 `tools/ble_audit/long-recording-20261019/wire/` 和 `segments/`，各有 `findings.md` 与 `evidence-index.json`。这些分析输出被 Git 忽略，不包含本轮实卡音频或凭据。
- 本文区分有方法体的静态事实、SunMate 的保守设计约束与仍缺失的保护方法。没有本轮实卡文件传输验收，不能宣称 APK 的全部内部逻辑已经恢复。

## 1. 文件获取的精确通道和报文

以下报文均为**十六进制**。Telink 业务服务是 `00010203-0405-0607-0809-0a0b0c0d1930`：命令 `...2B30`（withoutResponse）、事件 `...2B31`、实时音频 `...2B32`、文件数据 `...2B33`。`...1913/...2B15` 属 OTA，不得向其发送这些文件命令。

| 操作/事件 | 官方可见布局和含义 |
| --- | --- |
| 请求目录 | `11 22`，精确两字节 |
| 读取文件 | `11 26` + UTF-8 文件名；无 NUL、长度、offset、range、CRC 或 wire transfer ID |
| 删除文件 | `11 24` + UTF-8 文件名；破坏性独立操作，本轮不实现、不调用 |
| 停止录音 | `11 21`，不能当成停止文件传输 |
| 目录条目 | 事件 `AA 55 08` + UTF-8 文本；trim 后空白拆分，文件 basename 与 signed long size，额外项未用 |
| 目录结束 | 事件恰好为三字节 `AA 55 08` |
| 文件大小 | 事件 `AA 55 05`，至少七字节时从 offset 3 读取 BIG_ENDIAN signed int32；负值夹到 0，短包为 -1；长录上层拒绝 size<=0 |
| 文件数据 | `2B33` 通知原样追加，未见包级 seq/offset/CRC；由本地当前传输身份分配给接收器 |
| 文件完成 | 事件 `AA 55 06`；没有文件名、wire transfer ID 或校验和，仅此事件不能证明文件完整 |
| 段关闭提示 | JSON `reportLongOpsSegmentClosed`，含 session 与 part 候选字段；不内含音频 |

分段文件名严格形式为 `^/?longops_s(\d+)_p(\d+)\.ops$`，Telink 的 part 从 0 开始。官方低层取 basename 的行为不能代替路径安全验证；SunMate 后续应从已验证 SN/session/part 自行构造本地路径。

虽然 profile 将 FILE_RESUME 标为 READY，实际 Telink read 编码不带 offset，默认 `encodeDebugReadFile` 也忽略 offset 参数。恢复方式是**保留已确认完成的分段，失败段从零整段重下**，不能宣称任意字节断点续传。

## 2. 官方分段与本地提交顺序

1. `LongSegmentSyncCoordinator.start` 创建或恢复 session，记录 activePart、时长锚点和 Recording 状态；开始事件及状态回报都可能进入，同一 session 重复恢复不新建业务会话。
2. 请求目录，按 session/part 建 inventory 和段账本。目录有 generation、目标 session、结束标记及 watchdog，不能把迟到列表直接归到新会话。
3. 跳过当前正在下载和已提交段。恢复已有 `pN.ops` 前核对来源身份、大小和完整 OPS 结构；损坏段隔离，不当成功。
4. 同时仅一个 currentDownload，按 session/part 串行，正大小才开始。写 `pN.ops.tmp`，失败重试重新 truncate；不把实时流当文件数据。
5. 元数据更新 confirmedBytes；数据写临时文件、累计 receivedBytes 并刷新进度 watchdog。router 核对本地预期传输身份，但 wire 本身没有可验证 transfer ID。
6. 收到匹配完成事件后 sync/close，receivedBytes 必须等于 confirmedBytes；rename 临时段至最终 `pN.ops`，fsync 父目录，再标记 Committed、通知上层并下载下一段。失败不标提交。
7. 官方无进度期限 15 秒、最多 3 次重试，退避从 3.5 秒指数增长、上限 15 秒。重试换本地 attempt、从零读取该段，保留其它已完成段。上层取消传输不能据此推导 Telink 有某条停止文件流命令。
8. stop 后进入 AwaitingRecovery 并最终补扫目录。通常至少两次最终观察；不满足完整性时最多五次后按目标会话/修复条件处理。**收到录音结束不代表最后一段已关闭、目录齐全或音频已落盘。**
9. 合成前检查停止状态、相关下载/目录结束、所需段连续可用，以及策略要求的来源资料。记录 inventoryRevision 等快照，避免异步结果提交到已变化的会话。
10. `io.ktor.events.Events.assemble` 按段顺序以 64 KiB 块送入同一个 `BleStreamReceiver.start/pushData/finish`，返回本地音频路径。不能直接拼接 `.ops` 或改后缀当成可播放文件；此局部不调用 ASR/Hermes。

官方有两种不能混用的解析规则：恢复已有 OPS 文件的严格校验采用重复八字节头（LE payload 长度 1..65536、后四字节为 0）和 payload，必须恰好耗尽；通用 `OpusFrameAssembler` 则接受 payload/padding 两个 int 的 LE/BE 合理性判断（payload 1..8192、padding 0..8192），坏头逐字节 resync。后者用于流容错，不能把滑动恢复当完整文件校验通过；帧长范围也不能替代真实 Opus 解码验收。

## 3. 不照搬的删除行为、缺口与后续约束

官方 Telink 策略会在本地段提交后删除卡上段，最终合成成功后清理原始本地段。**用户未授权删录音，SunMate 不继承这些默认行为，后续默认保留卡上和本地源段。**

仍未确认：

- 当前恢复工件缺 `onSegmentClosed(JI)V` 的实际方法体；有 dispatcher 引用，不能断言它立即排队还是触发目录。
- `maybeAssembleStoppedSession$3.invokeSuspend` 缺体；已确认合成准入与 assembler，最终音频 rename/fsync/数据库事务的完整次序尚未恢复。
- 目录条目未证明排除正在写入的 activePart。后续应只取明确 closed 或 part<activePart 的段；状态未知先登记，停止后补扫尾段，不能仅凭大小暂稳报告完整。
- wire 无 seq/offset/CRC；完成和数据跨特征通知，本地 transfer ID 不能证明晚包隔离。后续须串行下载、会话世代及超时隔离，不能猜 ACK、offset 或立即将旧流导向新文件。
- 同卡固件的分段时长/阈值、真实目录与 OPS 样本、跨通道顺序、最终文件播放尚无本轮实卡证据。

因此后续完整文件同步应单独实现并验证段大小/来源/结构、缺段、尾段闭合、重复/迟到事件、断连重试、本地提交失败和最终播放；本轮不把一个用途选择菜单当成这些能力已完成。

## 4. 本轮 SunMate 已落地内容

- `recorder_long_recordings.dart`：本地用途选择与会话控制器，按 SN/session 保存用途、首次观察和结束观察时间；不保存密钥、Token、音频或远端路径。使用独立 SharedPreferences key，不引入依赖或迁移密钥。
- 录音设置新增「长录用途」会议/随身记录。选择持久化成功才显示已保存，录音中禁改，只影响下一次新长录；双/三击继续按现有固件配置启停，不虚构两种独立按键信号。
- 真实 AES 验证后收到二进制 LONG start 时固定本次用途，stop 仅记录结束；不混入实时短语音、不向 ASR/Hermes 提交长录占位数据，也不发送新的设备写入。
- 断连保留会话和用途，不伪造 stop；同 SN/session 重连继承原用途。重启后将旧“录音中”标为待确认，真实状态恢复后才确认当前会话。仅由状态回报发现、没有本机原始用途的历史 session 显示“用途未确认”，不套用今天的默认选择。
- 本地存储损坏保留原值并提供重读，保存失败保留内存会话并提示重试；本地错误不会使真实 AES 失效或写入旧密钥。初始化、选择保存与开始事件排队，已发生的开始不能被稍后保存的选择追溯改用途。
- 近期会话页和诊断明确提示“音频未同步”。HAL 基础接口、PhoneMic、多驱动、业务 AES、旧密钥保护、私有端点保持；不自动解绑或删卡。

## 5. 核心 REA Evidence 索引

| 方法/事项 | Evidence ID |
| --- | --- |
| Telink read 编码 | `ev_6322f6d6eaf9e6bc8c6fd5cc39fb7521eac8112f97dda22ad4c4b06152eccf56` |
| 命令常量 smali | `ev_3d708b436d96d041af06f511afd2841a7ac446dbf8d31353e6ad7fcc3cfefb3d` |
| start | `ev_797a52b26c3137cadecf148e63004778762dcbb3735fea483381314268762873` |
| 目录 | `ev_469eac3f5949301a1ad67e61ef24b6cb0d99189d8d264dcfc0013f5bca399d22` |
| 已有段结构校验 | `ev_f245de10044be5fac2b9f813f14bf8da940686c333d4798485b0bd545eab4d72` |
| 提交本地段 | `ev_d5544986dd50fd7ff901d59c0f90a32fc8b99ea774d1b860f825e771fa92bd8a` |
| 重试 | `ev_40312d5187d2ec97cb64a02b998b727f53cce205577fab4640939391f1acbf98` |
| 最终目录判定 | `ev_e354b20a23cdd6eff9ceb3a517fdee70ac7fee09870c6b46284180bcdbd7c07f` |
| 合成准入 smali | `ev_7d36bc0376048fa47426d4bb332d321e5a6a0d945e2a929391c5382fc125a746` |
| assembler | `ev_8836b158ca68f8c5d0b8c00c4251a00cb4179b75cabbb841b383e79d250439da` |
| 通用流解包 | `ev_a26db10316fe13aeaa571095fcbff677229b2b95696cc56f0966060392a44cca` |

## 6. 本地验证

- 全量 `flutter test --no-pub --reporter expanded`：284 项全部通过（既有 253 项 + 本轮会话控制器 18、真实驱动状态机/AES 测试挑战 7、用途 Widget 6）。
- `flutter analyze --no-pub --no-fatal-infos`：退出 0，无 error/warning，保留 11 条既有弃用 info。
- 另以截图开关运行用途 Widget：6 项通过；已查看 360×640、390×844 的选择状态、录音中禁用和保存失败四张截图，无溢出/遮挡发现。
- 回归涵盖用途持久化、开始冻结、同 SN/session 重连、进程重启待确认、历史用途未知、初始化/保存竞争、本地损坏与失败重试、实时/长录隔离、真实 AES 前不采纳事件、状态恢复后的结束事件、旧密钥不写入及无额外用途 BLE 写入。
- 差异空白检查通过；版本与依赖未改。HAL 基础、PhoneMic、端点文件未变，本轮未操作真实设备、解绑、凭据或账号，没有构建或推送。

静态 APK 分析和模拟平台回归不能代替实卡文件同步与播放验收。

## 7. 后续授权实现：本地文件闭环

### 代码与入口

- `telink_long_files.dart`：独立解析AA5508目录、AA5505大小、AA5506完成；命令仅11 22和11 26，不含删除、解绑、offset或猜测的停止传输命令。
- `recorder_long_file_sync.dart`：已验证SN/真实AES/GATT文件通道绑定的串行同步状态机。只有卡片明确空闲时读取，录音中不下载尚可能写入的段；这与官方边录边拉已关闭段策略不同，是本次保守选择。
- `recorder_long_file_store.dart`：ApplicationSupport/recorder_long_audio_v1/<SN>/s<session>，安全路径、唯一临时段、严格OPS/大小/SHA、内容摘要文件名、流式Ogg和本地JSON归档。已提交段和原始Ogg保留；不同内容不覆盖，坏文件隔离保留。只清理本次新建且重复的未提交临时副本。
- `recorder_local_audio.dart` / `RecorderLocalAudio.swift`：iOS本机Opus解码及播放。Ogg校验后转内部CAF，再完整流式解码为16k单声道PCM WAV；每次播放前校验源摘要证明、WAV SHA、格式和完整样本数。解码和校验在后台，原生播放回执才显示正在播放。没有网络、账号、蓝牙控制或ASR调用。
- `recorder_long_files_page.dart`：录音卡管理→长录文件与播放（录音设置也有入口）。先读取卡片目录，选择保存到手机；不完整项可继续恢复，完整本机音频离线可播放。没有删除/转写/云同步按钮。已有会议智能处理页尚未接入这些归档，本轮不扩大到ASR/Hermes。

### 完整性、尾段与恢复规则

1. 新物理连接真实AES完成后才开放同步，订阅2B33失败不破坏已验证的实时音频连接。文件/JSON/通知/录音分别分流，文件错误不取消AES、不写密钥。
2. 一个目录或文件操作在途，目录最多10000个长录条目；严格名称匹配及正整数大小，冲突重复目录拒绝。非长录文件忽略，不读写它们。临时接收与提交分开，失败不会把半文件当已保存段。
3. size元事件、completionSeen和received==size同时满足才提交；跨特征的完成事件先于最后数据时继续等待。大小冲突、超量、跨操作事件或15秒无进度后锁住文件通道，必须普通断开并重新连接才重试，避免无wire ID的旧数据混入新段。GATT命令Future未返回也能被超时/断连结束等待。
4. 保留已提交段并逐次复核size/SHA/OPS；失败段从零整段重读。进程重启即便尚未写归档JSON，也可从同SN/session的内容摘要文件恢复已完成孤段。未授权远端删除；没有任意字节offset续传。
5. 停止后最多5轮初始扫描，至少连续两轮非空、正大小、p0起连续且目录一致；如有已验证状态/段关闭提示，保留long_part最小尾段锚点，不能稳定缺尾也提前通过。下载完再两轮确认目录未变才合成。目录变化保留源段并提示继续恢复；之前已保存版本发现目录指纹变化时，持久化为待补齐，旧音频文件仍保留。
6. 严格OPS为u32LE长度1..65536+四字节零+payload，恰好耗尽；不滑动resync、不猜大小端。连续段以原始Opus packet生成新的Ogg，计算实际TOC的48k granule与CRC、preSkip=0，保留未知编码延迟的全部样本，不擅自截掉312。单声道守卫，2.5/5/10/20/40/60ms等按合法TOC计算，不假设每包960。
7. 原生CAF使用variable frames-per-packet和逐包样本数；包表及音频均走磁盘流，固定缓冲，不把整场音频/所有包元数据载入内存。完整解码WAV的frames与源TOC总时长匹配才记录已保存。JSON落盘失败、系统解码失败或时长不符仍为未完成，OPS/Ogg保留。

### 本次新增静态证据

在不改工具配置的情况下复用已有REA CLI/JDK/JADX，新增5项有体查询，安全索引位于`tools/ble_audit/long-recording-implementation-20261019/wire-review/`：

- `ev_de3a2929fc012991227864be15f1eb0d1296eaa985d64c59cfdc6e7dc0746572`：Telink完整decoder与段关闭字段候选。
- `ev_8809b12c93fbb567035916d12db6ee3b3004193bb46c4359368233fd5939a4ed`、`ev_19ce7bade1511a8977dd49eea8b88f2ba42a9bdf2ac48e81348815430417d19f`：nativeCreate(1,16000,312)/nativeWritePacket(...,960)数值；native参数语义与内部处理仍未恢复，不凭约定编造实现。
- `ev_810990718025a638e7e4cf42b7026210be117813eb861e025c3e0866d7f21875`：官方finish仅非空和rename，没有实际播放验证。
- `ev_3a8eb7144be5035aa071cee2a6ebbc5b26ea3947bf35d5472f097330e5c9e792`：onSegmentClosed方法体仍缺失，未声称完全解密APK。

### 验证与剩余边界

新增专项覆盖目录/NR命令/文件CCCD、真实AES测试挑战、断连和进程重启、超时和迟到、缺p0/缺中间段/尾段增长、大小/SHA/OPS/UTF8/路径、磁盘归档、源变更、Ogg CRC/TOC、播放回执及禁止假成功。另用同一条完整流程将两段合成OPS→Dart Ogg→实际CoreAudio WAV，得到32000帧/2000ms，保存归档并重新读取；测试输入均合成，不读取真实录音。

原生回归还用独立ffmpeg正弦输入得到非零PCM、混合10/20/40/60ms包得到2080帧/130ms、30000包长录得到960万帧，并验证CRC/截断/路径/symlink/缓存同长篡改与播放前再校验。Mac AVAudioPlayer可准备输出WAV；这不等于iPhone实际扬声器播放。

最终检查：全量`flutter test --no-pub --reporter expanded`373项通过（此前305项，本轮新增68）；`python3 -m unittest discover -s sunmate_app/test/native_audio -p 'test_*.py'`11项通过；`flutter analyze --no-pub --no-fatal-infos`退出0、无error/warning、11条既有弃用info。Swift同源核心及Flutter分支stub类型检查、pbxproj plutil、diff空白检查通过。HAL基础接口、PhoneMic、真实AES实现、pubspec/lock及私有端点均无本轮改动，依赖/版本未变。

边界：本机没有iPhone SDK/simctl，不做iOS整包编译或实机验收。Flutter Widget截图仅用于360/390手机尺寸、大字号和错误态布局。原生需iOS13.4+（低版本明确不支持），当前工程没有Android原生目录，Android明确不假报解码/播放成功。单个Opus包超过65024字节暂拒绝Ogg合成，原OPS保留；单段256MiB、整场4GiB及WAV约20亿样本为本地资源界限，不是固件容量声明。

wire仍没有seq/CRC/最终总段数：一致目录是恢复策略，不是固件最终尾段数的数学证明；实际固件关闭尾段时限、任意重放/迟包以及真实OPS编码仍需后续实卡样本验收。相同物理连接失败后不会用短暂等待冒充旧流已清空。Dart使用flush+同目录rename，未声称具备跨平台目录fsync的突然断电保障。ASR/Hermes、远端上传、全天VOR和原有会议处理页的归档接线均不在本轮。

## 8. 2026-10-20：录音期间保存闭合段，停止后完整归档

### 新增的行为

- 会议和随身记录复用同一条文件同步链。收到当前真实AES连接的LONG start或含同一会话身份的活动状态后，登记活动session；用途准备完成后才开始文件操作，同一会话沿用已冻结用途。状态恢复但没有本机原始用途时仍显示未知，不套用当前默认用途。
- 当前会话的`reportLongOpsSegmentClosed(session,p)`只确认p本身，不推断所有低段。未知activePart时，仅此明确集合可读；目录大小暂稳不构成关闭证明。若已报告activePart，只选择小于它的分段；显式关闭与仍标活动的段冲突时等待后续状态，绝不读当前或更高写入段。以activePart推断低段关闭依赖顺序单活动段语义，是应用层保守策略，不冒充已恢复的官方过滤条件或固件fsync保证。
- 闭合/段号前进触发合并排队，默认250ms合并密集提示。录音期间每5秒只读查询状态、复核已知闭合候选；目录和文件下载始终串行。已有size/SHA/OPS有效段复用不重复读；来源大小变化时下载新版本，旧源保留。
- 录音中仅保存独立OPS，不合成整场、不标整场saved、不开放其播放。UI显示“已保存N个已关闭分段”和“同步已关闭分段”；活动段不计作完整归档。文件页不必一直打开，但仍受iOS应用实际运行/蓝牙调度限制，不承诺被杀进程后持续同步。
- 收到匹配stop（或同session明确停止状态）后，先完成在途闭合段的接收/提交，再排队补扫尾段。沿用第7节的连续性、尾段锚点、多轮目录、size/SHA/OPS、Ogg及实际解码检查，全部通过且归档落盘才显示“已保存到手机”。不删除卡片原录音。
- 断连、新会话、未知身份或段号回退撤销本次闭合依据；已提交文件保留，须新连接真实AES及当前状态才能继续。迟到活动状态不能复活本连接已停止的同一session；旧的状态查询完成也不能修改新连接的查询互斥。超时/污染仍锁通道至新物理连接，不盲目换段重试。

### 官方依据与未知

REA复用既有原APK及恢复DEX分析副本，新增记录见`tools/ble_audit/long-recording-live-20261020/findings.md`及同目录`evidence-index.json`。`requestLatestFileList$default`（ev_3ee23f4260af671512d17722b98f1b825eda96238c17469d702ab777e85f5e43）与`onTransferComplete`（ev_890c9a88ba507f2313e87e17b0c7a9ccfd1876aa7285649ad1929ae78b843d35）有体，支持stop目录请求在当前下载后排队、提交后先恢复目录。`ensureSession`保留activePart参数名，但内部协程更新策略、`onSegmentClosed`完整方法体及固件目录是否排除活动段仍未知；未声称完整恢复官方源码。

### 本地验证

- Flutter最终全量411项通过。相对前轮373项，新增31项控制器、4项真实AES/GATT驱动及3项Widget。修复了“stop早于用途准备完成导致用途为空/提前归档”和“旧连接失败回调暂停新连接自动队列”两类已复现异步竞态；无放宽鉴权或密钥保护。
- 驱动回归验证两用途start→闭合段→stop→补尾归档、活动状态恢复、迟到状态/开始忽略、未知/不同会话隔离、只写2B30且withoutResponse。专项含停止时在途下载、重复闭合、activePart前进/回退/矛盾、断连/进程恢复、大小变化保留旧段、超时隔离、销毁停止命令、状态轮询互斥及连接代隔离。
- 12项长录页面Widget覆盖会议/随身活动状态及停止尾扫；360×640和390×844截图已查看。全量分析退出0，无error/warning，仅11条既有弃用info；原生同源CoreAudio11项通过，pbxproj检查及diff空白检查通过。

真实AES、旧业务密钥、HAL接口、PhoneMic、依赖与私有端点保持；没有解绑、清卡、删除原录音、访问真实账号或调用ASR/Hermes。版本仍1.0.25+26，本轮不打包推送。没有实卡边录边传抓包或iPhone SDK编译/扬声器验收，实际分段滚动、停止尾段延时、后台功耗/保持和固件编码仍需后续实卡测试；本地模拟与Mac同源CoreAudio测试不替代这些验收。

# 私有资料归档与引用查询 · Hermes 2.2.0 / App 1.0.33+34

本目录新增 `archive_runtime` 及 Hermes 原生插件：资料接收挂入 Hermes 已有 HTTP 服务，查询工具只读同一资料库。与既有五技能安装入口分开准备，默认安装技能不会启用插件或启动服务。与App 1.0.33+34配套发布；完整安装与手机验收顺序见README.md。服务器尚未代为部署。

## 一个 Hermes 入口，两种请求

- 对话仍使用 `https://你的节点/v1/chat/completions`，由 Hermes 原生接口运行工具及生成回复。
- 同步使用同一个私有入口的 `https://你的节点/sunmate/v1`，由 SunMate 插件校验、落盘、返回回执；不会为每条通知运行模型。
- 插件通过 `register_platform_handler("api_server", factory)` 在原生 aiohttp 路由冻结前挂载三个固定端点。没有新监听端口、新守护进程、对话代理或核心源码补丁。SQLite 归档及独立客户端凭据保留，文件操作放到工作线程，不占用对话事件循环。
- 同步凭据只允许资料写入/回执，不能当作 Hermes 对话 Token；原生对话 Token 也不能当作同步凭据。复用地址不会合并权限。
- 只为插件注册时选中的固定 profile 挂载 `/sunmate/v1`，**不添加 `/p/{profile}/sunmate/v1` 跨 profile 路由**。请求执行的Hermes运行时profile必须与挂载时一致，否则拒绝；只读工具通过Hermes的`get_hermes_home()`解析当前profile（支持不修改环境变量的运行时作用域）。使用多个 profile 时各自安装/启用，并核对该进程实际服务的资料库；不从请求、URL 参数或适配器私有属性选择磁盘路径。原有地址、serverId/libraryId、队列和数据库格式不变，无迁移操作。

已只读核对用户此前报告的上游 [562ee8ab 插件注册接口](https://github.com/NousResearch/hermes-agent/blob/562ee8ab/hermes_cli/plugins.py) 以及 [API 服务接线](https://github.com/NousResearch/hermes-agent/blob/562ee8ab/gateway/platforms/api_server.py)。这不代表远端带本地改动的 Hermes 已完成运行验证；最新网页文档也不能代替目标主机源码检查。若宿主没有注册入口，保留只读工具并提示原生接收不可用，绝不自动另开服务；若宿主有入口但 adapter 未调用工厂，能力探测失败，不报告已启用。

## 处理方式

- 会议：已关闭分段安全保存后，按原有自动 ASR 开关调用私有 MOSS；停止并补齐尾段、完成转写后，按原有自动纪要开关请求 Hermes。新增的会议同步开关负责会话状态及完成的转写，结果同步开关负责正式纪要。
- 随身记录：逐段调用私有 ASR（可选），携带会话、分段相对时间、估算/未知时间标记归档。复盘仍手动选范围，使用已转写段与允许通知。
- 通知：只归档采集允许的来源。同步不调用模型；通知简报仍手动选择今天、上次总结后或自定义范围。
- 开关默认关闭，只针对开启后的新增或更新资料。手动生成报告授权补传所选来源；自动会议纪要在会议同步关闭时只读取已有归档，若从未归档则沿用已开启的直接文字总结，不隐式写入归档库。历史资料按类别和31天以内范围预览确认补传。归档失败不自动触发 ASR，不删除源文件。
- 首期仅归档文字及显式允许的元数据，**不上传音频二进制**。ASR 初次处理仍需音频；归档转写后再次总结或问答只需资料引用。

## 安装时的显式准备

以下命令由你在目标服务器执行，本次没有代为部署。

```bash
# 指向实际选用的 Hermes profile 目录；不要把示例路径直接当作你的目录。
python3 prepare_archive.py --hermes-home /path/to/chosen/profile --initialize-archive
```

准备脚本只复制插件代码到指定 profile 的 `plugins/sunmate_archive/`，初始化私有 `sunmate-archive/`；已有插件或非空资料库会拒绝覆盖。初始化生成新的独立客户端凭据文件 `client-token.txt`，权限0600，凭据不打印、不写入模型消息。不要用录音卡共享密钥或 Hermes API Key 代替。

实际部署时，需要在正确 profile 显式启用插件并由操作者安排 Hermes 重载；本次未执行。复用原生 API 已有监听与生命周期，确认私有 HTTPS /受保护私网入口同时允许 `/v1` 和 `/sunmate/v1`，不要把原生对话 Token 强制作为同步路径的反向代理认证条件。凭据仍在插件内独立校验，不关闭鉴权。已有访问日志不应记录正文或认证头。

以下仅为隔离回归/诊断保留的显式回环服务，正常原生插件模式不需要运行：

```bash
python3 -m archive_runtime.service --root /path/to/chosen/profile/sunmate-archive --port 8765
```

诊断服务监听地址固定 `127.0.0.1`，不作为缺少宿主接口时的自动回退。它与原生适配器复用完全相同的鉴权、协议及数据库提交逻辑。没有配置 systemd/launchd、不修改 gateway、不自动重启。

Hermes 插件需在正确 profile 中另行显式启用，并分别确认 `/sunmate/v1/capabilities` 与 `sunmate_search/get/stats/sync_status` 实际可用；接收成功不等于模型已正确使用工具。实现使用 `register(ctx)` / `ctx.register_tool` / `ctx.register_platform_handler`；本地做了真实 aiohttp 路由、注册契约和隔离测试，尚未在用户实际 Hermes 版本中加载，不能把本地测试当部署验收。企微与 App 只有进入同一授权 profile 才查询同一资料库。

手机进入「设置 → 私有资料同步」，输入私有入口 `/sunmate/v1` 和独立同步凭据，核对 profile / libraryId 后确认连接，再按类别开启自动同步。地址、凭据保存在单独的安全存储条目，不触及既有端点或卡片密钥。切换服务会关闭自动开关，旧队列保留在原目标下，不转发给新库。

## 协议与故障恢复

`sunmate.archive.v1`：认证 `GET /sunmate/v1/capabilities` 返回 serverId、libraryId、profile、clientId；写入和查询回执必须携带绑定身份头。Token 的哈希绑定固定客户端，客户端不能在请求里指定别人的身份。

资料包含稳定 id、单调 revision、kind、含时区 timestamp、payload、visible、sha。SHA256 对 id/kind/timestamp/payload/visible 的递归键排序、UTF-8紧凑JSON计算；时间段使用整数毫秒，不使用浮点时间。相同revision内容变化是冲突；旧revision不能替换新版本，历史版本保留。

- `POST /ingest`：每批最多50条、请求最多2MiB；事务提交后逐条返回 accepted/already_present/invalid/conflict。
- `POST /receipts`：仅查询当前认证客户端的 id/revision/sha。手机先查回执，只有 missing 才发送正文。已确认的引用请求也核对服务器回执，可补齐服务器恢复旧备份后缺少的版本。
- 手机原子保存源资料后，启动/回前台/周期对账补齐入队空档。队列及确认落盘，未知回执重查而非换ID重传；断网退避，认证和身份不符暂停；无效/冲突版本单独隔离，其他记录可继续，不把HTTP200当作逐条成功。
- 自动处理在前台每20秒对账；不承诺 iOS 强杀后持续联网。回到前台继续。关闭自动开关暂停该类自动队列，显式范围补传/总结仍是用户授权的单次处理。
- 停用来源/隐藏记录后生成新可见性版本；服务器默认查询及旧版本精确读取均检查当前可见性。离线时撤回尚未送达，页面明确说明，不承诺立即撤回。归档内容不自动删除。
- 当前客户端向同一资料库按记录单调写入，手机本地队列应与凭据一起保留。换新手机应使用独立客户端凭据，不能拷贝旧客户端Token后从revision=1重新写入。同一手机跨目标队列隔离。管理员可显式运行 `python3 -m archive_runtime.service --root CHOSEN_ROOT --add-client` 生成另一独立客户端文件；`--revoke-client CLIENT_ID` 撤销该客户端，保留原资料及配置备份，服务下一请求立即重新检查授权。

## 引用处理与问答

已配置归档的 App 总结请求使用 `sunmate.reference.v1`，只发送 libraryId/profile/clientId、精确id/sha、范围和用途，不附原始正文。不完整引用先补传；失败保留任务并显示原因，不自动降级成重发全文。未配置归档时保留旧的手动文本请求兼容。

Hermes 必须逐一用 `sunmate_get` 读取引用，并按nextTextOffset/nextSpanOffset/nextSourceOffset翻页至全部为空、核对 libraryId，返回 JSON `status=complete, libraryId, used=[id/sha], text`。App 检查库、全部来源引用和非空结果后才保存。这是应用层契约，不能替代真实模型执行工具的后续验收。失败、缺工具、读取不全不作为有效总结保存。

大范围引用每批最多12个来源，8个局部结果以内逐级合并；中间整理不作为正式结果归档。总结保存时固定来源版本，后续源数据变化时标为source_changed，旧版缺版本证据标为legacy_versions_unknown。

普通对讲只附资料库身份和查询指引，不附手机数据库；Hermes 通过只读工具按时间/应用/会话/关键词检索。正文可能含恶意指令，始终只视为资料。只查询服务器已归档资料，不声称覆盖手机未同步/未转写内容；归档和长期记忆写入分开。

## 备份、容量和运维边界

SQLite使用事务与WAL，代码提供 `Archive.backup(new_path)` 的一致性备份，不覆盖已有备份。恢复到全新位置时须同时恢复库身份配置、客户端绑定及数据库；只有换成新资料库才生成新 libraryId。不要只复制正在写入的SQLite主文件。

默认归档数据库容量上限512MiB（配置maxDatabaseBytes可显式调整）。容量达到上限或磁盘已满返回507，其他写入失败返回503，手机保留队列等待恢复空间；没有自动清理音频/历史资料的任务。配置文件0600、数据库0600、目录0700，备份也应留在受控目录。生产部署前仍需确定HTTPS入口、容量、备份位置、宿主插件兼容和原生gateway重载时间；这些不在本次本地执行范围。

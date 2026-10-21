# SunMate × Hermes 2.2.0

适配 **SunMate App 1.0.33+34**。本包包含五个技能、私有资料接收和只读查询插件；通知、会议/随身转写及正式总结可按开关归档，之后直接问答时按资料引用读取。同步复用 Hermes 原生 HTTP 服务，不接官方 Relay，不新建守护进程，不改录音卡鉴权或密钥。2.0/2.1旧包保留。

## 离线安装：先安装，再由你启用

将 `sunmate-hermes-2.2.0.zip` 和 `SHA256SUMS-2.2.0` 放在 Hermes 所在电脑的同一目录。校验文件同时列出ZIP和tar.gz；只下载ZIP时校验对应一行：

```bash
# macOS；Linux 可将 shasum -a 256 -c 换成 sha256sum -c
grep 'sunmate-hermes-2.2.0.zip$' SHA256SUMS-2.2.0 | shasum -a 256 -c
unzip sunmate-hermes-2.2.0.zip
cd sunmate-hermes
```

以下以default profile为例。若App和企微使用另一个profile，改为其实际配置目录；所有步骤必须选择同一个profile，不要把资料库装到另一个智能体。

```bash
# 1. 只安装/升级技能，不请求模型、不重启。
bash setup_hermes.sh --hermes-home "$HOME/.hermes" --skills-only

# 2. 首次安装资料插件并初始化独立资料库/同步凭据。
python3 prepare_archive.py --hermes-home "$HOME/.hermes" --initialize-archive

# 3. 由你显式启用插件；不授权覆盖Hermes内置工具。
HERMES_HOME="$HOME/.hermes" hermes plugins enable sunmate-archive --no-allow-tool-override
HERMES_HOME="$HOME/.hermes" hermes plugins list

# 4. 由你安排原生gateway重启。短暂中断现有会话，不改密钥或卡片。
HERMES_HOME="$HOME/.hermes" hermes gateway restart

# 5. 核对已有原生对话接口及完整SSE；会发两次合成回显请求。
bash setup_hermes.sh --hermes-home "$HOME/.hermes" --check --check-stream
```

**保留已有资料：** 如果 `sunmate-archive/config.json` 已存在，第二步去掉 `--initialize-archive`，保留同一库身份和凭据。若 `plugins/sunmate_archive` 已存在，准备脚本会停止，绝不覆盖：先检查来源和用户修改，将整个旧插件目录移到该profile的 `sunmate-backups/` 下独立目录后再准备；不要移动/清空 `sunmate-archive/`、不要删除Token或数据库。未经管理的目录和用户改动不会被静默接管。技能如有用户改动也会停止；明确保留备份后才使用 `--replace-modified`。

插件启用与接收成功分开验证。实际宿主需要支持 `register_platform_handler("api_server", factory)`，本地已核对上游562ee8ab；没有该能力不会另开服务代替。确认当前profile工具集包含 `sunmate_archive` 的 `sunmate_search/get/stats/sync_status`；若该profile限制了工具集，请在Hermes正常工具设置中启用。现有私有HTTPS/隧道入口应同时转发 `/v1` 和 `/sunmate/v1`。本包不自动改反向代理、防火墙、Hermes核心配置或实际服务器设置；具体协议与恢复见 [ARCHIVE.md](ARCHIVE.md)。

## 手机配置与三类资料验收

1. 按此前自签方式覆盖安装App **1.0.33+34**，保持相同签名身份；不要先卸载。保留卡片绑定、旧密钥和原录音。ASR/Hermes节点保持现有值。
2. 打开「设置 → 私有资料同步」。地址填同一Hermes私有入口下的 `/sunmate/v1`，例如对话为 `https://你的节点/v1`，同步为 `https://你的节点/sunmate/v1`。多profile原生复用路径不能自行改成 `/p/其它profile/sunmate/v1`；本包只挂载选中profile的固定接收路由。
3. 在服务器本机安全查看对应profile的 `sunmate-archive/client-token.txt`，填入独立同步凭据；不要发到聊天。该Token与Hermes对话Token、卡片共享密钥分开。点击「核对并保存连接」，核对profile及资料库身份。未初始化的库或路径未转发时不会显示成功。
4. 四类自动同步默认关闭，按需开启「允许采集的通知」「会议资料与转写」「随身记录与转写」「纪要、简报与复盘结果」。开启后处理新增/更新资料；历史资料选范围预览补传。同步不触发ASR，自动转写/会议自动纪要仍由原有独立开关控制。
5. **通知：** 发送一条无隐私测试通知，确认App收件及同步回执已确认，再在AI对讲问「刚才的测试通知说了什么？」。不需要先生成通知简报；智能体应调用查询工具并说明来源/时间。
6. **转写：** 会议或随身长录停止后确认音频已归档，在App完成ASR或启用相应用途自动ASR，等待转写同步确认；问「刚才这场会议提到了哪些安排？」。未转写的原音频不在本期服务器归档内。
7. **总结：** 生成会议纪要、通知简报或随身复盘，等待结果同步确认，再问对应结论及来源；已归档版本仅按引用读取，不重复发送正文。提问不自动补读手机尚未同步的数据库。服务器恢复旧备份导致版本缺失时，App可核对回执后补传缺项。

同一授权profile的企微与App可查询同一资料库；其他profile不默认共享。对话回显、同步回执、模型实际调用工具是三项不同验收。本包不承诺仅凭安装即可完成实机验收，失败时保留源资料和待发队列，不解绑、不删除录音。

## 线上安装入口（同版发布后使用）

先下载并检查入口，再执行。入口会把 main 固定到一个 commit，将完整资源下载到临时目录，逐文件核对 SHA-256 后才安装：

```bash
task_dir="$(mktemp -d)"
curl --fail --show-error --location --retry 3 --connect-timeout 15 --max-time 60 \
  https://raw.githubusercontent.com/lrocky01/sunmate/main/sunmate-hermes/setup_hermes.sh \
  --output "$task_dir/setup_hermes.sh"
bash -n "$task_dir/setup_hermes.sh"
# 检查下载的脚本内容后运行：
bash "$task_dir/setup_hermes.sh"
```

原有管道入口仍兼容，入口不再依赖终端当前目录下的 skills 文件：

```bash
curl -fsSL https://raw.githubusercontent.com/lrocky01/sunmate/main/sunmate-hermes/setup_hermes.sh | bash
```

管道下载本身若中断，后续完整性校验不能修复已经截断的 shell 输入，因此优先使用上面的下载后执行方式。SHA-256 用于检测资源损坏/混合版本；清单与代码来自同一仓库，并非独立签名。复现某个版本时可设置 `SUNMATE_REF` 为完整 commit SHA。

## 前置条件与边界

- `hermes --version` 可运行，目标 profile 已完成自身初始化。
- 常规模式需要目标 Hermes 原生 API 已启用且已配置有效 `API_SERVER_KEY`。未启用时退出并提示，不擅自修改 `.env` 或核心配置。
- 原生 API 的配置、TLS 和服务管理以 [Hermes 官方 API 文档](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server) 为准。监听地址和端口从目标配置与环境变量读取；只有缺省时使用 Hermes 官方默认值。
- Token 必须是 Hermes **API 服务端密钥**，不是模型提供商 API Key。安装器只在内存中读取，不打印、不另存。
- 配置支持 `gateway.api_server` 与 `gateway.platforms.api_server`（含 `extra`），以及 `API_SERVER_*` 环境变量。当前进程环境优先于所选 profile `.env`。`.env` 仅解析字面量，绝不作为 shell 执行。
- 若启动 Python 没有 PyYAML，尝试借用 `hermes` 启动脚本实际指向的已有 Python 解析 YAML。仍不可用时，用 `SUNMATE_PYTHON` 指定已有 Hermes Python，不自动执行 pip。
- 多 profile 可用 `--profile NAME` / `--hermes-profile NAME`；尊重显式 `HERMES_HOME` 与已确认的 `active_profile`。存在多个 profile 且没有明确选择时退出。
- 不自动重启运行中的智能体。需要重载时显式使用 `--restart-native`，调用目标配置目录下的 Hermes 官方 `gateway restart`。不创建另一套 launchd/systemd 服务；守护由 Hermes 自己管理。

```bash
bash sunmate-hermes/setup_hermes.sh --profile work
bash sunmate-hermes/setup_hermes.sh --profile work --restart-native
bash sunmate-hermes/setup_hermes.sh --skills-only
bash sunmate-hermes/setup_hermes.sh --check
bash sunmate-hermes/setup_hermes.sh --app-url https://your-domain.example/v1
```

`--skills-only` 只报告文件安装，不宣称 API 可用。`--check` 不安装、不重启，也不检测技能发现；会发一次真实模型自检请求，可能产生少量费用。常规安装同样自检，并尝试技能发现：错误/缺失 Token 必须被拒绝；正确 Token 必须取得模型列表和带随机校验文本的成功推理回复。HTTP 200、进程存活、两次回复不同都不单独作为验收依据。

`--check-stream` 需要与连接检查或常规安装配合，不能与 `--skills-only` 同用；额外验证 `text/event-stream`、完整内容帧、正常stop及[DONE]。普通检查与SSE均不自动重试。它不验证天气工具是否真的执行；工具业务、手机端、持久归档要分别报告未测试，不能由文本回显推断。自检使用模型发现列表中的模型；若与App默认请求的 `hermes-agent` 不同，需在真实App测试中确认该标识可用。

默认推理超时 180 秒，可用 `--timeout` 调整。推理失败不自动重试，避免重复业务执行。安装器检查成功不证明实际记忆已写入、ASR 就绪或手机网络可达。新版本支持 `/v1/skills` 时，另查五个技能是否被发现；旧版缺少该接口时明确标为未验证。

## 手机访问

服务器回环地址不能直接填入手机。配置 TLS 反代或安全隧道后，使用 `--app-url` 检查手机将使用的完整 HTTPS 地址。多 profile 复用监听时保留真实 `/p/<profile>/v1` 前缀，使用该 profile 的密钥，不猜测路由。

`--base-url` 可覆盖本机自检地址，必须以 `/v1` 结尾；非回环 HTTP 地址被拒绝，避免明文传输密钥。带 Token 的请求禁止跟随重定向，避免密钥被带到其他主机。代理设置不会自动应用到自检请求。

输出只提供已验证地址和模型标识。请在本机安全查看目标 profile 的 `API_SERVER_KEY` 并填入 App，不让智能体将密钥复制到对话。手机仍需自行点击测试连接。

## 升级与旧安装迁移

- 同内容重复执行不写入、不产生新备份。
- 本安装器管理的旧版本整体备份到 Hermes 配置目录的 `sunmate-backups/`，位于 skills 扫描范围外。
- 用户修改过的文件默认拒绝覆盖。确认保留备份并升级时使用 `--replace-modified`。
- 没有 `.sunmate-managed` 标记的目录不接管。
- 旧脚本在 skills 根目录安装的同名技能可能遮蔽新版本。安装器列出冲突并退出，请先人工移到 skills 之外备份；不会自动删除。
- 旧模拟网关不再分发。若曾部署，须自行确认该进程身份后停止，并改用已验证原生 API。安装器不杀端口占用进程，不移除用户服务。

## 数据与 Skills

五个 Skills 都自带 `references/data-contract.md`。第一版数据随请求发送，不要求手机和服务器共享文件路径。服务器文件归档仅在已经完成上传并返回可验证引用时使用，不把聊天成功等同归档成功。

Skills 会报告缺失来源、未识别说话人和不可计算指标；长报告不整体写进长期记忆。安装 Skills 只是能力说明，App 仍需按契约发送数据；App 的流式解析、会话标识及历史版本的成功兜底需单独修复，不能靠安装脚本改变。

三类“生成报告”默认只分析并返回内容，不自动写长期记忆。若将来需要Hermes跨端检索所有通知和录音转写，需另行设计用户可控同步、按ID去重的归档和真实回执；本包没有后台同步端口、数据库或手机拉取接口。

## 官方安装入口的参考范围

只读检查了 [YoooClaw 官方安装脚本](https://artifact.yoooclaw.com/hermes-plugin/install.sh)。参考它对目标profile、安装完成/激活成功的区分，以及诊断分层；官方脚本还安装平台插件、配置其Relay接入并可重启gateway。SunMate继续采用已有Hermes原生API和私有端点，不引入该Relay、官方账号凭据或自动重启策略；未执行官方脚本。

## 离线包与开发验证

```bash
python3 sunmate-hermes/package_release.py
python3 -m unittest discover -s sunmate-hermes/tests -v
```

以上为源码仓库的开发命令。打包器更新 `manifest.json`，在 `build_output/hermes-release/` 生成按版本命名的完整 ZIP / tar.gz 及 `SHA256SUMS-版本号`，不覆盖2.0旧包。离线解压后运行其中 `setup_hermes.sh`；资源无需联网下载，真实 API 自检仍需要能连接目标 Hermes。

`tests/fixtures/current-app-requests.json` 是使用未改动App的AgentClient，通过本机HTTP回环捕获的五类合成请求（不含真实通知、音频或凭据）；测试记录请求代码摘要。App请求代码变动后应重新捕获并核对，不能只修改兼容版本声明。本地回归验证安装/协议与请求形态，不冒充真实模型的技能加载或业务效果验收。

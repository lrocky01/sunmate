# SunMate 1.0.34+35 / Hermes 2.3.0 安装与测试

本版支持会议与随身记录的已关闭分段后台接收、原生文件上传、服务器私有 ASR、完整录音自动总结和结果取回。所有新增开关默认关闭。保留真实 AES、旧密钥、HAL 和私有端点；不自动解绑、重新协商或删除卡片原录音。

## 1. 安装 App

下载 `build_output/SunMate-1.0.34+35.ipa`，按原有方式自签、覆盖安装，保持相同 Apple ID/签名身份及 Bundle ID。不要先卸载，保留现有本机资料与节点配置。打开后首页及诊断应显示 **1.0.34+35**。

IPA 是未签名构建，需要自签后安装。后台音频读写与现有本地播放均需要 iOS 13.4 或更新版本；App 最低部署版本保持不变。保持卡片现有绑定，用已验证身份普通连接；无需打开官方 App 或重新绑定。

## 2. 升级 Hermes

下载 `build_output/hermes-release/sunmate-hermes-2.3.0.zip` 及 `SHA256SUMS-2.3.0` 到 Hermes 所在电脑的一个空目录。使用其中 README 的安装顺序，先确认 App、企微和资料库属于同一个 profile。

```bash
# macOS；Linux 用 sha256sum -c 替代 shasum -a 256 -c。
grep 'sunmate-hermes-2.3.0.zip$' SHA256SUMS-2.3.0 | shasum -a 256 -c
unzip sunmate-hermes-2.3.0.zip
cd sunmate-hermes
bash setup_hermes.sh --hermes-home "$HOME/.hermes" --skills-only
```

已有 2.2.0 资料插件：安排维护窗口，备份配置与数据库，按 README 保留旧插件代码目录，再运行 `prepare_archive.py`，**不要加 `--initialize-archive`**。原 `sunmate-archive/` 的配置、身份、同步凭据、数据库及音频目录保持原位。首次安装则按 README 初始化。不要覆盖或删除用户修改。

显式启用 `sunmate-archive` 插件后，在该 profile 原有 `sunmate-archive/config.json` 中合并下列字段，保留其它内容：

```json
{
  "audioProcessing": {
    "enabled": true,
    "asrUrl": "https://自己的私有ASR根地址",
    "asrTokenFile": "/服务器绝对路径/asr-token.txt",
    "hermesUrl": "http://127.0.0.1:当前profile端口",
    "hermesTokenFile": "/服务器绝对路径/hermes-api-token.txt",
    "ffmpeg": "/服务器绝对路径/ffmpeg"
  }
}
```

这里只显示新增字段，不能拿示例替换整份配置。ASR 需兼容 `/v1/jobs`；两个 URL 均填根地址、不带末尾 `/v1`。Token 文件由你在服务器本机安全创建，要求普通文件和 0600 权限；不发到聊天。ASR 无鉴权可省略其 Token 文件。服务器需可用 ffmpeg 和 Hermes 已有 aiohttp。

按包内 README 显式重启目标 profile gateway。现有私有代理同时透传 `/v1`、`/sunmate/v1` 及其 `/audio/` 路径，支持 PUT 和分段音频请求体，上传地址不重定向。本次发布未替你部署或修改服务器。

## 3. 开启 App 新功能

1. 「设置 → 私有资料同步」核对原资料库连接。地址为同一私有 Hermes 入口 `/sunmate/v1`；独立同步凭据继续使用现有值，与聊天 Token 和卡片密钥分开。
2. 进入「后台录音与服务器处理」，开启「后台蓝牙收段」。默认仅 Wi-Fi，蜂窝许可另选。状态恢复设置在下次正常启动生效，可正常重开一次 App 后重新确认卡片已验证。
3. 按用途开启会议或随身的「自动上传」「服务器自动转写」「自动纪要/复盘」；总结依赖 ASR，ASR 依赖上传。开关会保存；关闭上游同时关闭其依赖。
4. 随身录音需要融合通知时，另开启允许通知的自动同步。通知只在可定位时间范围内融合。
5. 所有设置完成后，再在「录音卡管理 → 录音设置」选择下次长录用途，开始新录音。设置不追溯旧录音，也不接管手机已经提交的 ASR。

## 4. 分别验收会议与随身记录

- 先测前台短录，确认音频回执、ASR 和正式总结；再测锁屏几分钟。只有关闭的硬件分段可下载，不能以刚开始几秒没音频判定失败。
- 会议：按配置的双击/三击开始，停止后等待尾段确认与完整归档，再检查整场播放、逐字稿和纪要。
- 随身：开始前切换用途，录一场新录音，可发送一条无隐私测试通知；停止后检查分段时间线、通知范围及本次复盘。
- 回到 App 会取回服务器结果，也可点「核对上传与取回结果」。然后直接向 Hermes 问已归档内容，核对引用时间及来源。

iOS 的蓝牙后台执行由系统调度，不能保证持续运行。**强制划掉 App 会中断尚未完成的系统传输，需重新打开恢复**；服务器已经收妥的任务可继续。结果在 App 回前台取回，首期没有 APNs 即时推送。

上传失败、解码失败、未知提交或缺段都保留源录音；不以 HTTP 200、开关开启或仅收到结束事件冒充完整处理成功。锁屏/强退恢复及真实私有模型效果需要安装后实测。

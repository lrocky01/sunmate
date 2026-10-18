# SunMate 1.0.18+19：补齐无共享密钥时的正常绑定分支

## 已定位的缺陷

用户最新日志已在624ms连接，约1.5秒进入Telink GATT，并在订阅设备事件时收到 verifyIdentityRequest。本机没有共享密钥，最新账号设备页也显示「账号未返回共享密钥」。SunMate原实现立即结束鉴权，并因已经见过身份挑战跳过 bindRequest；随后由App主动清理断开。本次失败不能归因于没有系统配对弹窗或固件看门狗。

官方实现的不同之处：无key的身份挑战只跳过应答；通道就绪后无key仍发送一次正常bindRequest。收到真正verifyRequest后才请求账号验机签发，继续真实公钥协商。单纯补SN不能解决两处都无key的问题，本版没有猜测广播布局或编造密钥。

## APK证据

以下为忽略目录中的本地静态证据，不包含真实账号凭据：

| 路径 | Evidence / 结论 |
| --- | --- |
| tools/ble_audit/android-live-2.2.2/rea-no-key-transport-ready.json | ev_09130de79f184cd508cc398eb6b8d021e9060dd39b28bb4bcd026608b6e22577；无key走dispatchBindRequestIfNeeded |
| tools/ble_audit/android-live-2.2.2/rea-no-key-dispatch-bind.json | ev_d7dea359dc5cbbfd39f1a755662fa207badacc3721ab8d4893e182568e2d9e77；同连接只发一次，Telink不要求猜造user_id/sign |
| tools/ble_audit/rea-20261018-transport-ready.json | ev_c71b0852e23540d894a842d0854bc55cbe9a3ce1f50a223c14fd5c47584d7a87；2.3.0同分支 |
| tools/ble_audit/android-live-2.2.2/rea-first-connect-handler.json | ev_1c8077e16e82dec6baab27073157a1475ffa1e80a74ff346d5149b5f2d82af9b；无key身份挑战skip，非立即结束连接 |
| tools/ble_audit/keylookup-20261018/ | API、ExtInfo、云同步/保存静态核对；未找到额外正常读取完整共享密钥的接口，batch状态中的sign不是sharedSecret |

静态Android证据不能证明实体iOS和服务器一定接受这次新协商，亦未证实纯本地首次绑定。没有依据认定必须申请SDK授权。

## 本版修改与验证

- 保持HAL及私有MOSS-ASR/Hermes直连，保留真实/check、X25519、/bind和AES验证，不发送假凭证或解绑/重置。
- 区分早到身份挑战与厂商验机挑战；无key且有验机会话则按官方继续单次正常绑定。已有key不重新协商，账号恢复未结束不抢跑，设备拒绝即停止。
- 鉴权等待共用120秒截止，取消可中断；不将App失败清理写成用户主动取消。
- 全量77项测试通过；新用例已先在旧实现复现失败。覆盖订阅瞬间身份挑战、慢账号恢复、取消、设备拒绝、一次绑定和重连真实AES算法。厂商签发及云保存使用测试桩，无真实短信或账号写入。
- Flutter分析无错误/警告，11条已有弃用info；首页/诊断/构建版本同步1.0.18+19。

## 手机测试

1. 保留本次iPhone已成功建立的系统配对，不再解绑或重置。退出官方App，Android蓝牙保持关闭。
2. 安装本版并核对首页1.0.18+19，登录自己的官方账号，选择同一SN设备，再扫描连接。
3. 若仍显示账号未返回共享密钥，可以继续本次正常连接。预期早到identity挑战后不立即失败，日志出现「继续正常首次绑定流程」及一次 bindRequest。
4. 接下来观察是否收到verifyRequest、真实验机结果、pairingResult及新密钥保存/账号同步；同步成功只重连一次，收到本次AES身份成功回执才显示业务已验证。
5. 连接成功后保持一分钟，再长按说话并松开，检查按键、音频及私有端点转写。失败请复制完整蓝牙诊断，不发送手机号、验证码、Token或密钥。

若卡拒绝bindRequest，保留bindError/失败日志，停止本次尝试；不因测试失败清除绑定。新协商若被接受会更新业务密钥并同步同一账号，官方App旧本地密钥后续能否正常同步仍需实测。此包交付不等于已经完成真机稳定录音验收。

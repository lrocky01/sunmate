/// 当前连接的可观察状态；账号记录、系统授权和设备鉴权不能互相替代。
class RecorderConnectionDetails {
  final bool linkConnected;
  final bool gattDiscovered;
  final bool identityVerified;
  final bool authenticationStarted;
  final bool channelsReady;
  final bool businessReady;
  final bool localIdentityLoaded;
  final int? nativeState;
  final bool? systemConnectedMatch;
  final bool? advertisementConnectable;
  final bool requiresAncs;
  final bool? ancsAuthorized;
  final String protocol;

  const RecorderConnectionDetails({
    this.linkConnected = false,
    this.gattDiscovered = false,
    this.identityVerified = false,
    this.authenticationStarted = false,
    this.channelsReady = false,
    this.businessReady = false,
    this.localIdentityLoaded = false,
    this.nativeState,
    this.systemConnectedMatch,
    this.advertisementConnectable,
    this.requiresAncs = true,
    this.ancsAuthorized,
    this.protocol = '未识别',
  });

  String get nativeStateLabel =>
      const {0: '已断开', 1: '连接中', 2: '已连接', 3: '正在断开'}[nativeState] ?? '尚无系统状态';
}

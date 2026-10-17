import 'dart:convert';
import 'dart:typed_data';
import 'ble_tlv_packet.dart';

/// 录音卡 JSON-RPC 2.0 应用层指令编解码器
class BleJsonRpc {
  static int _requestId = 1;

  /// 构造 JSON-RPC 文本为 TLV 报文
  static Uint8List buildRequest(int type, String method, [Map<String, dynamic>? params]) {
    final Map<String, dynamic> rpcMap = {
      "version": "1.0.0",
      "method": method,
      "id": _requestId++,
    };
    if (params != null && params.isNotEmpty) {
      rpcMap["params"] = params;
    }
    final jsonStr = jsonEncode(rpcMap);
    final utf8Bytes = utf8.encode(jsonStr);
    return BleTlvPacket(type: type, value: Uint8List.fromList(utf8Bytes)).toBytes();
  }

  /// 快速构造各类具体业务指令

  // 1. 获取设备能力
  static Uint8List getCapabilities() => buildRequest(0x0001, "getCapabilities");

  // 2. 获取设备当前状态 (电量, 存储, 是否在录音)
  static Uint8List getStatus() => buildRequest(0x0002, "getStatus");

  // 2.1 获取用户设置 (指示灯与按键模式)
  static Uint8List getUserSettings() => buildRequest(0x0002, "getUserSettings");

  // 3. 开始录音 (携带时间戳与可选录音场景)
  static Uint8List startRecord({String? scene}) {
    return buildRequest(0x0010, "startRecord", {
      "timestamp": DateTime.now().millisecondsSinceEpoch ~/ 1000,
      if (scene != null) "scene": scene,
    });
  }

  // 4. 停止录音
  static Uint8List stopRecord() => buildRequest(0x0011, "stopRecord");

  // 5. 暂停录音
  static Uint8List pauseRecord() => buildRequest(0x0012, "pauseRecord");

  // 6. 恢复录音
  static Uint8List resumeRecord() => buildRequest(0x0013, "resumeRecord");

  // 7. 同步 RTC 时钟 (秒级 Unix 时间戳)
  static Uint8List syncTime([int? timestampSec]) {
    final sec = timestampSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final buffer = ByteData(4)..setUint32(0, sec, Endian.little);
    return BleTlvPacket(type: 0x0005, value: buffer.buffer.asUint8List()).toBytes();
  }

  // 8. 麦克风增益配置 (0~48dB)
  static Uint8List setGain(int gain0, int gain1) {
    final buffer = Uint8List(2)
      ..[0] = gain0.clamp(0, 48)
      ..[1] = gain1.clamp(0, 48);
    return BleTlvPacket(type: 0x0008, value: buffer).toBytes();
  }

  // 9. 硬件关机
  static Uint8List powerOff() => buildRequest(0x00FF, "powerOff");

  // 10. 配置 iOS ANCS 系统通知同步模式
  // mode: 0=禁用, 1=仅灯效, 2=仅上传通知, 3=上传通知并灯效
  static Uint8List setAncsConfig({
    required bool enable,
    int mode = 3,
    bool upload = true,
    bool light = true,
    List<String>? appFilter,
  }) {
    return buildRequest(0x0020, "setAncsConfig", {
      "enable": enable,
      "mode": mode,
      "upload": upload,
      "light": light,
      if (appFilter != null) "apps": appFilter,
    });
  }

  // 11. 设备首次配对绑定请求 (对齐官方 bindRequest)
  // confirm_code: 6位配对码
  // sign: 8位十六进制校验签名
  // user_id: 19位本地用户唯一ID
  static Uint8List bindRequest({
    String confirmCode = "123456",
    String sign = "a1b2c3d4",
    String userId = "1000000000000000001",
  }) {
    return buildRequest(0x0003, "bindRequest", {
      "confirm_code": confirmCode,
      "sign": sign,
      "user_id": userId,
      "timestamp": DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }

  // 12. 设备二次连接身份认证 (对齐官方 verifyIdentity)
  static Uint8List verifyIdentity({
    String token = "sunmate_auth",
    String? sharedSecret,
  }) {
    return buildRequest(0x0004, "verifyIdentity", {
      "token": token,
      "timestamp": DateTime.now().millisecondsSinceEpoch ~/ 1000,
      if (sharedSecret != null) "shared_secret": sharedSecret,
    });
  }

  // 13. 指示灯控制 (对齐官方 lightCtrl，让硬件从广播快闪切换为连接就绪常亮)
  // mode: 4 = 配对连接成功常亮/就绪, 0 = 熄灭, 1 = 白灯, 2 = 录音红灯
  static Uint8List lightCtrl({int mode = 4, bool success = true}) {
    return buildRequest(0x0006, "lightCtrl", {
      "mode": mode,
      "success": success,
    });
  }

  // 14. 构造原始纯 UTF-8 JSON 字节 (用于与 TLV 双模兼容下发)
  static Uint8List buildRawJson(String method, [Map<String, dynamic>? params]) {
    final Map<String, dynamic> rpcMap = {
      "version": "1.0.0",
      "method": method,
      "id": _requestId++,
    };
    if (params != null && params.isNotEmpty) {
      rpcMap["params"] = params;
    }
    return Uint8List.fromList(utf8.encode(jsonEncode(rpcMap)));
  }
}

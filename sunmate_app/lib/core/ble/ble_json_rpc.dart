import 'dart:convert';
import 'dart:typed_data';

/// 只构建 JSON 负载；传输帧由实际识别到的 profile 编码。
class BleJsonRpc {
  static Uint8List request(String method, [Map<String, dynamic>? params]) =>
      Uint8List.fromList(utf8.encode(jsonEncode({
        'version': '1.0.0',
        'method': method,
        if (params != null) 'params': params,
      })));

  static Uint8List getCapabilities() => request('getCapabilities');
  static Uint8List getStatus() => request('getStatus', {});

  /// 官方 Telink 允许不提供 sign/user_id/confirm_code；不伪造任何凭证。
  static Uint8List bindRequest(int timestampSeconds) =>
      request('bindRequest', {'timestamp': '$timestampSeconds'});
}

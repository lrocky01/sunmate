import 'dart:convert';
import 'package:dio/dio.dart';
import 'archive_models.dart';

abstract interface class ArchiveTransport {
  Future<Map<String, dynamic>> capabilities();
  Future<List<Map<String, dynamic>>> exchange(String route,
      Map<String, dynamic> identity, List<Map<String, dynamic>> records);
}

class HttpArchiveTransport implements ArchiveTransport {
  final String url, token;
  final Dio dio;
  HttpArchiveTransport(this.url, this.token, {Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 20),
                sendTimeout: const Duration(seconds: 20)));
  Future<Map<String, dynamic>> _request(String path,
      {Map<String, dynamic>? identity, Object? data}) async {
    try {
      final response = await dio.request<String>(
          '${url.replaceAll(RegExp(r'/+$'), '')}/$path',
          data: data,
          options: Options(
              method: data == null ? 'GET' : 'POST',
              followRedirects: false,
              maxRedirects: 0,
              responseType: ResponseType.plain,
              headers: {
                'Authorization': 'Bearer $token',
                if (identity != null) ...{
                  'X-Sunmate-serverId': identity['serverId'],
                  'X-Sunmate-libraryId': identity['libraryId']
                }
              }));
      final body = response.data;
      if (response.statusCode != 200 ||
          body == null ||
          utf8.encode(body).length > 2 * 1024 * 1024)
        throw const FormatException();
      final value = jsonDecode(body);
      if (value is! Map<String, dynamic> || value['schema'] != archiveSchema)
        throw const FormatException();
      for (final key in ['serverId', 'libraryId', 'profile', 'clientId']) {
        if (value[key] is! String ||
            (value[key] as String).isEmpty ||
            identity != null && identity[key] != value[key])
          throw const FormatException();
      }
      return value;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 507)
        throw const ArchiveSyncException('归档服务空间不足，队列已保留；请扩容后重试。', pause: true);
      if (status == 401 || status == 403)
        throw const ArchiveSyncException('同步凭据已失效，请检查独立同步凭据。', pause: true);
      if (status == 409)
        throw const ArchiveSyncException('服务器资料库身份变化，请重新核对并确认连接。', pause: true);
      throw const ArchiveSyncException('归档服务暂不可达，保留队列稍后重试。');
    } on ArchiveSyncException {
      rethrow;
    } catch (_) {
      throw const ArchiveSyncException('归档协议或回执不匹配，已暂停。', pause: true);
    }
  }

  @override
  Future<Map<String, dynamic>> capabilities() => _request('capabilities');
  @override
  Future<List<Map<String, dynamic>>> exchange(String route,
      Map<String, dynamic> identity, List<Map<String, dynamic>> records) async {
    final value = await _request(route, identity: identity, data: {
      'schema': archiveSchema,
      route == 'ingest' ? 'records' : 'refs': records
    });
    final receipts = value['receipts'];
    if (receipts is! List ||
        receipts.length != records.length ||
        receipts.any((v) => v is! Map<String, dynamic>)) {
      throw const ArchiveSyncException('服务器未逐条确认归档，已暂停。', pause: true);
    }
    return receipts.cast<Map<String, dynamic>>();
  }
}

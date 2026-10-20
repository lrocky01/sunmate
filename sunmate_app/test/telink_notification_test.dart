import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ble/telink_notification.dart';

// 全部为合成通知，不读取采样正文或真实身份资料。
List<int> notificationFrame({
  int uid = 0x12345678,
  int event = 0,
  String app = 'com.tencent.xin',
  String title = '测试标题',
  String subtitle = '副标题',
  String message = 'SM-LOCAL 通知测试甲123',
  String date = '20261019T222259',
  List<int> extra = const [255, 0, 0, 255, 0, 0],
}) {
  final id = [for (var i = 0; i < 4; i++) (uid >> (8 * i)) & 255];
  final payload = <int>[event, 0, 4, 1, ...id, 0, ...id];
  final attributes = {
    0: app,
    1: title,
    2: subtitle,
    3: message,
    4: utf8.encode(message).length.toString(),
    5: date
  };
  for (final attribute in attributes.entries) {
    final value = utf8.encode(attribute.value);
    payload.addAll(
        [attribute.key, value.length & 255, value.length >> 8, ...value]);
  }
  payload.addAll(extra);
  return [
    0xaa,
    0x55,
    0x41,
    payload.length & 255,
    payload.length >> 8,
    ...payload
  ];
}

void main() {
  test('confirmed source/data layout, UTF8 byte lengths and repeated empty 255',
      () {
    final frame = TelinkNotificationFrame.decode(notificationFrame());
    expect(frame.uid, 0x12345678);
    expect(frame.eventId, 0);
    expect(frame.appIdentifier, 'com.tencent.xin');
    expect(frame.title, '测试标题');
    expect(frame.subtitle, '副标题');
    expect(frame.message, 'SM-LOCAL 通知测试甲123');
    expect(frame.timestamp, DateTime(2026, 10, 19, 22, 22, 59));
    expect(frame.toString(), isNot(contains(frame.message)));
  });

  test('UID mismatch and command mismatch reject without exposing input', () {
    for (final offset in [9, 14, 13]) {
      final bytes = notificationFrame()..[offset] ^= 1;
      expect(
          () => TelinkNotificationFrame.decode(bytes), throwsFormatException);
    }
  });

  test(
      'length, trailing bytes, incomplete TLV and duplicate known fields reject',
      () {
    final frame = notificationFrame();
    final bad = [
      frame.sublist(0, frame.length - 1),
      [...frame, 0],
      [...frame]..[3] ^= 1,
      notificationFrame(extra: [90, 2, 0, 1]),
      notificationFrame(extra: [90]),
      notificationFrame(extra: [1, 0, 0]),
      notificationFrame(app: ''),
      notificationFrame(extra: [90, 255, 255]),
      [...frame]..[20] = -1,
    ];
    for (final bytes in bad) {
      expect(
          () => TelinkNotificationFrame.decode(bytes), throwsFormatException);
    }
  });

  test('invalid UTF8 is rejected with a content-free exception', () {
    final bytes = notificationFrame();
    final messageStart = bytes.indexOf(ascii.encode('SM-LOCAL').first,
        21 + utf8.encode('com.tencent.xin').length);
    bytes[messageStart] = 255;
    try {
      TelinkNotificationFrame.decode(bytes);
      fail('must reject invalid UTF8');
    } on FormatException catch (error) {
      expect(error.toString(), 'FormatException: notification_invalid_utf8');
      expect(error.source, isNull);
    }
  });

  test('unknown nonempty attributes are skipped by byte length', () {
    expect(
        TelinkNotificationFrame.decode(
            notificationFrame(extra: [99, 2, 0, 255, 255])).title,
        '测试标题');
  });

  test('modification removal and unknown event are not new notifications', () {
    for (final id in [1, 2, 255]) {
      final frame =
          TelinkNotificationFrame.decode(notificationFrame(event: id));
      expect(frame.eventId, id);
      expect(frame.message, isEmpty);
    }
  });

  test('invalid or absent date falls back without normalized fake date', () {
    for (final date in ['', '20260230T120000', '20261019T246060', 'invalid']) {
      expect(
          TelinkNotificationFrame.decode(notificationFrame(date: date))
              .timestamp,
          isNull);
    }
  });

  test('every split after type header and multi-fragment bytewise continuation',
      () {
    final bytes = notificationFrame(message: '长通知测试' * 100);
    for (var split = 3; split < bytes.length; split++) {
      final decoder = TelinkNotificationDecoder();
      expect(decoder.accepts(bytes.sublist(0, split)), true);
      expect(decoder.feed(bytes.sublist(0, split)), isNull);
      expect(decoder.accepts(bytes.sublist(split)), true);
      expect(decoder.feed(bytes.sublist(split))!.message, '长通知测试' * 100);
    }
    final decoder = TelinkNotificationDecoder();
    decoder.feed(bytes.sublist(0, 3));
    TelinkNotificationFrame? result;
    for (final byte in bytes.skip(3)) {
      result = decoder.feed([byte]);
    }
    expect(result!.title, '测试标题');
  });

  test('expiry reset and new other event discard partial notification', () {
    final decoder = TelinkNotificationDecoder();
    final bytes = notificationFrame();
    final now = DateTime(2026, 10, 19);
    decoder.feed(bytes.sublist(0, 10), now: now);
    expect(
        () => decoder.feed(bytes.sublist(10),
            now: now.add(const Duration(seconds: 6))),
        throwsFormatException);
    expect(decoder.accepts([1]), false);
    decoder.feed(bytes.sublist(0, 10));
    expect(decoder.accepts([0xaa, 0x55, 1, 0]), false);
    expect(decoder.accepts([1]), false);
    expect(decoder.feed(bytes)!.uid, 0x12345678);
    decoder.feed(bytes.sublist(0, 10));
    decoder.reset();
    expect(decoder.accepts(bytes.sublist(10)), false);
  });

  test('oversize and malformed fragments reset decoder for next good frame',
      () {
    final decoder = TelinkNotificationDecoder();
    for (final bytes in [
      [0xaa, 0x55, 0x41, 0, 0],
      [0xaa, 0x55, 0x41, 255, 255, ...List.filled(65536, 0)],
      [0xaa, 0x55, 0x41, 255, 255, -1],
    ]) {
      expect(() => decoder.feed(bytes), throwsFormatException);
      expect(decoder.feed(notificationFrame())!.title, '测试标题');
    }
  });
}

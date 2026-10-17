import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ble/ble_constants.dart';
import 'package:sunmate_app/core/ble/ble_json_rpc.dart';
import 'package:sunmate_app/core/ble/ble_protocol.dart';

void main() {
  test('OTA-only peripheral cannot become a business profile', () {
    expect(
        RecorderProfile.identify({
          BleConstants.serviceOta: {BleConstants.charOta}
        }),
        isNull);
  });
  test('matching characteristic names in wrong service are rejected', () {
    expect(
        RecorderProfile.identify({
          BleConstants.serviceOta: {
            BleConstants.charAppCmdWrite,
            BleConstants.charDeviceEvent,
            BleConstants.charOpusAudioData,
          }
        }),
        isNull);
  });
  test('complete Telink profile selects real command and no-response mode', () {
    final profile = RecorderProfile.identify({
      BleConstants.serviceOpus: {
        BleConstants.charAppCmdWrite,
        BleConstants.charDeviceEvent,
        BleConstants.charOpusAudioData,
      },
      BleConstants.serviceOta: {BleConstants.charOta}
    })!;
    expect(profile.command, endsWith('2b30'));
    expect(profile.command, isNot(BleConstants.charOta));
    expect(profile.withoutResponse, isTrue);
  });
  test('ambiguous two-profile device is not guessed', () {
    expect(
        RecorderProfile.identify({
          BleConstants.serviceOpus: {
            BleConstants.charAppCmdWrite,
            BleConstants.charDeviceEvent,
            BleConstants.charOpusAudioData
          },
          BleConstants.serviceAiNote: {
            BleConstants.charAiNoteCommand,
            BleConstants.charAiNoteEvent,
            BleConstants.charAiNoteAudio
          },
        }),
        isNull);
  });
  test('Telink status uses the official 11 30 envelope', () {
    final frame =
        RecorderProfile.telink.encodeJson(BleJsonRpc.getStatus(), 182).single;
    expect(frame.take(2), [0x11, 0x30]);
    expect(jsonDecode(utf8.decode(frame.sublist(2))), {
      'version': '1.0.0',
      'method': 'getStatus',
      'params': {},
    });
    expect(() => RecorderProfile.telink.encodeJson(BleJsonRpc.getStatus(), 20),
        throwsStateError);
  });
  test('bind request has no fabricated sign, user, token or isIos', () {
    final request = jsonDecode(utf8.decode(BleJsonRpc.bindRequest(1234567890)));
    expect(request['params'], {'timestamp': '1234567890'});
  });
  test('AiNote multi-packet JSON reassembles UTF-8 and big-endian length', () {
    final payload = BleJsonRpc.request('reportStatus', {'label': '通知测试' * 30});
    final frames = RecorderProfile.aiNote.encodeJson(payload, 23);
    expect(frames.length, greaterThan(1));
    expect(frames.every((f) => f.length <= 23), isTrue);
    expect(frames.first.sublist(0, 4),
        [0xfc, 1, payload.length >> 8, payload.length & 255]);
    final decoder = RecorderEventDecoder(RecorderProtocol.aiNote6095);
    for (final frame in frames.take(frames.length - 1)) {
      expect(decoder.feed(frame), isNull);
    }
    expect(decoder.feed(frames.last), jsonDecode(utf8.decode(payload)));
  });
  test('orphan continuation and arbitrary text cannot become auth success', () {
    final decoder = RecorderEventDecoder(RecorderProtocol.aiNote6095);
    expect(
        decoder.feed(
            [0xfc, 0x88, ...utf8.encode('{"method":"verifyIdentityResult"}')]),
        isNull);
    final telink = RecorderEventDecoder(RecorderProtocol.telink);
    expect(
        telink.feed(utf8.encode(
            '{"method":"verifyIdentityResult","params":{"success":true}}')),
        isNull);
  });
  test('Telink fragmented event remains structural and preserves failure', () {
    final decoder = RecorderEventDecoder(RecorderProtocol.telink);
    expect(
        decoder.feed([
          0xaa,
          0x55,
          0x30,
          0,
          0,
          ...utf8.encode('{"method":"bindResult",')
        ]),
        isNull);
    expect(decoder.feed(utf8.encode('"params":{"success":false}}'))?['params'],
        {'success': false});
  });
  test('oversized event is discarded and decoder recovers on next start', () {
    final decoder = RecorderEventDecoder(RecorderProtocol.aiNote6095);
    expect(() => decoder.feed([0xfc, 1, 0, 1, 0, 0]), throwsFormatException);
    final frame = RecorderProfile.aiNote
        .encodeJson(BleJsonRpc.request('reportStatus', {}), 100)
        .single;
    expect(decoder.feed(frame)?['method'], 'reportStatus');
  });
  test('clock encodings match distinct official profiles', () {
    final now = DateTime.fromMillisecondsSinceEpoch(100123);
    expect(RecorderProfile.telink.encodeTime(now), [0x11, 0x29, 100, 0, 0, 0]);
    expect(RecorderProfile.aiNote.encodeTime(now),
        [0xe5, 0, 0, 0, 100, 0, 0, 0, 123]);
  });
  test('short Bluetooth UUIDs normalize without suffix substring matching', () {
    expect(BleConstants.normalize('180F'), BleConstants.serviceBattery);
    expect(BleConstants.isTargetDevice('', [BleConstants.serviceOpus]), isTrue);
    expect(BleConstants.isTargetDevice('unknown', [BleConstants.serviceOta]),
        isFalse);
  });
}

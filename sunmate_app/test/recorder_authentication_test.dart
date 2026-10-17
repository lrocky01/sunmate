import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunmate_app/core/ble/ble_protocol.dart';
import 'package:sunmate_app/core/ble/recorder_authentication.dart';

// RFC 7748 section 6.1 的公开向量，不是设备或用户凭证。
List<int> hex(String value) => List.generate(value.length ~/ 2,
    (i) => int.parse(value.substring(i * 2, i * 2 + 2), radix: 16));
final alicePrivate =
    hex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
final bobPublic =
    hex('de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f');
final shared =
    hex('4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742');

class MemoryKeyStore implements RecorderKeyStore {
  String? value;
  int writes = 0;
  @override
  Future<String?> read(String id, RecorderProtocol protocol) async => value;
  @override
  Future<void> write(String id, RecorderProtocol protocol, String key) async {
    value = key;
    writes++;
  }
}

void main() {
  test('X25519 agrees with published RFC 7748 vector, without HKDF', () async {
    final pair = await X25519().newKeyPairFromSeed(alicePrivate);
    expect(
        await RecorderCryptography()
            .sharedSecret(pair, base64Encode(bobPublic)),
        shared);
  });
  test('identity cipher matches independent OpenSSL AES-256-CBC vector',
      () async {
    final answer = await RecorderCryptography.answerIdentity(
        shared, base64Encode(List.generate(32, (i) => i)));
    expect(answer,
        'AWzzgd9AzLT+5DRwv3vC0DVE6lAp3218tf/EtCRcSY7+tu7AL/fYC9sVh8tjnQEh');
  });
  test('rejects invalid key sizes, low-order public key, invalid challenges',
      () async {
    expect(() => RecorderCryptography.decode32(base64Encode([1, 2])),
        throwsFormatException);
    expect(
        () => RecorderCryptography.decode32(base64Encode(List.filled(32, 0))),
        throwsFormatException);
    await expectLater(
        RecorderCryptography.answerIdentity(shared, ''), throwsFormatException);
    await expectLater(RecorderCryptography.answerIdentity(shared, '**'),
        throwsFormatException);
  });
  test(
      'Telink reconnect uses saved key, omits timestamp, requires matching phase',
      () async {
    final store = MemoryKeyStore()..value = base64Encode(shared);
    final auth = RecorderAuthentication(
        protocol: RecorderProtocol.telink,
        deviceId: 'device-one',
        store: store);
    expect(await auth.loadKey(), true);
    expect(auth.acceptIdentityResult(true), false);
    final reply = jsonDecode(utf8.decode(await auth.answerIdentity({
      'random': base64Encode([1, 2, 3])
    }, timestampSeconds: 1234)));
    expect(reply['method'], 'verifyIdentity');
    expect((reply['params'] as Map).keys, ['encrypted']);
    expect(auth.acceptIdentityResult('true'), false);
    expect(auth.acceptIdentityResult(true), false);
    expect(store.writes, 0);
  });
  test('AiNote identity includes timestamp; boolean true only after response',
      () async {
    final store = MemoryKeyStore()..value = base64Encode(shared);
    final auth = RecorderAuthentication(
        protocol: RecorderProtocol.aiNote6095,
        deviceId: 'device-two',
        store: store);
    await auth.loadKey();
    final reply = jsonDecode(utf8.decode(await auth.answerIdentity({
      'random': base64Encode([1])
    }, timestampSeconds: 1234)));
    expect(reply['params']['timestamp'], '1234');
    expect(auth.acceptIdentityResult(true), true);
    expect(auth.acceptIdentityResult(true), false);
  });
  test('no manufacturer issuer means no invented HMAC or pairing persistence',
      () async {
    final store = MemoryKeyStore();
    final auth = RecorderAuthentication(
        protocol: RecorderProtocol.telink,
        deviceId: 'device-one',
        store: store);
    expect(await auth.loadKey(), false);
    await expectLater(auth.answerManufacturer({}), throwsStateError);
    await expectLater(
        auth.acceptPairing(
            {'success': true, 'public_key': base64Encode(bobPublic)}),
        throwsStateError);
    expect(store.writes, 0);
  });
  test('legitimate issuer seam and X25519 pairing persist only validated keys',
      () async {
    final store = MemoryKeyStore();
    final auth = RecorderAuthentication(
        protocol: RecorderProtocol.telink,
        deviceId: 'device-one',
        store: store,
        verifier: ({required checkContent, required mac, required sn}) async {
          expect(checkContent, 'test-only-challenge');
          return 'test-only-issuer-result'; // Mock server, never used by production.
        });
    final response = jsonDecode(utf8.decode(await auth.answerManufacturer({
      'encrypted': 'test-only-challenge',
      'mac': 'test-device',
      'sn': 'test-serial'
    })));
    expect(response['method'], 'verifyResult');
    expect(response['params']['isIos'], isNull);
    expect(base64Decode(response['params']['public_key']), hasLength(32));
    expect(store.writes, 0);
    await expectLater(
        auth.acceptPairing({
          'success': true,
          'public_key': base64Encode([1, 2])
        }),
        throwsFormatException);
    expect(store.writes, 0);
    await auth.acceptPairing(
        {'success': true, 'public_key': base64Encode(bobPublic)});
    expect(store.writes, 1);
    expect(RecorderCryptography.decode32(store.value!), hasLength(32));
    expect(auth.acceptIdentityResult(true), false);
    expect(auth.state, RecorderAuthenticationState.keyNegotiated);
  });
  test(
      'corrupt stored Base64 is rejected without putting key content in errors',
      () async {
    const corrupt = 'do-not-expose-this-corrupt-key!';
    final auth = RecorderAuthentication(
        protocol: RecorderProtocol.telink,
        deviceId: 'device-one',
        store: MemoryKeyStore()..value = corrupt);
    try {
      await auth.loadKey();
      fail('must reject malformed key');
    } on FormatException catch (error) {
      expect(error.toString(), isNot(contains(corrupt)));
    }
  });
  test(
      'cancel during manufacturer request cannot emit a late authentication packet',
      () async {
    final pending = Completer<String>();
    final auth = RecorderAuthentication(
        protocol: RecorderProtocol.telink,
        deviceId: 'device-one',
        store: MemoryKeyStore(),
        verifier: ({required checkContent, required mac, required sn}) =>
            pending.future);
    final reply = auth.answerManufacturer({
      'encrypted': 'test-only-challenge',
      'mac': 'test-only-device',
      'sn': 'test-only-serial'
    });
    auth.cancel();
    pending.complete('test-only-issuer-result');
    await expectLater(reply, throwsStateError);
  });
}

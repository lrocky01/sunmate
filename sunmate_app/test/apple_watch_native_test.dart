import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native offline store preserves samples and durable receipts', () async {
    final dir = await Directory.systemTemp.createTemp('sunmate-watch-native-');
    try {
      final executable = '${dir.path}/watch-core';
      final compile = await Process.run('swiftc', [
        '-swift-version',
        '5',
        'apple_watch/Shared/WatchRecordingStore.swift',
        'test/native_watch/main.swift',
        '-o',
        executable
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      final result = await Process.run(executable, ['${dir.path}/recordings']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(jsonDecode(result.stdout as String),
          {'checks': 60, 'purposes': 3, 'realWavDecode': true});
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(minutes: 2)));
}

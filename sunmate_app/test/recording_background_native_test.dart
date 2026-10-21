import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'native receiver with synthetic transport: fragmented status, closed parts, early completion, tail, journal and CoreAudio playback',
      () async {
    final sandbox =
        await Directory.systemTemp.createTemp('sm-background-native-');
    addTearDown(() => sandbox.delete(recursive: true));
    final module = await Process.run('swiftc', [
      '-swift-version',
      '5',
      '-emit-module',
      '-emit-library',
      '-module-name',
      'CoreBluetooth',
      'test/native_background/CoreBluetooth.swift',
      '-emit-module-path',
      '${sandbox.path}/CoreBluetooth.swiftmodule',
      '-o',
      '${sandbox.path}/libCoreBluetooth.dylib'
    ]);
    expect(module.exitCode, 0, reason: '${module.stderr}');
    final exe = '${sandbox.path}/receive';
    final compile = await Process.run('swiftc', [
      '-swift-version',
      '5',
      '-I',
      sandbox.path,
      '-L',
      sandbox.path,
      '-lCoreBluetooth',
      '-Xlinker',
      '-rpath',
      '-Xlinker',
      sandbox.path,
      'ios/Runner/RecorderBackgroundFiles.swift',
      'ios/Runner/RecorderBackgroundTransfer.swift',
      'ios/Runner/RecorderBackgroundReceiver.swift',
      'ios/Runner/RecorderLocalAudio.swift',
      'test/native_background/main.swift',
      '-o',
      exe
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stderr}');
    for (final scenario in ['normal', 'bad-size']) {
      final dir = await Directory('${sandbox.path}/$scenario').create();
      final run = await Process.run(exe, [dir.path, scenario]);
      expect(run.exitCode, 0, reason: '$scenario: ${run.stderr}');
      final result = jsonDecode(run.stdout as String);
      expect(result['clean'], scenario == 'normal');
      expect(result['sources'], scenario == 'normal' ? 2 : 0);
    }
  },
      skip: !Platform.isMacOS
          ? '需 macOS Swift/CoreAudio；合成传输不代表 iPhone 后台验收'
          : false,
      timeout: const Timeout(Duration(minutes: 2)));
}

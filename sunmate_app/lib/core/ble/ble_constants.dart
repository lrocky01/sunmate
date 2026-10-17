/// UUID 来自官方 APK 的 TelinkDeviceProfile / AiNote6095Profile。
class BleConstants {
  static const serviceOpus = '00010203-0405-0607-0809-0a0b0c0d1930';
  static const charAppCmdWrite = '00010203-0405-0607-0809-0a0b0c0d2b30';
  static const charDeviceEvent = '00010203-0405-0607-0809-0a0b0c0d2b31';
  static const charOpusAudioData = '00010203-0405-0607-0809-0a0b0c0d2b32';
  static const charFileData = '00010203-0405-0607-0809-0a0b0c0d2b33';
  static const serviceOta = '00010203-0405-0607-0809-0a0b0c0d1913';
  static const charOta = '00010203-0405-0607-0809-0a0b0c0d2b15';
  static const serviceAiNote = 'e2c1a300-7f4b-5e9d-bc23-1a2f3e4d5c6b';
  static const charAiNoteCommand = 'e2c1a302-7f4b-5e9d-bc23-1a2f3e4d5c6b';
  static const charAiNoteEvent = 'e2c1a303-7f4b-5e9d-bc23-1a2f3e4d5c6b';
  static const charAiNoteAudio = 'e2c1a301-7f4b-5e9d-bc23-1a2f3e4d5c6b';
  static const serviceBattery = '0000180f-0000-1000-8000-00805f9b34fb';
  static const charBatteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';

  static String normalize(String uuid) {
    final value = uuid.toLowerCase();
    return value.length == 4 ? '0000$value-0000-1000-8000-00805f9b34fb' : value;
  }

  /// 名称仅用于扫描推荐，不能决定协议或写入端点。
  static bool isTargetDevice(String name, [List<dynamic>? serviceUuids]) {
    if (serviceUuids?.any((u) =>
            normalize(u.toString()) == serviceOpus ||
            normalize(u.toString()) == serviceAiNote) ??
        false) {
      return true;
    }
    final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return ['cone', 'ainote', '6095', 'claw', 'yooo'].any(normalized.contains);
  }
}

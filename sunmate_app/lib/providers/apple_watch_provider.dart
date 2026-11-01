import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/recordings/apple_watch_controller.dart';
import 'device_provider.dart';

final appleWatchProvider = ChangeNotifierProvider<AppleWatchController>((ref) {
  return AppleWatchController(ref.watch(deviceFactoryProvider).watchDriver);
});

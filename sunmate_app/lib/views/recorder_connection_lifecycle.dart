import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/device_provider.dart';

/// UI生命周期只发出前台状态，设备选择、蓝牙和真实AES仍由原驱动处理。
class RecorderConnectionLifecycle extends ConsumerStatefulWidget {
  final Widget child;
  const RecorderConnectionLifecycle({super.key, required this.child});
  @override
  ConsumerState<RecorderConnectionLifecycle> createState() =>
      _RecorderConnectionLifecycleState();
}

class _RecorderConnectionLifecycleState
    extends ConsumerState<RecorderConnectionLifecycle>
    with WidgetsBindingObserver {
  late final DeviceNotifier _notifier;
  @override
  void initState() {
    super.initState();
    _notifier = ref.read(deviceProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted)
        unawaited(_notifier.setAppForeground(
            WidgetsBinding.instance.lifecycleState == null ||
                WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.resumed));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_notifier.setAppForeground(state == AppLifecycleState.resumed));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_notifier.setAppForeground(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

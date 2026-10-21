import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/server_config_provider.dart';
import 'core/notifications/mobile_notification_manager.dart';
import 'views/home_page.dart';
import 'views/chat_page.dart';
import 'views/meeting_page.dart';
import 'views/timeline_page.dart';
import 'views/settings_page.dart';
import 'views/recorder_connection_lifecycle.dart';
import 'views/recording_processing_lifecycle.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final servers = ServerConfigNotifier();
  await Future.wait([servers.ready, MobileNotificationManager().initialize()]);
  runApp(ProviderScope(overrides: [
    serverConfigProvider.overrideWith((ref) => servers),
  ], child: const SunMateApp()));
}

class SunMateApp extends StatelessWidget {
  const SunMateApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SunMate 阳光智伴',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF8C00), // 阳光橙色调
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      home: const RecordingProcessingLifecycle(child: RecorderConnectionLifecycle(child: RootNavigationContainer())),
    );
  }
}

/// 全局底部导航当前选中 Tab Provider (0: 首页, 1: 对讲, 2: 会议纪要, 3: 时光复盘, 4: 设置)
final currentTabProvider = StateProvider<int>((ref) => 0);

class RootNavigationContainer extends ConsumerWidget {
  const RootNavigationContainer({super.key});

  static const List<Widget> _pages = [
    HomePage(),
    ChatPage(),
    MeetingPage(),
    TimelinePage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentIndex = ref.watch(currentTabProvider);

    return Scaffold(
      body: IndexedStack(
        index: currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: (idx) =>
            ref.read(currentTabProvider.notifier).state = idx,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: "首页",
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: "AI对讲",
          ),
          NavigationDestination(
            icon: Icon(Icons.meeting_room_outlined),
            selectedIcon: Icon(Icons.meeting_room),
            label: "会议纪要",
          ),
          NavigationDestination(
            icon: Icon(Icons.timeline),
            selectedIcon: Icon(Icons.timeline),
            label: "时光复盘",
          ),
          NavigationDestination(
            icon: Icon(Icons.tune),
            selectedIcon: Icon(Icons.tune),
            label: "按键设置",
          ),
        ],
      ),
    );
  }
}

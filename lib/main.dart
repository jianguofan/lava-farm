/// Lava Farm — 局域网 3D 打印机群控桌面端
///
/// 基于 Flutter Desktop + Riverpod + 独立 MQTT Broker
/// 支持 1-100 台 Snapmaker Moonraker 打印机的实时监控与批量控制
///
/// App 作为纯 MQTT 客户端：Broker 独立部署（生产模式）或内嵌运行（评估模式）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/farm/data/farm_logger.dart';
import 'features/farm/presentation/pages/broker_setup_page.dart';
import 'features/farm/presentation/pages/farm_dashboard_page.dart';
import 'features/farm/presentation/pages/discovery_wizard_page.dart';
import 'features/farm/presentation/pages/settings_page.dart';
import 'features/farm/presentation/pages/batch_print_page.dart';
import 'features/farm/presentation/pages/log_viewer_page.dart';
import 'features/farm/presentation/pages/product_center_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地日志系统
  FarmLogger.instance.init();

  // 允许 Freestyle 窗口（macOS 隐藏标题栏时可用）
  // await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  runApp(const ProviderScope(child: LavaFarmApp()));
}

/// Lava Farm 应用根组件
class LavaFarmApp extends StatelessWidget {
  const LavaFarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Snapmaker Farm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      // 命名路由
      initialRoute: '/',
      onGenerateRoute: _onGenerateRoute,
    );
  }

  /// 路由生成器
  Route<dynamic>? _onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case '/':
        return MaterialPageRoute(
          builder: (_) => const FarmDashboardPage(),
        );
      case '/discovery':
        return MaterialPageRoute(
          builder: (_) => const DiscoveryWizardPage(),
        );
      case '/broker-setup':
        return MaterialPageRoute(
          builder: (_) => const BrokerSetupPage(),
          fullscreenDialog: true,
        );
      case '/settings':
        return MaterialPageRoute(
          builder: (_) => const SettingsPage(),
        );
      case '/batch-print':
        final args = settings.arguments;
        final initialSns = args is List<String> ? args : <String>[];
        return MaterialPageRoute(
          builder: (_) => BatchPrintPage(initialSns: initialSns.toSet()),
        );
      case '/products':
        return MaterialPageRoute(
          builder: (_) => const ProductCenterPage(),
        );
      case '/logs':
        return MaterialPageRoute(
          builder: (_) => const LogViewerPage(),
        );
      default:
        // 未匹配路由：回退到 Dashboard
        return MaterialPageRoute(
          builder: (_) => const FarmDashboardPage(),
        );
    }
  }
}

# Lava Farm 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建 Flutter 桌面端局域网 3D 打印机群控系统，支持 1-100 台 Snapmaker Moonraker 打印机的实时监控与批量控制。

**Architecture:** 独立 Mosquitto MQTT Broker（7×24 运行） + Flutter Desktop App（纯 MQTT 客户端）。双模式：生产模式连接外部 Broker，快速体验模式内嵌 Broker。MQTT 主力通道 + HTTP 降级保底。FarmStore 单入口状态聚合 + 时间戳保护解决数据竞争。100ms 批处理通知窗口降低 UI 重建频率。

**Tech Stack:** Flutter 3.x (macOS/Windows/Linux), Dart 3.x, Riverpod 2.x, Hive, flutter_secure_storage, lava_device_sdk (MqttTransport, MoonrakerAdapter, JsonRpc), Mosquitto MQTT Broker, Moonraker REST API

**Spec:** `ARCHITECTURE.md` | **Design:** `openspec/changes/lava-farm/design.md` | **Task outline:** `openspec/changes/lava-farm/tasks.md`

---

## File Map

### 数据层 (`lib/features/farm/data/`)

| 文件 | 职责 | 依赖 |
|------|------|------|
| `staleable.dart` | 可过期值包装器，断连时标记 stale | 无 |
| `farm_snapshot.dart` | 快照数据类 | 无 |
| `farm_printer_state.dart` | 单打印机状态模型（遥测、时间戳、快照） | staleable, farm_snapshot |
| `printer_info.dart` | 打印机注册信息（Hive 持久化） | hive |
| `farm_store.dart` | 多设备状态聚合（单入口写入、时间戳保护、批处理通知） | farm_printer_state, farm_snapshot |
| `request_tracker.dart` | JSON-RPC 请求-响应 ID 匹配 | 无 |
| `request_queue.dart` | 并发请求队列（Semaphore 控制） | 无 |
| `farm_mqtt_router.dart` | MQTT 消息路由（通配符订阅、分发、命令发布） | farm_store, request_tracker, lava_device_sdk |
| `broker_connection_manager.dart` | 外部 Broker 连接 + 自动重连（指数退避） | farm_mqtt_router |
| `broker_health_monitor.dart` | Broker 假活检测（MQTT PING） | farm_mqtt_router |
| `credential_store.dart` | 凭据生成与安全存储 | flutter_secure_storage |
| `printer_registry.dart` | Hive 打印机列表持久化封装 | printer_info, hive |
| `printer_discovery.dart` | mDNS + TCP 扫描发现打印机 | 无 |
| `config_push_service.dart` | Moonraker 配置推送 + 后台升级重试 | farm_store |
| `batch_result.dart` | 批量操作结果数据类 | 无 |
| `batch_operator.dart` | 批量命令 Fan-Out（优先级并发） | farm_store, farm_mqtt_router |
| `http_poller.dart` | HTTP 轮询降级（probeSingle + 后台升级） | farm_store, request_queue |
| `file_uploader.dart` | 文件批量上传（HTTP multipart） | farm_store |
| `farm_connection_monitor.dart` | 打印机心跳检测 + 假在线判定 | farm_store |
| `farm_hub.dart` | 群控系统入口（编排所有组件） | 以上全部 |

### 应用层 (`lib/features/farm/application/providers/`)

| 文件 | 职责 |
|------|------|
| `farm_store_provider.dart` | FarmStoreNotifier (StateNotifier) |
| `broker_state_provider.dart` | BrokerConnState Stream |
| `discovery_provider.dart` | 发现状态 |
| `printer_list_provider.dart` | 派生打印机列表 |
| `farm_stats_provider.dart` | 派生统计 |
| `batch_operation_provider.dart` | 批量操作状态 |

### 表现层 (`lib/features/farm/presentation/`)

| 文件 | 职责 |
|------|------|
| `pages/farm_dashboard_page.dart` | 主仪表盘（打印机网格 + 统计栏 + 工具栏） |
| `pages/printer_detail_page.dart` | 单机详情（温度曲线、手动控制） |
| `pages/discovery_wizard_page.dart` | 发现向导（mDNS/TCP/手动/CSV） |
| `pages/broker_setup_page.dart` | Broker 连接配置 |
| `pages/settings_page.dart` | 应用设置 |
| `widgets/printer_card.dart` | 打印机状态卡片 |
| `widgets/printer_grid.dart` | 自适应网格布局 |
| `widgets/stats_bar.dart` | 顶部统计栏 |
| `widgets/batch_toolbar.dart` | 批量操作工具栏 |
| `widgets/broker_status_indicator.dart` | Broker 连接状态指示器 |
| `widgets/deployment_mode_banner.dart` | 部署模式提示横幅 |
| `widgets/connection_badge.dart` | MQTT/HTTP 标记 |
| `widgets/discovery_result_list.dart` | 发现结果列表 |

---

## Task 1: 项目初始化 + 核心数据类

**目标:** 创建 Flutter 项目，实现所有无依赖的数据类。

### Step 1.1: 创建 Flutter 项目

```bash
cd /Users/jgfan/code/lava-farm
flutter create --project-name lava_farm --org com.lavafarm .
```

**验证:** `flutter run -d macos` 显示空白窗口。

### Step 1.2: 配置 pubspec.yaml

修改 `pubspec.yaml`，添加依赖：

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_riverpod: ^2.5.1
  riverpod_annotation: ^2.3.5
  hive: ^2.2.3
  hive_flutter: ^1.1.0
  flutter_secure_storage: ^9.2.2
  http: ^1.2.1
  freezed_annotation: ^2.4.1
  json_annotation: ^4.9.0
  rxdart: ^0.28.0

  # lava_device_sdk — 复用 MoonrakerAdapter, MqttTransport, JsonRpc
  lava_device_sdk:
    path: ../lava_device_sdk

dev_dependencies:
  flutter_test:
    sdk: flutter
  build_runner: ^2.4.9
  freezed: ^2.5.2
  json_serializable: ^6.8.0
  hive_generator: ^2.0.1
```

运行 `flutter pub get`。

### Step 1.3: 实现 Staleable<T>

创建 `lib/features/farm/data/staleable.dart`:

```dart
/// 可过期值 — 断连时标记过期，UI 据此显示 "--"
class Staleable<T> {
  final T value;
  final DateTime updatedAt;
  final bool isStale;

  const Staleable(this.value, {DateTime? updatedAt, this.isStale = false})
    : updatedAt = updatedAt ?? DateTime.now();

  Staleable<T> copyWith({T? value, bool? isStale}) =>
    Staleable(value ?? this.value, isStale: isStale ?? this.isStale);

  /// UI 中使用: stale → staleText, fresh → 格式化显示
  String display(String Function(T) formatter, {String staleText = '--'}) {
    if (isStale) return staleText;
    return formatter(value);
  }

  @override
  bool operator ==(Object other) =>
    other is Staleable<T> && other.value == value && other.isStale == isStale;

  @override
  int get hashCode => Object.hash(value, isStale);
}
```

创建测试 `test/features/farm/data/staleable_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lava_farm/features/farm/data/staleable.dart';

void main() {
  group('Staleable', () {
    test('creates fresh value', () {
      final s = Staleable(210.5);
      expect(s.value, 210.5);
      expect(s.isStale, false);
    });

    test('display returns formatted value when fresh', () {
      final s = Staleable(210.5);
      expect(s.display((v) => '${v.toStringAsFixed(1)}°C'), '210.5°C');
    });

    test('display returns staleText when stale', () {
      final s = Staleable(210.5, isStale: true);
      expect(s.display((v) => '${v.toStringAsFixed(1)}°C'), '--');
    });

    test('copyWith changes isStale', () {
      final s = Staleable(210.5);
      final stale = s.copyWith(isStale: true);
      expect(stale.isStale, true);
      expect(stale.value, 210.5);
    });

    test('equality', () {
      expect(Staleable(210.5), Staleable(210.5));
      expect(Staleable(210.5).hashCode, Staleable(210.5).hashCode);
    });
  });
}
```

运行: `flutter test test/features/farm/data/staleable_test.dart`
预期: 5 tests PASS

### Step 1.4: 实现 FarmSnapshot

创建 `lib/features/farm/data/farm_snapshot.dart`:

```dart
class FarmSnapshot {
  final DateTime timestamp;
  final String reason;
  final String sn;
  final String? context;
  final double? nozzleTemp;
  final double? bedTemp;
  final String? printState;
  final double? progress;
  final String? connectionState;
  final String? error;

  const FarmSnapshot({
    required this.timestamp,
    required this.reason,
    required this.sn,
    this.context,
    this.nozzleTemp,
    this.bedTemp,
    this.printState,
    this.progress,
    this.connectionState,
    this.error,
  });
}
```

### Step 1.5: 实现 FarmConnectionState 和 Source 枚举 + PrinterInfo

创建 `lib/features/farm/data/printer_info.dart`:

```dart
import 'package:hive/hive.dart';

part 'printer_info.g.dart';

enum FarmConnectionState {
  offline,
  online,
  configuring,
  restarting,
  degraded,
}

enum Source { mqtt, http }

@HiveType(typeId: 0)
class PrinterInfo extends HiveObject {
  @HiveField(0)
  final String sn;

  @HiveField(1)
  String? displayName;

  @HiveField(2)
  String ip;

  @HiveField(3)
  int port;

  @HiveField(4)
  String? group;

  @HiveField(5)
  String sourceName;  // 'mqtt' | 'http'

  @HiveField(6)
  String? model;

  @HiveField(7)
  String? firmwareVersion;

  Source get source => sourceName == 'mqtt' ? Source.mqtt : Source.http;

  PrinterInfo({
    required this.sn,
    this.displayName,
    required this.ip,
    this.port = 7125,
    this.group,
    required this.sourceName,
    this.model,
    this.firmwareVersion,
  });
}
```

生成 Hive adapter: `dart run build_runner build --delete-conflicting-outputs`

### Step 1.6: 实现 FarmPrinterState

创建 `lib/features/farm/data/farm_printer_state.dart`:

```dart
import 'staleable.dart';
import 'farm_snapshot.dart';
import 'printer_info.dart';

class FarmPrinterState {
  // ── 身份 ──
  final String sn;
  String? displayName;
  String ip;
  int port;
  String? group;
  String? model;
  String? firmwareVersion;

  // ── 通信模式 ──
  Source source;
  FarmConnectionState connectionState;

  // ── 实时遥测 ──
  Staleable<double>? nozzleTemp;
  Staleable<double>? bedTemp;
  Staleable<String>? printState;
  Staleable<double>? progress;
  Staleable<String>? currentFile;

  // ── 累积指标 ──
  double? totalDuration;
  double? filamentUsed;
  double? _lastReportedDuration;

  // ── 数据版本（解决 MQTT/HTTP 竞争）──
  DateTime? lastDataTimestamp;
  DateTime lastStatusTime;
  DateTime? lastOnlineTime;

  // ── 批量操作 ──
  BatchResult? lastBatchResult;

  // ── 快照 ──
  static const _maxSnapshots = 50;
  final List<FarmSnapshot> _snapshots = [];
  List<FarmSnapshot> get snapshots => List.unmodifiable(_snapshots);
  FarmSnapshot? get lastSnapshot => _snapshots.isNotEmpty ? _snapshots.last : null;

  FarmPrinterState({
    required this.sn,
    this.displayName,
    required this.ip,
    this.port = 7125,
    this.group,
    this.model,
    this.firmwareVersion,
    this.source = Source.mqtt,
    this.connectionState = FarmConnectionState.offline,
    this.nozzleTemp,
    this.bedTemp,
    this.printState,
    this.progress,
    this.currentFile,
    this.totalDuration,
    this.filamentUsed,
    this.lastDataTimestamp,
    DateTime? lastStatusTime,
    this.lastOnlineTime,
  }) : lastStatusTime = lastStatusTime ?? DateTime.now();

  factory FarmPrinterState.fromInfo(PrinterInfo info) {
    return FarmPrinterState(
      sn: info.sn,
      displayName: info.displayName,
      ip: info.ip,
      port: info.port,
      group: info.group,
      source: info.source,
      model: info.model,
      firmwareVersion: info.firmwareVersion,
      connectionState: FarmConnectionState.offline,
    );
  }

  // ── 派生属性 ──
  bool get isOnline => connectionState == FarmConnectionState.online;
  bool get isPrinting => printState?.value == 'printing';
  bool get isMqtt => source == Source.mqtt;
  bool get isHttp => source == Source.http;

  // ── 状态更新 ──
  void updateTelemetry(Map<String, dynamic> data, {DateTime? eventTime}) {
    // 时间戳保护
    if (eventTime != null && lastDataTimestamp != null) {
      if (!eventTime.isAfter(lastDataTimestamp!)) return;
    }

    if (data.containsKey('extruder.temperature')) {
      nozzleTemp = Staleable(
        (data['extruder.temperature'] as num).toDouble(),
        isStale: false,
      );
    }
    if (data.containsKey('heater_bed.temperature')) {
      bedTemp = Staleable(
        (data['heater_bed.temperature'] as num).toDouble(),
        isStale: false,
      );
    }
    if (data.containsKey('print_stats.state')) {
      printState = Staleable(
        data['print_stats.state'] as String,
        isStale: false,
      );
    }
    if (data.containsKey('virtual_sdcard.progress')) {
      progress = Staleable(
        (data['virtual_sdcard.progress'] as num).toDouble(),
        isStale: false,
      );
    }
    if (data.containsKey('print_stats.filename')) {
      currentFile = Staleable(
        data['print_stats.filename'] as String,
        isStale: false,
      );
    }
    // 增量累加
    if (data.containsKey('print_stats.total_duration')) {
      final current = (data['print_stats.total_duration'] as num).toDouble();
      if (_lastReportedDuration != null && current > _lastReportedDuration!) {
        totalDuration = (totalDuration ?? 0) + (current - _lastReportedDuration!);
      } else if (_lastReportedDuration == null) {
        totalDuration = current;
      }
      _lastReportedDuration = current;
    }
    if (data.containsKey('print_stats.filament_used')) {
      filamentUsed = (data['print_stats.filament_used'] as num).toDouble();
    }
    if (eventTime != null) {
      lastDataTimestamp = eventTime;
    }
    lastStatusTime = DateTime.now();
  }

  void markFresh(Source src) {
    source = src;
    connectionState = FarmConnectionState.online;
  }

  void markTelemetryStale() {
    nozzleTemp = nozzleTemp?.copyWith(isStale: true);
    bedTemp = bedTemp?.copyWith(isStale: true);
    printState = printState?.copyWith(isStale: true);
    progress = progress?.copyWith(isStale: true);
    currentFile = currentFile?.copyWith(isStale: true);
  }

  void addSnapshot(FarmSnapshot snapshot) {
    _snapshots.add(snapshot);
    if (_snapshots.length > _maxSnapshots) {
      _snapshots.removeAt(0);
    }
  }
}
```

创建测试 `test/features/farm/data/farm_printer_state_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lava_farm/features/farm/data/farm_printer_state.dart';
import 'package:lava_farm/features/farm/data/printer_info.dart';

void main() {
  group('FarmPrinterState', () {
    late FarmPrinterState state;

    setUp(() {
      state = FarmPrinterState(sn: 'TEST001', ip: '192.168.1.100');
    });

    test('fromInfo creates state with correct defaults', () {
      final info = PrinterInfo(sn: 'TEST001', ip: '192.168.1.100', sourceName: 'mqtt');
      final s = FarmPrinterState.fromInfo(info);
      expect(s.sn, 'TEST001');
      expect(s.connectionState, FarmConnectionState.offline);
      expect(s.source, Source.mqtt);
    });

    test('updateTelemetry sets values from extruder status', () {
      state.updateTelemetry({'extruder.temperature': 215.5, 'heater_bed.temperature': 62.0});
      expect(state.nozzleTemp?.value, 215.5);
      expect(state.bedTemp?.value, 62.0);
      expect(state.nozzleTemp?.isStale, false);
    });

    test('updateTelemetry sets print state and progress', () {
      state.updateTelemetry({
        'print_stats.state': 'printing',
        'virtual_sdcard.progress': 0.45,
        'print_stats.filename': 'benchy.gcode',
      });
      expect(state.printState?.value, 'printing');
      expect(state.progress?.value, 0.45);
      expect(state.currentFile?.value, 'benchy.gcode');
    });

    test('updateTelemetry rejects older data via timestamp', () {
      final t1 = DateTime(2026, 6, 18, 12, 0, 0);
      final t2 = DateTime(2026, 6, 18, 11, 59, 0); // older

      state.updateTelemetry({'extruder.temperature': 215.0}, eventTime: t1);
      state.updateTelemetry({'extruder.temperature': 210.0}, eventTime: t2); // should be rejected

      expect(state.nozzleTemp?.value, 215.0); // keeps newer value
    });

    test('updateTelemetry accumulates totalDuration incrementally', () {
      state.updateTelemetry({'print_stats.total_duration': 100.0});
      expect(state.totalDuration, 100.0);

      state.updateTelemetry({'print_stats.total_duration': 150.0});
      expect(state.totalDuration, 150.0); // 100 + (150-100)
    });

    test('markTelemetryStale sets all telemetry to stale', () {
      state.updateTelemetry({'extruder.temperature': 215.0, 'print_stats.state': 'printing'});
      state.markTelemetryStale();
      expect(state.nozzleTemp?.isStale, true);
      expect(state.printState?.isStale, true);
    });

    test('markFresh sets source and online', () {
      state.markFresh(Source.mqtt);
      expect(state.connectionState, FarmConnectionState.online);
      expect(state.source, Source.mqtt);
    });

    test('snapshots maintain max 50 limit', () {
      for (int i = 0; i < 60; i++) {
        state.addSnapshot(FarmSnapshot(
          timestamp: DateTime.now(),
          reason: 'test_$i',
          sn: state.sn,
        ));
      }
      expect(state.snapshots.length, 50);
      expect(state.snapshots.first.reason, 'test_10'); // oldest 10 dropped
    });
  });
}
```

运行: `flutter test test/features/farm/data/farm_printer_state_test.dart`
预期: 9 tests PASS

### Step 1.7: 实现 BatchResult + RequestTracker

创建 `lib/features/farm/data/batch_result.dart`:

```dart
class BatchResult {
  final String printerSn;
  final bool success;
  final String operation;
  final String? error;
  final Duration duration;

  const BatchResult({
    required this.printerSn,
    required this.success,
    required this.operation,
    this.error,
    required this.duration,
  });
}
```

创建 `lib/features/farm/data/request_tracker.dart`:

```dart
import 'dart:async';
import 'dart:math';

class RequestTracker {
  final Map<int, Completer<Map<String, dynamic>?>> _pending = {};
  int _nextId = Random().nextInt(10000);

  int get nextId => _nextId++;

  /// 注册一个待响应请求，返回 Future
  Future<Map<String, dynamic>?> track(int id, {Duration timeout = const Duration(seconds: 30)}) {
    final completer = Completer<Map<String, dynamic>?>();
    _pending[id] = completer;

    // 超时处理
    Timer(timeout, () {
      if (_pending.containsKey(id) && !completer.isCompleted) {
        completer.completeError(TimeoutException('请求超时: id=$id'));
        _pending.remove(id);
      }
    });

    return completer.future;
  }

  /// 完成一个待响应请求
  void complete(int id, Map<String, dynamic>? result) {
    final completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  /// 取消所有待响应请求
  void cancelAll() {
    for (final entry in _pending.entries) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(CancelledException('连接已断开'));
      }
    }
    _pending.clear();
  }

  int get pendingCount => _pending.length;
}

class CancelledException implements Exception {
  final String message;
  const CancelledException(this.message);
  @override
  String toString() => 'CancelledException: $message';
}
```

创建测试 `test/features/farm/data/request_tracker_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lava_farm/features/farm/data/request_tracker.dart';

void main() {
  group('RequestTracker', () {
    late RequestTracker tracker;

    setUp(() => tracker = RequestTracker());

    test('track returns future and completes with result', () async {
      final future = tracker.track(42);
      tracker.complete(42, {'result': 'ok'});
      final result = await future;
      expect(result, {'result': 'ok'});
    });

    test('track times out', () async {
      final future = tracker.track(42, timeout: Duration(milliseconds: 100));
      expectLater(future, throwsA(isA<TimeoutException>()));
    });

    test('cancelAll completes all pending with CancelledException', () {
      final f1 = tracker.track(1);
      final f2 = tracker.track(2);
      tracker.cancelAll();
      expect(tracker.pendingCount, 0);
      expectLater(f1, throwsA(isA<CancelledException>()));
      expectLater(f2, throwsA(isA<CancelledException>()));
    });
  });
}
```

运行: `flutter test test/features/farm/data/request_tracker_test.dart`
预期: 3 tests PASS

### Step 1.8: 实现 RequestQueue

创建 `lib/features/farm/data/request_queue.dart`:

```dart
import 'dart:async';

class RequestQueue {
  final int maxConcurrency;
  final Semaphore _semaphore;

  RequestQueue({this.maxConcurrency = 20}) : _semaphore = Semaphore(maxConcurrency);

  Future<List<T>> executeAll<T>(Iterable<Future<T> Function()> tasks) async {
    final results = <T>[];
    final futures = tasks.map((task) async {
      await _semaphore.acquire();
      try {
        final result = await task();
        results.add(result);
        return result;
      } finally {
        _semaphore.release();
      }
    });
    await Future.wait(futures);
    return results;
  }
}

class Semaphore {
  final int _maxPermits;
  int _available;
  final List<Completer<void>> _waiters = [];

  Semaphore(int permits)
    : _maxPermits = permits,
      _available = permits;

  Future<void> acquire() {
    if (_available > 0) {
      _available--;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _available++;
    }
  }
}
```

### Step 1.9: Commit

```bash
git add -A
git commit -m "feat: project init + core data classes (Staleable, FarmPrinterState, RequestTracker, RequestQueue)"
```

---

## Task 2: FarmStore 核心

**目标:** 实现多设备状态聚合引擎，含时间戳保护、批处理通知。

### Step 2.1: 写 FarmStore 测试

创建 `test/features/farm/data/farm_store_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lava_farm/features/farm/data/farm_store.dart';
import 'package:lava_farm/features/farm/data/farm_printer_state.dart';
import 'package:lava_farm/features/farm/data/printer_info.dart';

void main() {
  group('FarmStore', () {
    late FarmStore store;

    setUp(() {
      store = FarmStore();
    });

    test('onPrinterRegistered adds new printer', () {
      final info = PrinterInfo(sn: 'TEST001', ip: '192.168.1.100', sourceName: 'mqtt');
      store.onPrinterRegistered(info);
      expect(store.count, 1);
      expect(store.getPrinter('TEST001')?.sn, 'TEST001');
    });

    test('onPrinterRegistered updates existing printer', () {
      store.onPrinterRegistered(PrinterInfo(sn: 'TEST001', ip: '192.168.1.100', sourceName: 'mqtt'));
      store.onPrinterRegistered(PrinterInfo(sn: 'TEST001', ip: '192.168.1.101', sourceName: 'http'));
      expect(store.count, 1);
      expect(store.getPrinter('TEST001')?.ip, '192.168.1.101');
    });

    test('onMqttStatus updates telemetry', () {
      store.onPrinterRegistered(PrinterInfo(sn: 'TEST001', ip: '192.168.1.100', sourceName: 'mqtt'));
      final t = DateTime(2026, 6, 18, 12, 0, 0);
      store.onMqttStatus('TEST001', {'extruder.temperature': 215.0, 'heater_bed.temperature': 62.0}, eventTime: t);
      final p = store.getPrinter('TEST001')!;
      expect(p.nozzleTemp?.value, 215.0);
      expect(p.source, Source.mqtt);
      expect(p.connectionState, FarmConnectionState.online);
    });

    test('onMqttStatus ignores unknown SN', () {
      store.onMqttStatus('UNKNOWN', {'extruder.temperature': 215.0});
      // Should not throw
    });

    test('onMqttStatus rejects older data via timestamp', () {
      store.onPrinterRegistered(PrinterInfo(sn: 'TEST001', ip: '192.168.1.100', sourceName: 'mqtt'));
      final tNew = DateTime(2026, 6, 18, 12, 0, 1);
      final tOld = DateTime(2026, 6, 18, 12, 0, 0);

      store.onMqttStatus('TEST001', {'extruder.temperature': 215.0}, eventTime: tNew);
      store.onMqttStatus('TEST001', {'extruder.temperature': 200.0}, eventTime: tOld);

      expect(store.getPrinter('TEST001')?.nozzleTemp?.value, 215.0);
    });

    test('onHttpPollResult discards data older than MQTT', () {
      store.onPrinterRegistered(PrinterInfo(sn: 'TEST001', ip: '192.168.1.100', sourceName: 'mqtt'));
      final tMqtt = DateTime(2026, 6, 18, 12, 0, 5);
      final tHttp = DateTime(2026, 6, 18, 12, 0, 2); // older

      store.onMqttStatus('TEST001', {'extruder.temperature': 215.0}, eventTime: tMqtt);
      store.onHttpPollResult('TEST001', {'extruder.temperature': 200.0}, pollTime: tHttp);

      expect(store.getPrinter('TEST001')?.nozzleTemp?.value, 215.0);
    });

    test('onHttpPollResult accepts newer data than MQTT', () {
      store.onPrinterRegistered(PrinterInfo(sn: 'TEST001', ip: '192.168.1.100', sourceName: 'mqtt'));
      final tMqtt = DateTime(2026, 6, 18, 12, 0, 2);
      final tHttp = DateTime(2026, 6, 18, 12, 0, 5); // newer

      store.onMqttStatus('TEST001', {'extruder.temperature': 210.0}, eventTime: tMqtt);
      store.onHttpPollResult('TEST001', {'extruder.temperature': 215.0}, pollTime: tHttp);

      expect(store.getPrinter('TEST001')?.nozzleTemp?.value, 215.0);
    });

    test('onMqttNotification handles online/offline', () {
      store.onPrinterRegistered(PrinterInfo(sn: 'TEST001', ip: '192.168.1.100', sourceName: 'mqtt'));
      store.onMqttNotification('TEST001', {'server': 'online'});
      expect(store.getPrinter('TEST001')?.connectionState, FarmConnectionState.online);

      store.onMqttNotification('TEST001', {'server': 'offline'});
      expect(store.getPrinter('TEST001')?.connectionState, FarmConnectionState.offline);
      expect(store.getPrinter('TEST001')?.nozzleTemp?.isStale, true);
    });

    test('forceOffline marks printer offline and stale', () {
      store.onPrinterRegistered(PrinterInfo(sn: 'TEST001', ip: '192.168.1.100', sourceName: 'mqtt'));
      store.onMqttStatus('TEST001', {'extruder.temperature': 215.0});
      store.forceOffline('TEST001', 'heartbeat_timeout');
      expect(store.getPrinter('TEST001')?.connectionState, FarmConnectionState.offline);
      expect(store.getPrinter('TEST001')?.nozzleTemp?.isStale, true);
      expect(store.getPrinter('TEST001')?.lastSnapshot?.reason, 'heartbeat_timeout');
    });

    test('onPrinterRemoved deletes printer', () {
      store.onPrinterRegistered(PrinterInfo(sn: 'TEST001', ip: '192.168.1.100', sourceName: 'mqtt'));
      store.onPrinterRemoved('TEST001');
      expect(store.count, 0);
    });

    test('statistics are correct', () {
      store.onPrinterRegistered(PrinterInfo(sn: 'A', ip: '192.168.1.1', sourceName: 'mqtt'));
      store.onPrinterRegistered(PrinterInfo(sn: 'B', ip: '192.168.1.2', sourceName: 'http'));
      store.onPrinterRegistered(PrinterInfo(sn: 'C', ip: '192.168.1.3', sourceName: 'mqtt'));

      store.onMqttStatus('A', {'extruder.temperature': 210.0});
      store.onMqttStatus('C', {'print_stats.state': 'printing'});

      expect(store.count, 3);
      expect(store.onlineCount, 1);
      expect(store.printingCount, 1);
      expect(store.mqttCount, 2);
      expect(store.httpCount, 1);
    });

    test('loadFromRegistry and exportToRegistry round-trip', () {
      final infos = [
        PrinterInfo(sn: 'A', ip: '192.168.1.1', sourceName: 'mqtt', displayName: 'P1'),
        PrinterInfo(sn: 'B', ip: '192.168.1.2', sourceName: 'http', displayName: 'P2'),
      ];
      store.loadFromRegistry(infos);
      expect(store.count, 2);

      final exported = store.exportToRegistry();
      expect(exported.length, 2);
      expect(exported.map((e) => e.sn).toSet(), {'A', 'B'});
    });
  });
}
```

### Step 2.2: 运行测试验证失败

```bash
flutter test test/features/farm/data/farm_store_test.dart
```
预期: FAIL — FarmStore 类未实现。

### Step 2.3: 实现 FarmStore

创建 `lib/features/farm/data/farm_store.dart`:

```dart
import 'dart:async';
import 'farm_printer_state.dart';
import 'farm_snapshot.dart';
import 'printer_info.dart';

class FarmStore {
  final Map<String, FarmPrinterState> _printers = {};
  final List<void Function()> _listeners = [];
  Timer? _batchTimer;
  static const _batchWindow = Duration(milliseconds: 100);

  // ═══ 监听器 ═══

  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void _notify() {
    if (_batchTimer == null || !_batchTimer!.isActive) {
      _batchTimer = Timer(_batchWindow, () {
        for (final listener in _listeners) {
          listener();
        }
        _batchTimer = null;
      });
    }
  }

  // ═══ 写入方法 ═══

  void onMqttStatus(String sn, Map<String, dynamic> status, {DateTime? eventTime}) {
    final printer = _printers[sn];
    if (printer == null) return;

    if (eventTime != null && printer.lastDataTimestamp != null) {
      if (!eventTime.isAfter(printer.lastDataTimestamp!)) return;
    }

    printer.updateTelemetry(status, eventTime: eventTime);
    printer.markFresh(Source.mqtt);
    _notify();
  }

  void onHttpPollResult(String sn, Map<String, dynamic> data, {required DateTime pollTime}) {
    final printer = _printers[sn];
    if (printer == null) return;

    if (printer.lastDataTimestamp != null && !pollTime.isAfter(printer.lastDataTimestamp!)) {
      return;
    }

    printer.updateTelemetry(data, eventTime: pollTime);
    printer.markFresh(Source.http);
    _notify();
  }

  void onMqttNotification(String sn, Map<String, dynamic> data) {
    final printer = _printers[sn];
    if (printer == null) return;

    if (data['server'] == 'online') {
      printer.connectionState = FarmConnectionState.online;
      printer.lastOnlineTime = DateTime.now();
      printer.markTelemetryStale();
    } else if (data['server'] == 'offline') {
      printer.connectionState = FarmConnectionState.offline;
      printer.markTelemetryStale();
    }
    _notify();
  }

  void onHttpPollFailed(String sn) {
    // 仅记录，状态由 FarmConnectionMonitor 累积判定
  }

  void forceOffline(String sn, String reason) {
    final printer = _printers[sn];
    if (printer == null) return;
    printer.connectionState = FarmConnectionState.offline;
    printer.markTelemetryStale();
    captureSnapshot(sn, reason);
    _notify();
  }

  void onPrinterRegistered(PrinterInfo info) {
    if (_printers.containsKey(info.sn)) {
      final existing = _printers[info.sn]!;
      existing.displayName = info.displayName ?? existing.displayName;
      existing.ip = info.ip;
      existing.source = info.source;
      existing.connectionState = FarmConnectionState.online;
    } else {
      _printers[info.sn] = FarmPrinterState.fromInfo(info);
    }
    _notify();
  }

  void onPrinterRemoved(String sn) {
    _printers.remove(sn);
    _notify();
  }

  void onBatchResult(String sn, BatchResult result) {
    final printer = _printers[sn];
    if (printer == null) return;
    printer.lastBatchResult = result;
    _notify();
  }

  void captureSnapshot(String sn, String reason, {String? context, Object? error}) {
    final printer = _printers[sn];
    if (printer == null) return;
    printer.addSnapshot(FarmSnapshot(
      timestamp: DateTime.now(),
      reason: reason,
      sn: sn,
      context: context,
      nozzleTemp: printer.nozzleTemp?.value,
      bedTemp: printer.bedTemp?.value,
      printState: printer.printState?.value,
      progress: printer.progress?.value,
      connectionState: printer.connectionState.name,
      error: error?.toString(),
    ));
  }

  // ═══ 读取出口 ═══

  FarmPrinterState? getPrinter(String sn) => _printers[sn];
  List<FarmPrinterState> get allPrinters => List.unmodifiable(_printers.values);

  List<FarmPrinterState> getByGroup(String group) =>
    _printers.values.where((p) => p.group == group).toList();

  List<FarmPrinterState> get mqttPrinters =>
    _printers.values.where((p) => p.isMqtt).toList();

  List<FarmPrinterState> get httpFallbackPrinters =>
    _printers.values.where((p) => p.isHttp).toList();

  int get count => _printers.length;
  int get onlineCount => _printers.values.where((p) => p.isOnline).length;
  int get printingCount => _printers.values.where((p) => p.isPrinting).length;
  int get mqttCount => _printers.values.where((p) => p.isMqtt).length;
  int get httpCount => _printers.values.where((p) => p.isHttp).length;
  int get httpPrintingCount =>
    _printers.values.where((p) => p.isHttp && p.isPrinting).length;
  int get httpOnlineCount =>
    _printers.values.where((p) => p.isHttp && p.isOnline).length;

  // ═══ 持久化 ═══

  void loadFromRegistry(List<PrinterInfo> printers) {
    _printers.clear();
    for (final info in printers) {
      _printers[info.sn] = FarmPrinterState.fromInfo(info);
    }
    _notify();
  }

  List<PrinterInfo> exportToRegistry() {
    return _printers.values.map((p) => PrinterInfo(
      sn: p.sn,
      displayName: p.displayName,
      ip: p.ip,
      port: p.port,
      group: p.group,
      sourceName: p.source == Source.mqtt ? 'mqtt' : 'http',
      model: p.model,
      firmwareVersion: p.firmwareVersion,
    )).toList();
  }
}
```

### Step 2.4: 运行测试验证通过

```bash
flutter test test/features/farm/data/farm_store_test.dart
```
预期: 13 tests PASS

### Step 2.5: Commit

```bash
git add -A
git commit -m "feat: FarmStore with timestamp protection and batch notification"
```

---

## Task 3: Riverpod Providers

**目标:** 创建 FarmStoreNotifier 和所有派生 Provider。

### Step 3.1: 实现 FarmStoreProvider

创建 `lib/features/farm/application/providers/farm_store_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/farm_store.dart';
import '../../data/farm_printer_state.dart';
import '../../data/printer_info.dart';

final farmStoreProvider = StateNotifierProvider<FarmStoreNotifier, Map<String, FarmPrinterState>>((ref) {
  return FarmStoreNotifier();
});

class FarmStoreNotifier extends StateNotifier<Map<String, FarmPrinterState>> {
  final FarmStore _store = FarmStore();

  FarmStoreNotifier() : super({}) {
    _store.addListener(_onStoreChanged);
  }

  void _onStoreChanged() {
    state = Map.from(_store.allPrinters.map((p) => MapEntry(p.sn, p)));
  }

  FarmStore get store => _store;

  // 代理所有写入方法
  void onMqttStatus(String sn, Map<String, dynamic> status, {DateTime? eventTime}) =>
    _store.onMqttStatus(sn, status, eventTime: eventTime);

  void onHttpPollResult(String sn, Map<String, dynamic> data, {required DateTime pollTime}) =>
    _store.onHttpPollResult(sn, data, pollTime: pollTime);

  void onMqttNotification(String sn, Map<String, dynamic> data) =>
    _store.onMqttNotification(sn, data);

  void onHttpPollFailed(String sn) => _store.onHttpPollFailed(sn);

  void forceOffline(String sn, String reason) => _store.forceOffline(sn, reason);

  void onPrinterRegistered(PrinterInfo info) => _store.onPrinterRegistered(info);

  void onPrinterRemoved(String sn) => _store.onPrinterRemoved(sn);

  void onBatchResult(String sn, BatchResult result) => _store.onBatchResult(sn, result);

  void loadFromRegistry(List<PrinterInfo> printers) => _store.loadFromRegistry(printers);
  List<PrinterInfo> exportToRegistry() => _store.exportToRegistry();
}

// FarmStore 快捷访问 Provider
final farmStoreInstanceProvider = Provider<FarmStore>((ref) {
  return ref.read(farmStoreProvider.notifier).store;
});
```

### Step 3.2: 实现派生 Provider

创建 `lib/features/farm/application/providers/printer_list_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'farm_store_provider.dart';
import '../../data/farm_printer_state.dart';

final printerListProvider = Provider<List<FarmPrinterState>>((ref) {
  final state = ref.watch(farmStoreProvider);
  return state.values.toList()..sort((a, b) => a.sn.compareTo(b.sn));
});

final printingPrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  return ref.watch(printerListProvider).where((p) => p.isPrinting).toList();
});

final offlinePrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  return ref.watch(printerListProvider).where((p) => !p.isOnline).toList();
});

final httpFallbackPrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  return ref.watch(printerListProvider).where((p) => p.isHttp).toList();
});
```

创建 `lib/features/farm/application/providers/farm_stats_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'printer_list_provider.dart';

class FarmStats {
  final int total;
  final int online;
  final int printing;
  final int mqttCount;
  final int httpCount;

  const FarmStats({
    required this.total,
    required this.online,
    required this.printing,
    required this.mqttCount,
    required this.httpCount,
  });

  double get onlineRate => total > 0 ? online / total : 0;
}

final farmStatsProvider = Provider<FarmStats>((ref) {
  final printers = ref.watch(printerListProvider);
  return FarmStats(
    total: printers.length,
    online: printers.where((p) => p.isOnline).length,
    printing: printers.where((p) => p.isPrinting).length,
    mqttCount: printers.where((p) => p.isMqtt).length,
    httpCount: printers.where((p) => p.isHttp).length,
  );
});
```

### Step 3.3: 实现 Broker 状态 Provider

创建 `lib/features/farm/application/providers/broker_state_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum BrokerConnState { disconnected, connecting, connected, degraded, error }

final brokerStateProvider = StateProvider<BrokerConnState>((ref) {
  return BrokerConnState.disconnected;
});
```

### Step 3.4: 实现发现 + 批量操作 Provider

创建 `lib/features/farm/application/providers/discovery_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DiscoveredPrinter {
  final String ip;
  final int port;
  final String? hostname;
  final String? sn;
  final String? model;

  const DiscoveredPrinter({
    required this.ip,
    this.port = 7125,
    this.hostname,
    this.sn,
    this.model,
  });
}

class DiscoveryState {
  final bool isScanning;
  final List<DiscoveredPrinter> results;
  final String? error;

  const DiscoveryState({this.isScanning = false, this.results = const [], this.error});

  DiscoveryState copyWith({bool? isScanning, List<DiscoveredPrinter>? results, String? error}) {
    return DiscoveryState(
      isScanning: isScanning ?? this.isScanning,
      results: results ?? this.results,
      error: error,
    );
  }
}

final discoveryProvider = StateNotifierProvider<DiscoveryNotifier, DiscoveryState>((ref) {
  return DiscoveryNotifier();
});

class DiscoveryNotifier extends StateNotifier<DiscoveryState> {
  DiscoveryNotifier() : super(const DiscoveryState());

  void startScan() => state = state.copyWith(isScanning: true, results: [], error: null);

  void setResults(List<DiscoveredPrinter> results) =>
    state = state.copyWith(isScanning: false, results: results);

  void setError(String error) =>
    state = state.copyWith(isScanning: false, error: error);
}
```

创建 `lib/features/farm/application/providers/batch_operation_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/batch_result.dart';

class BatchOperationState {
  final bool isRunning;
  final String? operation;
  final int totalCount;
  final int completedCount;
  final List<BatchResult> results;

  const BatchOperationState({
    this.isRunning = false,
    this.operation,
    this.totalCount = 0,
    this.completedCount = 0,
    this.results = const [],
  });

  double get progress => totalCount > 0 ? completedCount / totalCount : 0;

  BatchOperationState copyWith({
    bool? isRunning, String? operation, int? totalCount,
    int? completedCount, List<BatchResult>? results,
  }) {
    return BatchOperationState(
      isRunning: isRunning ?? this.isRunning,
      operation: operation ?? this.operation,
      totalCount: totalCount ?? this.totalCount,
      completedCount: completedCount ?? this.completedCount,
      results: results ?? this.results,
    );
  }
}

final batchOperationProvider = StateNotifierProvider<BatchOperationNotifier, BatchOperationState>((ref) {
  return BatchOperationNotifier();
});

class BatchOperationNotifier extends StateNotifier<BatchOperationState> {
  BatchOperationNotifier() : super(const BatchOperationState());

  void startOperation(String operation, int totalCount) {
    state = BatchOperationState(isRunning: true, operation: operation, totalCount: totalCount);
  }

  void addResult(BatchResult result) {
    final newResults = [...state.results, result];
    state = state.copyWith(
      results: newResults,
      completedCount: newResults.length,
      isRunning: newResults.length < state.totalCount,
    );
  }

  void reset() => state = const BatchOperationState();
}
```

### Step 3.5: Commit

```bash
git add -A
git commit -m "feat: Riverpod providers (FarmStore, Broker, Discovery, Batch, Stats)"
```

---

## Task 4: PrinterDiscovery + ConfigPushService

**目标:** 局域网打印机发现 + Moonraker 配置推送。

### Step 4.1: 实现 PrinterDiscovery

创建 `lib/features/farm/data/printer_discovery.dart`:

```dart
import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../application/providers/discovery_provider.dart';

class DiscoveredRaw {
  final String ip;
  final int port;
  final String? hostname;
  final String? sn;
  final String? model;

  const DiscoveredRaw({required this.ip, this.port = 7125, this.hostname, this.sn, this.model});
}

class PrinterDiscovery {
  static const int defaultPort = 7125;
  static const int defaultConcurrency = 50;
  static const Duration defaultMdnsTimeout = Duration(seconds: 5);

  /// mDNS 发现 _moonraker._tcp.local
  Future<List<DiscoveredRaw>> discoverMdns({Duration timeout = defaultMdnsTimeout}) async {
    // 平台相关 mDNS 实现。macOS 用 dns-sd 命令，Linux 用 avahi-browse
    // 此处为接口定义，具体实现在 Task 4.2 中按平台实现
    final results = <DiscoveredRaw>[];

    try {
      final process = await Process.run('dns-sd', [
        '-B', '_moonraker._tcp', 'local.',
      ]);
      // 解析输出，提取 hostname 和端口
      // 然后用 dns-sd -L 解析每个实例的 IP
    } catch (_) {
      // mDNS 不可用时返回空
    }

    return results;
  }

  /// TCP 端口扫描子网
  Future<List<DiscoveredRaw>> discoverTcp({
    required String subnet,
    int port = defaultPort,
    int concurrency = defaultConcurrency,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final results = <DiscoveredRaw>[];
    final semaphore = Semaphore(concurrency);

    final futures = List.generate(254, (i) => i + 1).map((host) async {
      await semaphore.acquire();
      try {
        final ip = '$subnet.$host';
        final uri = Uri.parse('http://$ip:$port/server/info');
        final response = await http.get(uri).timeout(timeout);
        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final result = json['result'] as Map<String, dynamic>?;
          if (result != null) {
            results.add(DiscoveredRaw(
              ip: ip,
              port: port,
              sn: result['instance_name'] as String?,
              model: _extractModel(result),
            ));
          }
        }
      } catch (_) {
        // 超时或连接拒绝，跳过
      } finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
    return results;
  }

  String? _extractModel(Map<String, dynamic> serverResult) {
    final components = serverResult['components'] as List?;
    return components?.join(',');
  }

  /// 合并 mDNS 和 TCP 结果，按 IP 去重
  static List<DiscoveredRaw> merge(List<DiscoveredRaw> mdns, List<DiscoveredRaw> tcp) {
    final seen = <String>{};
    final merged = <DiscoveredRaw>[];

    for (final item in [...mdns, ...tcp]) {
      final key = '${item.ip}:${item.port}';
      if (!seen.contains(key)) {
        seen.add(key);
        merged.add(item);
      }
    }
    return merged;
  }
}
```

### Step 4.2: 实现 ConfigPushService

创建 `lib/features/farm/data/config_push_service.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'farm_store.dart';
import 'printer_info.dart';

class ConfigPushService {
  final FarmStore? _store;
  static const _maxRetries = 3;
  static const _restartTimeout = Duration(seconds: 20);

  ConfigPushService({FarmStore? store}) : _store = store;

  /// 推送 MQTT 配置到打印机
  Future<(bool, Source)> push({
    required String ip,
    required int port,
    required String sn,
    required String brokerHost,
    required int brokerPort,
    required String mqttUsername,
    required String mqttPassword,
    double statusInterval = 1.0,
    String? apiKey,
  }) async {
    final config = {
      'config': {
        'mqtt': {
          'address': brokerHost,
          'port': brokerPort,
          'username': mqttUsername,
          'password': mqttPassword,
          'instance_name': sn,
          'status_interval': statusInterval,
          'enable_moonraker_api': true,
        }
      }
    };

    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (apiKey != null) {
      headers['X-Api-Key'] = apiKey;
    }

    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        final resp = await http.post(
          Uri.parse('http://$ip:$port/server/config'),
          headers: headers,
          body: jsonEncode(config),
        ).timeout(Duration(seconds: 10));

        if (resp.statusCode != 200) {
          if (attempt < _maxRetries - 1) {
            await Future.delayed(Duration(seconds: 3));
            continue;
          }
          return (false, Source.http);
        }

        // 重启 Moonraker
        await http.post(
          Uri.parse('http://$ip:$port/server/restart'),
          headers: headers,
        ).timeout(Duration(seconds: 5));

        // 等待 MQTT 上线
        final online = await _waitForMqttOnline(sn);
        if (online) return (true, Source.mqtt);

      } catch (_) {
        if (attempt < _maxRetries - 1) {
          await Future.delayed(Duration(seconds: 5));
        }
      }
    }

    return (false, Source.http);
  }

  Future<bool> _waitForMqttOnline(String sn) async {
    final start = DateTime.now();
    while (DateTime.now().difference(start) < _restartTimeout) {
      final printer = _store?.getPrinter(sn);
      if (printer?.connectionState == FarmConnectionState.online) {
        return true;
      }
      await Future.delayed(Duration(milliseconds: 500));
    }
    return false;
  }
}
```

### Step 4.3: Commit

```bash
git add -A
git commit -m "feat: PrinterDiscovery (mDNS + TCP scan) + ConfigPushService"
```

---

## Task 5: MQTT 通信层

**目标:** FarmMqttRouter + BrokerConnectionManager + BrokerHealthMonitor。

### Step 5.1: 实现 FarmMqttRouter

创建 `lib/features/farm/data/farm_mqtt_router.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'farm_store.dart';
import 'request_tracker.dart';
// import from lava_device_sdk:
// import 'package:lava_device_sdk/lava_device_sdk.dart';

class MqttMessage {
  final String topic;
  final List<int> payload;
  const MqttMessage({required this.topic, required this.payload});
}

/// FarmMqttRouter — MQTT 消息路由
/// 依赖 lava_device_sdk 的 MqttTransport 和 MoonrakerAdapter
/// 此处提供接口和核心路由逻辑，lava_device_sdk 集成在 Task 5.3
class FarmMqttRouter {
  final FarmStore _store;
  final RequestTracker _tracker = RequestTracker();
  final Map<String, StreamSubscription> _responseSubs = {};

  // MqttTransport 由外部注入（BrokerConnectionManager）
  dynamic _mqtt;  // 实际类型: MqttTransport

  // 消息流（从 MqttTransport.messageStream 转发）
  final _messageController = StreamController<MqttMessage>.broadcast();
  Stream<MqttMessage> get messageStream => _messageController.stream;

  FarmMqttRouter(this._store);

  /// 绑定 MqttTransport
  void bindTransport(dynamic transport) {
    _mqtt = transport;
    // 监听 transport 的消息流
    // transport.messageStream.listen((msg) {
    //   _messageController.add(MqttMessage(topic: msg.topic, payload: msg.payload));
    // });
  }

  /// 订阅通配符 topic
  Future<void> subscribeWildcards() async {
    // await _mqtt.subscribe('+/status', qos: 1);
    // await _mqtt.subscribe('+/notification', qos: 1);
  }

  /// 消息分发
  void dispatch(MqttMessage msg) {
    final topic = msg.topic;
    final sn = _extractSn(topic);

    if (topic.endsWith('/status')) {
      _handleStatus(sn, msg.payload);
    } else if (topic.endsWith('/notification')) {
      _handleNotification(sn, msg.payload);
    } else if (topic.endsWith('/response')) {
      _handleResponse(sn, msg.payload);
    }
  }

  void _handleStatus(String sn, List<int> payload) {
    try {
      final json = jsonDecode(utf8.decode(payload));
      Map<String, dynamic>? status;
      DateTime? eventTime;

      if (json['params'] is List && (json['params'] as List).isNotEmpty) {
        status = json['params'][0] as Map<String, dynamic>?;
        if ((json['params'] as List).length >= 2) {
          eventTime = DateTime.fromMillisecondsSinceEpoch(
            ((json['params'][1] as num) * 1000).toInt(),
          );
        }
      }
      if (status == null) return;

      // MoonrakerAdapter._expandStatus 展平嵌套对象
      // 此处简化实现，实际使用 lava_device_sdk 的 MoonrakerAdapter
      final expanded = _flattenStatus(status, '');

      _store.onMqttStatus(sn, expanded, eventTime: eventTime);
    } catch (_) {
      // 解析失败，跳过
    }
  }

  Map<String, dynamic> _flattenStatus(Map<String, dynamic> nested, String prefix) {
    final result = <String, dynamic>{};
    for (final entry in nested.entries) {
      final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      if (entry.value is Map<String, dynamic>) {
        result.addAll(_flattenStatus(entry.value as Map<String, dynamic>, key));
      } else {
        result[key] = entry.value;
      }
    }
    return result;
  }

  void _handleNotification(String sn, List<int> payload) {
    try {
      final json = jsonDecode(utf8.decode(payload));
      _store.onMqttNotification(sn, json);
    } catch (_) {}
  }

  void _handleResponse(String sn, List<int> payload) {
    try {
      final json = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      final id = json['id'] as int?;
      if (id != null) {
        _tracker.complete(id, json['result'] as Map<String, dynamic>?);
      }
    } catch (_) {}
  }

  /// 发送命令到指定打印机
  Future<Map<String, dynamic>?> sendCommand(
    String sn, String method, [Map<String, dynamic>? params]) async {
    final id = _tracker.nextId;
    final request = {
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
      'id': id,
    };

    final future = _tracker.track(id, timeout: Duration(seconds: 30));

    // await _mqtt.publish('$sn/request', utf8.encode(jsonEncode(request)), qos: 1);
    return future;
  }

  /// PING 检测 Broker 连通性
  Future<void> ping() async {
    // MQTT 协议层的 PINGREQ
  }

  Future<void> stop() async {
    for (final sub in _responseSubs.values) {
      await sub.cancel();
    }
    _responseSubs.clear();
    _tracker.cancelAll();
    await _messageController.close();
  }

  String _extractSn(String topic) => topic.split('/').first;
}
```

### Step 5.2: 实现 BrokerConnectionManager

创建 `lib/features/farm/data/broker_connection_manager.dart`:

```dart
import 'dart:async';
import 'dart:math';
import 'package:rxdart/rxdart.dart';
import '../application/providers/broker_state_provider.dart';
import 'farm_mqtt_router.dart';

class BrokerConnectionManager {
  final FarmMqttRouter _router;
  final BehaviorSubject<BrokerConnState> _stateController =
    BehaviorSubject<BrokerConnState>.seeded(BrokerConnState.disconnected);

  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  String? _host;
  int? _port;
  String? _username;
  String? _password;

  BrokerConnectionManager(this._router);

  Stream<BrokerConnState> get stateStream => _stateController.stream;
  BrokerConnState get state => _stateController.value;
  bool get isConnected => state == BrokerConnState.connected;

  /// 连接到外部 Broker
  Future<void> connect({
    required String host,
    required int port,
    required String username,
    required String password,
  }) async {
    _host = host;
    _port = port;
    _username = username;
    _password = password;

    _stateController.add(BrokerConnState.connecting);

    try {
      // await _mqttTransport.connect(
      //   host: host,
      //   port: port,
      //   username: username,
      //   password: password,
      // );

      await _router.subscribeWildcards();

      _reconnectAttempt = 0;
      _stateController.add(BrokerConnState.connected);
    } catch (e) {
      _stateController.add(BrokerConnState.error);
      _scheduleReconnect();
    }
  }

  /// 自动重连（指数退避）
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final delay = Duration(seconds: min(pow(2, _reconnectAttempt).toInt(), 30));
    _reconnectAttempt++;

    _reconnectTimer = Timer(delay, () async {
      if (_host != null && _port != null && _username != null && _password != null) {
        await connect(host: _host!, port: _port!, username: _username!, password: _password!);
      }
    });
  }

  /// 断开连接
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    // await _mqttTransport.disconnect();
    _stateController.add(BrokerConnState.disconnected);
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _stateController.close();
  }
}
```

### Step 5.3: Commit

```bash
git add -A
git commit -m "feat: FarmMqttRouter + BrokerConnectionManager with auto-reconnect"
```

---

## Task 6: BatchOperator + FileUploader + HttpPoller

**目标:** 批量操作引擎、文件上传、HTTP 降级轮询。

### Step 6.1: 实现 BatchOperator

创建 `lib/features/farm/data/batch_operator.dart`:

```dart
import 'farm_store.dart';
import 'farm_mqtt_router.dart';
import 'batch_result.dart';
import 'request_queue.dart';  // for Semaphore

class BatchOperator {
  final FarmStore _store;
  final FarmMqttRouter _mqttRouter;
  static const int maxConcurrency = 20;
  static const int highPriorityConcurrency = 40;

  BatchOperator(this._store, this._mqttRouter);

  Future<List<BatchResult>> batchPause(List<String> printerSns) =>
    _fanOut(printerSns, operation: 'pause', action: (sn) => _sendCommand(sn, 'printer.print.pause'));

  Future<List<BatchResult>> batchResume(List<String> printerSns) =>
    _fanOut(printerSns, operation: 'resume', action: (sn) => _sendCommand(sn, 'printer.print.resume'));

  Future<List<BatchResult>> batchCancel(List<String> printerSns) =>
    _fanOut(printerSns, operation: 'cancel', action: (sn) => _sendCommand(sn, 'printer.print.cancel'));

  Future<List<BatchResult>> batchGcode({
    required List<String> printerSns,
    required String gcode,
    Duration timeout = const Duration(seconds: 30),
  }) => _fanOut(printerSns, operation: 'gcode', timeout: timeout,
       action: (sn) => _sendCommand(sn, 'printer.gcode.script', {'script': gcode}));

  Future<List<BatchResult>> batchSetNozzleTemp({
    required List<String> printerSns,
    required double temp,
  }) => _fanOut(printerSns, operation: 'set_temp',
       action: (sn) => _sendCommand(sn, 'printer.gcode.script', {'script': 'M104 S${temp.toInt()}\\n'}));

  Future<List<BatchResult>> batchEmergencyStop() {
    final allSns = _store.allPrinters.map((p) => p.sn).toList();
    return _fanOut(allSns, operation: 'emergency_stop',
      timeout: Duration(seconds: 5),
      maxConcurrency: highPriorityConcurrency,
      action: (sn) => _sendCommand(sn, 'printer.gcode.script', {'script': 'M112\\n'}));
  }

  Future<List<BatchResult>> _fanOut(
    List<String> printerSns, {
    required String operation,
    required Future<void> Function(String sn) action,
    Duration timeout = const Duration(seconds: 30),
    int maxConcurrency = maxConcurrency,
  }) async {
    final results = <BatchResult>[];
    final semaphore = Semaphore(maxConcurrency);

    final futures = printerSns.map((sn) async {
      await semaphore.acquire();
      final startTime = DateTime.now();
      try {
        await action(sn).timeout(timeout);
        results.add(BatchResult(
          printerSn: sn, success: true, operation: operation,
          duration: DateTime.now().difference(startTime),
        ));
      } catch (e) {
        results.add(BatchResult(
          printerSn: sn, success: false, operation: operation,
          error: e.toString(),
          duration: DateTime.now().difference(startTime),
        ));
      } finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
    return results;
  }

  Future<void> _sendCommand(String sn, String method, [Map<String, dynamic>? params]) async {
    final printer = _store.getPrinter(sn);
    if (printer == null) throw Exception('打印机未注册: $sn');

    if (printer.source == Source.mqtt) {
      final result = await _mqttRouter.sendCommand(sn, method, params);
      if (result == null) throw TimeoutException('MQTT 命令超时: $method');
    }
    // HTTP 降级情况由 HttpPoller 处理
  }
}
```

### Step 6.2: 实现 HttpPoller（含 probeSingle + 后台升级）

创建 `lib/features/farm/data/http_poller.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'farm_store.dart';
import 'request_queue.dart';

class HttpPoller {
  final FarmStore _store;
  final RequestQueue _queue = RequestQueue(maxConcurrency: 20);
  Timer? _timer;
  Timer? _upgradeTimer;
  final List<_HttpTarget> _targets = [];

  void addPrinter(String sn, String ip, {int port = 7125, String? apiKey}) {
    _targets.removeWhere((t) => t.sn == sn);
    _targets.add(_HttpTarget(sn: sn, ip: ip, port: port, apiKey: apiKey));
  }

  void removePrinter(String sn) {
    _targets.removeWhere((t) => t.sn == sn);
  }

  void start() {
    _scheduleNext(adaptiveInterval);
  }

  void _scheduleNext(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () async {
      await _pollAll();
      _scheduleNext(adaptiveInterval);
    });
  }

  Future<void> _pollAll() async {
    final now = DateTime.now();
    final targets = List<_HttpTarget>.from(_targets);
    final results = await _queue.executeAll(
      targets.map((t) => () => _pollOne(t)),
    );
    for (final result in results) {
      if (result.isSuccess) {
        _store.onHttpPollResult(result.sn, result.data, pollTime: now);
      } else {
        _store.onHttpPollFailed(result.sn);
      }
    }
  }

  Future<_PollResult> _pollOne(_HttpTarget target) async {
    try {
      final uri = Uri.parse('http://${target.ip}:${target.port}/printer/objects/query');
      final response = await http.get(uri,
        headers: target.apiKey != null ? {'X-Api-Key': target.apiKey!} : {},
      ).timeout(Duration(seconds: 10));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final status = json['result']['status'] as Map<String, dynamic>?;
        if (status != null) {
          return _PollResult(sn: target.sn, isSuccess: true, data: status);
        }
      }
      return _PollResult(sn: target.sn, isSuccess: false);
    } catch (_) {
      return _PollResult(sn: target.sn, isSuccess: false);
    }
  }

  /// 命令发送后即时确认
  Future<void> probeSingle(String sn) async {
    final target = _targets.firstWhere(
      (t) => t.sn == sn,
      orElse: () => throw StateError('打印机 $sn 不在 HTTP 轮询列表中'),
    );
    final result = await _pollOne(target);
    if (result.isSuccess) {
      _store.onHttpPollResult(result.sn, result.data, pollTime: DateTime.now());
    }
  }

  Duration get adaptiveInterval {
    if (_store.httpPrintingCount > 0) return Duration(seconds: 3);
    if (_store.httpOnlineCount > 0) return Duration(seconds: 15);
    return Duration(seconds: 30);
  }

  void stop() {
    _timer?.cancel();
    _upgradeTimer?.cancel();
  }
}

class _HttpTarget {
  final String sn;
  final String ip;
  final int port;
  final String? apiKey;
  const _HttpTarget({required this.sn, required this.ip, this.port = 7125, this.apiKey});
}

class _PollResult {
  final String sn;
  final bool isSuccess;
  final Map<String, dynamic>? data;
  const _PollResult({required this.sn, required this.isSuccess, this.data});
}
```

### Step 6.3: 实现 FileUploader

创建 `lib/features/farm/data/file_uploader.dart`:

```dart
import 'dart:io';
import 'package:http/http.dart' as http;
import 'farm_store.dart';
import 'request_queue.dart';  // for Semaphore

class UploadResult {
  final String printerSn;
  final bool success;
  final String? error;
  const UploadResult({required this.printerSn, required this.success, this.error});
}

class FileUploader {
  static const int maxConcurrent = 5;
  static const int maxFileSize = 200 * 1024 * 1024; // 200MB

  Future<List<UploadResult>> batchUpload({
    required List<String> printerSns,
    required String localFilePath,
    required String remoteFileName,
    FarmStore? store,
    void Function(int completed, int total)? onProgress,
  }) async {
    final file = File(localFilePath);
    if (!await file.exists()) throw Exception('文件不存在: $localFilePath');

    final fileSize = await file.length();
    if (fileSize > maxFileSize) throw Exception('文件过大: $fileSize bytes, 超过 200MB 限制');

    final fileBytes = await file.readAsBytes();
    final results = <UploadResult>[];
    final semaphore = Semaphore(maxConcurrent);
    int completed = 0;

    final futures = printerSns.map((sn) async {
      await semaphore.acquire();
      try {
        final printer = store?.getPrinter(sn);
        if (printer == null) throw Exception('打印机未找到: $sn');

        await _uploadToPrinter(
          ip: printer.ip, port: printer.port,
          fileBytes: fileBytes, fileName: remoteFileName,
        );
        results.add(UploadResult(printerSn: sn, success: true));
      } catch (e) {
        results.add(UploadResult(printerSn: sn, success: false, error: e.toString()));
      } finally {
        completed++;
        onProgress?.call(completed, printerSns.length);
        semaphore.release();
      }
    });

    await Future.wait(futures);
    return results;
  }

  Future<void> _uploadToPrinter({
    required String ip, required int port,
    required Uint8List fileBytes, required String fileName,
  }) async {
    final uri = Uri.parse('http://$ip:$port/server/files/upload');
    final request = http.MultipartRequest('POST', uri);
    request.files.add(http.MultipartFile.fromBytes('file', fileBytes, filename: fileName));
    request.fields['path'] = fileName;

    final streamedResponse = await request.send().timeout(Duration(minutes: 5));
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode != 200) {
      throw Exception('上传失败: ${response.statusCode}');
    }
  }
}
```

### Step 6.4: Commit

```bash
git add -A
git commit -m "feat: BatchOperator + HttpPoller (probeSingle) + FileUploader"
```

---

## Task 7: FarmHub + CredentialStore + PrinterRegistry + FarmConnectionMonitor

### Step 7.1: 实现 CredentialStore

创建 `lib/features/farm/data/credential_store.dart`:

```dart
import 'dart:convert';
import 'dart:math';
// import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class BrokerConfig {
  final String host;
  final int port;
  final String username;
  final String password;
  final String mode; // 'embedded' | 'external'

  const BrokerConfig({
    required this.host,
    this.port = 1883,
    required this.username,
    required this.password,
    this.mode = 'external',
  });
}

class CredentialStore {
  // final _secureStorage = FlutterSecureStorage();

  /// 为打印机生成随机密码
  static String generatePrinterPassword(String sn) {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  Future<void> saveBrokerCredentials(BrokerConfig config) async {
    // await _secureStorage.write(key: 'broker_host', value: config.host);
    // await _secureStorage.write(key: 'broker_port', value: config.port.toString());
    // await _secureStorage.write(key: 'broker_username', value: config.username);
    // await _secureStorage.write(key: 'broker_password', value: config.password);
    // await _secureStorage.write(key: 'broker_mode', value: config.mode);
  }

  Future<BrokerConfig?> loadBrokerCredentials() async {
    // final host = await _secureStorage.read(key: 'broker_host');
    // if (host == null) return null;
    // final port = int.tryParse(await _secureStorage.read(key: 'broker_port') ?? '1883') ?? 1883;
    // final username = await _secureStorage.read(key: 'broker_username') ?? '';
    // final password = await _secureStorage.read(key: 'broker_password') ?? '';
    // final mode = await _secureStorage.read(key: 'broker_mode') ?? 'external';
    // return BrokerConfig(host: host, port: port, username: username, password: password, mode: mode);
    return null;
  }

  Future<void> clearBrokerCredentials() async {
    // await _secureStorage.deleteAll();
  }
}
```

### Step 7.2: 实现 PrinterRegistry

创建 `lib/features/farm/data/printer_registry.dart`:

```dart
import 'package:hive/hive.dart';
import 'printer_info.dart';

class PrinterRegistry {
  static const _boxName = 'printers';

  static Future<Box<PrinterInfo>> _box() async {
    return await Hive.openBox<PrinterInfo>(_boxName);
  }

  static Future<List<PrinterInfo>> loadAll() async {
    final box = await _box();
    return box.values.toList();
  }

  static Future<void> save(List<PrinterInfo> printers) async {
    final box = await _box();
    await box.clear();
    for (final info in printers) {
      await box.put(info.sn, info);
    }
  }

  static Future<void> add(PrinterInfo info) async {
    final box = await _box();
    await box.put(info.sn, info);
  }

  static Future<void> remove(String sn) async {
    final box = await _box();
    await box.delete(sn);
  }

  static Future<void> clear() async {
    final box = await _box();
    await box.clear();
  }
}
```

### Step 7.3: 实现 FarmConnectionMonitor

创建 `lib/features/farm/data/farm_connection_monitor.dart`:

```dart
import 'dart:async';
import 'farm_store.dart';

class FarmConnectionMonitor {
  final FarmStore _store;
  Timer? _heartbeatTimer;

  void start() {
    // 每 30s 检查所有在线打印机的心跳
    _heartbeatTimer = Timer.periodic(Duration(seconds: 30), (_) => _checkHeartbeats());
  }

  void _checkHeartbeats() {
    final now = DateTime.now();
    for (final printer in _store.allPrinters) {
      if (!printer.isOnline) continue;

      final elapsed = now.difference(printer.lastStatusTime);
      if (elapsed > Duration(seconds: 60)) {
        _store.forceOffline(printer.sn, 'heartbeat_timeout: ${elapsed.inSeconds}s');
      }
    }
  }

  void stop() {
    _heartbeatTimer?.cancel();
  }
}
```

### Step 7.4: 实现 FarmHub（组装所有组件）

创建 `lib/features/farm/data/farm_hub.dart`:

```dart
import 'farm_store.dart';
import 'farm_mqtt_router.dart';
import 'broker_connection_manager.dart';
import 'broker_health_monitor.dart';  // 占位
import 'credential_store.dart';
import 'printer_registry.dart';
import 'printer_discovery.dart';
import 'config_push_service.dart';
import 'batch_operator.dart';
import 'http_poller.dart';
import 'file_uploader.dart';
import 'farm_connection_monitor.dart';
import 'batch_result.dart';
import 'printer_info.dart';

class FarmHub {
  final FarmStore store = FarmStore();
  late final FarmMqttRouter mqttRouter = FarmMqttRouter(store);
  late final BrokerConnectionManager brokerConnMgr = BrokerConnectionManager(mqttRouter);
  late final CredentialStore credentialStore = CredentialStore();
  late final PrinterDiscovery discovery = PrinterDiscovery();
  late final ConfigPushService configPusher = ConfigPushService(store: store);
  late final BatchOperator batchOperator = BatchOperator(store, mqttRouter);
  late final HttpPoller httpPoller = HttpPoller(store);
  late final FileUploader fileUploader = FileUploader();
  late final FarmConnectionMonitor connectionMonitor = FarmConnectionMonitor(store);

  /// 启动群控系统
  Future<void> start({required BrokerConfig brokerConfig}) async {
    // 1. 连接 Broker
    await brokerConnMgr.connect(
      host: brokerConfig.host,
      port: brokerConfig.port,
      username: brokerConfig.username,
      password: brokerConfig.password,
    );

    // 2. 加载已注册打印机
    final saved = await PrinterRegistry.loadAll();
    store.loadFromRegistry(saved);

    // 3. 启动监控
    connectionMonitor.start();
  }

  /// 发现局域网打印机
  Future<List<DiscoveredRaw>> discover({String? subnet}) async {
    final mdns = await discovery.discoverMdns();
    final s = subnet ?? '192.168.1';
    final tcp = await discovery.discoverTcp(subnet: s);
    return PrinterDiscovery.merge(mdns, tcp);
  }

  /// 打印机入网
  Future<({bool success, String sn, Source source})> onboard({
    required String ip,
    required int port,
    required String accessCode,
    required BrokerConfig brokerConfig,
    String? apiKey,
  }) async {
    // 1. 验证 Access Code — 通过 GET /server/info 验证可达性
    try {
      final response = await http.get(
        Uri.parse('http://$ip:$port/server/info'),
        headers: apiKey != null ? {'X-Api-Key': apiKey} : {},
      ).timeout(Duration(seconds: 10));
      if (response.statusCode != 200) {
        return (success: false, sn: '', source: Source.http);
      }
      final json = jsonDecode(response.body);
      final sn = json['result']?['instance_name'] as String? ?? '';

      // 2. 生成打印机凭据
      final mqttPassword = CredentialStore.generatePrinterPassword(sn);
      final mqttUsername = 'printer_$sn';

      // 3. 推送 MQTT 配置
      final (pushSuccess, source) = await configPusher.push(
        ip: ip,
        port: port,
        sn: sn,
        brokerHost: brokerConfig.host,
        brokerPort: brokerConfig.port,
        mqttUsername: mqttUsername,
        mqttPassword: mqttPassword,
        apiKey: apiKey,
      );

      // 4. 注册到系统
      store.onPrinterRegistered(PrinterInfo(
        sn: sn,
        ip: ip,
        port: port,
        sourceName: source == Source.mqtt ? 'mqtt' : 'http',
      ));

      // 5. 如果是 HTTP 降级，加入 HttpPoller
      if (source == Source.http) {
        httpPoller.addPrinter(sn, ip, port: port, apiKey: apiKey);
        httpPoller.start();
      }

      // 6. 持久化
      await PrinterRegistry.save(store.exportToRegistry());

      return (success: pushSuccess, sn: sn, source: source);
    } catch (e) {
      return (success: false, sn: '', source: Source.http);
    }
  }

  Future<void> shutdown() async {
    connectionMonitor.stop();
    httpPoller.stop();
    await brokerConnMgr.disconnect();
    await PrinterRegistry.save(store.exportToRegistry());
  }
}
```

需要添加 import:
```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
```

### Step 7.5: Commit

```bash
git add -A
git commit -m "feat: FarmHub + CredentialStore + PrinterRegistry + FarmConnectionMonitor"
```

---

## Task 8: 初始 UI — Dashboard + PrinterCard + StatsBar

**目标:** 创建最小可用的主界面。

### Step 8.1: 实现 PrinterCard

创建 `lib/features/farm/presentation/widgets/printer_card.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/farm_printer_state.dart';
import '../../data/printer_info.dart';

class PrinterCard extends ConsumerWidget {
  final FarmPrinterState printer;
  final bool isSelected;
  final VoidCallback onTap;

  const PrinterCard({
    super.key,
    required this.printer,
    this.isSelected = false,
    required this.onTap,
  });

  Color get _statusColor {
    if (!printer.isOnline) return Colors.grey;
    switch (printer.printState?.value) {
      case 'printing': return Colors.blue;
      case 'paused':   return Colors.orange;
      case 'complete': return Colors.green;
      case 'error':    return Colors.red;
      default:         return Colors.green.shade300;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        color: isSelected ? Colors.blue.shade50 : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Row 1: name + connection badge
              Row(children: [
                if (isSelected)
                  const Icon(Icons.check_circle, color: Colors.blue, size: 18),
                Expanded(
                  child: Text(
                    printer.displayName ?? printer.sn,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ConnectionBadge(source: printer.source),
              ]),
              const SizedBox(height: 8),
              // Row 2: status indicator
              Row(children: [
                Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(color: _statusColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(printer.printState?.display((s) {
                  switch (s) {
                    case 'standby':  return '待机';
                    case 'printing': return '打印中';
                    case 'paused':   return '暂停';
                    case 'complete': return '完成';
                    case 'error':    return '错误';
                    default:         return s;
                  }
                }) ?? '离线'),
              ]),
              const SizedBox(height: 8),
              // Row 3: temperatures
              Row(children: [
                const Icon(Icons.thermostat, size: 14),
                Text(printer.nozzleTemp?.display((t) => '${t.toStringAsFixed(1)}°C') ?? '--'),
                const SizedBox(width: 8),
                Text(printer.bedTemp?.display((t) => '🛏 ${t.toStringAsFixed(1)}°C') ?? '--'),
              ]),
              // Row 4: progress (printing only)
              if (printer.isPrinting && printer.progress != null) ...[
                const SizedBox(height: 4),
                Text(printer.currentFile?.value ?? '', overflow: TextOverflow.ellipsis),
                LinearProgressIndicator(value: printer.progress!.value),
                Text('${(printer.progress!.value * 100).toStringAsFixed(1)}%'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ConnectionBadge extends StatelessWidget {
  final Source source;
  const ConnectionBadge({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    final isMqtt = source == Source.mqtt;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isMqtt ? Colors.green.shade100 : Colors.orange.shade100,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isMqtt ? 'MQTT' : 'HTTP',
        style: TextStyle(
          fontSize: 10, fontWeight: FontWeight.bold,
          color: isMqtt ? Colors.green.shade800 : Colors.orange.shade800,
        ),
      ),
    );
  }
}
```

### Step 8.2: 实现 StatsBar

创建 `lib/features/farm/presentation/widgets/stats_bar.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../application/providers/farm_stats_provider.dart';

class StatsBar extends ConsumerWidget {
  const StatsBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(farmStatsProvider);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _StatChip('总数', stats.total.toString(), Colors.grey),
          _StatChip('在线', stats.online.toString(), Colors.green),
          _StatChip('打印中', stats.printing.toString(), Colors.blue),
          _StatChip('MQTT', stats.mqttCount.toString(), Colors.green.shade700),
          _StatChip('HTTP', stats.httpCount.toString(), Colors.orange),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatChip(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
      Text(label, style: const TextStyle(fontSize: 12)),
    ]);
  }
}
```

### Step 8.3: 实现 PrinterGrid

创建 `lib/features/farm/presentation/widgets/printer_grid.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../application/providers/printer_list_provider.dart';
import 'printer_card.dart';

class PrinterGrid extends ConsumerStatefulWidget {
  const PrinterGrid({super.key});

  @override
  ConsumerState<PrinterGrid> createState() => _PrinterGridState();
}

class _PrinterGridState extends ConsumerState<PrinterGrid> {
  final _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    final printers = ref.watch(printerListProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = (constraints.maxWidth / 200).floor().clamp(1, 6);
        return GridView.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 1.0,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: printers.length,
          itemBuilder: (context, index) {
            final printer = printers[index];
            return PrinterCard(
              printer: printer,
              isSelected: _selected.contains(printer.sn),
              onTap: () => setState(() {
                if (_selected.contains(printer.sn)) {
                  _selected.remove(printer.sn);
                } else {
                  _selected.add(printer.sn);
                }
              }),
            );
          },
        );
      },
    );
  }
}
```

### Step 8.4: 实现 BrokerStatusIndicator

创建 `lib/features/farm/presentation/widgets/broker_status_indicator.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../application/providers/broker_state_provider.dart';

class BrokerStatusIndicator extends ConsumerWidget {
  const BrokerStatusIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(brokerStateProvider);

    final (color, label) = switch (state) {
      BrokerConnState.connected    => (Colors.green, '已连接'),
      BrokerConnState.connecting   => (Colors.orange, '连接中'),
      BrokerConnState.disconnected => (Colors.grey, '断开'),
      BrokerConnState.degraded     => (Colors.red.shade300, '降级'),
      BrokerConnState.error        => (Colors.red, '错误'),
    };

    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 10, height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text('Broker: $label', style: const TextStyle(fontSize: 12)),
    ]);
  }
}
```

### Step 8.5: 实现 FarmDashboardPage

创建 `lib/features/farm/presentation/pages/farm_dashboard_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/printer_grid.dart';
import '../widgets/stats_bar.dart';
import '../widgets/broker_status_indicator.dart';

class FarmDashboardPage extends ConsumerWidget {
  const FarmDashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lava Farm'),
        actions: const [
          BrokerStatusIndicator(),
          SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          const StatsBar(),
          const Divider(height: 1),
          const Expanded(child: PrinterGrid()),
        ],
      ),
    );
  }
}
```

### Step 8.6: 更新 main.dart

修改 `lib/main.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'features/farm/presentation/pages/farm_dashboard_page.dart';
import 'features/farm/data/printer_info.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  Hive.registerAdapter(PrinterInfoAdapter());
  runApp(const ProviderScope(child: LavaFarmApp()));
}

class LavaFarmApp extends StatelessWidget {
  const LavaFarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lava Farm',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const FarmDashboardPage(),
    );
  }
}
```

### Step 8.7: 验证

```bash
flutter run -d macos
```

预期: 显示 Dashboard，统计栏显示 0/0/0/0/0。

### Step 8.8: Commit

```bash
git add -A
git commit -m "feat: Dashboard UI (PrinterCard, StatsBar, PrinterGrid, BrokerStatus)"
```

---

## Task 9: Broker 设置页 + 快速体验模式

**目标:** Broker 连接配置 UI + 内嵌 Mosquitto 评估模式。

### Step 9.1: 实现 BrokerSetupPage

创建 `lib/features/farm/presentation/pages/broker_setup_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../application/providers/broker_state_provider.dart';

class BrokerSetupPage extends ConsumerStatefulWidget {
  const BrokerSetupPage({super.key});

  @override
  ConsumerState<BrokerSetupPage> createState() => _BrokerSetupPageState();
}

class _BrokerSetupPageState extends ConsumerState<BrokerSetupPage> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '1883');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Broker 设置')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _hostController,
              decoration: const InputDecoration(labelText: 'Broker 地址', hintText: '192.168.1.100'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(labelText: '端口'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: '密码'),
              obscureText: true,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('连接'),
            ),
          ],
        ),
      ),
    );
  }
}
```

### Step 9.2: 实现 DeploymentModeBanner

创建 `lib/features/farm/presentation/widgets/deployment_mode_banner.dart`:

```dart
import 'package:flutter/material.dart';

class DeploymentModeBanner extends StatelessWidget {
  final bool isEmbedded;

  const DeploymentModeBanner({super.key, required this.isEmbedded});

  @override
  Widget build(BuildContext context) {
    if (!isEmbedded) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.orange.shade100,
      child: const Row(children: [
        Icon(Icons.warning_amber, size: 16, color: Colors.orange),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            '评估模式 — 关闭应用将断开所有打印机',
            style: TextStyle(fontSize: 12, color: Colors.orange),
          ),
        ),
      ]),
    );
  }
}
```

### Step 9.3: Commit

```bash
git add -A
git commit -m "feat: BrokerSetupPage + DeploymentModeBanner"
```

---

## Task 10: DiscoveryWizardPage + 入网流程 UI

### Step 10.1: 实现 DiscoveryWizardPage

创建 `lib/features/farm/presentation/pages/discovery_wizard_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../application/providers/discovery_provider.dart';
import '../widgets/discovery_result_list.dart';

class DiscoveryWizardPage extends ConsumerStatefulWidget {
  const DiscoveryWizardPage({super.key});

  @override
  ConsumerState<DiscoveryWizardPage> createState() => _DiscoveryWizardPageState();
}

class _DiscoveryWizardPageState extends ConsumerState<DiscoveryWizardPage> {
  int _step = 0;
  final _accessCodeController = TextEditingController(text: '12345678');

  @override
  void dispose() {
    _accessCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('添加打印机')),
      body: Stepper(
        currentStep: _step,
        onStepContinue: () {
          if (_step < 2) {
            setState(() => _step++);
            if (_step == 1) {
              ref.read(discoveryProvider.notifier).startScan();
              // 触发实际扫描 — 由 FarmHub.discover() 驱动
            }
          } else {
            Navigator.pop(context);
          }
        },
        onStepCancel: () {
          if (_step > 0) setState(() => _step--);
        },
        steps: [
          Step(
            title: const Text('选择发现方式'),
            content: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.wifi_find),
                  title: const Text('mDNS 扫描'),
                  subtitle: const Text('快速发现 Moonraker 服务'),
                  onTap: () {},
                ),
                ListTile(
                  leading: const Icon(Icons.search),
                  title: const Text('TCP 端口扫描'),
                  subtitle: const Text('扫描子网 :7125 端口（较慢）'),
                  onTap: () {},
                ),
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('手动输入 IP'),
                  subtitle: const Text('直接输入打印机 IP 地址'),
                  onTap: () {},
                ),
              ],
            ),
            isActive: _step >= 0,
          ),
          Step(
            title: const Text('扫描结果'),
            content: const DiscoveryResultList(),
            isActive: _step >= 1,
          ),
          Step(
            title: const Text('输入 Access Code'),
            content: TextField(
              controller: _accessCodeController,
              decoration: const InputDecoration(
                labelText: 'Access Code',
                hintText: '默认: 12345678',
              ),
            ),
            isActive: _step >= 2,
          ),
        ],
      ),
    );
  }
}
```

### Step 10.2: 实现 DiscoveryResultList

创建 `lib/features/farm/presentation/widgets/discovery_result_list.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../application/providers/discovery_provider.dart';

class DiscoveryResultList extends ConsumerWidget {
  const DiscoveryResultList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(discoveryProvider);

    if (state.isScanning) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.results.isEmpty) {
      return const Center(child: Text('未发现打印机'));
    }

    return ListView.builder(
      shrinkWrap: true,
      itemCount: state.results.length,
      itemBuilder: (context, index) {
        final printer = state.results[index];
        return ListTile(
          leading: const Icon(Icons.print),
          title: Text(printer.sn ?? printer.ip),
          subtitle: Text('${printer.ip}:${printer.port}'),
          onTap: () {},
        );
      },
    );
  }
}
```

### Step 10.3: Commit

```bash
git add -A
git commit -m "feat: DiscoveryWizardPage + DiscoveryResultList"
```

---

## Task 11: PrinterDetailPage + 手动控制

### Step 11.1: 实现 PrinterDetailPage

创建 `lib/features/farm/presentation/pages/printer_detail_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/farm_printer_state.dart';

class PrinterDetailPage extends ConsumerWidget {
  final String sn;

  const PrinterDetailPage({super.key, required this.sn});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 使用 select() 精确重建
    final printer = ref.watch(
      farmStoreProvider.select((state) => state[sn]),
    );

    if (printer == null) {
      return Scaffold(
        appBar: AppBar(title: Text(sn)),
        body: const Center(child: Text('打印机未找到')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(printer.displayName ?? printer.sn),
        actions: [
          ConnectionBadge(source: printer.source),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 状态
            _SectionCard(title: '状态', children: [
              _InfoRow('连接状态', printer.connectionState.name),
              _InfoRow('打印状态', printer.printState?.value ?? '--'),
              _InfoRow('当前文件', printer.currentFile?.value ?? '--'),
              _InfoRow('进度', printer.progress != null ? '${(printer.progress!.value * 100).toStringAsFixed(1)}%' : '--'),
            ]),
            const SizedBox(height: 16),
            // 温度
            _SectionCard(title: '温度', children: [
              _InfoRow('喷嘴', printer.nozzleTemp?.display((t) => '${t.toStringAsFixed(1)}°C') ?? '--'),
              _InfoRow('热床', printer.bedTemp?.display((t) => '${t.toStringAsFixed(1)}°C') ?? '--'),
            ]),
            const SizedBox(height: 16),
            // 累计
            _SectionCard(title: '累计', children: [
              _InfoRow('总打印时间', '${(printer.totalDuration ?? 0) ~/ 3600}h ${((printer.totalDuration ?? 0) % 3600) ~/ 60}m'),
              _InfoRow('耗材用量', '${(printer.filamentUsed ?? 0).toStringAsFixed(1)}m'),
            ]),
            const SizedBox(height: 16),
            // 手动控制
            _SectionCard(title: '手动控制', children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                ElevatedButton(onPressed: () {}, child: const Text('暂停')),
                ElevatedButton(onPressed: () {}, child: const Text('取消')),
                ElevatedButton(onPressed: () {}, child: const Text('归零')),
              ]),
            ]),
            const SizedBox(height: 16),
            // 快照历史
            if (printer.snapshots.isNotEmpty) ...[
              _SectionCard(title: '快照历史 (最近 ${printer.snapshots.length})', children: [
                ...printer.snapshots.reversed.take(5).map((s) => ListTile(
                  dense: true,
                  title: Text(s.reason, style: const TextStyle(fontSize: 12)),
                  subtitle: Text(s.timestamp.toString().substring(11, 19), style: const TextStyle(fontSize: 10)),
                )),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SectionCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value),
        ],
      ),
    );
  }
}
```

注意：需要在文件头部添加 import:
```dart
import '../../application/providers/farm_store_provider.dart';
import '../widgets/connection_badge.dart';
```

### Step 11.2: 在 PrinterCard 中集成导航

在 `printer_card.dart` 的 `onTap` 改为导航到详情页。或者在 Dashboard 中处理选中逻辑。

### Step 11.3: Commit

```bash
git add -A
git commit -m "feat: PrinterDetailPage with precise rebuild via select()"
```

---

## Task 12: 集成测试 + 端到端验证

### Step 12.1: FarmStore 集成测试

在 `test/features/farm/data/farm_store_integration_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lava_farm/features/farm/data/farm_store.dart';
import 'package:lava_farm/features/farm/data/printer_info.dart';

void main() {
  group('FarmStore Integration', () {
    test('100 printers MQTT status flood', () {
      final store = FarmStore();
      // Register 100 printers
      for (int i = 0; i < 100; i++) {
        store.onPrinterRegistered(PrinterInfo(
          sn: 'SN${i.toString().padLeft(3, '0')}',
          ip: '192.168.1.${i + 1}',
          sourceName: 'mqtt',
        ));
      }
      expect(store.count, 100);

      // Simulate 100 status updates in 1 second
      final start = DateTime.now();
      for (int i = 0; i < 100; i++) {
        store.onMqttStatus(
          'SN${i.toString().padLeft(3, '0')}',
          {'extruder.temperature': 210.0 + i * 0.1, 'print_stats.state': 'printing'},
          eventTime: DateTime.now(),
        );
      }
      final elapsed = DateTime.now().difference(start);
      expect(elapsed.inMilliseconds, lessThan(500)); // Should process in < 500ms
      expect(store.printingCount, 100);
    });
  });
}
```

### Step 12.2: 运行全部测试

```bash
flutter test
```

预期: 所有测试 PASS。

### Step 12.3: 验证 Flutter 构建

```bash
flutter build macos --debug
```

预期: 构建成功。

### Step 12.4: Commit

```bash
git add -A
git commit -m "test: FarmStore 100-printer stress test + integration"
```

---

## 验证清单

在所有 Task 完成后，逐项验证：

- [ ] `flutter test` — 全部测试通过
- [ ] `flutter run -d macos` — 应用启动显示 Dashboard
- [ ] Dashboard 统计栏显示初始状态（0/0/0/0/0）
- [ ] Broker 状态指示器显示正确的连接状态
- [ ] 打印机注册 → FarmStore 更新 → UI 刷新
- [ ] MQTT 消息到达 → 打印机卡片实时更新温度/进度
- [ ] 打印机断电 → 卡片变灰 + 温度显示 "--"
- [ ] 批量暂停/取消 命令发送 + 结果聚合
- [ ] HTTP 降级打印机卡片显示橙色 HTTP badge
- [ ] `probeSingle` 即时确认 HTTP 命令结果
- [ ] 100 台打印机 MQTT 模拟 — UI 无卡顿
- [ ] App 重启后从 Hive 恢复打印机列表

---

## 计划总结

| 项目 | 数据 |
|------|------|
| 总 Task 数 | 12 |
| 新建文件数 | ~35 |
| 关键数据类 | Staleable, FarmSnapshot, FarmPrinterState, PrinterInfo, BatchResult |
| 关键服务类 | FarmStore, FarmMqttRouter, BrokerConnectionManager, BatchOperator, HttpPoller, ConfigPushService, FileUploader |
| 关键 UI 页面 | FarmDashboardPage, PrinterDetailPage, DiscoveryWizardPage, BrokerSetupPage |
| 关键 Provider | farmStoreProvider, brokerStateProvider, discoveryProvider, printerListProvider, farmStatsProvider, batchOperationProvider |

/// 打印机连接监控 + Broker 健康监控
///
/// T8.1: FarmConnectionMonitor — 检测打印机假在线
/// T8.2: BrokerHealthMonitor — Broker 假活检测
///
/// 故障检测矩阵:
///   打印机断电          Last Will offline         1-3s
///   打印机 MQTT 断连     Last Will offline         1-3s
///   打印机假在线        60s 无状态更新             60s
///   Broker 崩溃         BrokerHealthMonitor       < 15s
///   Broker 假活         MQTT PINGREQ 无响应       15-45s

import 'dart:async';

/// 农场连接状态更新回调
typedef OnPrinterOffline = void Function(String sn, String reason);
typedef OnBrokerUnhealthy = void Function();

/// 打印机连接监控器
///
/// 职责:
/// - 每 30s 检查所有在线打印机的 lastStatusTime
/// - 超过 60s 无更新 → forceOffline
/// - 配合 Moonraker Last Will 遗嘱消息（1-3s 延迟）
class FarmConnectionMonitor {
  final OnPrinterOffline _onForceOffline;
  Timer? _timer;

  /// 打印机最后状态时间: Map<sn, lastStatusTime>
  final Map<String, DateTime> _lastStatusTimes = {};

  static const _checkInterval = Duration(seconds: 30);
  static const _heartbeatTimeout = Duration(seconds: 60);

  FarmConnectionMonitor({required OnPrinterOffline onForceOffline})
      : _onForceOffline = onForceOffline;

  /// 添加/更新打印机的最后状态时间
  void heartbeat(String sn) {
    _lastStatusTimes[sn] = DateTime.now();
  }

  /// 移除打印机（下线或取消注册时）
  void remove(String sn) {
    _lastStatusTimes.remove(sn);
  }

  /// 开始周期性检测
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(_checkInterval, (_) => _checkAll());
  }

  /// 停止检测
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 检查所有打印机的最后心跳时间
  void _checkAll() {
    final now = DateTime.now();
    final toRemove = <String>[];

    for (final entry in _lastStatusTimes.entries) {
      final elapsed = now.difference(entry.value);
      if (elapsed > _heartbeatTimeout) {
        _onForceOffline(entry.key, 'heartbeat_timeout_${elapsed.inSeconds}s');
        toRemove.add(entry.key);
      }
    }

    for (final sn in toRemove) {
      _lastStatusTimes.remove(sn);
    }
  }

  void dispose() {
    stop();
  }
}

/// Broker 健康监控器
///
/// 职责:
/// - 每 15s 调用 BrokerConnectionManager.ping()
/// - 连续 3 次失败 → 判定 Broker 假活
/// - 通知 UI + 触发 BrokerConnectionManager 重连
class BrokerHealthMonitor {
  final Future<bool> Function() _pingFn;
  final OnBrokerUnhealthy _onUnhealthy;
  final void Function(int consecutiveFailures)? _onFailure;

  Timer? _timer;
  int _consecutiveFailures = 0;

  static const _pingInterval = Duration(seconds: 15);
  static const _maxConsecutiveFailures = 3;

  /// 当前连续失败次数（只读）
  int get consecutiveFailures => _consecutiveFailures;

  /// 当前健康状态
  bool get isHealthy => _consecutiveFailures < _maxConsecutiveFailures;

  BrokerHealthMonitor({
    required Future<bool> Function() pingFn,
    required OnBrokerUnhealthy onUnhealthy,
    void Function(int consecutiveFailures)? onFailure,
  })  : _pingFn = pingFn,
        _onUnhealthy = onUnhealthy,
        _onFailure = onFailure;

  /// 开始周期性健康检测
  void start() {
    _timer?.cancel();
    _consecutiveFailures = 0;
    _timer = Timer.periodic(_pingInterval, (_) => _check());
  }

  /// 停止检测（断开连接时调用）
  void stop() {
    _timer?.cancel();
    _timer = null;
    _consecutiveFailures = 0;
  }

  /// 重置失败计数（重连成功时调用）
  void reset() {
    _consecutiveFailures = 0;
  }

  /// 执行单次健康检测
  Future<void> _check() async {
    try {
      final success = await _pingFn();
      if (success) {
        _consecutiveFailures = 0;
      } else {
        _onPingFailed();
      }
    } catch (_) {
      _onPingFailed();
    }
  }

  void _onPingFailed() {
    _consecutiveFailures++;
    _onFailure?.call(_consecutiveFailures);

    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      _onUnhealthy();
    }
  }

  void dispose() {
    stop();
  }
}

/// Broker 健康状态（用于 UI）
enum BrokerHealthState {
  healthy,
  degraded, // 1-2 次连续失败
  unhealthy, // ≥3 次连续失败
  unknown,   // 尚未开始检测
}

extension BrokerHealthStateDisplay on BrokerHealthState {
  String get label {
    switch (this) {
      case BrokerHealthState.healthy:   return '健康';
      case BrokerHealthState.degraded:  return '降级';
      case BrokerHealthState.unhealthy: return '异常';
      case BrokerHealthState.unknown:   return '未知';
    }
  }
}

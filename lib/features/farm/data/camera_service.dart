/// CameraService — 摄像头监控服务
///
/// 混合方式：
///   MQTT camera.start_monitor  → 激活打印机摄像头
///   HTTP GET {streamUrl}       → MJPEG 长连接流（MjpegView 渲染）
///   MQTT camera.stop_monitor   → 停止摄像头
///
/// 由于 Moonraker MQTT handler 对 camera 命令不返回响应，
/// startMonitor 采用 fire-and-forget 方式发送命令，
/// 然后由 MjpegView 通过 HTTP 长连接解析 multipart/x-mixed-replace 流。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'farm_mqtt_router.dart';

class CameraStartResult {
  final bool success;
  final String? frameUrl;   // 快照 URL（轮询方案，已废弃，保留兼容）
  final String? streamUrl;  // MJPEG 流 URL（长连接方案）
  final String? error;

  const CameraStartResult({
    required this.success,
    this.frameUrl,
    this.streamUrl,
    this.error,
  });
}

class CameraService {
  final FarmMqttRouter _router;
  final HttpClient _httpClient = HttpClient();

  final Set<String> _activeMonitors = {};

  CameraService({required FarmMqttRouter router}) : _router = router;

  bool isMonitoring(String sn) => _activeMonitors.contains(sn);

  /// 开启摄像头
  ///
  /// 1. MQTT 发送 camera.start_monitor（fire-and-forget，不等响应）
  /// 2. 返回帧 URL: http://{ip}:{port}/server/files/camera/monitor.jpg
  Future<CameraStartResult> startMonitor({
    required String sn,
    required String ip,
    int port = 7125,
  }) async {
    if (_activeMonitors.contains(sn)) {
      return CameraStartResult(
        success: true,
        frameUrl: _buildFrameUrl(ip, port),
        streamUrl: _buildStreamUrl(ip, port),
      );
    }

    debugPrint('[CameraService] MQTT camera.start_monitor → $sn');

    // 发送命令（不等待响应，因为 Moonraker MQTT 不返回 camera 响应）
    unawaited(_router.sendCommand(
      sn,
      'camera.start_monitor',
      {
        'domain': 'lan',
        'interval': 0,
        'expect_pw': false,
        'clientid': 'lava-farm-$sn',
      },
    ));

    // 短暂延迟让打印机处理命令
    await Future<void>.delayed(const Duration(milliseconds: 500));

    _activeMonitors.add(sn);
    final frameUrl = _buildFrameUrl(ip, port);
    final streamUrl = _buildStreamUrl(ip, port);
    debugPrint('[CameraService] $sn: 帧 URL = $frameUrl, 流 URL = $streamUrl');
    return CameraStartResult(success: true, frameUrl: frameUrl, streamUrl: streamUrl);
  }

  /// 停止摄像头
  Future<void> stopMonitor({
    required String sn,
    required String ip,
    int port = 7125,
  }) async {
    if (!_activeMonitors.contains(sn)) return;

    debugPrint('[CameraService] MQTT camera.stop_monitor → $sn');

    unawaited(_router.sendCommand(
      sn,
      'camera.stop_monitor',
      {
        'domain': 'lan',
        'clientid': 'lava-farm-$sn',
      },
    ));

    _activeMonitors.remove(sn);
  }

  /// 构造帧图片 URL（LAN 模式，来自 lava_app 实现）
  /// 格式: http://{ip}:{port}/server/files/camera/monitor.jpg
  String _buildFrameUrl(String ip, int port) {
    return 'http://$ip:$port/server/files/camera/monitor.jpg';
  }

  /// 构造 MJPEG 流 URL
  /// 格式: http://{ip}:{port}/webcam/stream
  String _buildStreamUrl(String ip, int port) {
    return 'http://$ip:$port/webcam/stream';
  }

  /// 通过 MQTT machine.system_info 获取设备真实 LAN IP
  ///
  /// 返回 IP 地址，失败返回 null。
  Future<String?> resolveDeviceIp(String sn) async {
    try {
      final result = await _router.sendCommand(sn, 'machine.system_info');
      if (!result.success || result.data == null) return null;

      final sysInfo = result.data!['system_info'] as Map<String, dynamic>?;
      final network = sysInfo?['network'] as Map<String, dynamic>?;
      if (network == null) return null;

      for (final entry in network.entries) {
        final iface = entry.value as Map<String, dynamic>?;
        final addresses = iface?['ip_addresses'] as List?;
        if (addresses == null) continue;

        for (final addr in addresses) {
          if (addr is Map<String, dynamic> &&
              addr['family'] == 'ipv4' &&
              addr['is_link_local'] != true) {
            final ip = addr['address'] as String?;
            if (ip != null && ip != '127.0.0.1') {
              _router.ipCache[sn] = ip; // 同步更新缓存
              return ip;
            }
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _httpClient.close();
    _activeMonitors.clear();
  }
}

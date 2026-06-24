/// 打印机发现服务
///
/// T2.1 + T2.2: 局域网打印机发现
///
/// 双重发现策略:
///   1. mDNS 扫描 _moonraker._tcp.local (5s 超时)
///   2. TCP 端口扫描 192.168.x.0/24:7125 (50 并发, 500ms 超时)
///   3. 合并去重
///
/// 注意: TCP 扫描对网络有一定冲击，仅在 mDNS 无法覆盖时作为补充。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 发现的打印机信息
class DiscoveredPrinter {
  /// 序列号（来自 Moonraker /server/info 的 instance_name）
  final String? sn;

  final String ip;
  final int port;

  /// 主机名（来自 mDNS）
  final String? hostname;

  /// 型号（来自 /server/info）
  final String? model;

  /// 固件版本
  final String? firmwareVersion;

  /// Klipper 是否已连接
  final bool? klippyConnected;

  /// 发现来源
  final DiscoverySource source;

  const DiscoveredPrinter({
    this.sn,
    required this.ip,
    this.port = 7125,
    this.hostname,
    this.model,
    this.firmwareVersion,
    this.klippyConnected,
    required this.source,
  });

  /// 唯一标识（优先用 SN，否则 IP:port）
  String get id => sn ?? '$ip:$port';

  /// 显示名称
  String get displayName {
    if (hostname != null && hostname!.isNotEmpty) return hostname!;
    if (sn != null) return sn!;
    return ip;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredPrinter && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// 发现来源
enum DiscoverySource { mdns, tcp, manual, csvImport }

/// 打印机发现器
class PrinterDiscovery {
  static const int _moonrakerPort = 7125;
  static const Duration _mdnsTimeout = Duration(seconds: 5);
  static const Duration _tcpTimeout = Duration(milliseconds: 500);
  static const int _tcpConcurrency = 50;

  // ═══════════════════════════════════════════════════════════
  // mDNS 发现
  // ═══════════════════════════════════════════════════════════

  /// 通过 mDNS 发现局域网内的 Moonraker 打印机
  ///
  /// 服务类型: _moonraker._tcp.local
  /// 超时时间: 5 秒
  ///
  /// 注意: mDNS 在部分 Windows 版本和受限网络环境下不可用，
  /// 需要配合 TCP 扫描作为降级方案。
  Future<List<DiscoveredPrinter>> discoverMdns({
    Duration timeout = _mdnsTimeout,
  }) async {
    final printers = <DiscoveredPrinter>[];

    try {
      // mDNS 需要平台支持。macOS 上可用 multicast_dns 包。
      // 此处为实现框架，实际需集成 multicast_dns 或 bonsoir 包。

      // TODO: 集成 multicast_dns / bonsoir
      // final client = MDnsClient();
      // await client.start();
      //
      // await for (final PtrResourceRecord ptr in client.lookup<PtrResourceRecord>(
      //   ResourceRecordQuery.serverPointer('_moonraker._tcp.local'),
      // )) {
      //   final service = ptr.domainName;
      //   await for (final SrvResourceRecord srv in client.lookup<SrvResourceRecord>(
      //     ResourceRecordQuery.service(service),
      //   )) {
      //     printers.add(DiscoveredPrinter(
      //       hostname: service,
      //       ip: srv.target,
      //       port: srv.port,
      //       source: DiscoverySource.mdns,
      //     ));
      //   }
      // }
      //
      // await client.stop();
    } catch (_) {
      // mDNS 不可用，静默回退到 TCP 扫描
    }

    return printers;
  }

  // ═══════════════════════════════════════════════════════════
  // TCP 端口扫描
  // ═══════════════════════════════════════════════════════════

  /// 通过 TCP 扫描 LAN 子网发现打印机
  ///
  /// 扫描 192.168.x.2 ~ 192.168.x.254 上端口 7125，
  /// 尝试 HTTP GET /server/info 获取设备信息。
  ///
  /// [subnet] 格式: "192.168.1"（不含 .0）
  /// [concurrency] 并发连接数（默认 50）
  Future<List<DiscoveredPrinter>> discoverTcp({
    required String subnet,
    int port = _moonrakerPort,
    int startIp = 2,
    int endIp = 254,
    int concurrency = _tcpConcurrency,
    Duration timeout = _tcpTimeout,
  }) async {
    final printers = <DiscoveredPrinter>[];
    final ips = List.generate(
      endIp - startIp + 1,
      (i) => '$subnet.${startIp + i}',
    );

    // 并发控制：使用信号量限制并发数
    final semaphore = Semaphore(concurrency);

    final futures = ips.map((ip) async {
      await semaphore.acquire();
      try {
        final printer = await _probeIp(ip, port, timeout);
        if (printer != null) {
          printers.add(printer);
        }
      } finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
    return printers;
  }

  /// 探测单个 IP
  Future<DiscoveredPrinter?> _probeIp(
    String ip,
    int port,
    Duration timeout,
  ) async {
    try {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: timeout,
      );
      socket.destroy();

      // 连接成功 → 获取设备信息
      try {
        final client = HttpClient();
        client.connectionTimeout = timeout;
        final request = await client.getUrl(
          Uri.parse('http://$ip:$port/server/info'),
        );
        final response = await request.close().timeout(timeout);

        if (response.statusCode == 200) {
          // 解析 JSON 响应获取 SN 和型号
          // {
          //   "result": {
          //     "klippy_connected": true,
          //     "instance_name": "8110026B060740017",
          //     ...
          //   }
          // }
          final body = await response.transform(utf8.decoder).join();
          // 简单字符串解析（避免依赖完整 JSON 解析用于发现阶段）
          final sn = _extractJsonString(body, 'instance_name');
          final model = _extractJsonString(body, 'model');
          final version = _extractJsonString(body, 'version');
          final klippyConnected = _extractJsonBool(body, 'klippy_connected');

          return DiscoveredPrinter(
            sn: sn,
            ip: ip,
            port: port,
            model: model,
            firmwareVersion: version,
            klippyConnected: klippyConnected,
            source: DiscoverySource.tcp,
          );
        }
      } catch (_) {
        // HTTP 请求失败（可能不是 Moonraker 或网络错误）
      }

      // TCP 端口开放但 HTTP 不可达 → 仍返回基础信息
      return DiscoveredPrinter(
        ip: ip,
        port: port,
        source: DiscoverySource.tcp,
      );
    } on SocketException {
      // 端口不可达
      return null;
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 合并去重
  // ═══════════════════════════════════════════════════════════

  /// 合并 mDNS 和 TCP 扫描结果，按 id 去重
  ///
  /// 优先级: mDNS > TCP（mDNS 携带更多信息如 hostname）
  static List<DiscoveredPrinter> merge(
    List<DiscoveredPrinter> mdns,
    List<DiscoveredPrinter> tcp,
  ) {
    final merged = <String, DiscoveredPrinter>{};

    // 先放 TCP 结果（优先级低）
    for (final p in tcp) {
      merged[p.id] = p;
    }

    // 再放 mDNS 结果（优先级高，覆盖同 id）
    for (final p in mdns) {
      merged[p.id] = p;
    }

    return merged.values.toList()
      ..sort((a, b) => a.ip.compareTo(b.ip));
  }

  // ═══════════════════════════════════════════════════════════
  // 按 SN 反查 IP（解决 MQTT 自动发现后 IP 缺失问题）
  // ═══════════════════════════════════════════════════════════

  /// 子网扫描 + /server/info SN 匹配，返回打印机 IP
  ///
  /// 用于 MQTT 自动发现后只知道 SN 不知道 IP 的场景。
  /// 原理: 并发扫描 192.168.x.2~254:7125，逐台调 /server/info，
  /// 匹配 instance_name 后立即返回，不继续扫描。
  ///
  /// 返回 IP 地址，未找到返回 null。
  static Future<String?> resolveIpBySn(
    String sn, {
    int port = _moonrakerPort,
    int concurrency = _tcpConcurrency,
    Duration tcpTimeout = _tcpTimeout,
    Duration httpTimeout = const Duration(seconds: 3),
  }) async {
    final subnet = await detectSubnet();
    if (subnet == null) return null;

    final ips = List.generate(253, (i) => '$subnet.${i + 2}');
    final semaphore = Semaphore(concurrency);
    String? result;
    bool found = false;

    final futures = ips.map((ip) async {
      if (found) return;
      await semaphore.acquire();
      if (found) { semaphore.release(); return; }
      try {
        // TCP 快速探测端口
        final socket = await Socket.connect(ip, port, timeout: tcpTimeout);
        socket.destroy();

        // 端口开放 → 调 /server/info 查 instance_name
        try {
          final client = HttpClient();
          client.connectionTimeout = httpTimeout;
          final request = await client.getUrl(
            Uri.parse('http://$ip:$port/server/info'),
          );
          final response = await request.close().timeout(httpTimeout);

          if (response.statusCode == 200) {
            final body = await response.transform(utf8.decoder).join();
            final instanceName = _extractJsonString(body, 'instance_name');
            if (instanceName == sn) {
              result = ip;
              found = true;
            }
          }
          client.close();
        } catch (_) {}
      } on SocketException {
        // 端口不可达
      } catch (_) {} finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
    return result;
  }

  // ═══════════════════════════════════════════════════════════
  // 子网检测
  // ═══════════════════════════════════════════════════════════

  /// 自动检测局域网子网
  ///
  /// 从本机网络接口中检测出最可能的 LAN 子网（如 192.168.1）。
  /// 排除 loopback (127.x) 和 link-local (169.254.x)。
  static Future<String?> detectSubnet() async {
    try {
      for (final interface in await NetworkInterface.list()) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4) {
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              final first = int.parse(parts[0]);
              final second = int.parse(parts[1]);
              // 排除 loopback 和 link-local
              if (first == 127 || (first == 169 && second == 254)) continue;
              // 返回 192.168.1 格式的子网前缀
              return '${parts[0]}.${parts[1]}.${parts[2]}';
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ═══════════════════════════════════════════════════════════
  // JSON 辅助（轻量解析，避免引入完整 JSON 库到发现层）
  // ═══════════════════════════════════════════════════════════

  static String? _extractJsonString(String json, String key) {
    final pattern = RegExp('"$key"\\s*:\\s*"([^"]*)"');
    final match = pattern.firstMatch(json);
    return match?.group(1);
  }

  static bool? _extractJsonBool(String json, String key) {
    final pattern = RegExp('"$key"\\s*:\\s*(true|false)');
    final match = pattern.firstMatch(json);
    final val = match?.group(1);
    if (val == 'true') return true;
    if (val == 'false') return false;
    return null;
  }
}

/// 简单信号量实现（避免额外依赖）
class Semaphore {
  int _permits;
  final List<Completer<void>> _waiters = [];

  Semaphore(int maxPermits) : _permits = maxPermits;

  Future<void> acquire() async {
    if (_permits > 0) {
      _permits--;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
    _permits--;
  }

  void release() {
    _permits++;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }
}

/// CameraMonitorPage — 多设备摄像头集中监控页面
///
/// 一键开启所有在线设备的摄像头，网格布局同时显示多路视频流。
/// 每张卡片叠加设备名称和 IP，定时轮询 server/files/camera/monitor.jpg。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/broker_state_provider.dart';
import '../../application/providers/printer_list_provider.dart';
import '../../data/camera_service.dart';
import '../../data/farm_printer_state.dart';

class CameraMonitorPage extends ConsumerStatefulWidget {
  const CameraMonitorPage({super.key});

  @override
  ConsumerState<CameraMonitorPage> createState() => _CameraMonitorPageState();
}

class _CameraStreamInfo {
  final String frameUrl;
  _CameraStreamInfo({required this.frameUrl});
}

class _CameraMonitorPageState extends ConsumerState<CameraMonitorPage> {
  final Map<String, _CameraStreamInfo> _cameraUrls = {};
  List<FarmPrinterState> _eligibleDevices = [];
  final Set<String> _closedSns = {};

  bool _loading = false;
  String? _error;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startAllCameras());
  }

  @override
  void dispose() {
    _disposed = true;
    // 只做清理，不调用 setState（dispose 期间禁止）
    final cameraService = ref.read(cameraServiceProvider);
    for (final device in _eligibleDevices) {
      if (_cameraUrls.containsKey(device.sn) && cameraService != null) {
        cameraService.stopMonitor(sn: device.sn, ip: device.ip, port: device.port);
      }
    }
    _cameraUrls.clear();
    super.dispose();
  }

  // ─── 摄像头生命周期 ────────────────────────────────────────────

  Future<void> _startAllCameras() async {
    if (_disposed || !mounted) return;
    final cameraService = ref.read(cameraServiceProvider);
    final router = ref.read(farmMqttRouterProvider);
    if (cameraService == null) {
      debugPrint('[CameraMonitor] cameraService is null, MQTT not connected');
      if (!_disposed) setState(() => _error = 'MQTT 未连接');
      return;
    }

    if (!_disposed) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    _cameraUrls.clear();
    _closedSns.clear();

    final printers = ref.read(printerListProvider);
    // 用缓存补充 IP：缓存里有的 SN 视为有效
    final cachedSn = router?.ipCache.keys.toSet() ?? {};
    debugPrint('[CameraMonitor] total printers: ${printers.length}, '
        'online: ${printers.where((p) => p.isOnline).length}, '
        'hasValidIp: ${printers.where((p) => p.hasValidIp || cachedSn.contains(p.sn)).length}, '
        'cachedIps: ${cachedSn.length}');

    _eligibleDevices = printers
        .where((p) => p.isOnline && (p.hasValidIp || cachedSn.contains(p.sn)))
        .toList();

    // 给没有有效 IP 但缓存命中的设备临时替换 IP
    for (final device in _eligibleDevices) {
      if (!device.hasValidIp && router?.ipCache.containsKey(device.sn) == true) {
        device.ip = router!.ipCache[device.sn]!;
      }
    }

    debugPrint('[CameraMonitor] eligible devices: ${_eligibleDevices.map((p) => "${p.sn} (${p.ip})").join(", ")}');

    if (_eligibleDevices.isEmpty) {
      if (!_disposed) {
        setState(() {
          _loading = false;
          _error = '没有可用的在线设备';
        });
      }
      return;
    }

    // 并发启动所有摄像头
    final results = await Future.wait(
      _eligibleDevices.map((p) async {
        debugPrint('[CameraMonitor] startMonitor → ${p.sn} @ ${p.ip}');
        final result = await cameraService.startMonitor(
          sn: p.sn,
          ip: p.ip,
          port: p.port,
        );
        debugPrint('[CameraMonitor] startMonitor ← ${p.sn}: success=${result.success}, frameUrl=${result.frameUrl != null}');
        if (result.success && result.frameUrl != null) {
          _cameraUrls[p.sn] = _CameraStreamInfo(
            frameUrl: result.frameUrl!,
          );
        }
        return result;
      }),
    );

    debugPrint('[CameraMonitor] done: ${_cameraUrls.length}/${_eligibleDevices.length} cameras started');

    if (_disposed || !mounted) return;
    setState(() => _loading = false);
  }

  void _stopSingleCamera(String sn) {
    final urlInfo = _cameraUrls.remove(sn);
    if (urlInfo == null) return;
    final device = _eligibleDevices.where((d) => d.sn == sn).firstOrNull;
    final cameraService = ref.read(cameraServiceProvider);
    if (cameraService != null && device != null) {
      cameraService.stopMonitor(sn: sn, ip: device.ip, port: device.port);
    }
    if (_disposed || !mounted) return;
    setState(() => _closedSns.add(sn));
  }

  void _stopAllCameras() {
    final cameraService = ref.read(cameraServiceProvider);
    for (final device in _eligibleDevices) {
      if (_cameraUrls.containsKey(device.sn) && cameraService != null) {
        cameraService.stopMonitor(
          sn: device.sn,
          ip: device.ip,
          port: device.port,
        );
      }
    }
    _cameraUrls.clear();
    _closedSns.addAll(_eligibleDevices.map((d) => d.sn));
    if (_disposed || !mounted) return;
    setState(() {});
  }

  void _resumeSingleCamera(String sn) async {
    final device = _eligibleDevices.where((d) => d.sn == sn).firstOrNull;
    if (device == null) return;
    final cameraService = ref.read(cameraServiceProvider);
    if (cameraService == null) return;

    final result = await cameraService.startMonitor(
      sn: device.sn,
      ip: device.ip,
      port: device.port,
    );
    if (_disposed || !mounted) return;
    if (result.success && result.frameUrl != null) {
      setState(() {
        _cameraUrls[sn] = _CameraStreamInfo(
          frameUrl: result.frameUrl!,
        );
        _closedSns.remove(sn);
      });
    }
  }

  // ─── 辅助 ──────────────────────────────────────────────────────

  String _deviceLabel(FarmPrinterState p) {
    if (p.displayName != null && p.displayName!.isNotEmpty) {
      return p.displayName!;
    }
    if (p.hostname != null && p.hostname!.isNotEmpty) return p.hostname!;
    return p.sn.length > 6 ? p.sn.substring(p.sn.length - 6) : p.sn;
  }

  // ─── UI ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final allPrinters = ref.watch(printerListProvider);
    final onlineCount = allPrinters.where((p) => p.isOnline && p.hasValidIp).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设备监控'),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            )
          else ...[
            if (_cameraUrls.isNotEmpty)
              TextButton.icon(
                onPressed: _stopAllCameras,
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('停止全部'),
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
              ),
            TextButton.icon(
              onPressed: _startAllCameras,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text('刷新 ($onlineCount)'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // 加载中
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在开启摄像头…'),
          ],
        ),
      );
    }

    // 错误
    if (_error != null && _cameraUrls.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Colors.grey.shade600)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _startAllCameras,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 没有可用设备
    if (_eligibleDevices.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text('没有可用设备', style: TextStyle(color: Colors.grey.shade600)),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount =
            (constraints.maxWidth / 320).floor().clamp(1, 4);
        return GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 16 / 10,
          ),
          itemCount: _eligibleDevices.length,
          itemBuilder: (context, index) {
            final device = _eligibleDevices[index];
            final urls = _cameraUrls[device.sn];
            final closed = _closedSns.contains(device.sn);
            return _CameraFeedCard(
              label: _deviceLabel(device),
              ip: device.ip,
              frameUrl: closed ? null : urls?.frameUrl,
              closed: closed,
              onClose: urls != null
                  ? () => _stopSingleCamera(device.sn)
                  : null,
              onReopen: closed
                  ? () => _resumeSingleCamera(device.sn)
                  : null,
            );
          },
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// 摄像头卡片
// ═══════════════════════════════════════════════════════════════════

class _CameraFeedCard extends StatefulWidget {
  final String label;
  final String ip;
  final String? frameUrl;
  final bool closed;
  final VoidCallback? onClose;
  final VoidCallback? onReopen;

  const _CameraFeedCard({
    required this.label,
    required this.ip,
    this.frameUrl,
    this.closed = false,
    this.onClose,
    this.onReopen,
  });

  @override
  State<_CameraFeedCard> createState() => _CameraFeedCardState();
}

class _CameraFeedCardState extends State<_CameraFeedCard> {
  Timer? _pollTimer;

  // 双缓冲
  Uint8List? _bufferA;
  Uint8List? _bufferB;
  bool _showBufferA = true;
  bool _isLoadingFrame = false;
  final HttpClient _frameHttpClient = HttpClient();

  String? get _frameUrl => widget.frameUrl;

  @override
  void initState() {
    super.initState();
    if (_frameUrl != null) _startPolling();
  }

  @override
  void didUpdateWidget(covariant _CameraFeedCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.frameUrl != oldWidget.frameUrl) {
      if (widget.frameUrl != null) {
        _startPolling();
      } else {
        _stopPolling();
      }
    }
  }

  @override
  void dispose() {
    _stopPolling();
    _frameHttpClient.close();
    super.dispose();
  }

  void _startPolling() {
    _stopPolling();
    _bufferA = null;
    _bufferB = null;
    _showBufferA = true;
    _isLoadingFrame = false;

    // 立即拉第一帧，之后每 500ms 拉一帧（双缓冲）
    _fetchNextFrame();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _fetchNextFrame();
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isLoadingFrame = false;
    _bufferA = null;
    _bufferB = null;
  }

  Future<void> _fetchNextFrame() async {
    if (_frameUrl == null || _isLoadingFrame) return;

    _isLoadingFrame = true;
    final loadIntoA = !_showBufferA;

    try {
      final uri = Uri.parse('${_frameUrl!}?ts=${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
      final request = await _frameHttpClient.getUrl(uri);
      request.headers.set('Accept', 'image/jpeg, image/png, image/*');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );

      if (response.statusCode != 200) {
        if (mounted) setState(() => _isLoadingFrame = false);
        return;
      }

      final bytes = await response.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );

      if (!mounted) return;
      if (_frameUrl == null) {
        _isLoadingFrame = false;
        return;
      }

      final imageData = Uint8List.fromList(bytes);
      setState(() {
        if (loadIntoA) {
          _bufferA = imageData;
        } else {
          _bufferB = imageData;
        }
        _showBufferA = loadIntoA;
        _isLoadingFrame = false;
      });
    } catch (e) {
      debugPrint('[CameraFeed] 帧下载失败: $e');
      if (mounted) {
        setState(() => _isLoadingFrame = false);
      }
    }
  }

  Widget _buildCameraFrame() {
    final currentImage = _showBufferA ? _bufferA : _bufferB;

    if (currentImage != null) {
      return Image.memory(
        currentImage,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => Container(
          color: Colors.grey.shade200,
          child: const Center(
            child: Icon(Icons.broken_image, size: 32, color: Colors.grey),
          ),
        ),
      );
    }

    // 首帧加载中
    return Container(
      color: Colors.grey.shade200,
      child: const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 已关闭状态
          if (widget.closed)
            Container(
              color: Colors.grey.shade900,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.videocam_off, size: 28, color: Colors.white38),
                    const SizedBox(height: 6),
                    const Text('已关闭',
                        style: TextStyle(color: Colors.white38, fontSize: 12)),
                    const SizedBox(height: 10),
                    if (widget.onReopen != null)
                      TextButton.icon(
                        onPressed: widget.onReopen,
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('重新开启', style: TextStyle(fontSize: 11)),
                        style: TextButton.styleFrom(foregroundColor: Colors.white70),
                      ),
                  ],
                ),
              ),
            )
          // 双缓冲帧显示（500ms 刷新，无闪烁）
          else if (_frameUrl != null)
            _buildCameraFrame()
          else
            Container(
              color: Colors.grey.shade200,
              child: Center(
                child: Text(
                  '无视频流',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                ),
              ),
            ),

          // 顶部设备信息叠加层
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent],
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.closed ? Icons.videocam_off : Icons.videocam,
                    size: 14,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.ip,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 关闭按钮（右上角，非关闭状态下显示）
          if (!widget.closed && widget.onClose != null)
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                onTap: widget.onClose,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, size: 14, color: Colors.white70),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

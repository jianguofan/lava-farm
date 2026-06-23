/// CameraView — 摄像头实时画面组件
///
/// 定时轮询快照 URL（LAN 100ms）+ key 驱动重建 + 交叉淡入过渡，
/// 模拟视频流效果。
///
/// 用法:
///   CameraView(
///     frameUrl: 'http://192.168.1.100:7125/webcam/snapshot',
///     isActive: true,
///   )

import 'dart:async';

import 'package:flutter/material.dart';

class CameraView extends StatefulWidget {
  final String frameUrl;
  final bool isActive;
  final Duration pollInterval;

  const CameraView({
    super.key,
    required this.frameUrl,
    required this.isActive,
    this.pollInterval = const Duration(milliseconds: 100),
  });

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView>
    with SingleTickerProviderStateMixin {
  Timer? _pollTimer;

  /// 帧计数器，用作 Image widget 的 key 来强制刷新
  int _frameCount = 0;

  /// 当前显示的 URL（带时间戳防缓存）
  String? _currentUrl;

  /// 上一帧 URL（用于交叉淡入）
  String? _previousUrl;

  /// 淡入动画
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  /// 状态
  bool _isLoading = true;
  int _consecutiveErrors = 0;
  static const int _maxErrors = 5;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.linear,
    );
    _fadeController.value = 1.0;

    if (widget.isActive) {
      _startPolling();
    }
  }

  @override
  void didUpdateWidget(CameraView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isActive && !oldWidget.isActive) {
      _startPolling();
    } else if (!widget.isActive && oldWidget.isActive) {
      _stopPolling();
    }

    if (widget.frameUrl != oldWidget.frameUrl) {
      _currentUrl = null;
      _previousUrl = null;
      _frameCount = 0;
      _isLoading = true;
      _consecutiveErrors = 0;
      if (widget.isActive) {
        _fetchFrame();
      }
    }
  }

  @override
  void dispose() {
    _stopPolling();
    _fadeController.dispose();
    super.dispose();
  }

  void _startPolling() {
    _stopPolling();
    _currentUrl = null;
    _previousUrl = null;
    _frameCount = 0;
    _isLoading = true;
    _consecutiveErrors = 0;
    _fetchFrame();
    _pollTimer = Timer.periodic(widget.pollInterval, (_) => _fetchFrame());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 请求一帧快照
  Future<void> _fetchFrame() async {
    final url =
        '${widget.frameUrl}?ts=${DateTime.now().microsecondsSinceEpoch}';

    try {
      // 先验证 URL 可达（HEAD 或直接加载）
      // 使用 NetworkImage.resolve 来检查
      final provider = NetworkImage(url);
      final completer = Completer<void>();

      final stream = provider.resolve(const ImageConfiguration());
      late ImageStreamListener listener;

      listener = ImageStreamListener(
        (ImageInfo info, bool sync) {
          // 成功加载
          if (!mounted) return;
          _consecutiveErrors = 0;

          // 将当前帧推为上一帧，新帧为当前帧
          _previousUrl = _currentUrl;
          _currentUrl = url;
          _frameCount++;

          final wasLoading = _isLoading;
          setState(() {
            _isLoading = false;
          });

          // 交叉淡入：从 0 → 1
          if (!wasLoading && _previousUrl != null) {
            _fadeController.forward(from: 0.0);
          }

          stream.removeListener(listener);
          if (!completer.isCompleted) completer.complete();
        },
        onError: (dynamic error, StackTrace? stackTrace) {
          stream.removeListener(listener);
          if (!completer.isCompleted) completer.completeError(error);
        },
      );

      stream.addListener(listener);
      await completer.future;
    } catch (e) {
      if (!mounted) return;
      _consecutiveErrors++;
      debugPrint('[CameraView] 帧加载失败 ($_consecutiveErrors/$_maxErrors): $e');
      if (_consecutiveErrors >= _maxErrors) {
        setState(() {}); // 触发错误 UI
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    // 错误
    if (_consecutiveErrors >= _maxErrors) {
      return _buildErrorView();
    }

    // 加载中
    if (_isLoading && _currentUrl == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white54, strokeWidth: 2),
            SizedBox(height: 12),
            Text('正在连接摄像头...',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
          ],
        ),
      );
    }

    // 有画面 — 双层 Stack 交叉淡入
    return Stack(
      fit: StackFit.expand,
      children: [
        // 底层：上一帧（或相同帧，用于背景填充）
        if (_previousUrl != null)
          Image.network(
            _previousUrl!,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            cacheWidth: 640, // 限制解码分辨率，节省内存
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),

        // 顶层：当前帧，淡入
        if (_currentUrl != null)
          FadeTransition(
            opacity: _fadeAnimation,
            child: Image.network(
              _currentUrl!,
              key: ValueKey(_frameCount), // 强制重建
              fit: BoxFit.contain,
              gaplessPlayback: true,
              cacheWidth: 640,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_off, color: Colors.white38, size: 48),
          const SizedBox(height: 12),
          const Text('摄像头画面获取失败',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () {
              _consecutiveErrors = 0;
              _isLoading = true;
              _currentUrl = null;
              _previousUrl = null;
              setState(() {});
              _fetchFrame();
            },
            icon: const Icon(Icons.refresh, size: 16),
            label:
                const Text('重试', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}

/// MjpegView — MJPEG multipart 流解析 Widget
///
/// 用法:
///   MjpegView(url: "http://192.168.1.150:7125/webcam/stream")
///
/// 原理:
///   后端持续推送 multipart/x-mixed-replace 格式的 MJPEG 流，
///   每个 boundary 之间是一帧完整 JPEG。本 Widget 通过 dart:io
///   HttpClient（autoUncompress=false）建立长连接，逐字节解析
///   boundary → 提取 JPEG 字节 → 异步解码为 ui.Image → RawImage 渲染。
///
/// 故障自动恢复:
///   - Stream error / 流结束 / HTTP 非 200 / 连接异常 → retrySeconds 后重连
///   - 连续 N 帧解码失败 → 视为流损坏，触发重连
///   - 超过 watchdogSeconds 未收到帧 → 视为静默断流，触发重连（可设 0 禁用）

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class MjpegView extends StatefulWidget {
  final String url;

  /// 连接失败或超时后的重试间隔（秒），0 表示不重试
  final int retrySeconds;

  /// 空闲超时：如果超过此时间（秒）未收到任何帧，认为流已死并重连，0 表示禁用
  final int watchdogSeconds;

  /// 降级快照 URL：MJPEG 流连续连接失败 maxStreamFailures 次后，回退到定时轮询此 URL
  final String? fallbackSnapshotUrl;

  /// 连续流连接失败 N 次后降级到轮询（需 fallbackSnapshotUrl 不为 null）
  final int maxStreamFailures;

  /// 轮询间隔（降级模式）
  final Duration snapshotPollInterval;

  /// 加载中占位 Widget
  final Widget? loadingWidget;

  /// 连接失败占位 Widget
  final Widget Function(String error)? errorWidget;

  const MjpegView({
    super.key,
    required this.url,
    this.retrySeconds = 3,
    this.watchdogSeconds = 5,
    this.fallbackSnapshotUrl,
    this.maxStreamFailures = 2,
    this.snapshotPollInterval = const Duration(milliseconds: 200),
    this.loadingWidget,
    this.errorWidget,
  });

  @override
  State<MjpegView> createState() => _MjpegViewState();
}

class _MjpegViewState extends State<MjpegView> {
  HttpClient? _httpClient;
  HttpClientResponse? _response;
  StreamSubscription<List<int>>? _subscription;
  ui.Image? _currentImage;
  String? _error;
  bool _connecting = true;
  Timer? _retryTimer;
  Timer? _watchdogTimer;
  int _consecutiveDecodeErrors = 0;
  static const int _maxDecodeErrors = 3;

  /// MJPEG 流连续失败次数（连接级别，不含解码错误）
  int _streamFailureCount = 0;

  /// 是否已降级到快照轮询模式
  bool _useFallback = false;

  /// 防止 dispose 后 setState 调用
  bool _disposed = false;

  // ─── Boundary 解析状态 ─────────────────────────────────────────
  // 后端输出格式:
  //   --mjpeg-boundary\r\n
  //   Content-Type: image/jpeg\r\n
  //   Content-Length: 24567\r\n
  //   \r\n
  //   <JPEG bytes>
  //   \r\n

  final _boundary = '--mjpeg-boundary'.codeUnits;
  final _headerEnd = '\r\n\r\n'.codeUnits;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _watchdogTimer?.cancel();
    _disconnect();
    _currentImage?.dispose();
    super.dispose();
  }

  // ─── 重连管理 ──────────────────────────────────────────────────

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _disconnect() {
    _cancelRetry();
    _subscription?.cancel();
    _subscription = null;
    _httpClient?.close();
    _response = null;
    _httpClient = null;
  }

  // ─── 看门狗 ────────────────────────────────────────────────────

  void _resetWatchdog() {
    _watchdogTimer?.cancel();
    if (widget.watchdogSeconds > 0) {
      _watchdogTimer = Timer(
        Duration(seconds: widget.watchdogSeconds),
        () => _onError('No frame for ${widget.watchdogSeconds}s'),
      );
    }
  }

  Future<void> _connect() async {
    if (_useFallback) return; // 已降级，不再尝试 MJPEG

    _disconnect();
    final oldImage = _currentImage;
    _currentImage = null;
    oldImage?.dispose();
    setState(() {
      _connecting = true;
      _error = null;
    });

    try {
      final client = HttpClient();
      client.autoUncompress = false; // 关键：禁止自动 gzip 解压，确保原始字节透传
      client.connectionTimeout = const Duration(seconds: 5);

      final request = await client.getUrl(Uri.parse(widget.url));
      final response = await request.close();

      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        final permanent = response.statusCode >= 400 && response.statusCode < 500;
        _onError('HTTP ${response.statusCode}: $body', permanent: permanent);
        client.close();
        return;
      }

      _httpClient = client;
      _response = response;
      _consecutiveDecodeErrors = 0;
      if (_disposed || !mounted) { client.close(); return; }
      setState(() => _connecting = false);
      _resetWatchdog();
      debugPrint('MjpegView: ✅ connected HTTP ${response.statusCode}, '
          'contentType=${response.headers.contentType}, '
          'url=${widget.url}');

      var frameCount = 0;
      final parser = _MjpegParser(
        boundary: _boundary,
        headerEnd: _headerEnd,
        onFrame: (jpeg) {
          frameCount++;
          if (frameCount == 1) {
            debugPrint('MjpegView: 🎞️ 首帧解码: ${jpeg.length} bytes');
          }
          _onFrame(jpeg);
        },
      );

      _subscription = response.listen(
        parser.feed,
        onError: (e) => _onError('Stream error: $e'),
        onDone: () => _onError('Stream ended'),
        cancelOnError: false,
      );
    } catch (e) {
      _onError('Connection failed: $e');
    }
  }

  void _onFrame(Uint8List jpeg) async {
    if (_disposed || !mounted) return;
    try {
      final codec = await ui.instantiateImageCodec(jpeg);
      final frameInfo = await codec.getNextFrame();
      final newImage = frameInfo.image;

      if (_disposed || !mounted) {
        newImage.dispose();
        return;
      }

      final oldImage = _currentImage;
      setState(() {
        _currentImage = newImage;
        _connecting = false;
        _error = null;
      });
      oldImage?.dispose();

      // 帧成功收到 + 解码成功 → 复位看门狗和错误计数
      _consecutiveDecodeErrors = 0;
      _streamFailureCount = 0;
      _resetWatchdog();
    } catch (e) {
      if (_disposed || !mounted) return;
      _consecutiveDecodeErrors++;
      debugPrint('MjpegView: decode error ($_consecutiveDecodeErrors/$_maxDecodeErrors): $e');
      if (_consecutiveDecodeErrors >= _maxDecodeErrors) {
        _onError('Too many decode errors');
      }
    }
  }

  void _onError(String msg, {bool permanent = false}) {
    if (_disposed || !mounted) return;
    debugPrint('MjpegView: $msg${permanent ? ' (permanent)' : ''}');
    // 立即断开旧连接并停止看门狗
    _subscription?.cancel();
    _subscription = null;
    _httpClient?.close();
    _response = null;
    _httpClient = null;
    _cancelRetry();

    // 永久错误直接触发降级，不浪费重试机会
    if (permanent) {
      _streamFailureCount = widget.maxStreamFailures;
    } else {
      _streamFailureCount++;
    }

    // 有降级 URL 且连续失败达到阈值 → 降级到轮询
    if (widget.fallbackSnapshotUrl != null &&
        _streamFailureCount >= widget.maxStreamFailures) {
      debugPrint('MjpegView: falling back to snapshot polling');
      setState(() {
        _useFallback = true;
        _error = null;
        _connecting = false;
      });
      return;
    }

    setState(() {
      _error = msg;
      _connecting = false;
    });
    // 永久错误不重试
    if (!permanent && widget.retrySeconds > 0) {
      _retryTimer = Timer(Duration(seconds: widget.retrySeconds), _connect);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 降级模式：快照轮询
    if (_useFallback && widget.fallbackSnapshotUrl != null) {
      return _SnapshotPoller(
        url: widget.fallbackSnapshotUrl!,
        interval: widget.snapshotPollInterval,
      );
    }

    if (_connecting) {
      return widget.loadingWidget ??
          const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return widget.errorWidget?.call(_error!) ??
          Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
          );
    }
    if (_currentImage != null) {
      return RawImage(image: _currentImage, fit: BoxFit.cover);
    }
    return widget.loadingWidget ??
        const Center(child: CircularProgressIndicator());
  }
}

// ═══════════════════════════════════════════════════════════════════
// MJPEG multipart 流解析器（纯 Dart，零依赖）
// ═══════════════════════════════════════════════════════════════════

class _MjpegParser {
  final List<int> _boundary;
  final List<int> _headerEnd;
  final void Function(Uint8List jpeg) onFrame;

  /// 未消费的字节缓冲区
  final _buf = <int>[];

  /// 当前状态
  _State _state = _State.seekBoundary;

  /// 找到 boundary + header end 后待收集的帧字节数
  int _pendingBytes = 0;

  _MjpegParser({
    required List<int> boundary,
    required List<int> headerEnd,
    required this.onFrame,
  })  : _boundary = boundary,
        _headerEnd = headerEnd;

  bool _firstChunk = true;

  void feed(List<int> chunk) {
    if (_firstChunk) {
      debugPrint('MjpegView: 📥 首个 chunk: ${chunk.length} bytes');
      _firstChunk = false;
    }
    _buf.addAll(chunk);

    var framesFound = 0;
    while (true) {
      final prevState = _state;
      switch (_state) {
        case _State.seekBoundary:
          _doSeekBoundary();
        case _State.readHeaders:
          _doReadHeaders();
        case _State.readFrame:
          _doReadFrame();
        case _State.discardToBoundary:
          _doDiscardToBoundary();
      }
      // 如果在某个状态没有进展（buffer 不够），跳出循环等下一批数据
      if (_state == _State.seekBoundary && !_hasBoundary() ||
          _state == _State.readHeaders && !_hasHeaderEnd() ||
          _state == _State.readFrame && _buf.length < _pendingBytes) {
        break;
      }
    }
  }

  // ─── 状态机实现 ─────────────────────────────────────────────────

  void _doSeekBoundary() {
    final idx = _indexOf(_buf, _boundary);
    if (idx < 0) {
      // 保留最后几个字节（防止 boundary 跨 chunk 边界）
      if (_buf.length > _boundary.length) {
        _buf.removeRange(0, _buf.length - _boundary.length + 1);
      }
      return;
    }
    // 丢弃 boundary 之前的所有数据
    _buf.removeRange(0, idx + _boundary.length);
    _state = _State.readHeaders;
  }

  void _doReadHeaders() {
    // boundary 之后紧接 \r\n，统一跳过
    while (_buf.isNotEmpty && (_buf[0] == 0x0D || _buf[0] == 0x0A)) {
      _buf.removeAt(0);
    }

    final hdrEnd = _indexOf(_buf, _headerEnd);
    if (hdrEnd < 0) return; // 等更多数据

    // 解析 Content-Length
    final headerBytes = _buf.sublist(0, hdrEnd);
    final headerStr = String.fromCharCodes(headerBytes);
    final contentLength = _parseContentLength(headerStr);

    // 丢弃 headers + \r\n\r\n
    _buf.removeRange(0, hdrEnd + _headerEnd.length);

    if (contentLength != null && contentLength > 0) {
      _pendingBytes = contentLength;
      _state = _State.readFrame;
    } else {
      // 没有 Content-Length，在收到下一个 boundary 时截断
      _pendingBytes = -1;
      _state = _State.readFrame;
    }
  }

  void _doReadFrame() {
    if (_pendingBytes > 0) {
      // 有 Content-Length：精确读取
      if (_buf.length < _pendingBytes) return; // 等更多数据
      final frame = Uint8List.fromList(_buf.sublist(0, _pendingBytes));
      _buf.removeRange(0, _pendingBytes);
      onFrame(frame);
      // 跳过帧后的 \r\n
      _trimLeadingCRLF();
      _state = _State.seekBoundary;
    } else {
      // 无 Content-Length：找到下一个 boundary 截断
      final nextBd = _indexOf(_buf, _boundary);
      if (nextBd < 0) return; // 还没看到下一个 boundary
      // boundary 之前的字节就是帧数据（去掉末尾的 \r\n）
      var frameEnd = nextBd;
      while (frameEnd > 0 &&
          (_buf[frameEnd - 1] == 0x0D || _buf[frameEnd - 1] == 0x0A)) {
        frameEnd--;
      }
      if (frameEnd > 0) {
        final frame = Uint8List.fromList(_buf.sublist(0, frameEnd));
        onFrame(frame);
      }
      _buf.removeRange(0, nextBd);
      _state = _State.seekBoundary;
    }
  }

  void _doDiscardToBoundary() {
    final idx = _indexOf(_buf, _boundary);
    if (idx >= 0) {
      _buf.removeRange(0, idx);
      _state = _State.seekBoundary;
    } else {
      if (_buf.length > _boundary.length) {
        _buf.removeRange(0, _buf.length - _boundary.length + 1);
      }
    }
  }

  // ─── 工具方法 ───────────────────────────────────────────────────

  bool _hasBoundary() => _indexOf(_buf, _boundary) >= 0;
  bool _hasHeaderEnd() => _indexOf(_buf, _headerEnd) >= 0;

  static int _indexOf(List<int> haystack, List<int> needle) {
    outer:
    for (var i = 0; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static int? _parseContentLength(String headers) {
    final re = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false);
    final match = re.firstMatch(headers);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    return null;
  }

  void _trimLeadingCRLF() {
    while (_buf.isNotEmpty && (_buf[0] == 0x0D || _buf[0] == 0x0A)) {
      _buf.removeAt(0);
    }
  }
}

enum _State { seekBoundary, readHeaders, readFrame, discardToBoundary }

// ═══════════════════════════════════════════════════════════════════
// 快照轮询器 — MJPEG 流的降级方案
// ═══════════════════════════════════════════════════════════════════

class _SnapshotPoller extends StatefulWidget {
  final String url;
  final Duration interval;

  const _SnapshotPoller({required this.url, required this.interval});

  @override
  State<_SnapshotPoller> createState() => _SnapshotPollerState();
}

class _SnapshotPollerState extends State<_SnapshotPoller> {
  Timer? _timer;
  String? _currentUrl;
  int _errorCount = 0;
  static const int _maxErrors = 10;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _fetch();
    _timer = Timer.periodic(widget.interval, (_) => _fetch());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  void _fetch() {
    final url = '${widget.url}?ts=${DateTime.now().microsecondsSinceEpoch}';
    final provider = NetworkImage(url);
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    final completer = Completer<void>();

    listener = ImageStreamListener(
      (ImageInfo info, bool sync) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
        if (_disposed || !mounted) return;
        _errorCount = 0;
        setState(() => _currentUrl = url);
      },
      onError: (dynamic error, StackTrace? stackTrace) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
        if (_disposed || !mounted) return;
        _errorCount++;
      },
    );
    stream.addListener(listener);
    unawaited(completer.future);
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCount >= _maxErrors || _currentUrl == null) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Image.network(_currentUrl!, fit: BoxFit.cover);
  }
}

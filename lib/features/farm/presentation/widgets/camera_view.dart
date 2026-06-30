/// MjpegView — MJPEG multipart 流解析 Widget
///
/// 用法:
///   MjpegView(url: "http://192.168.1.150:7125/webcam/stream")
///
/// 原理:
///   后端持续推送 multipart/x-mixed-replace 格式的 MJPEG 流，
///   每个 boundary 之间是一帧完整 JPEG。本 Widget 通过 http
///   包建立长连接，逐字节解析 boundary → 提取 JPEG → Image.memory() 渲染。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class MjpegView extends StatefulWidget {
  final String url;

  /// 连接失败或超时后的重试间隔（秒），0 表示不重试
  final int retrySeconds;

  /// 加载中占位 Widget
  final Widget? loadingWidget;

  /// 连接失败占位 Widget
  final Widget Function(String error)? errorWidget;

  const MjpegView({
    super.key,
    required this.url,
    this.retrySeconds = 3,
    this.loadingWidget,
    this.errorWidget,
  });

  @override
  State<MjpegView> createState() => _MjpegViewState();
}

class _MjpegViewState extends State<MjpegView> {
  http.Client? _client;
  StreamSubscription<List<int>>? _subscription;
  Uint8List? _currentFrame;
  String? _error;
  bool _connecting = true;
  Timer? _retryTimer;

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
    _retryTimer?.cancel();
    _disconnect();
    super.dispose();
  }

  // ─── 连接管理 ──────────────────────────────────────────────────

  void _disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _client?.close();
    _client = null;
  }

  Future<void> _connect() async {
    _disconnect();
    setState(() {
      _connecting = true;
      _error = null;
    });

    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(widget.url));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        _onError('HTTP ${response.statusCode}: $body');
        client.close();
        return;
      }

      _client = client;
      _connecting = false;
      final parser = _MjpegParser(
        boundary: _boundary,
        headerEnd: _headerEnd,
        onFrame: _onFrame,
      );

      _subscription = response.stream.listen(
        parser.feed,
        onError: (e) => _onError('Stream error: $e'),
        onDone: () => _onError('Stream ended'),
        cancelOnError: false,
      );
      // ignore: avoid_dynamic_calls
    } catch (e) {
      _onError('Connection failed: $e');
    }
  }

  void _onFrame(Uint8List jpeg) {
    if (!mounted) return;
    setState(() {
      _currentFrame = jpeg;
      _connecting = false;
      _error = null;
    });
  }

  void _onError(String msg) {
    if (!mounted) return;
    debugPrint('MjpegView: $msg');
    setState(() {
      _error = msg;
      _connecting = false;
    });
    if (widget.retrySeconds > 0) {
      _retryTimer = Timer(Duration(seconds: widget.retrySeconds), _connect);
    }
  }

  @override
  Widget build(BuildContext context) {
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
    if (_currentFrame != null) {
      return Image.memory(
        _currentFrame!,
        fit: BoxFit.cover,
        gaplessPlayback: false,
      );
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

  void feed(List<int> chunk) {
    _buf.addAll(chunk);

    while (true) {
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

/// ThumbnailService — 打印缩略图获取服务
///
/// 通过 MQTT 命令从打印机获取 G-code 文件缩略图，支持两条路径:
///
///   路径 1 — Snapmaker 自定义命令
///     MQTT customGetFileThumbnailData → 返回 base64 编码的图片数据
///
///   路径 2 — 标准 Moonraker 元数据
///     MQTT server.files.metadata → 解析 thumbnails 数组
///     → HTTP GET 下载实际的缩略图文件
///
/// 缓存:
///   - 内存 LRU 缓存，上限 100 条
///   - Key: "$sn:$filename"
///   - 超过上限时淘汰最早缓存的条目
///
/// 使用方式:
///   final result = await service.getThumbnail(
///     sn: 'ABC123', ip: '192.168.1.100',
///     filename: 'benchy.gcode',
///   );
///   if (result.imageBytes != null) { ... }

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'farm_mqtt_router.dart';

/// 缓存条目
class CachedThumbnail {
  final Uint8List imageBytes;
  final int? width;
  final int? height;
  final DateTime cachedAt;

  const CachedThumbnail({
    required this.imageBytes,
    this.width,
    this.height,
    required this.cachedAt,
  });
}

/// 缩略图获取结果
class ThumbnailResult {
  final Uint8List? imageBytes;
  final int? width;
  final int? height;

  /// 数据来源: 'cache' | 'custom_command' | 'metadata' | 'fallback'
  final String source;

  const ThumbnailResult({
    this.imageBytes,
    this.width,
    this.height,
    required this.source,
  });

  bool get hasImage => imageBytes != null;
}

/// 缩略图获取服务
class ThumbnailService {
  final FarmMqttRouter _router;
  final HttpClient _httpClient = HttpClient();

  static const int _maxCacheEntries = 100;
  static const _fetchTimeout = Duration(seconds: 10);
  static const _httpTimeout = Duration(seconds: 10);

  final Map<String, CachedThumbnail> _cache = {};

  ThumbnailService({required FarmMqttRouter router}) : _router = router;

  // ═══════════════════════════════════════════════════════════════
  // 公开接口
  // ═══════════════════════════════════════════════════════════════

  /// 获取打印任务的缩略图
  ///
  /// [sn]       打印机序列号
  /// [ip]       打印机 IP（路径 2 需要，为空则跳过 HTTP）
  /// [port]     打印机 Moonraker 端口，默认 7125
  /// [filename] 当前打印的文件名
  ///
  /// 返回 [ThumbnailResult]，优先走缓存，其次 MQTT 命令。
  Future<ThumbnailResult> getThumbnail({
    required String sn,
    required String ip,
    int port = 7125,
    required String filename,
  }) async {
    // 文件名无效 → 直接 fallback
    if (filename.isEmpty) {
      return const ThumbnailResult(source: 'fallback');
    }

    // 缓存命中
    final cacheKey = '$sn:$filename';
    final cached = _cache[cacheKey];
    if (cached != null) {
      return ThumbnailResult(
        imageBytes: cached.imageBytes,
        width: cached.width,
        height: cached.height,
        source: 'cache',
      );
    }

    // 路径 1: Snapmaker 自定义命令 (MQTT → base64)
    final path1 = await _fetchViaCustomCommand(sn, filename);
    if (path1 != null) {
      _cacheBytes(cacheKey, path1);
      return ThumbnailResult(
        imageBytes: path1,
        source: 'custom_command',
      );
    }

    // 路径 2: Moonraker 元数据 (MQTT → thumbnails → HTTP GET)
    if (ip.isNotEmpty && ip != 'MQTT' && ip != '—') {
      final path2 = await _fetchViaMetadata(sn, ip, port, filename);
      if (path2 != null) {
        _cacheBytes(cacheKey, path2);
        return ThumbnailResult(
          imageBytes: path2,
          source: 'metadata',
        );
      }
    }

    return const ThumbnailResult(source: 'fallback');
  }

  /// 清空缓存
  void clearCache() {
    _cache.clear();
  }

  /// 移除单个缓存条目
  void evict(String sn, String filename) {
    _cache.remove('$sn:$filename');
  }

  /// 释放资源
  void dispose() {
    _httpClient.close();
    _cache.clear();
  }

  // ═══════════════════════════════════════════════════════════════
  // 路径 1: customGetFileThumbnailData (MQTT → base64)
  // ═══════════════════════════════════════════════════════════════

  Future<Uint8List?> _fetchViaCustomCommand(String sn, String filename) async {
    try {
      final result = await _router.gateway.sendToOne(
        sn: sn,
        method: 'customGetFileThumbnailData',
        params: {'path': filename},
        timeout: _fetchTimeout,
      );

      if (!result.success || result.data == null) return null;

      final dataStr = result.data!['data'] as String?;
      if (dataStr == null || dataStr.isEmpty) return null;

      return base64Decode(dataStr);
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 路径 2: server.files.metadata (MQTT → thumbnails → HTTP GET)
  // ═══════════════════════════════════════════════════════════════

  Future<Uint8List?> _fetchViaMetadata(
    String sn, String ip, int port, String filename,
  ) async {
    try {
      final result = await _router.gateway.sendToOne(
        sn: sn,
        method: 'server.files.metadata',
        params: {'filename': filename},
        timeout: _fetchTimeout,
      );

      if (!result.success || result.data == null) return null;

      final thumbnails = result.data!['thumbnails'] as List?;
      if (thumbnails == null || thumbnails.isEmpty) return null;

      // 选择最佳缩略图: 优先 160×160, 否则取面积最大的
      Map<String, dynamic>? best;
      int? bestArea;
      for (final t in thumbnails) {
        if (t is! Map<String, dynamic>) continue;
        final w = (t['width'] as num?)?.toInt() ?? 0;
        final h = (t['height'] as num?)?.toInt() ?? 0;
        if (w <= 0 || h <= 0) continue;
        // 优先精确匹配 160×160
        if (w == 160 && h == 160) {
          best = t;
          break;
        }
        final area = w * h;
        if (bestArea == null || area > bestArea) {
          bestArea = area;
          best = t;
        }
      }

      if (best == null) return null;
      final relativePath = best['relative_path'] as String?;
      if (relativePath == null) return null;

      return _httpGetThumbnail(ip, port, relativePath);
    } catch (_) {
      return null;
    }
  }

  /// HTTP GET 下载缩略图二进制数据
  Future<Uint8List?> _httpGetThumbnail(
    String ip, int port, String relativePath,
  ) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = _httpTimeout;

      final path = relativePath.startsWith('/')
          ? relativePath
          : '/$relativePath';
      final uri = Uri.parse('http://$ip:$port/server/files/gcodes$path');

      final request = await client.getUrl(uri);
      // Moonraker LAN 模式约定：即使无认证也要带空 Authorization header
      request.headers.set('Authorization', '');
      final response = await request.close().timeout(_httpTimeout);

      if (response.statusCode == 200) {
        final bytes = await response.fold<BytesBuilder>(
          BytesBuilder(),
          (builder, chunk) => builder..add(chunk),
        );
        client.close();
        return bytes.toBytes();
      }
      client.close();
      return null;
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 缓存管理
  // ═══════════════════════════════════════════════════════════════

  void _cacheBytes(String key, Uint8List bytes) {
    // 超过上限 → 淘汰最旧条目
    if (_cache.length >= _maxCacheEntries) {
      String? oldestKey;
      DateTime? oldestTime;
      for (final entry in _cache.entries) {
        if (oldestTime == null || entry.value.cachedAt.isBefore(oldestTime)) {
          oldestTime = entry.value.cachedAt;
          oldestKey = entry.key;
        }
      }
      if (oldestKey != null) _cache.remove(oldestKey);
    }

    _cache[key] = CachedThumbnail(
      imageBytes: bytes,
      cachedAt: DateTime.now(),
    );
  }
}

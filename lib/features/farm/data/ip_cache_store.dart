/// IP 缓存持久化存储
///
/// 将 SN → IP 映射持久化到本地，App 重启后自动恢复，
/// 避免断连后重新走 MQTT machine.system_info 解析。
///
/// 存储格式：单 key `ip_cache` 下存整个 Map 的 JSON。
/// 参照 CredentialStore 模式，复用 flutter_secure_storage。

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class IpCacheStore {
  final FlutterSecureStorage _secureStorage;

  static const _ipCacheKey = 'ip_cache';

  IpCacheStore({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  /// 加载全部缓存的 SN→IP 映射
  Future<Map<String, String>> loadAll() async {
    try {
      final raw = await _secureStorage.read(key: _ipCacheKey);
      if (raw == null || raw.isEmpty) return {};

      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  /// 更新单条 SN→IP（读→改→写）
  Future<void> update(String sn, String ip) async {
    try {
      final all = await loadAll();
      all[sn] = ip;
      await _secureStorage.write(key: _ipCacheKey, value: jsonEncode(all));
    } catch (_) {
      // 非关键路径，静默忽略
    }
  }

  /// 删除单条缓存
  Future<void> remove(String sn) async {
    try {
      final all = await loadAll();
      all.remove(sn);
      await _secureStorage.write(key: _ipCacheKey, value: jsonEncode(all));
    } catch (_) {
      // 非关键路径，静默忽略
    }
  }
}

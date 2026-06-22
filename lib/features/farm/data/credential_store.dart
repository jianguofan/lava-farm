/// 凭据安全存储
///
/// T1.2: CredentialStore 实现
///
/// 职责:
/// - App Broker 凭据的安全存储（flutter_secure_storage / keychain）
/// - 打印机密码的生成与存储
/// - 凭据加载/清除
///
/// 安全层次:
///   macOS:   Keychain Services
///   Windows: Windows Credential Manager
///   Linux:   libsecret (GNOME Keyring)

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class BrokerCredentials {
  final String host;
  final int port;
  final String username;
  final String password;

  const BrokerCredentials({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
  });
}

class PrinterCredential {
  final String sn;
  final String username;
  final String password;

  const PrinterCredential({
    required this.sn,
    required this.username,
    required this.password,
  });
}

class CredentialStore {
  final FlutterSecureStorage _secureStorage;

  // 存储 key 常量
  static const _brokerHostKey = 'broker_host';
  static const _brokerPortKey = 'broker_port';
  static const _brokerUsernameKey = 'broker_username';
  static const _brokerPasswordKey = 'broker_password';
  static const _printerCredentialsKey = 'printer_credentials'; // JSON map

  CredentialStore({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  // ── App Broker 凭据 ──

  /// 保存 Broker 连接凭据
  Future<void> saveBrokerCredentials({
    required String host,
    required int port,
    required String username,
    required String password,
  }) async {
    await Future.wait([
      _secureStorage.write(key: _brokerHostKey, value: host),
      _secureStorage.write(key: _brokerPortKey, value: port.toString()),
      _secureStorage.write(key: _brokerUsernameKey, value: username),
      _secureStorage.write(key: _brokerPasswordKey, value: password),
    ]);
  }

  /// 加载 Broker 连接凭据
  /// 返回 null 表示尚未配置（首次启动）
  Future<BrokerCredentials?> loadBrokerCredentials() async {
    try {
      final results = await Future.wait([
        _secureStorage.read(key: _brokerHostKey),
        _secureStorage.read(key: _brokerPortKey),
        _secureStorage.read(key: _brokerUsernameKey),
        _secureStorage.read(key: _brokerPasswordKey),
      ]);

      final host = results[0];
      final portStr = results[1];
      final username = results[2];
      final password = results[3];

      if (host == null || portStr == null || username == null || password == null) {
        return null;
      }

      return BrokerCredentials(
        host: host,
        port: int.tryParse(portStr) ?? 1883,
        username: username,
        password: password,
      );
    } catch (_) {
      return null;
    }
  }

  /// 清除 Broker 凭据
  Future<void> clearBrokerCredentials() async {
    await Future.wait([
      _secureStorage.delete(key: _brokerHostKey),
      _secureStorage.delete(key: _brokerPortKey),
      _secureStorage.delete(key: _brokerUsernameKey),
      _secureStorage.delete(key: _brokerPasswordKey),
    ]);
  }

  // ── 打印机凭据 ──

  /// 为打印机生成随机密码
  static String generatePrinterPassword(String sn) {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// 保存单台打印机凭据
  Future<void> savePrinterCredential({
    required String sn,
    required String username,
    required String password,
  }) async {
    final all = await _loadAllPrinterCredentials();
    all[sn] = {
      'username': username,
      'password': password,
    };
    await _saveAllPrinterCredentials(all);
  }

  /// 加载单台打印机凭据
  Future<PrinterCredential?> loadPrinterCredential(String sn) async {
    final all = await _loadAllPrinterCredentials();
    final entry = all[sn];
    if (entry == null) return null;

    return PrinterCredential(
      sn: sn,
      username: entry['username'] as String,
      password: entry['password'] as String,
    );
  }

  /// 加载所有打印机凭据
  Future<Map<String, PrinterCredential>> loadAllPrinterCredentials() async {
    final all = await _loadAllPrinterCredentials();
    return all.map((sn, entry) => MapEntry(
      sn,
      PrinterCredential(
        sn: sn,
        username: entry['username'] as String,
        password: entry['password'] as String,
      ),
    ));
  }

  /// 删除打印机凭据
  Future<void> removePrinterCredential(String sn) async {
    final all = await _loadAllPrinterCredentials();
    all.remove(sn);
    await _saveAllPrinterCredentials(all);
  }

  // ── 内部方法 ──

  Future<Map<String, Map<String, String>>> _loadAllPrinterCredentials() async {
    try {
      final raw = await _secureStorage.read(key: _printerCredentialsKey);
      if (raw == null) return {};

      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((sn, entry) {
        final map = entry as Map<String, dynamic>;
        return MapEntry(
          sn,
          {
            'username': map['username'] as String,
            'password': map['password'] as String,
          },
        );
      });
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveAllPrinterCredentials(
    Map<String, Map<String, String>> credentials,
  ) async {
    await _secureStorage.write(
      key: _printerCredentialsKey,
      value: jsonEncode(credentials),
    );
  }

  /// 清除所有存储的凭据（恢复出厂设置时调用）
  Future<void> clearAll() async {
    await clearBrokerCredentials();
    await _secureStorage.delete(key: _printerCredentialsKey);
  }
}

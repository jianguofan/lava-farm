/// CredentialStore Provider

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/credential_store.dart';

/// CredentialStore 单例 Provider
final credentialStoreProvider = Provider<CredentialStore>((ref) {
  return CredentialStore();
});

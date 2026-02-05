import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_store_base.dart';

class _SecureStoreIo implements SecureStore {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Future<String?> read({required String key}) {
    return _storage.read(key: key);
  }

  @override
  Future<void> write({required String key, required String value}) {
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete({required String key}) {
    return _storage.delete(key: key);
  }
}

SecureStore createSecureStoreImpl() => _SecureStoreIo();

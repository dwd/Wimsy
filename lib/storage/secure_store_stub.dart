import 'secure_store_base.dart';

class _NoopSecureStore implements SecureStore {
  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

SecureStore createSecureStoreImpl() => _NoopSecureStore();

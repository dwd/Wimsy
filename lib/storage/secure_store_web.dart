import 'package:shared_preferences/shared_preferences.dart';

import 'secure_store_base.dart';

class _SecureStoreWeb implements SecureStore {
  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  @override
  Future<String?> read({required String key}) async {
    final prefs = await _prefs();
    return prefs.getString(key);
  }

  @override
  Future<void> write({required String key, required String value}) async {
    final prefs = await _prefs();
    await prefs.setString(key, value);
  }

  @override
  Future<void> delete({required String key}) async {
    final prefs = await _prefs();
    await prefs.remove(key);
  }
}

SecureStore createSecureStoreImpl() => _SecureStoreWeb();

export 'secure_store_base.dart';

import 'secure_store_base.dart';
import 'secure_store_stub.dart'
    if (dart.library.html) 'secure_store_web.dart'
    if (dart.library.io) 'secure_store_io.dart';

SecureStore createSecureStore() => createSecureStoreImpl();

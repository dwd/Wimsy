import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/storage/account_record.dart';

void main() {
  group('AccountRecord useTcp', () {
    test('defaults to true when not specified', () {
      final record = AccountRecord(
        jid: 'user@example.org',
        password: '',
        host: '',
        port: 5222,
        resource: 'wimsy',
        rememberPassword: false,
        useWebSocket: false,
        directTls: false,
        wsEndpoint: '',
        wsProtocols: const <String>[],
      );
      expect(record.useTcp, isTrue);
      // Direct TLS default unchanged.
      expect(record.directTls, isFalse);
      // QUIC default unchanged.
      expect(record.useQuic, isTrue);
    });

    test('round-trips through toMap/fromMap', () {
      final record = AccountRecord(
        jid: 'user@example.org',
        password: '',
        host: '',
        port: 5222,
        resource: 'wimsy',
        rememberPassword: false,
        useWebSocket: false,
        directTls: false,
        wsEndpoint: '',
        wsProtocols: const <String>[],
        useTcp: false,
      );
      final restored = AccountRecord.fromMap(record.toMap());
      expect(restored, isNotNull);
      expect(restored!.useTcp, isFalse);
    });

    test('fromMap defaults useTcp to true for legacy records', () {
      // Older persisted records have no `useTcp` key. They must default to
      // true so existing accounts continue to allow plain-TCP connections
      // exactly as they did before this option was introduced.
      final restored = AccountRecord.fromMap(<String, dynamic>{
        'jid': 'user@example.org',
        'password': '',
        'host': '',
        'port': 5222,
        'resource': 'wimsy',
        'rememberPassword': false,
        'useWebSocket': false,
        'directTls': false,
        'wsEndpoint': '',
        'wsProtocols': const <String>[],
      });
      expect(restored, isNotNull);
      expect(restored!.useTcp, isTrue);
    });

    test('fromMap honours explicit useTcp=false', () {
      final restored = AccountRecord.fromMap(<String, dynamic>{
        'jid': 'user@example.org',
        'password': '',
        'host': '',
        'port': 5222,
        'resource': 'wimsy',
        'rememberPassword': false,
        'useWebSocket': false,
        'directTls': true,
        'wsEndpoint': '',
        'wsProtocols': const <String>[],
        'useTcp': false,
      });
      expect(restored, isNotNull);
      expect(restored!.useTcp, isFalse);
      expect(restored.directTls, isTrue);
    });
  });
}

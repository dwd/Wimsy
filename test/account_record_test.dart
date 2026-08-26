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
        connectionUrl: '',
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
        connectionUrl: '',
        serverCertificateHash: 'certificate-digest',
        useTcp: false,
      );
      final restored = AccountRecord.fromMap(record.toMap());
      expect(restored, isNotNull);
      expect(restored!.serverCertificateHash, 'certificate-digest');
      expect(restored.useTcp, isFalse);
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
      });
      expect(restored, isNotNull);
      expect(restored!.useTcp, isTrue);
    });

    test('fromMap reads legacy wsEndpoint key as connectionUrl', () {
      final restored = AccountRecord.fromMap(<String, dynamic>{
        'jid': 'user@example.org',
        'password': '',
        'host': '',
        'port': 5222,
        'resource': 'wimsy',
        'rememberPassword': false,
        'useWebSocket': true,
        'directTls': false,
        'wsEndpoint': 'wss://legacy.example.com/xmpp-websocket',
      });
      expect(restored, isNotNull);
      expect(
        restored!.connectionUrl,
        'wss://legacy.example.com/xmpp-websocket',
      );
    });

    test('fromMap prefers connectionUrl over legacy wsEndpoint', () {
      final restored = AccountRecord.fromMap(<String, dynamic>{
        'jid': 'user@example.org',
        'password': '',
        'host': '',
        'port': 5222,
        'resource': 'wimsy',
        'rememberPassword': false,
        'useWebSocket': true,
        'directTls': false,
        'connectionUrl': 'https://new.example.com/xmpp-webtransport',
        'wsEndpoint': 'wss://old.example.com/xmpp-websocket',
      });
      expect(restored, isNotNull);
      expect(
        restored!.connectionUrl,
        'https://new.example.com/xmpp-webtransport',
      );
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
        'useTcp': false,
      });
      expect(restored, isNotNull);
      expect(restored!.useTcp, isFalse);
      expect(restored.directTls, isTrue);
    });
  });
}

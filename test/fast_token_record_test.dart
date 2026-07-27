import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/storage/fast_token_record.dart';

void main() {
  group('FastTokenRecord serialization', () {
    test('round-trips all fields', () {
      const record = FastTokenRecord(
        token: 'dG9rZW4=',
        expiry: '2099-01-01T00:00:00Z',
        mechanism: 'HT2-SHA-256-NONE',
      );
      final restored = FastTokenRecord.fromMap(record.toMap());
      expect(restored, isNotNull);
      expect(restored!.token, equals('dG9rZW4='));
      expect(restored.expiry, equals('2099-01-01T00:00:00Z'));
      expect(restored.mechanism, equals('HT2-SHA-256-NONE'));
    });

    test('round-trips a token without expiry or mechanism', () {
      const record = FastTokenRecord(token: 'dG9rZW4=');
      final restored = FastTokenRecord.fromMap(record.toMap());
      expect(restored, isNotNull);
      expect(restored!.expiry, isNull);
      expect(restored.mechanism, isNull);
    });

    test('returns null for a missing map', () {
      expect(FastTokenRecord.fromMap(null), isNull);
    });

    test('returns null when the token is missing or empty', () {
      expect(FastTokenRecord.fromMap(<String, dynamic>{}), isNull);
      expect(
        FastTokenRecord.fromMap(<String, dynamic>{'token': ''}),
        isNull,
      );
    });

    test('treats empty expiry and mechanism strings as absent', () {
      final restored = FastTokenRecord.fromMap(<String, dynamic>{
        'token': 'dG9rZW4=',
        'expiry': '',
        'mechanism': '',
      });
      expect(restored, isNotNull);
      expect(restored!.expiry, isNull);
      expect(restored.mechanism, isNull);
    });
  });

  group('FastTokenRecord expiry', () {
    test('a past expiry is expired', () {
      const record = FastTokenRecord(
        token: 'dG9rZW4=',
        expiry: '2000-01-01T00:00:00Z',
      );
      expect(record.isExpired, isTrue);
    });

    test('a future expiry is not expired', () {
      const record = FastTokenRecord(
        token: 'dG9rZW4=',
        expiry: '2099-01-01T00:00:00Z',
      );
      expect(record.isExpired, isFalse);
    });

    test('a missing expiry never expires', () {
      const record = FastTokenRecord(token: 'dG9rZW4=');
      expect(record.isExpired, isFalse);
    });

    test('an unparseable expiry is treated as non-expiring', () {
      const record = FastTokenRecord(token: 'dG9rZW4=', expiry: 'soon');
      expect(record.isExpired, isFalse);
    });
  });
}

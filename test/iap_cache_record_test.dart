import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/storage/iap_cache_record.dart';

void main() {
  test('IAP cache record round-trips pipelining state', () {
    const record = IapCacheRecord(
      configVersion: 'config-1',
      sasl2Mechanisms: ['PLAIN', 'SCRAM-SHA-1'],
      lastMechanism: 'SCRAM-SHA-1',
      bind2Features: ['urn:xmpp:carbons:2'],
      fastMechanisms: ['HT2-SHA-256-NONE'],
    );

    final restored = IapCacheRecord.fromMap(record.toMap());

    expect(restored?.configVersion, 'config-1');
    expect(restored?.sasl2Mechanisms, ['PLAIN', 'SCRAM-SHA-1']);
    expect(restored?.lastMechanism, 'SCRAM-SHA-1');
    expect(restored?.bind2Features, ['urn:xmpp:carbons:2']);
    expect(restored?.fastMechanisms, ['HT2-SHA-256-NONE']);
  });

  test('IAP cache record rejects incomplete state', () {
    expect(IapCacheRecord.fromMap(const {}), isNull);
    expect(
      IapCacheRecord.fromMap(const {
        'configVersion': 'config-1',
        'sasl2Mechanisms': ['SCRAM-SHA-1'],
      }),
      isNull,
    );
  });
}

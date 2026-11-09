import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

/// Regression test for a bug where a decrypted OMEMO message's plaintext
/// (delivered via a second call to the internal message-add path, after an
/// earlier placeholder/fallback-body add for the same `messageId`) never
/// reached the UI: the "merge into existing message" branch updated many
/// fields (mamId, stanzaId, oobUrl, ...) but silently dropped `body`,
/// `encryptionProtocol`, and `encryptionError`, so the merge was a no-op
/// for exactly the fields that mattered for a successful decrypt.
void main() {
  test(
    'a later add for the same messageId updates body/encryptionProtocol/'
    'encryptionError on the existing message instead of discarding them',
    () {
      final service = XmppService();
      const bareJid = 'alice@example.com';
      const from = 'alice@example.com';
      const to = 'bob@example.com';
      const messageId = 'msg-1';
      final timestamp = DateTime.utc(2026, 1, 1);

      // First add: the synchronous/placeholder version of the message, as
      // seen immediately while decryption is still in flight (e.g. the
      // literal EME fallback text, with no encryption metadata yet).
      service.addMessageForTesting(
        bareJid: bareJid,
        from: from,
        to: to,
        body: 'I sent you an OMEMO encrypted message but your client '
            "doesn't seem to support that.",
        outgoing: false,
        timestamp: timestamp,
        messageId: messageId,
      );

      final placeholder = service.messagesFor(bareJid).single;
      expect(placeholder.body, contains("doesn't seem to support"));
      expect(placeholder.encryptionProtocol, isNull);

      // Second add for the same messageId: the decrypted plaintext arrives
      // asynchronously, along with the protocol id used to decrypt it.
      service.addMessageForTesting(
        bareJid: bareJid,
        from: from,
        to: to,
        body: 'hello from the real plaintext',
        outgoing: false,
        timestamp: timestamp,
        messageId: messageId,
        encryptionProtocol: 'omemo',
      );

      final messages = service.messagesFor(bareJid);
      expect(messages.length, 1, reason: 'must merge, not duplicate');
      final merged = messages.single;
      expect(merged.body, 'hello from the real plaintext');
      expect(merged.encryptionProtocol, 'omemo');
    },
  );

  test(
    'a later add for the same messageId updates encryptionError on the '
    'existing message when decryption ultimately fails',
    () {
      final service = XmppService();
      const bareJid = 'carol@example.com';
      const from = 'carol@example.com';
      const to = 'bob@example.com';
      const messageId = 'msg-2';
      final timestamp = DateTime.utc(2026, 1, 1);

      service.addMessageForTesting(
        bareJid: bareJid,
        from: from,
        to: to,
        body: 'fallback placeholder',
        outgoing: false,
        timestamp: timestamp,
        messageId: messageId,
      );

      service.addMessageForTesting(
        bareJid: bareJid,
        from: from,
        to: to,
        body: 'fallback placeholder',
        outgoing: false,
        timestamp: timestamp,
        messageId: messageId,
        encryptionProtocol: 'omemo',
        encryptionError: 'bad MAC',
      );

      final merged = service.messagesFor(bareJid).single;
      expect(merged.encryptionProtocol, 'omemo');
      expect(merged.encryptionError, 'bad MAC');
    },
  );
}

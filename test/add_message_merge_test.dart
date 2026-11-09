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

  test(
    'a later failed re-decrypt of an already successfully-decrypted message '
    'does not revert its body/protocol/error back to the fallback (e.g. '
    'MAM catch-up/history replay re-delivering a message after restart, '
    'whose Double Ratchet message key was already consumed)',
    () {
      final service = XmppService();
      const bareJid = 'dave@example.com';
      const from = 'dave@example.com';
      const to = 'bob@example.com';
      const messageId = 'msg-3';
      final timestamp = DateTime.utc(2026, 1, 1);
      const fallbackBody =
          'I sent you an OMEMO encrypted message but your client '
          "doesn't seem to support that.";

      // First add: successfully decrypted live.
      service.addMessageForTesting(
        bareJid: bareJid,
        from: from,
        to: to,
        body: 'the real decrypted plaintext',
        outgoing: false,
        timestamp: timestamp,
        messageId: messageId,
        encryptionProtocol: 'omemo',
      );

      // Second add for the same messageId: a re-delivery of the same
      // stanza (e.g. after an app restart triggers a MAM catch-up replay)
      // fails to re-decrypt, since the message key was already consumed
      // and removed from the ratchet the first time.
      service.addMessageForTesting(
        bareJid: bareJid,
        from: from,
        to: to,
        body: fallbackBody,
        outgoing: false,
        timestamp: timestamp,
        messageId: messageId,
        encryptionError: 'message key already consumed',
      );

      final merged = service.messagesFor(bareJid).single;
      expect(merged.body, 'the real decrypted plaintext');
      expect(merged.encryptionProtocol, 'omemo');
      expect(merged.encryptionError, isNull);
    },
  );

  test(
    'a later MAM catch-up/carbon replay of an already-decrypted *outgoing* '
    'message - which never re-attempts decryption and so carries neither '
    'an encryptionProtocol nor an encryptionError, only the wire-level '
    'XEP-0380 fallback body - does not revert its body back to that '
    'fallback text',
    () {
      final service = XmppService();
      const bareJid = 'erin@example.com';
      const from = 'me@example.com';
      const to = 'erin@example.com';
      const messageId = 'msg-4';
      final timestamp = DateTime.utc(2026, 1, 1);
      const fallbackBody =
          'I sent you an OMEMO encrypted message but your client '
          "doesn't seem to support that.";

      // First add: our own locally-composed-and-sent message, recorded
      // with its known plaintext and encryption protocol.
      service.addMessageForTesting(
        bareJid: bareJid,
        from: from,
        to: to,
        body: 'the message I actually typed',
        outgoing: true,
        timestamp: timestamp,
        messageId: messageId,
        encryptionProtocol: 'omemo',
        plaintext: 'the message I actually typed',
      );

      // Second add for the same messageId: a MAM catch-up/carbon replay of
      // our own outgoing stanza after a restart. Outgoing messages never
      // go through decryptIncoming, so this call carries only the wire
      // fallback body, with no encryptionProtocol/encryptionError/
      // plaintext at all.
      service.addMessageForTesting(
        bareJid: bareJid,
        from: from,
        to: to,
        body: fallbackBody,
        outgoing: true,
        timestamp: timestamp,
        messageId: messageId,
      );

      final merged = service.messagesFor(bareJid).single;
      expect(merged.body, 'the message I actually typed');
      expect(merged.plaintext, 'the message I actually typed');
      expect(merged.encryptionProtocol, 'omemo');
    },
  );
}

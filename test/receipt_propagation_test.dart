import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/xmpp/xmpp_service.dart';

void main() {
  group('receipt propagation hardening', () {
    const toBareJid = 'bob@example.com';
    late XmppService service;

    setUp(() {
      service = XmppService();
      service.seedConnectedChatForTesting(toBareJid);
      addTearDown(service.dispose);
    });

    test(
      'a receipt reconciles every outgoing message sharing the same id, '
      'not just the most recent copy',
      () {
        service.sendMessage(toBareJid: toBareJid, text: 'hello');
        final messageId = service.messagesFor(toBareJid).single.messageId!;

        // Simulate the duplicate that a resend-on-reconnect race could
        // previously leave behind: a second outgoing copy with the exact
        // same stanza id.
        service.seedDuplicateOutgoingMessageForTesting(
          bareJid: toBareJid,
          messageId: messageId,
          body: 'hello',
        );
        expect(service.messagesFor(toBareJid), hasLength(2));
        expect(
          service.messagesFor(toBareJid).every((m) => !m.receiptReceived),
          isTrue,
        );

        // A single XEP-0184 receipt for that id arrives.
        service.applyReceiptForTesting(toBareJid, messageId);

        // Both copies must be reconciled - previously only the most
        // recently added one would have been, leaving the other looking
        // permanently unacknowledged and primed for another resend.
        final messages = service.messagesFor(toBareJid);
        expect(messages, hasLength(2));
        expect(messages.every((m) => m.receiptReceived), isTrue);
      },
    );
  });
}

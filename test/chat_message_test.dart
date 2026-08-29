import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/models/chat_message.dart';

void main() {
  test('ChatMessage serializes reactions and raw XML', () {
    final message = ChatMessage(
      from: 'alice@example.com',
      to: 'bob@example.com',
      body: 'hello',
      timestamp: DateTime.parse('2024-08-09T10:11:12Z'),
      outgoing: false,
      messageId: 'msg-1',
      rawXml: '<message id="msg-1"><body>hello</body></message>',
      oobDescription: 'A friendly greeting',
      edited: true,
      editedAt: DateTime.parse('2024-08-09T10:12:13Z'),
      fileTransferId: 'ft-1',
      fileName: 'photo.png',
      fileSize: 1234,
      fileMime: 'image/png',
      fileBytes: 567,
      fileState: 'in_progress',
      reactions: const {
        '👍': ['alice@example.com', 'bob@example.com'],
      },
      replyToId: 'orig-1',
      replyToJid: 'alice@example.com',
      replyFallback: '> hello',
    );

    final roundtrip = ChatMessage.fromMap(message.toMap());
    expect(roundtrip, isNotNull);
    expect(roundtrip!.rawXml, contains('<message'));
    expect(roundtrip.oobDescription, 'A friendly greeting');
    expect(roundtrip.edited, isTrue);
    expect(roundtrip.editedAt, DateTime.parse('2024-08-09T10:12:13Z'));
    expect(roundtrip.fileTransferId, 'ft-1');
    expect(roundtrip.fileName, 'photo.png');
    expect(roundtrip.fileSize, 1234);
    expect(roundtrip.fileMime, 'image/png');
    expect(roundtrip.fileBytes, 567);
    expect(roundtrip.fileState, 'in_progress');
    expect(roundtrip.reactions, isNotNull);
    expect(roundtrip.reactions!['👍'], [
      'alice@example.com',
      'bob@example.com',
    ]);
    expect(roundtrip.replyToId, 'orig-1');
    expect(roundtrip.replyToJid, 'alice@example.com');
    expect(roundtrip.replyFallback, '> hello');
  });

  test('ChatMessage persists outgoing tick state', () {
    final message = ChatMessage(
      from: 'me@example.com',
      to: 'alice@example.com',
      body: 'hello',
      timestamp: DateTime.parse('2024-08-09T10:11:12Z'),
      outgoing: true,
      rawXml: '<message><body>hello</body></message>',
      acked: true,
      receiptReceived: true,
      displayed: true,
    );

    final roundtrip = ChatMessage.fromMap(message.toMap());

    expect(roundtrip, isNotNull);
    expect(roundtrip!.acked, isTrue);
    expect(roundtrip.receiptReceived, isTrue);
    expect(roundtrip.displayed, isTrue);
  });

  test('legacy outgoing message without tick state defaults to two ticks', () {
    final message = ChatMessage.fromMap({
      'from': 'me@example.com',
      'to': 'alice@example.com',
      'body': 'historical',
      'timestamp': '2024-08-09T10:11:12Z',
      'outgoing': true,
      'rawXml': '<message><body>historical</body></message>',
    });

    expect(message, isNotNull);
    expect(message!.acked, isFalse);
    expect(message.receiptReceived, isTrue);
    expect(message.displayed, isFalse);
  });

  test('ChatMessage rejects cached entries without raw XML', () {
    final roundtrip = ChatMessage.fromMap({
      'from': 'alice@example.com',
      'to': 'bob@example.com',
      'body': 'hello',
      'timestamp': '2024-08-09T10:11:12Z',
      'outgoing': false,
      'messageId': 'msg-1',
    });

    expect(roundtrip, isNull);
  });

  // ── copyWith ────────────────────────────────────────────────────────────────

  group('copyWith', () {
    // A fully-populated message used as the baseline for copyWith tests.
    final base = ChatMessage(
      from: 'alice@example.com',
      to: 'bob@example.com',
      body: 'hello',
      timestamp: DateTime.utc(2024, 1, 1),
      outgoing: false,
      messageId: 'msg-base',
      mamId: 'mam-1',
      stanzaId: 'stanza-1',
      oobUrl: 'https://example.com/img.png',
      oobDescription: 'An image',
      rawXml: '<message/>',
      inviteRoomJid: 'room@example.com',
      inviteReason: 'Join us',
      invitePassword: 'secret',
      fileTransferId: 'ft-1',
      fileName: 'photo.png',
      fileSize: 1024,
      fileMime: 'image/png',
      fileBytes: 512,
      fileState: 'in_progress',
      edited: false,
      editedAt: null,
      reactions: const {'👍': ['alice@example.com']},
      replyToId: 'orig-1',
      replyToJid: 'alice@example.com',
      replyFallback: '> hello',
      acked: false,
      receiptReceived: false,
      displayed: false,
    );

    test('returns identical field values when called with no arguments', () {
      final copy = base.copyWith();
      expect(copy.from, base.from);
      expect(copy.to, base.to);
      expect(copy.body, base.body);
      expect(copy.timestamp, base.timestamp);
      expect(copy.outgoing, base.outgoing);
      expect(copy.messageId, base.messageId);
      expect(copy.mamId, base.mamId);
      expect(copy.stanzaId, base.stanzaId);
      expect(copy.oobUrl, base.oobUrl);
      expect(copy.oobDescription, base.oobDescription);
      expect(copy.rawXml, base.rawXml);
      expect(copy.inviteRoomJid, base.inviteRoomJid);
      expect(copy.inviteReason, base.inviteReason);
      expect(copy.invitePassword, base.invitePassword);
      expect(copy.fileTransferId, base.fileTransferId);
      expect(copy.fileName, base.fileName);
      expect(copy.fileSize, base.fileSize);
      expect(copy.fileMime, base.fileMime);
      expect(copy.fileBytes, base.fileBytes);
      expect(copy.fileState, base.fileState);
      expect(copy.edited, base.edited);
      expect(copy.editedAt, base.editedAt);
      expect(copy.reactions, base.reactions);
      expect(copy.replyToId, base.replyToId);
      expect(copy.replyToJid, base.replyToJid);
      expect(copy.replyFallback, base.replyFallback);
      expect(copy.acked, base.acked);
      expect(copy.receiptReceived, base.receiptReceived);
      expect(copy.displayed, base.displayed);
    });

    test('overrides scalar non-nullable fields', () {
      final copy = base.copyWith(
        from: 'carol@example.com',
        to: 'dave@example.com',
        body: 'updated body',
        outgoing: true,
        edited: true,
        acked: true,
        receiptReceived: true,
        displayed: true,
      );
      expect(copy.from, 'carol@example.com');
      expect(copy.to, 'dave@example.com');
      expect(copy.body, 'updated body');
      expect(copy.outgoing, isTrue);
      expect(copy.edited, isTrue);
      expect(copy.acked, isTrue);
      expect(copy.receiptReceived, isTrue);
      expect(copy.displayed, isTrue);
      // Unrelated fields must be unchanged.
      expect(copy.messageId, base.messageId);
      expect(copy.mamId, base.mamId);
    });

    test('overrides nullable String fields via sentinel', () {
      final copy = base.copyWith(
        messageId: 'new-id',
        mamId: 'new-mam',
        stanzaId: 'new-stanza',
        oobUrl: 'https://example.com/new.png',
        oobDescription: 'New description',
        rawXml: '<message id="new"/>',
        fileTransferId: 'ft-2',
        fileName: 'video.mp4',
        fileMime: 'video/mp4',
        fileState: 'complete',
        replyToId: 'orig-2',
        replyToJid: 'carol@example.com',
        replyFallback: '> updated',
      );
      expect(copy.messageId, 'new-id');
      expect(copy.mamId, 'new-mam');
      expect(copy.stanzaId, 'new-stanza');
      expect(copy.oobUrl, 'https://example.com/new.png');
      expect(copy.oobDescription, 'New description');
      expect(copy.rawXml, '<message id="new"/>');
      expect(copy.fileTransferId, 'ft-2');
      expect(copy.fileName, 'video.mp4');
      expect(copy.fileMime, 'video/mp4');
      expect(copy.fileState, 'complete');
      expect(copy.replyToId, 'orig-2');
      expect(copy.replyToJid, 'carol@example.com');
      expect(copy.replyFallback, '> updated');
    });

    test('overrides nullable int fields via sentinel', () {
      final copy = base.copyWith(fileSize: 2048, fileBytes: 1024);
      expect(copy.fileSize, 2048);
      expect(copy.fileBytes, 1024);
    });

    test('clears nullable fields to null via explicit null (sentinel pattern)',
        () {
      final copy = base.copyWith(
        messageId: null,
        mamId: null,
        stanzaId: null,
        oobUrl: null,
        oobDescription: null,
        rawXml: null,
        inviteRoomJid: null,
        inviteReason: null,
        invitePassword: null,
        fileTransferId: null,
        fileName: null,
        fileSize: null,
        fileMime: null,
        fileBytes: null,
        fileState: null,
        editedAt: null,
        reactions: null,
        replyToId: null,
        replyToJid: null,
        replyFallback: null,
      );
      expect(copy.messageId, isNull);
      expect(copy.mamId, isNull);
      expect(copy.stanzaId, isNull);
      expect(copy.oobUrl, isNull);
      expect(copy.oobDescription, isNull);
      expect(copy.rawXml, isNull);
      expect(copy.inviteRoomJid, isNull);
      expect(copy.inviteReason, isNull);
      expect(copy.invitePassword, isNull);
      expect(copy.fileTransferId, isNull);
      expect(copy.fileName, isNull);
      expect(copy.fileSize, isNull);
      expect(copy.fileMime, isNull);
      expect(copy.fileBytes, isNull);
      expect(copy.fileState, isNull);
      expect(copy.editedAt, isNull);
      expect(copy.reactions, isNull);
      expect(copy.replyToId, isNull);
      expect(copy.replyToJid, isNull);
      expect(copy.replyFallback, isNull);
      // Non-nullable fields must be unchanged.
      expect(copy.from, base.from);
      expect(copy.body, base.body);
    });

    test('updates reactions map independently', () {
      final newReactions = {
        '❤️': ['bob@example.com'],
        '👍': ['alice@example.com', 'carol@example.com'],
      };
      final copy = base.copyWith(reactions: newReactions);
      expect(copy.reactions, newReactions);
      // Original must be unaffected.
      expect(base.reactions, const {'👍': ['alice@example.com']});
    });

    test('sets editedAt when marking a message as edited', () {
      final editTime = DateTime.utc(2024, 6, 15, 12, 0, 0);
      final copy = base.copyWith(edited: true, editedAt: editTime);
      expect(copy.edited, isTrue);
      expect(copy.editedAt, editTime);
    });

    test('does not mutate the original message', () {
      base.copyWith(body: 'mutated', acked: true, mamId: null);
      expect(base.body, 'hello');
      expect(base.acked, isFalse);
      expect(base.mamId, 'mam-1');
    });
  });

  // ── Notification ID stability ────────────────────────────────────────────────

  group('notification ID stability', () {
    // The notification ID formula used in main.dart:
    //   bareJid.hashCode.abs() % (1 << 31)
    // It must be deterministic (same JID → same ID) and within Android's
    // valid notification ID range [0, 2^31 - 1].

    int notifId(String bareJid) => bareJid.hashCode.abs() % (1 << 31);

    test('same JID always produces the same notification ID', () {
      const jid = 'alice@example.com';
      expect(notifId(jid), notifId(jid));
    });

    test('notification ID is non-negative', () {
      for (final jid in [
        'alice@example.com',
        'bob@xmpp.org',
        'room@conference.example.com',
        'a@b',
      ]) {
        expect(notifId(jid), isNonNegative,
            reason: 'ID for $jid must be non-negative');
      }
    });

    test('notification ID is within 32-bit signed range', () {
      for (final jid in [
        'alice@example.com',
        'bob@xmpp.org',
        'room@conference.example.com',
      ]) {
        expect(notifId(jid), lessThan(1 << 31),
            reason: 'ID for $jid must be < 2^31');
      }
    });

    test('different JIDs produce different notification IDs', () {
      final ids = {
        notifId('alice@example.com'),
        notifId('bob@example.com'),
        notifId('carol@xmpp.org'),
      };
      // All three should be distinct (hash collisions are astronomically
      // unlikely for these short, well-separated strings).
      expect(ids.length, 3);
    });
  });

  test('ChatMessage accepts invite without body when raw XML present', () {
    final roundtrip = ChatMessage.fromMap({
      'from': 'alice@example.com',
      'to': 'bob@example.com',
      'body': '',
      'timestamp': '2024-08-09T10:11:12Z',
      'outgoing': false,
      'messageId': 'msg-2',
      'rawXml': '<message id="msg-2"/>',
      'inviteRoomJid': 'room@example.com',
      'inviteReason': 'Join us',
    });

    expect(roundtrip, isNotNull);
    expect(roundtrip!.inviteRoomJid, 'room@example.com');
    expect(roundtrip.inviteReason, 'Join us');
  });
}

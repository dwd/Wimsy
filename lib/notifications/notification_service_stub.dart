class NotificationEvent {
  const NotificationEvent({
    required this.actionId,
    required this.payload,
    required this.launchedApp,
  });

  final String? actionId;
  final String? payload;
  final bool launchedApp;
}

typedef NotificationEventHandler = void Function(NotificationEvent event);

class NotificationService {
  Future<void> initialize({NotificationEventHandler? onEvent}) async {}

  Future<void> showMessage({
    required int id,
    required String title,
    required String body,
    required String chatJid,
    String? tag,
  }) async {}

  Future<void> cancelMessagesForTag(String tag) async {}

  Future<void> showIncomingCall({
    required String sid,
    required String peerJid,
    required bool video,
  }) async {}

  Future<void> cancelIncomingCall(String sid) async {}

  bool get isInitialized => true;
}

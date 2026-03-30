import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final Map<String, Set<int>> _messageIdsByTag = <String, Set<int>>{};
  bool _initialized = false;
  NotificationEventHandler? _eventHandler;

  Future<void> initialize({NotificationEventHandler? onEvent}) async {
    if (_initialized) {
      if (onEvent != null) {
        _eventHandler = onEvent;
      }
      return;
    }
    _eventHandler = onEvent;
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    final darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestSoundPermission: true,
      requestBadgePermission: true,
    );
    final linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open',
    );
    final settings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
      linux: linuxSettings,
    );
    try {
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: _handleNotificationResponse,
        onDidReceiveBackgroundNotificationResponse:
            notificationTapBackgroundHandler,
      );
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
      }
      _initialized = true;
      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true &&
          launchDetails?.notificationResponse != null) {
        _emitNotificationEvent(
          launchDetails!.notificationResponse!,
          launchedApp: true,
        );
      }
    } catch (error) {
      if (error.toString().contains('LateInitializationError')) {
        // Flutter test environment doesn't wire the platform implementation.
        _initialized = true;
        return;
      }
      // Avoid crashing app startup if notifications fail to initialize.
      _initialized = false;
    }
  }

  Future<void> showMessage({
    required int id,
    required String title,
    required String body,
    required String chatJid,
    String? tag,
  }) async {
    if (!_initialized) {
      await initialize();
    }
    final androidDetails = AndroidNotificationDetails(
      'wimsy_messages',
      'Messages',
      channelDescription: 'Incoming chat messages',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      tag: tag,
    );
    const darwinDetails = DarwinNotificationDetails();
    const linuxDetails = LinuxNotificationDetails();
    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      linux: linuxDetails,
    );
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
        payload: jsonEncode(<String, String>{
          'type': 'chat',
          'chatJid': chatJid,
        }),
      );
      if (tag != null && tag.isNotEmpty) {
        _messageIdsByTag.putIfAbsent(tag, () => <int>{}).add(id);
      }
    } catch (error) {
      if (error.toString().contains('LateInitializationError')) {
        // Ignore in tests or unsupported environments.
        return;
      }
      // Ignore notification failures to avoid impacting core UX.
    }
  }

  Future<void> cancelMessagesForTag(String tag) async {
    if (tag.isEmpty) {
      return;
    }
    if (!_initialized) {
      await initialize();
    }
    final ids = _messageIdsByTag.remove(tag);
    if (ids == null || ids.isEmpty) {
      return;
    }
    for (final id in ids) {
      try {
        await _plugin.cancel(id: id);
      } catch (_) {
        // Ignore cancellation errors.
      }
    }
  }

  Future<void> showIncomingCall({
    required String sid,
    required String peerJid,
    required bool video,
  }) async {
    if (!_initialized) {
      await initialize();
    }
    final androidDetails = AndroidNotificationDetails(
      'wimsy_calls',
      'Calls',
      channelDescription: 'Incoming calls',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true,
      ongoing: true,
      autoCancel: false,
      playSound: true,
      actions: <AndroidNotificationAction>[
        const AndroidNotificationAction(
          'call_answer',
          'Answer',
          showsUserInterface: true,
          cancelNotification: true,
        ),
        const AndroidNotificationAction(
          'call_decline',
          'Decline',
          showsUserInterface: true,
          cancelNotification: true,
        ),
      ],
      tag: sid,
    );
    final details = NotificationDetails(android: androidDetails);
    final kind = video ? 'video' : 'voice';
    try {
      await _plugin.show(
        id: _callNotificationIdForSid(sid),
        title: 'Incoming $kind call',
        body: peerJid,
        notificationDetails: details,
        payload: jsonEncode(<String, String>{
          'type': 'call',
          'sid': sid,
          'chatJid': peerJid,
        }),
      );
    } catch (_) {
      // Ignore notification failures to avoid impacting core UX.
    }
  }

  Future<void> cancelIncomingCall(String sid) async {
    if (sid.isEmpty) {
      return;
    }
    if (!_initialized) {
      await initialize();
    }
    try {
      await _plugin.cancel(id: _callNotificationIdForSid(sid));
    } catch (_) {
      // Ignore cancellation errors.
    }
  }

  bool get isInitialized => _initialized;

  void _handleNotificationResponse(NotificationResponse response) {
    _emitNotificationEvent(response, launchedApp: false);
  }

  void _emitNotificationEvent(
    NotificationResponse response, {
    required bool launchedApp,
  }) {
    _eventHandler?.call(
      NotificationEvent(
        actionId: response.actionId,
        payload: response.payload,
        launchedApp: launchedApp,
      ),
    );
  }
}

int _callNotificationIdForSid(String sid) {
  var hash = 0;
  for (final codeUnit in sid.codeUnits) {
    hash = ((hash * 31) + codeUnit) & 0x7fffffff;
  }
  return 0x40000000 | hash;
}

@pragma('vm:entry-point')
void notificationTapBackgroundHandler(NotificationResponse response) {
  // Main isolate handles launch details and foreground notification responses.
}

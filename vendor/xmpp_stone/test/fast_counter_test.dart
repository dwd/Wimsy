import 'dart:async';
import 'package:test/test.dart';
import 'package:xmpp_stone/src/account/XmppAccountSettings.dart';

void main() {
  test('counter reservation waits for durable storage and never reuses a count',
      () async {
    final saved = Completer<void>();
    final account = XmppAccountSettings.fromJid('a@example.com', '')
      ..fastToken = 'token'
      ..fastTokenCount = 12
      ..persistFastCounter = (_) => saved.future;
    var complete = false;
    final reservation = account.reserveFastCounter('token').then((value) {
      complete = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(complete, isFalse);
    expect(account.fastTokenCount, 13);
    saved.complete();
    expect(await reservation, 13);
    expect(await account.reserveFastCounter('token'), 14);
  });

  test('storage failure and token rotation cannot release an unsafe count',
      () async {
    final account = XmppAccountSettings.fromJid('a@example.com', '')
      ..fastToken = 'token'
      ..persistFastCounter = (_) => Future.error(StateError('disk full'));
    await expectLater(account.reserveFastCounter('token'), throwsStateError);
    expect(account.fastTokenCount, 1);
    account.persistFastCounter = (_) async {};
    expect(await account.reserveFastCounter('token'), 2);
    account.storeFastToken('next', null);
    expect(account.fastTokenCount, 0);
    await expectLater(account.reserveFastCounter('token'), throwsStateError);
    expect(await account.reserveFastCounter('next'), 1);
  });
}

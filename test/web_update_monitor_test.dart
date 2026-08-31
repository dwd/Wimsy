import 'package:flutter_test/flutter_test.dart';
import 'package:wimsy/web_update_monitor.dart';

void main() {
  test('parseBuildId reads a valid update marker', () {
    expect(parseBuildId('{"build_id":"abc123"}'), 'abc123');
  });

  test('parseBuildId rejects malformed or empty markers', () {
    expect(parseBuildId('not json'), isNull);
    expect(parseBuildId('{}'), isNull);
    expect(parseBuildId('{"build_id":""}'), isNull);
  });
}

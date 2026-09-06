import 'dart:convert';
import 'dart:typed_data';

/// Retains only the initial negotiation flight until QUIC accepts or rejects it.
/// Rejected 0-RTT streams disappear entirely; their bytes must be resent on a
/// new stream. Accepted bytes must never be sent a second time.
class QuicEarlyDataBuffer {
  final _bytes = BytesBuilder(copy: false);
  static const maxBytes = 64 * 1024;

  void add(String payload) {
    final bytes = utf8.encode(payload);
    if (_bytes.length + bytes.length > maxBytes) {
      throw StateError('QUIC early authentication exceeds buffer limit');
    }
    _bytes.add(bytes);
  }

  Uint8List finish({required bool accepted}) {
    final bytes = _bytes.takeBytes();
    return accepted ? Uint8List(0) : bytes;
  }
}

/// Serializes platform service requests so Stop cannot overtake a pending
/// Start, and a fresh Start waits for the previous service to stop.
class ServiceLifecycle {
  Future<void> _pending = Future<void>.value();

  Future<void> run(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    // A failed platform request must not poison all subsequent requests.
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// Serializes resource mutations without blocking an isolate or poisoning the
/// next command when one operation fails.
class SerialExecutor {
  Future<void> _tail = Future.value();
  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }
}

import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;

/// A network interface is not proof that the selected server is reachable.
/// Failed reads open a short circuit shared by catalogue and playback requests.
class ServerHttpClient extends http.BaseClient {
  ServerHttpClient(
    this.inner, {
    this.readTimeout = const Duration(seconds: 4),
    this.backoff = const Duration(seconds: 8),
  });
  final http.Client inner;
  final Duration readTimeout, backoff;
  bool unavailable = false;
  DateTime? _retryAt;
  void Function(bool available)? onConnectionChanged;

  void allowRetry() => _retryAt = null;

  void _failed() {
    _retryAt = DateTime.now().add(backoff);
    if (!unavailable) {
      unavailable = true;
      onConnectionChanged?.call(false);
    }
  }

  bool _transportError(Object error) =>
      error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_retryAt case final retryAt? when DateTime.now().isBefore(retryAt)) {
      throw const SocketException('Server temporarily unavailable');
    }
    final deadline =
        request.method == 'GET' || request.url.path.endsWith('/PlaybackInfo')
        ? readTimeout
        : const Duration(seconds: 30);
    try {
      final response = await inner.send(request).timeout(deadline);
      return http.StreamedResponse(
        _body(response.stream, deadline),
        response.statusCode,
        headers: response.headers,
        contentLength: response.contentLength,
        request: response.request,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } on Object catch (error) {
      if (_transportError(error)) _failed();
      rethrow;
    }
  }

  Stream<List<int>> _body(Stream<List<int>> stream, Duration deadline) async* {
    try {
      await for (final chunk in stream.timeout(deadline)) {
        yield chunk;
      }
      if (unavailable) {
        unavailable = false;
        _retryAt = null;
        onConnectionChanged?.call(true);
      }
    } on Object catch (error) {
      if (_transportError(error)) _failed();
      rethrow;
    }
  }

  @override
  void close() {
    onConnectionChanged = null;
    inner.close();
  }
}

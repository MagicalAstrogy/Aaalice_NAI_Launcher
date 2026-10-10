import 'dart:async';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

import '../cloud_sync/oauth/oauth_pkce.dart';
import 'codex_oauth_models.dart';

abstract interface class CodexOAuthCallbackReceiver {
  Uri get redirectUri;
  Future<Uri> receive({required String state});
  Future<void> close();
}

typedef CodexOAuthReceiverFactory =
    Future<CodexOAuthCallbackReceiver> Function();
typedef CodexOAuthBrowserLauncher = Future<bool> Function(Uri uri);

Future<bool> launchCodexOAuthBrowser(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

Future<CodexOAuthCallbackReceiver> startCodexOAuthReceiver() async {
  try {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _LoopbackReceiver(server);
  } catch (_) {
    throw const CodexOAuthException(
      'browser_unavailable',
      'Could not open the local sign-in callback.',
    );
  }
}

final class _LoopbackReceiver implements CodexOAuthCallbackReceiver {
  _LoopbackReceiver(this._server)
    : redirectUri = Uri.parse('http://127.0.0.1:${_server.port}/auth/callback');

  final HttpServer _server;
  final Completer<Uri> _callback = Completer<Uri>();
  StreamSubscription<HttpRequest>? _subscription;
  bool _closed = false;

  @override
  final Uri redirectUri;

  @override
  Future<Uri> receive({required String state}) {
    _subscription ??= _server.listen(
      (request) {
        unawaited(_handleRequest(request, state));
      },
      onError: (Object _) {
        if (!_callback.isCompleted) {
          _callback.completeError(
            const CodexOAuthException(
              'network_error',
              'The local sign-in callback failed.',
            ),
          );
        }
      },
    );
    return _callback.future;
  }

  Future<void> _handleRequest(HttpRequest request, String state) async {
    var accepted = false;
    try {
      final uri = request.uri;
      final states = uri.queryParametersAll['state'];
      accepted =
          !_closed &&
          !_callback.isCompleted &&
          request.method == 'GET' &&
          uri.path == '/auth/callback' &&
          request.headers.value(HttpHeaders.hostHeader) ==
              '127.0.0.1:${_server.port}' &&
          request.connectionInfo?.remoteAddress.isLoopback == true &&
          uri.toString().length <= 16384 &&
          states?.length == 1 &&
          OAuthPkce.secureEquals(state, states!.single);
      request.response.statusCode = accepted
          ? HttpStatus.ok
          : HttpStatus.badRequest;
      request.response.headers.contentType = ContentType.text;
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.response.headers.set('Referrer-Policy', 'no-referrer');
      request.response.headers.set(
        'Content-Security-Policy',
        "default-src 'none'",
      );
      request.response.write(
        accepted
            ? 'Return to Aaalice NAI Launcher to finish signing in.'
            : 'Invalid sign-in callback.',
      );
      // Consume exactly once before asynchronous response completion.
      if (accepted) _callback.complete(uri);
      await request.response.close();
    } catch (_) {
      // Browser disconnects must not leak callback URLs or abort another login.
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_callback.isCompleted && _subscription != null) {
      _callback.completeError(
        const CodexOAuthException('cancelled', 'Sign-in was cancelled.'),
      );
    }
    await _subscription?.cancel();
    await _server.close(force: true);
  }
}

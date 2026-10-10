import 'dart:async';

import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../cloud_sync/oauth/oauth_pkce.dart';
import 'codex_oauth_http.dart';
import 'codex_oauth_id_token_validator.dart';
import 'codex_oauth_loopback.dart';
import 'codex_oauth_models.dart';
import 'codex_oauth_session.dart';
import 'codex_oauth_store.dart';

export 'codex_oauth_models.dart';

/// Public-client Sign in with ChatGPT for this locally hosted, open-source app.
/// Credentials never enter provider configuration or its export/sync boundary.
/// Protocol: https://developers.openai.com/siwc/token-sharing-open-source/sign-in
class CodexOAuthService {
  CodexOAuthService({
    CodexOAuthStore? store,
    CodexOAuthHttp? http,
    CodexOAuthReceiverFactory? receiverFactory,
    CodexOAuthBrowserLauncher? browserLauncher,
    CodexOAuthIdTokenValidator? idTokenValidator,
    OAuthPkce? pkce,
    DateTime Function()? clock,
    Duration loginTimeout = const Duration(minutes: 5),
  }) : _store = store ?? SecureCodexOAuthStore(),
       _http = http ?? OfficialCodexOAuthHttp(),
       _receiverFactory = receiverFactory ?? startCodexOAuthReceiver,
       _browserLauncher = browserLauncher ?? launchCodexOAuthBrowser,
       _pkce = pkce ?? OAuthPkce(),
       _clock = clock ?? DateTime.now,
       _loginTimeout = loginTimeout {
    _validator =
        idTokenValidator ??
        CodexOAuthIdTokenValidator(loadJwks: _loadJwks, clock: _clock);
  }

  final CodexOAuthStore _store;
  final CodexOAuthHttp _http;
  final CodexOAuthReceiverFactory _receiverFactory;
  final CodexOAuthBrowserLauncher _browserLauncher;
  final OAuthPkce _pkce;
  final DateTime Function() _clock;
  final Duration _loginTimeout;
  late final CodexOAuthIdTokenValidator _validator;
  final _changes = StreamController<CodexOAuthStatus>.broadcast();
  final _statuses = <String, CodexOAuthStatus>{};
  final _generations = <String, int>{};
  final _locks = <String, Lock>{};
  final _hostLock = Lock();
  final _attempts = <String, _LoginAttempt>{};
  final _refreshes = <String, Future<String>>{};
  final _blocked = <String>{};
  // Provisional callback registrations are not verified accounts. Retain only
  // in memory after invalid_grant so a fresh authorization can reuse the ID.
  final _pendingClientIds = <String, String>{};
  final _requests = <String, Set<void Function()>>{};
  bool _disposed = false;

  Lock _lock(String id) => _locks.putIfAbsent(id, Lock.new);
  int _generation(String id) => _generations[id] ?? 0;
  String _sessionKey(String id) => 'provider:$id';

  /// Binds an inference request to the current account lifecycle. The returned
  /// callback unregisters it after completion without cancelling the request.
  void Function() registerRequest(String providerId, void Function() cancel) {
    void cancelRequest() {
      try {
        cancel();
      } catch (_) {
        /* Cancellation is best-effort cleanup. */
      }
    }

    if (_disposed || _blocked.contains(providerId)) {
      cancelRequest();
      return () {};
    }
    _requests.putIfAbsent(providerId, () => {}).add(cancelRequest);
    return () {
      final requests = _requests[providerId];
      requests?.remove(cancelRequest);
      if (requests?.isEmpty == true) _requests.remove(providerId);
    };
  }

  int _invalidate(String id) {
    final generation = _generation(id) + 1;
    _generations[id] = generation;
    _refreshes.remove(id);
    final requests = _requests.remove(id);
    for (final cancel in requests ?? <void Function()>{}) {
      cancel();
    }
    return generation;
  }

  void _checkCurrent(String id, int generation) {
    if (_disposed || _generation(id) != generation) {
      throw const CodexOAuthException('cancelled', 'Sign-in was cancelled.');
    }
  }

  void _emit(CodexOAuthStatus status) {
    if (_disposed) return;
    _statuses[status.providerId] = status;
    _changes.add(status);
  }

  Future<CodexOAuthSession?> _read(String id) async {
    try {
      final encoded = await _store.read(_sessionKey(id));
      return encoded == null ? null : CodexOAuthSession.decode(encoded, id);
    } on CodexOAuthException {
      rethrow;
    } catch (_) {
      throw const CodexOAuthException(
        'storage_error',
        'Secure credential storage is unavailable.',
      );
    }
  }

  Future<void> _writeRaw(String id, String? value) async {
    try {
      if (value == null) {
        await _store.delete(_sessionKey(id));
      } else {
        await _store.write(_sessionKey(id), value);
      }
    } catch (_) {
      _blocked.add(id);
      throw const CodexOAuthException(
        'storage_error',
        'Could not update credentials securely.',
      );
    }
  }

  Future<void> _save(CodexOAuthSession session, int generation) =>
      _lock(session.providerId).synchronized(() async {
        final id = session.providerId;
        _checkCurrent(id, generation);
        final previous = await _read(id);
        _checkCurrent(id, generation);
        await _writeRaw(id, session.encodeForSecureStorage());
        if (_generation(id) != generation || _disposed) {
          await _writeRaw(id, previous?.encodeForSecureStorage());
          _checkCurrent(id, generation);
        }
        _blocked.remove(id);
      });

  Future<String> _hostId() => _hostLock.synchronized(() async {
    try {
      const key = 'installation_host_id';
      final existing = await _store.read(key);
      if (existing != null &&
          RegExp(
            r'^urn:uuid:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-'
            r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
          ).hasMatch(existing)) {
        return existing;
      }
      final value = 'urn:uuid:${const Uuid().v4()}';
      await _store.write(key, value);
      return value;
    } catch (_) {
      throw const CodexOAuthException(
        'storage_error',
        'Could not save the sign-in host securely.',
      );
    }
  });

  Future<CodexOAuthStatus> getStatus(String providerId) async {
    final current = _statuses[providerId];
    if (current != null) return current;
    try {
      final record = await _lock(
        providerId,
      ).synchronized(() => _read(providerId));
      final status =
          _statuses[providerId] ??
          CodexOAuthStatus(
            providerId: providerId,
            phase: record?.planPermissionMissing == true
                ? CodexOAuthPhase.error
                : record?.hasCredentials == true &&
                      !_blocked.contains(providerId)
                ? CodexOAuthPhase.signedIn
                : CodexOAuthPhase.signedOut,
            accountLabel: record?.accountLabel,
            errorCode: record?.planPermissionMissing == true
                ? 'permission_missing'
                : null,
          );
      _statuses[providerId] = status;
      return status;
    } on CodexOAuthException catch (error) {
      return CodexOAuthStatus(
        providerId: providerId,
        phase: CodexOAuthPhase.error,
        errorCode: error.code,
      );
    }
  }

  Stream<CodexOAuthStatus> watchStatus(String providerId) =>
      Stream.multi((sink) {
        var changed = false;
        final subscription = _changes.stream
            .where((status) => status.providerId == providerId)
            .listen((status) {
              changed = true;
              sink.add(status);
            });
        unawaited(
          getStatus(providerId).then((status) {
            if (!changed) sink.add(status);
          }),
        );
        sink.onCancel = subscription.cancel;
      });

  Future<CodexOAuthStatus> login({required String providerId}) {
    if (_disposed) {
      return Future.error(
        const CodexOAuthException('cancelled', 'Service closed.'),
      );
    }
    final existing = _attempts[providerId];
    if (existing != null) return existing.result;
    final generation = _invalidate(providerId);
    final attempt = _LoginAttempt(generation, _statuses[providerId]);
    _attempts[providerId] = attempt;
    _emit(
      CodexOAuthStatus(
        providerId: providerId,
        phase: CodexOAuthPhase.signingIn,
        accountLabel: _statuses[providerId]?.accountLabel,
      ),
    );
    attempt.result = _performLogin(providerId, attempt);
    return attempt.result;
  }

  Future<CodexOAuthStatus> _performLogin(
    String id,
    _LoginAttempt attempt,
  ) async {
    try {
      final record =
          await Future.any([
            _authorize(id, attempt),
            attempt.cancelled.future.then<CodexOAuthSession>(
              (_) => throw const CodexOAuthException(
                'cancelled',
                'Sign-in was cancelled.',
              ),
            ),
          ]).timeout(
            _loginTimeout,
            onTimeout: () {
              _invalidate(id);
              throw const CodexOAuthException('timeout', 'Sign-in timed out.');
            },
          );
      _checkCurrent(id, attempt.generation);
      final status = CodexOAuthStatus(
        providerId: id,
        phase: CodexOAuthPhase.signedIn,
        accountLabel: record.accountLabel,
      );
      _emit(status);
      return status;
    } catch (error) {
      final safe = error is CodexOAuthException
          ? error
          : const CodexOAuthException(
              'invalid_response',
              'Sign-in could not be completed.',
            );
      if (!_disposed && identical(_attempts[id], attempt)) {
        _emit(
          CodexOAuthStatus(
            providerId: id,
            phase: CodexOAuthPhase.error,
            errorCode: safe.code,
            accountLabel: _statuses[id]?.accountLabel,
          ),
        );
      }
      throw safe;
    } finally {
      await _closeReceiver(attempt.receiver);
      if (identical(_attempts[id], attempt)) _attempts.remove(id);
    }
  }

  Future<CodexOAuthSession> _authorize(String id, _LoginAttempt attempt) async {
    final previous = await _lock(id).synchronized(() => _read(id));
    final selectedClientId = previous?.clientId ?? _pendingClientIds[id];
    final hostId = await _hostId();
    _checkCurrent(id, attempt.generation);
    final receiver = await _receiverFactory();
    attempt.receiver = receiver;
    try {
      _checkCurrent(id, attempt.generation);
      final redirectUri = receiver.redirectUri;
      if (redirectUri.scheme != 'http' ||
          redirectUri.host != '127.0.0.1' ||
          redirectUri.path != '/auth/callback' ||
          redirectUri.userInfo.isNotEmpty ||
          redirectUri.hasQuery ||
          redirectUri.hasFragment) {
        throw const CodexOAuthException(
          'invalid_callback',
          'Invalid callback address.',
        );
      }
      final pkce = _pkce.create();
      final callback = receiver.receive(state: pkce.state);
      // Attach an error listener before opening an external application.
      unawaited(
        callback.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
      );
      final authorization = CodexOAuthEndpoints.authorize.replace(
        queryParameters: {
          'client_id':
              selectedClientId ?? CodexOAuthEndpoints.registrationClient,
          if (selectedClientId == null)
            'agent_name_hint': 'Aaalice NAI Launcher',
          'ext_agent_host_id': hostId,
          if (previous?.idToken != null) 'id_token_hint': previous!.idToken!,
          if (previous?.planPermissionMissing == true) 'prompt': 'consent',
          'response_type': 'code',
          'redirect_uri': redirectUri.toString(),
          'scope': CodexOAuthEndpoints.scopes,
          'resource': CodexOAuthEndpoints.resource,
          'state': pkce.state,
          'nonce': pkce.nonce,
          'code_challenge_method': 'S256',
          'code_challenge': pkce.codeChallenge,
        },
      );
      if (!await _browserLauncher(authorization)) {
        throw const CodexOAuthException(
          'browser_unavailable',
          'Could not open the system browser.',
        );
      }
      final result = await callback;
      _checkCurrent(id, attempt.generation);
      return await _exchangeAndSave(
        id,
        attempt.generation,
        previous,
        selectedClientId,
        redirectUri,
        pkce,
        result,
      );
    } finally {
      await _closeReceiver(receiver);
    }
  }

  Future<CodexOAuthSession> _exchangeAndSave(
    String id,
    int generation,
    CodexOAuthSession? previous,
    String? selectedClientId,
    Uri redirectUri,
    OAuthPkceRequest pkce,
    Uri result,
  ) async {
    final clientId = _validateCallback(result, pkce.state, selectedClientId);
    final Map<String, dynamic> response;
    try {
      response = await _http.postForm(CodexOAuthEndpoints.token, {
        'grant_type': 'authorization_code',
        'client_id': clientId,
        'code': result.queryParameters['code']!,
        'code_verifier': pkce.codeVerifier,
        'redirect_uri': redirectUri.toString(),
        'resource': CodexOAuthEndpoints.resource,
      });
    } on CodexOAuthException catch (error) {
      if (previous == null && error.oauthErrorCode == 'invalid_grant') {
        _checkCurrent(id, generation);
        _pendingClientIds[id] = clientId;
      }
      rethrow;
    }
    _checkCurrent(id, generation);
    final idToken = _requiredString(response, 'id_token');
    CodexOAuthIdentity identity;
    try {
      identity = await _validator.validate(
        idToken,
        clientId: clientId,
        nonce: pkce.nonce,
        expectedSubject: previous?.subject,
      );
    } catch (_) {
      throw const CodexOAuthException(
        'invalid_id_token',
        'The account could not be verified.',
      );
    }
    final record = _tokens(
      response,
      CodexOAuthSession(
        providerId: id,
        clientId: clientId,
        subject: identity.subject,
        accountLabel: identity.email ?? identity.name ?? 'ChatGPT',
      ),
      idToken: idToken,
    );
    await _save(record, generation);
    _checkCurrent(id, generation);
    _pendingClientIds.remove(id);
    if (record.planPermissionMissing) {
      _emit(
        CodexOAuthStatus(
          providerId: id,
          phase: CodexOAuthPhase.error,
          accountLabel: record.accountLabel,
          errorCode: 'permission_missing',
        ),
      );
      throw const CodexOAuthException(
        'permission_missing',
        'ChatGPT plan usage permission was not granted.',
      );
    }
    return record;
  }

  String _validateCallback(Uri uri, String state, String? existingClientId) {
    for (final key in ['state', 'code', 'client_id', 'error', 'iss']) {
      if ((uri.queryParametersAll[key]?.length ?? 0) > 1) {
        throw const CodexOAuthException(
          'invalid_callback',
          'Ambiguous callback.',
        );
      }
    }
    if (uri.path != '/auth/callback' ||
        !OAuthPkce.secureEquals(state, uri.queryParameters['state'] ?? '') ||
        (uri.queryParameters.containsKey('iss') &&
            uri.queryParameters['iss'] != CodexOAuthEndpoints.issuer)) {
      throw const CodexOAuthException(
        'invalid_callback',
        'Sign-in callback did not match.',
      );
    }
    if (uri.queryParameters.containsKey('error')) {
      throw const CodexOAuthException(
        'authorization_denied',
        'Authorization was not granted.',
      );
    }
    final code = uri.queryParameters['code'];
    final clientId = uri.queryParameters['client_id'] ?? existingClientId;
    if (code == null ||
        code.isEmpty ||
        code.length > 8192 ||
        clientId == null ||
        clientId.isEmpty ||
        clientId.length > 512 ||
        clientId == CodexOAuthEndpoints.registrationClient ||
        (existingClientId != null && clientId != existingClientId)) {
      throw const CodexOAuthException(
        'invalid_callback',
        'Sign-in registration is incomplete.',
      );
    }
    return clientId;
  }

  void cancelLogin(String providerId) {
    final attempt = _attempts[providerId];
    if (attempt == null || attempt.cancelled.isCompleted) return;
    _invalidate(providerId);
    _attempts.remove(providerId);
    attempt.cancelled.complete();
    unawaited(_closeReceiver(attempt.receiver));
    _emit(attempt.previousStatus ?? CodexOAuthStatus(providerId: providerId));
  }

  Future<String> getAccessToken(
    String providerId, {
    bool forceRefresh = false,
  }) {
    if (_attempts.containsKey(providerId)) {
      return Future.error(
        const CodexOAuthException(
          'signed_out',
          'Complete the current ChatGPT sign-in first.',
        ),
      );
    }
    final existing = _refreshes[providerId];
    if (existing != null) return existing;
    final generation = _generation(providerId);
    final future = _accessToken(providerId, generation, forceRefresh);
    _refreshes[providerId] = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_refreshes[providerId], future)) {
            _refreshes.remove(providerId);
          }
        },
        onError: (Object _, StackTrace __) {
          if (identical(_refreshes[providerId], future)) {
            _refreshes.remove(providerId);
          }
        },
      ),
    );
    return future;
  }

  Future<String> _accessToken(
    String id,
    int generation,
    bool forceRefresh,
  ) async {
    _checkCurrent(id, generation);
    if (_blocked.contains(id)) {
      throw const CodexOAuthException(
        'storage_error',
        'Sign in again after checking secure storage.',
      );
    }
    final record = await _lock(id).synchronized(() => _read(id));
    _checkCurrent(id, generation);
    if (record == null || !record.hasCredentials) {
      if (record?.planPermissionMissing == true) {
        throw const CodexOAuthException(
          'permission_missing',
          'ChatGPT plan usage is disabled.',
        );
      }
      throw const CodexOAuthException(
        'signed_out',
        'Sign in with ChatGPT first.',
      );
    }
    if (record.planPermissionMissing) {
      throw const CodexOAuthException(
        'permission_missing',
        'ChatGPT plan usage is disabled.',
      );
    }
    final now = _clock().toUtc();
    if (!forceRefresh &&
        record.expiresAt!.isAfter(now.add(const Duration(minutes: 1)))) {
      return record.accessToken!;
    }
    if (record.earliestRefreshAt?.isAfter(now) == true) {
      if (!forceRefresh && record.expiresAt!.isAfter(now)) {
        return record.accessToken!;
      }
      throw const CodexOAuthException(
        'reauthentication_required',
        'The session cannot be renewed yet.',
      );
    }
    return _refreshToken(record, generation);
  }

  Future<String> _refreshToken(CodexOAuthSession record, int generation) async {
    final id = record.providerId;
    _emit(
      CodexOAuthStatus(
        providerId: id,
        phase: CodexOAuthPhase.refreshing,
        accountLabel: record.accountLabel,
      ),
    );
    try {
      final response = await _http.postForm(CodexOAuthEndpoints.token, {
        'grant_type': 'refresh_token',
        'client_id': record.clientId,
        'refresh_token': record.refreshToken!,
        'resource': CodexOAuthEndpoints.resource,
      });
      var idToken = record.idToken;
      if (response.containsKey('id_token')) {
        idToken = _requiredString(response, 'id_token');
        try {
          await _validator.validateRefresh(
            idToken,
            clientId: record.clientId,
            expectedSubject: record.subject,
          );
        } catch (_) {
          throw const CodexOAuthException(
            'invalid_id_token',
            'The renewed account could not be verified.',
          );
        }
      }
      final refreshed = _tokens(response, record, idToken: idToken);
      await _save(refreshed, generation);
      _checkCurrent(id, generation);
      if (refreshed.planPermissionMissing) {
        throw const CodexOAuthException(
          'permission_missing',
          'ChatGPT plan usage is disabled.',
        );
      }
      _emit(
        CodexOAuthStatus(
          providerId: id,
          phase: CodexOAuthPhase.signedIn,
          accountLabel: record.accountLabel,
        ),
      );
      return refreshed.accessToken!;
    } catch (error) {
      final safe = error is CodexOAuthException
          ? error
          : const CodexOAuthException(
              'network_error',
              'Could not renew the ChatGPT session.',
            );
      if (_generation(id) == generation && !_disposed) {
        if (safe.code == 'reauthentication_required') {
          await _save(record.withoutCredentials(), generation);
        }
        _emit(
          CodexOAuthStatus(
            providerId: id,
            phase: CodexOAuthPhase.error,
            accountLabel: record.accountLabel,
            errorCode: safe.code,
          ),
        );
      }
      throw safe;
    }
  }

  CodexOAuthSession _tokens(
    Map<String, dynamic> body,
    CodexOAuthSession identity, {
    String? idToken,
  }) {
    final tokenType = _requiredString(body, 'token_type');
    final seconds = body['expires_in'];
    if (tokenType.toLowerCase() != 'bearer' ||
        seconds is! num ||
        !seconds.isFinite ||
        seconds <= 0 ||
        seconds > 86400) {
      throw const CodexOAuthException(
        'invalid_response',
        'Invalid token lifetime or type.',
      );
    }
    final granted = body['scope'];
    final scopes = granted is String
        ? granted.split(RegExp(r'\s+')).toSet()
        : identity.scopes;
    final permissionMissing =
        !scopes.contains('chatgpt.tokens.use.direct') ||
        !scopes.contains('resource.invoke');
    DateTime? earliestRefreshAt;
    final earliest = body['earliest_refresh_at'];
    if (earliest is num && earliest.isFinite) {
      earliestRefreshAt = DateTime.fromMillisecondsSinceEpoch(
        (earliest * 1000).toInt(),
        isUtc: true,
      );
    } else if (earliest is String) {
      earliestRefreshAt = DateTime.tryParse(earliest)?.toUtc();
    }
    return CodexOAuthSession(
      providerId: identity.providerId,
      clientId: identity.clientId,
      subject: identity.subject,
      accountLabel: identity.accountLabel,
      accessToken: _requiredString(body, 'access_token'),
      refreshToken: permissionMissing && !body.containsKey('refresh_token')
          ? null
          : _requiredString(body, 'refresh_token'),
      idToken: idToken,
      scopes: scopes,
      planPermissionMissing: permissionMissing,
      expiresAt: _clock().toUtc().add(Duration(seconds: seconds.toInt())),
      earliestRefreshAt: earliestRefreshAt,
    );
  }

  String _requiredString(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String ||
        value.isEmpty ||
        value.length > 32768 ||
        value.contains('\r') ||
        value.contains('\n')) {
      throw const CodexOAuthException(
        'invalid_response',
        'Authentication response is incomplete.',
      );
    }
    return value;
  }

  Future<Map<String, dynamic>> _discovery() async {
    final discovery = await _http.getJson(CodexOAuthEndpoints.discovery);
    if (discovery['issuer'] != CodexOAuthEndpoints.issuer) {
      throw const CodexOAuthException(
        'invalid_response',
        'Authentication issuer did not match.',
      );
    }
    return discovery;
  }

  Future<Map<String, dynamic>> _loadJwks() async {
    final discovery = await _discovery();
    final uri = Uri.tryParse(_requiredString(discovery, 'jwks_uri'));
    if (uri == null) {
      throw const CodexOAuthException(
        'invalid_response',
        'Missing authentication signing keys.',
      );
    }
    OfficialCodexOAuthHttp.validateUri(uri);
    return _http.getJson(uri);
  }

  Future<void> logout(String providerId) => _endSession(providerId, false);

  /// Removes the account binding as well as credentials when deleting a channel.
  /// A later channel reusing the same ID must register its own account afresh.
  Future<void> deleteRegistration(String providerId) =>
      _endSession(providerId, true);

  Future<void> _endSession(String providerId, bool deleteRegistration) async {
    cancelLogin(providerId);
    _pendingClientIds.remove(providerId);
    _blocked.add(providerId);
    final generation = _invalidate(providerId);
    final record = await _lock(providerId).synchronized(() async {
      _checkCurrent(providerId, generation);
      final value = await _read(providerId);
      _checkCurrent(providerId, generation);
      await _writeRaw(
        providerId,
        deleteRegistration
            ? null
            : value?.withoutCredentials().encodeForSecureStorage(),
      );
      return value;
    });
    if (!_endSessionIsCurrent(providerId, generation, deleteRegistration)) {
      return;
    }
    _blocked.remove(providerId);
    _emit(
      CodexOAuthStatus(
        providerId: providerId,
        accountLabel: deleteRegistration ? null : record?.accountLabel,
      ),
    );
    if (record?.refreshToken == null) return;
    try {
      final discovery = await _discovery();
      if (!_endSessionIsCurrent(providerId, generation, deleteRegistration)) {
        return;
      }
      final uri = Uri.parse(_requiredString(discovery, 'revocation_endpoint'));
      OfficialCodexOAuthHttp.validateUri(uri);
      await _http.postForm(uri, {
        'token': record!.refreshToken!,
        'token_type_hint': 'refresh_token',
        'client_id': record.clientId,
      }, allowEmpty: true);
      _endSessionIsCurrent(providerId, generation, deleteRegistration);
    } catch (_) {
      if (!_endSessionIsCurrent(providerId, generation, deleteRegistration)) {
        return;
      }
      _emit(
        CodexOAuthStatus(
          providerId: providerId,
          errorCode: 'revocation_unconfirmed',
          accountLabel: deleteRegistration ? null : record?.accountLabel,
        ),
      );
      throw const CodexOAuthException(
        'revocation_unconfirmed',
        'Signed out locally. Remote revocation was not confirmed; disconnect the app in ChatGPT Settings.',
      );
    }
  }

  bool _endSessionIsCurrent(String id, int generation, bool deleting) {
    if (_generation(id) == generation && !_disposed) return true;
    if (deleting) {
      // The caller must not delete channel configuration after a newer login
      // has established another registration under the same provider ID.
      throw const CodexOAuthException(
        'cancelled',
        'Channel deletion was superseded by a newer account action.',
      );
    }
    return false;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pendingClientIds.clear();
    for (final id in _attempts.keys.toList()) {
      cancelLogin(id);
    }
    for (final id in _requests.keys.toList()) {
      _invalidate(id);
    }
    await _changes.close();
  }

  Future<void> _closeReceiver(CodexOAuthCallbackReceiver? receiver) async {
    try {
      await receiver?.close();
    } catch (_) {
      // Cleanup must not replace a sanitized result with a raw platform error.
    }
  }
}

final class _LoginAttempt {
  _LoginAttempt(this.generation, this.previousStatus);
  final int generation;
  final CodexOAuthStatus? previousStatus;
  final cancelled = Completer<void>();
  CodexOAuthCallbackReceiver? receiver;
  late final Future<CodexOAuthStatus> result;
}

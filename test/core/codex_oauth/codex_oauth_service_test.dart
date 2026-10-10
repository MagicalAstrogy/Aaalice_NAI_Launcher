import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/cloud_sync/oauth/oauth_pkce.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_http.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_id_token_validator.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_loopback.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_service.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_session.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_store.dart';

const providerId = 'test-provider';
final now = DateTime.utc(2026, 10, 10);

void main() {
  late _Harness harness;
  setUp(() => harness = _Harness());
  tearDown(() async => harness.service.dispose());

  test(
    'registers a public client, validates identity, and persists only securely',
    () async {
      final status = await harness.service.login(providerId: providerId);
      expect(status.phase, CodexOAuthPhase.signedIn);
      expect(status.accountLabel, 'test@example.invalid');
      final authorize = harness.authorizations.single;
      expect(authorize.origin, 'https://auth.openai.com');
      expect(authorize.path, '/api/accounts/authorize');
      expect(authorize.queryParameters['client_id'], 'dynamic_agent_client');
      expect(
        authorize.queryParameters['agent_name_hint'],
        'Aaalice NAI Launcher',
      );
      expect(
        authorize.queryParameters['ext_agent_host_id'],
        startsWith('urn:uuid:'),
      );
      expect(
        authorize.queryParameters['resource'],
        'https://api.openai.com/v1',
      );
      expect(
        authorize.queryParameters['scope'],
        contains('chatgpt.tokens.use.direct'),
      );
      expect(authorize.queryParameters['code_challenge_method'], 'S256');
      expect(
        authorize.queryParameters['redirect_uri'],
        harness.receiver.redirectUri.toString(),
      );
      final exchange = harness.http.forms.single;
      expect(exchange.uri, CodexOAuthEndpoints.token);
      expect(exchange.fields['client_id'], 'oaiapp_test');
      expect(
        exchange.fields['redirect_uri'],
        authorize.queryParameters['redirect_uri'],
      );
      expect(exchange.fields['client_secret'], isNull);
      expect(
        OAuthPkce.challengeForVerifier(exchange.fields['code_verifier']!),
        authorize.queryParameters['code_challenge'],
      );
      expect(harness.validator.nonce, authorize.queryParameters['nonce']);
      expect(harness.validator.clientId, 'oaiapp_test');
      expect(
        await harness.service.getAccessToken(providerId),
        'test-access-token',
      );
      expect(harness.http.forms, hasLength(1));
      expect(harness.receiver.closed, isTrue);
    },
  );

  test('restores saved account status without exposing credentials', () async {
    harness.seed();
    final status = await harness.service.watchStatus(providerId).first;
    expect(status.phase, CodexOAuthPhase.signedIn);
    expect(status.accountLabel, 'test@example.invalid');
    expect(status.toString(), isNot(contains('test-access-token')));
    expect(
      await harness.service.getAccessToken(providerId),
      'test-access-token',
    );
  });

  test(
    'expired initial code retains only an unverified client for a fresh retry',
    () async {
      harness.http.failure = const CodexOAuthException(
        'reauthentication_required',
        'Sign in again.',
        oauthErrorCode: 'invalid_grant',
      );
      await expectLater(
        harness.service.login(providerId: providerId),
        _hasCode('reauthentication_required'),
      );
      expect(harness.store.values['provider:$providerId'], isNull);
      expect(
        harness.store.values.values.join(),
        isNot(contains('oaiapp_test')),
      );
      await expectLater(
        harness.service.getAccessToken(providerId),
        _hasCode('signed_out'),
      );
      final first = harness.authorizations.single;
      harness.http.failure = null;
      harness.callbackFields = (uri) => {
        'state': uri.queryParameters['state']!,
        'code': 'fresh-synthetic-code',
      };
      await harness.service.login(providerId: providerId);
      final retry = harness.authorizations.last;
      expect(retry.queryParameters['client_id'], 'oaiapp_test');
      expect(retry.queryParameters['agent_name_hint'], isNull);
      expect(retry.queryParameters['id_token_hint'], isNull);
      expect(harness.validator.expectedSubject, isNull);
      for (final parameter in ['state', 'nonce', 'code_challenge']) {
        expect(
          retry.queryParameters[parameter],
          isNot(first.queryParameters[parameter]),
        );
      }
      expect(harness.http.forms.last.fields['client_id'], 'oaiapp_test');
      expect(harness.http.forms.last.fields['code'], 'fresh-synthetic-code');
      expect(harness.saved().hasCredentials, isTrue);
    },
  );

  test(
    'deleting a provisional registration starts the next login afresh',
    () async {
      harness.http.failure = const CodexOAuthException(
        'reauthentication_required',
        'Sign in again.',
        oauthErrorCode: 'invalid_grant',
      );
      await expectLater(
        harness.service.login(providerId: providerId),
        _hasCode('reauthentication_required'),
      );
      await harness.service.deleteRegistration(providerId);
      harness.http.failure = null;
      await harness.service.login(providerId: providerId);
      expect(
        harness.authorizations.last.queryParameters['client_id'],
        'dynamic_agent_client',
      );
    },
  );

  test(
    'provisional registration does not accept a replacement callback client',
    () async {
      harness.http.failure = const CodexOAuthException(
        'reauthentication_required',
        'Sign in again.',
        oauthErrorCode: 'invalid_grant',
      );
      await expectLater(
        harness.service.login(providerId: providerId),
        _hasCode('reauthentication_required'),
      );
      harness.http.failure = null;
      harness.callbackFields = (uri) => {
        'state': uri.queryParameters['state']!,
        'code': 'fresh-code',
        'client_id': 'oaiapp_other',
      };
      await expectLater(
        harness.service.login(providerId: providerId),
        _hasCode('invalid_callback'),
      );
      expect(harness.http.forms, hasLength(1));
      expect(harness.store.values['provider:$providerId'], isNull);
    },
  );

  test(
    'logout synchronously cancels only requests for that provider',
    () async {
      harness.seed();
      var cancelled = 0;
      var otherCancelled = 0;
      harness.service.registerRequest(providerId, () => cancelled++);
      final unregister = harness.service.registerRequest(
        'other-provider',
        () => otherCancelled++,
      );
      final logout = harness.service.logout(providerId);
      expect(cancelled, 1);
      expect(otherCancelled, 0);
      await logout;
      unregister();
      await harness.service.dispose();
      expect(otherCancelled, 0);
    },
  );

  test(
    'completed requests unregister and disposal cancels remaining requests once',
    () async {
      var completedCancelled = 0;
      var activeCancelled = 0;
      harness.service.registerRequest(providerId, () => activeCancelled++);
      final unregister = harness.service.registerRequest(
        providerId,
        () => completedCancelled++,
      );
      unregister();
      unregister();
      await harness.service.dispose();
      await harness.service.dispose();
      expect(completedCancelled, 0);
      expect(activeCancelled, 1);
      harness.service.registerRequest(providerId, () => activeCancelled++);
      expect(activeCancelled, 2);
    },
  );

  test('a new sign-in invalidates current inference immediately', () async {
    var cancelled = 0;
    harness.service.registerRequest(providerId, () => cancelled++);
    await harness.service.login(providerId: providerId);
    expect(cancelled, 1);
  });

  test(
    'reauthorization reuses issued client and stable host with identity binding',
    () async {
      await harness.service.login(providerId: providerId);
      final hostId =
          harness.authorizations.single.queryParameters['ext_agent_host_id'];
      await harness.service.login(providerId: providerId);
      final uri = harness.authorizations.last;
      expect(uri.queryParameters['client_id'], 'oaiapp_test');
      expect(uri.queryParameters['agent_name_hint'], isNull);
      expect(uri.queryParameters['id_token_hint'], 'test-id-token');
      expect(uri.queryParameters['ext_agent_host_id'], hostId);
      expect(harness.validator.expectedSubject, 'subject-test');
    },
  );

  for (final entry in <String, Map<String, String> Function(Uri)>{
    'wrong state': (uri) => {
      'state': 'wrong',
      'code': 'test-code',
      'client_id': 'oaiapp_test',
    },
    'missing client': (uri) => {
      'state': uri.queryParameters['state']!,
      'code': 'test-code',
    },
    'dynamic client': (uri) => {
      'state': uri.queryParameters['state']!,
      'code': 'test-code',
      'client_id': 'dynamic_agent_client',
    },
    'wrong issuer': (uri) => {
      'state': uri.queryParameters['state']!,
      'code': 'test-code',
      'client_id': 'oaiapp_test',
      'iss': 'https://example.invalid',
    },
  }.entries) {
    test('rejects ${entry.key} without exchanging credentials', () async {
      harness.callbackFields = entry.value;
      await expectLater(
        harness.service.login(providerId: providerId),
        _hasCode('invalid_callback'),
      );
      expect(harness.http.forms, isEmpty);
      expect(harness.store.values['provider:$providerId'], isNull);
    });
  }

  test('handles authorization refusal after validating state', () async {
    harness.callbackFields = (uri) => {
      'state': uri.queryParameters['state']!,
      'error': 'access_denied',
    };
    await expectLater(
      harness.service.login(providerId: providerId),
      _hasCode('authorization_denied'),
    );
    expect(harness.http.forms, isEmpty);
  });

  test('rejects changed returning client id', () async {
    harness.seed();
    harness.callbackFields = (uri) => {
      'state': uri.queryParameters['state']!,
      'code': 'test-code',
      'client_id': 'oaiapp_other',
    };
    await expectLater(
      harness.service.login(providerId: providerId),
      _hasCode('invalid_callback'),
    );
    expect(harness.http.forms, isEmpty);
  });

  test('requires plan-use grant even with a valid ID token', () async {
    harness.http.tokenResponse = {
      ..._tokenResponse(),
      'scope': 'openid profile email',
    };
    await expectLater(
      harness.service.login(providerId: providerId),
      _hasCode('permission_missing'),
    );
    expect(harness.saved().clientId, 'oaiapp_test');
    expect(harness.saved().planPermissionMissing, isTrue);
    await expectLater(
      harness.service.getAccessToken(providerId),
      _hasCode('permission_missing'),
    );
    harness.http.tokenResponse = _tokenResponse();
    await harness.service.login(providerId: providerId);
    expect(harness.authorizations.last.queryParameters['prompt'], 'consent');
    expect(
      harness.authorizations.last.queryParameters['client_id'],
      'oaiapp_test',
    );
    expect(harness.saved().planPermissionMissing, isFalse);
  });

  test('signature/identity failure prevents persistence', () async {
    harness.validator.fail = true;
    await expectLater(
      harness.service.login(providerId: providerId),
      _hasCode('invalid_id_token'),
    );
    expect(harness.store.values['provider:$providerId'], isNull);
  });

  test(
    'secure storage failure is fatal and never falls back to memory',
    () async {
      harness.store.failSessionWrites = true;
      await expectLater(
        harness.service.login(providerId: providerId),
        _hasCode('storage_error'),
      );
      await expectLater(
        harness.service.getAccessToken(providerId),
        _hasCode('storage_error'),
      );
      expect(harness.store.values['provider:$providerId'], isNull);
    },
  );

  test('concurrent callers share one rotating refresh token request', () async {
    harness.seed(expired: true);
    final gate = Completer<Map<String, dynamic>>();
    harness.http.tokenGate = gate;
    final first = harness.service.getAccessToken(providerId);
    final second = harness.service.getAccessToken(providerId);
    await _until(() => harness.http.forms.isNotEmpty);
    expect(harness.http.forms, hasLength(1));
    expect(harness.http.forms.single.fields, {
      'grant_type': 'refresh_token',
      'client_id': 'oaiapp_test',
      'refresh_token': 'test-refresh-token',
      'resource': 'https://api.openai.com/v1',
    });
    gate.complete(
      _tokenResponse(access: 'rotated-access', refresh: 'rotated-refresh'),
    );
    expect(await Future.wait([first, second]), [
      'rotated-access',
      'rotated-access',
    ]);
    final saved = harness.saved();
    expect(saved.refreshToken, 'rotated-refresh');
    expect(saved.expiresAt, now.add(const Duration(hours: 1)));
    expect(await harness.service.getAccessToken(providerId), 'rotated-access');
    expect(harness.http.forms, hasLength(1));
  });

  test(
    'invalid grant clears renewable credentials but retains registration',
    () async {
      harness.seed(expired: true);
      harness.http.failure = const CodexOAuthException(
        'reauthentication_required',
        'Sign in again.',
      );
      await expectLater(
        harness.service.getAccessToken(providerId),
        _hasCode('reauthentication_required'),
      );
      expect(harness.saved().hasCredentials, isFalse);
      expect(harness.saved().clientId, 'oaiapp_test');
      expect(harness.saved().idToken, isNull);
    },
  );

  test(
    'transient refresh failure preserves a session for a later retry',
    () async {
      harness.seed(expired: true);
      harness.http.failure = const CodexOAuthException(
        'network_error',
        'Network unavailable.',
      );
      await expectLater(
        harness.service.getAccessToken(providerId),
        _hasCode('network_error'),
      );
      expect(harness.saved().refreshToken, 'test-refresh-token');
      harness.http.failure = null;
      expect(
        await harness.service.getAccessToken(providerId),
        'test-access-token',
      );
    },
  );

  test(
    'cancel closes listener and rejects a late authorization exchange',
    () async {
      harness.autoCallback = false;
      final login = harness.service.login(providerId: providerId);
      final assertion = expectLater(login, _hasCode('cancelled'));
      await _until(() => harness.authorizations.isNotEmpty);
      harness.service.cancelLogin(providerId);
      await assertion;
      expect(harness.receiver.closed, isTrue);
      expect(harness.http.forms, isEmpty);
      expect(harness.store.values['provider:$providerId'], isNull);
    },
  );

  test(
    'double click shares login rather than opening a second browser',
    () async {
      harness.autoCallback = false;
      final first = harness.service.login(providerId: providerId);
      final second = harness.service.login(providerId: providerId);
      expect(identical(first, second), isTrue);
      await _until(() => harness.authorizations.isNotEmpty);
      harness.deliverCallback(harness.authorizations.single);
      await Future.wait([first, second]);
      expect(harness.authorizations, hasLength(1));
    },
  );

  test('timeout closes callback without creating a session', () async {
    await harness.service.dispose();
    harness = _Harness(loginTimeout: const Duration(milliseconds: 10));
    harness.autoCallback = false;
    await expectLater(
      harness.service.login(providerId: providerId),
      _hasCode('timeout'),
    );
    expect(harness.receiver.closed, isTrue);
    expect(harness.store.values['provider:$providerId'], isNull);
  });

  test(
    'cancellation during secure persistence rolls back the late write',
    () async {
      final gate = Completer<void>();
      harness.store.writeGate = gate;
      final login = harness.service.login(providerId: providerId);
      final assertion = expectLater(login, _hasCode('cancelled'));
      await _until(() => harness.store.sessionWriteStarted);
      harness.service.cancelLogin(providerId);
      await assertion;
      gate.complete();
      await _drain();
      expect(harness.store.values['provider:$providerId'], isNull);
    },
  );

  test(
    'pending login blocks an account-selection race with inference',
    () async {
      harness.seed();
      harness.autoCallback = false;
      final login = harness.service.login(providerId: providerId);
      final assertion = expectLater(login, _hasCode('cancelled'));
      await expectLater(
        harness.service.getAccessToken(providerId),
        _hasCode('signed_out'),
      );
      harness.service.cancelLogin(providerId);
      await assertion;
      expect(harness.http.forms, isEmpty);
    },
  );

  test('late token response cannot reconnect after cancellation', () async {
    final gate = Completer<Map<String, dynamic>>();
    harness.http.tokenGate = gate;
    final login = harness.service.login(providerId: providerId);
    final assertion = expectLater(login, _hasCode('cancelled'));
    await _until(() => harness.http.forms.isNotEmpty);
    harness.service.cancelLogin(providerId);
    await assertion;
    gate.complete(_tokenResponse());
    await _drain();
    expect(harness.store.values['provider:$providerId'], isNull);
    expect(
      (await harness.service.getStatus(providerId)).phase,
      CodexOAuthPhase.signedOut,
    );
  });

  test(
    'logout prevents an in-flight refresh from resurrecting credentials',
    () async {
      harness.seed(expired: true);
      final gate = Completer<Map<String, dynamic>>();
      harness.http.tokenGate = gate;
      final access = harness.service.getAccessToken(providerId);
      final assertion = expectLater(access, _hasCode('cancelled'));
      await _until(() => harness.http.forms.isNotEmpty);
      await harness.service.logout(providerId);
      gate.complete(
        _tokenResponse(access: 'late-access', refresh: 'late-refresh'),
      );
      await assertion;
      expect(harness.saved().hasCredentials, isFalse);
      expect(harness.saved().clientId, 'oaiapp_test');
      expect(harness.http.forms.last.uri.path, '/oauth/revoke');
      expect(
        (await harness.service.getStatus(providerId)).phase,
        CodexOAuthPhase.signedOut,
      );
    },
  );

  test(
    'deleting and re-adding a provider permits a different account',
    () async {
      harness.seed();
      await harness.service.deleteRegistration(providerId);
      expect(harness.store.values['provider:$providerId'], isNull);
      expect(
        (await harness.service.getStatus(providerId)).accountLabel,
        isNull,
      );
      harness.validator.subject = 'new-subject';
      await harness.service.login(providerId: providerId);
      expect(
        harness.authorizations.last.queryParameters['client_id'],
        'dynamic_agent_client',
      );
      expect(harness.validator.expectedSubject, isNull);
      expect(harness.saved().subject, 'new-subject');
    },
  );

  test(
    'registration deletion remains local when remote revocation fails',
    () async {
      harness.seed();
      harness.http.revokeFailure = true;
      await expectLater(
        harness.service.deleteRegistration(providerId),
        _hasCode('revocation_unconfirmed'),
      );
      expect(harness.store.values['provider:$providerId'], isNull);
      await expectLater(
        harness.service.getAccessToken(providerId),
        _hasCode('signed_out'),
      );
    },
  );

  for (final revokeFails in [false, true]) {
    test(
      'superseded deletion cancels configuration removal (revoke failure: $revokeFails)',
      () async {
        harness.seed();
        final gate = Completer<Map<String, dynamic>>();
        harness.http.revokeGate = gate;
        final deletion = harness.service.deleteRegistration(providerId);
        final assertion = expectLater(deletion, _hasCode('cancelled'));
        await _until(
          () => harness.http.forms.any(
            (form) => form.uri.path == '/oauth/revoke',
          ),
        );
        await harness.service.login(providerId: providerId);
        if (revokeFails) {
          gate.completeError(
            const CodexOAuthException('network_error', 'Network unavailable.'),
          );
        } else {
          gate.complete({});
        }
        await assertion;
        expect(
          (await harness.service.getStatus(providerId)).phase,
          CodexOAuthPhase.signedIn,
        );
        expect(harness.saved().hasCredentials, isTrue);
        expect(
          await harness.service.getAccessToken(providerId),
          'test-access-token',
        );
      },
    );
  }

  test(
    'late revocation failure cannot overwrite a newer successful login',
    () async {
      harness.seed();
      final gate = Completer<Map<String, dynamic>>();
      harness.http.revokeGate = gate;
      final logout = harness.service.logout(providerId);
      await _until(
        () =>
            harness.http.forms.any((form) => form.uri.path == '/oauth/revoke'),
      );
      await harness.service.login(providerId: providerId);
      gate.completeError(
        const CodexOAuthException('network_error', 'Network unavailable.'),
      );
      await logout;
      expect(
        (await harness.service.getStatus(providerId)).phase,
        CodexOAuthPhase.signedIn,
      );
      expect((await harness.service.getStatus(providerId)).errorCode, isNull);
      expect(harness.saved().hasCredentials, isTrue);
      expect(
        await harness.service.getAccessToken(providerId),
        'test-access-token',
      );
    },
  );

  test(
    'unconfirmed remote revocation still removes local credentials',
    () async {
      harness.seed();
      harness.http.revokeFailure = true;
      await expectLater(
        harness.service.logout(providerId),
        _hasCode('revocation_unconfirmed'),
      );
      expect(harness.saved().hasCredentials, isFalse);
      expect(
        (await harness.service.getStatus(providerId)).phase,
        CodexOAuthPhase.signedOut,
      );
      expect(
        (await harness.service.getStatus(providerId)).errorCode,
        'revocation_unconfirmed',
      );
    },
  );

  test(
    'fixed-origin transport rejects arbitrary, downgraded, or redirected destinations',
    () {
      for (final uri in [
        'http://auth.openai.com/oauth/token',
        'https://example.invalid/oauth/token',
        'https://auth.openai.com:444/oauth/token',
        'https://user@auth.openai.com/oauth/token',
        'https://auth.openai.com/oauth/token?token=secret',
      ]) {
        expect(
          () => OfficialCodexOAuthHttp.validateUri(Uri.parse(uri)),
          _hasCode('invalid_response'),
        );
      }
    },
  );
}

Matcher _hasCode(String code) =>
    throwsA(isA<CodexOAuthException>().having((e) => e.code, 'code', code));

Map<String, dynamic> _tokenResponse({
  String access = 'test-access-token',
  String refresh = 'test-refresh-token',
}) => {
  'access_token': access,
  'refresh_token': refresh,
  'id_token': 'test-id-token',
  'token_type': 'Bearer',
  'expires_in': 3600,
  'scope': CodexOAuthEndpoints.scopes,
};

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Expected asynchronous stage did not start.');
}

Future<void> _drain() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Harness {
  _Harness({Duration loginTimeout = const Duration(minutes: 5)}) {
    service = CodexOAuthService(
      store: store,
      http: http,
      idTokenValidator: validator,
      clock: () => now,
      loginTimeout: loginTimeout,
      receiverFactory: () async {
        receiver = _Receiver();
        return receiver;
      },
      browserLauncher: (uri) async {
        authorizations.add(uri);
        if (autoCallback) deliverCallback(uri);
        return true;
      },
    );
  }
  final store = _Store();
  final http = _Http();
  final validator = _Validator();
  final authorizations = <Uri>[];
  late _Receiver receiver;
  late CodexOAuthService service;
  bool autoCallback = true;
  Map<String, String> Function(Uri)? callbackFields;

  void deliverCallback(Uri uri) => receiver.callback.complete(
    receiver.redirectUri.replace(
      queryParameters:
          callbackFields?.call(uri) ??
          {
            'state': uri.queryParameters['state']!,
            'code': 'test-code',
            'client_id': 'oaiapp_test',
          },
    ),
  );

  void seed({bool expired = false}) {
    store.values['provider:$providerId'] = CodexOAuthSession(
      providerId: providerId,
      clientId: 'oaiapp_test',
      subject: 'subject-test',
      accountLabel: 'test@example.invalid',
      accessToken: 'test-access-token',
      refreshToken: 'test-refresh-token',
      idToken: 'test-id-token',
      expiresAt: expired
          ? now.subtract(const Duration(seconds: 1))
          : now.add(const Duration(hours: 1)),
      scopes: CodexOAuthEndpoints.scopes.split(' ').toSet(),
    ).encodeForSecureStorage();
  }

  CodexOAuthSession saved() => CodexOAuthSession.decode(
    store.values['provider:$providerId']!,
    providerId,
  );
}

class _Store implements CodexOAuthStore {
  final values = <String, String>{};
  bool failSessionWrites = false;
  Completer<void>? writeGate;
  bool sessionWriteStarted = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (failSessionWrites && key.startsWith('provider:')) {
      throw StateError('secret backend detail');
    }
    if (key.startsWith('provider:') && writeGate != null) {
      sessionWriteStarted = true;
      await writeGate!.future;
    }
    values[key] = value;
  }
}

class _Form {
  _Form(this.uri, this.fields);
  final Uri uri;
  final Map<String, String> fields;
}

class _Http implements CodexOAuthHttp {
  final forms = <_Form>[];
  Map<String, dynamic> tokenResponse = _tokenResponse();
  Completer<Map<String, dynamic>>? tokenGate;
  Completer<Map<String, dynamic>>? revokeGate;
  CodexOAuthException? failure;
  bool revokeFailure = false;
  @override
  Future<Map<String, dynamic>> getJson(Uri uri) async => {
    'issuer': CodexOAuthEndpoints.issuer,
    'jwks_uri': 'https://auth.openai.com/.well-known/jwks.json',
    'revocation_endpoint': 'https://auth.openai.com/oauth/revoke',
  };
  @override
  Future<Map<String, dynamic>> postForm(
    Uri uri,
    Map<String, String> fields, {
    bool allowEmpty = false,
  }) async {
    forms.add(_Form(uri, Map.of(fields)));
    if (allowEmpty) {
      if (revokeGate != null) return revokeGate!.future;
      if (revokeFailure) {
        throw const CodexOAuthException(
          'network_error',
          'Network unavailable.',
        );
      }
      return {};
    }
    if (failure != null) throw failure!;
    if (tokenGate != null) return tokenGate!.future;
    return tokenResponse;
  }
}

class _Receiver implements CodexOAuthCallbackReceiver {
  final callback = Completer<Uri>();
  bool closed = false;
  @override
  Uri get redirectUri => Uri.parse('http://127.0.0.1:1455/auth/callback');
  @override
  Future<Uri> receive({required String state}) => callback.future;
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!callback.isCompleted) {
      callback.completeError(
        const CodexOAuthException('cancelled', 'Cancelled.'),
      );
    }
  }
}

class _Validator extends CodexOAuthIdTokenValidator {
  _Validator() : super(loadJwks: () async => {});
  String? clientId;
  String? nonce;
  String? expectedSubject;
  bool fail = false;
  String subject = 'subject-test';
  @override
  Future<CodexOAuthIdentity> validate(
    String token, {
    required String clientId,
    required String nonce,
    String? expectedSubject,
  }) async {
    this.clientId = clientId;
    this.nonce = nonce;
    this.expectedSubject = expectedSubject;
    if (fail) {
      throw const CodexOAuthException('invalid_id_token', 'Invalid token.');
    }
    return CodexOAuthIdentity(subject: subject, email: 'test@example.invalid');
  }

  @override
  Future<CodexOAuthIdentity> validateRefresh(
    String token, {
    required String clientId,
    required String expectedSubject,
  }) async {
    if (fail) {
      throw const CodexOAuthException('invalid_id_token', 'Invalid token.');
    }
    return CodexOAuthIdentity(subject: subject, email: 'test@example.invalid');
  }
}

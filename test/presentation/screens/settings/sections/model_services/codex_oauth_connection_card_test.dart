import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_providers.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_service.dart';
import 'package:nai_launcher/data/models/prompt_assistant/prompt_assistant_models.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/prompt_assistant/providers/provider_remote_models_provider.dart';
import 'package:nai_launcher/presentation/screens/settings/sections/model_services/codex_oauth_connection_card.dart';

class _FakeOAuthService implements CodexOAuthService {
  final _events = StreamController<CodexOAuthStatus>.broadcast();
  final statuses = <String, CodexOAuthStatus>{};
  final pending = <Completer<CodexOAuthStatus>>[];
  final cancelled = <String>[];
  final loggedOut = <String>[];
  int loginCalls = 0;
  String? logoutError;

  void emit(CodexOAuthStatus status) {
    statuses[status.providerId] = status;
    _events.add(status);
  }

  @override
  Stream<CodexOAuthStatus> watchStatus(String providerId) async* {
    yield await getStatus(providerId);
    yield* _events.stream.where((status) => status.providerId == providerId);
  }

  @override
  Future<CodexOAuthStatus> getStatus(String providerId) async =>
      statuses[providerId] ?? CodexOAuthStatus(providerId: providerId);

  @override
  Future<CodexOAuthStatus> login({required String providerId}) {
    loginCalls++;
    emit(
      CodexOAuthStatus(
        providerId: providerId,
        phase: CodexOAuthPhase.signingIn,
      ),
    );
    final completer = Completer<CodexOAuthStatus>();
    pending.add(completer);
    return completer.future;
  }

  @override
  void cancelLogin(String providerId) {
    cancelled.add(providerId);
    if (statuses[providerId]?.phase == CodexOAuthPhase.signingIn) {
      emit(CodexOAuthStatus(providerId: providerId));
    }
  }

  @override
  Future<void> logout(String providerId) async {
    loggedOut.add(providerId);
    emit(CodexOAuthStatus(providerId: providerId, errorCode: logoutError));
    if (logoutError != null) {
      throw CodexOAuthException(logoutError!, 'private server detail');
    }
  }

  @override
  Future<void> deleteRegistration(String providerId) => logout(providerId);

  @override
  void Function() registerRequest(String providerId, void Function() cancel) =>
      () {};

  @override
  Future<String> getAccessToken(
    String providerId, {
    bool forceRefresh = false,
  }) async => throw StateError('UI must never read a token');

  @override
  Future<void> dispose() async {
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.complete(const CodexOAuthStatus(providerId: 'disposed'));
      }
    }
    await _events.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRemoteModels extends ProviderRemoteModelsNotifier {
  _FakeRemoteModels(super.ref);

  final fetched = <String>[];
  final forgotten = <String>[];
  Completer<List<String>>? pending;

  @override
  Future<List<String>> fetch(String providerId) {
    fetched.add(providerId);
    return pending?.future ?? Future.value(['gpt-5.4']);
  }

  @override
  void forget(String providerId) {
    forgotten.add(providerId);
    super.forget(providerId);
  }
}

final _provider = ProviderPreset.codexOAuth.createConfig();

Finder _key(String key) => find.byKey(ValueKey(key));

Future<_FakeRemoteModels> _pump(
  WidgetTester tester,
  _FakeOAuthService auth, {
  double width = 840,
  double textScale = 1,
  ValueNotifier<ProviderConfig>? selected,
  Locale locale = const Locale('en'),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  late _FakeRemoteModels remote;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        codexOAuthServiceProvider.overrideWithValue(auth),
        providerRemoteModelsProvider.overrideWith((ref) {
          return remote = _FakeRemoteModels(ref);
        }),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: selected == null
                ? CodexOAuthConnectionCard(provider: _provider)
                : ValueListenableBuilder<ProviderConfig>(
                    valueListenable: selected,
                    builder: (context, provider, _) =>
                        CodexOAuthConnectionCard(provider: provider),
                  ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await auth.dispose();
  });
  return remote;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = _key(key);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  testWidgets(
    'sign-in is explicit, repeated clicks are safe and cancel stops it',
    (tester) async {
      final auth = _FakeOAuthService();
      await _pump(tester, auth);
      expect(auth.loginCalls, 0);
      expect(find.byType(TextField), findsNothing);
      expect(_key('codex-oauth-sign-in'), findsOneWidget);

      final button = tester.widget<FilledButton>(_key('codex-oauth-sign-in'));
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(auth.loginCalls, 1);
      expect(_key('codex-oauth-cancel'), findsOneWidget);
      expect(find.text('Waiting for ChatGPT sign-in…'), findsOneWidget);

      await _tap(tester, 'codex-oauth-cancel');
      await tester.pump();
      expect(auth.cancelled, contains(_provider.id));
      expect(_key('codex-oauth-sign-in'), findsOneWidget);
      auth.pending.single.complete(CodexOAuthStatus(providerId: _provider.id));
      await tester.pump();
      expect(_key('codex-oauth-error'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching providers cancels login and ignores its late failure',
    (tester) async {
      final auth = _FakeOAuthService();
      final selected = ValueNotifier(_provider);
      addTearDown(selected.dispose);
      await _pump(tester, auth, selected: selected);
      await _tap(tester, 'codex-oauth-sign-in');
      selected.value = _provider.copyWith(id: 'second-account');
      await tester.pumpAndSettle();
      expect(auth.cancelled, contains(_provider.id));
      auth.pending.single.completeError(
        StateError('sk-test-secret-never-show'),
      );
      await tester.pump();
      expect(_key('codex-oauth-error'), findsNothing);
      expect(_key('codex-oauth-sign-in'), findsOneWidget);
      expect(find.textContaining('sk-test-secret'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'safe account label, connection check and sign-out stay per provider',
    (tester) async {
      final auth = _FakeOAuthService();
      auth.statuses[_provider.id] = CodexOAuthStatus(
        providerId: _provider.id,
        phase: CodexOAuthPhase.signedIn,
        accountLabel: 'creator@example.test',
      );
      final remote = await _pump(tester, auth);
      expect(find.text('creator@example.test'), findsOneWidget);
      expect(_key('codex-oauth-sign-in'), findsNothing);
      await _tap(tester, 'codex-oauth-check-connection');
      await tester.pump();
      expect(remote.fetched, [_provider.id]);
      expect(_key('codex-oauth-connection-result'), findsOneWidget);
      await _tap(tester, 'codex-oauth-sign-out');
      await tester.pump();
      expect(auth.loggedOut, [_provider.id]);
      expect(find.text('creator@example.test'), findsNothing);
      expect(_key('codex-oauth-sign-in'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('errors are localized without showing raw exception content', (
    tester,
  ) async {
    final auth = _FakeOAuthService();
    await _pump(tester, auth);
    await _tap(tester, 'codex-oauth-sign-in');
    auth.emit(CodexOAuthStatus(providerId: _provider.id));
    auth.pending.single.completeError(StateError('secret-token-and-callback'));
    await tester.pump();
    expect(_key('codex-oauth-error'), findsOneWidget);
    expect(find.textContaining('secret-token'), findsNothing);
    expect(_key('codex-oauth-sign-in'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'connection checks reject repeat clicks and discard stale results',
    (tester) async {
      final auth = _FakeOAuthService();
      for (final id in [_provider.id, 'second-account']) {
        auth.statuses[id] = CodexOAuthStatus(
          providerId: id,
          phase: CodexOAuthPhase.signedIn,
          accountLabel: '$id@example.test',
        );
      }
      final selected = ValueNotifier(_provider);
      addTearDown(selected.dispose);
      final remote = await _pump(tester, auth, selected: selected);
      final pending = Completer<List<String>>();
      remote.pending = pending;
      final button = tester.widget<TextButton>(
        _key('codex-oauth-check-connection'),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(remote.fetched, [_provider.id]);
      selected.value = _provider.copyWith(id: 'second-account');
      await tester.pumpAndSettle();
      pending.completeError(StateError('old-account-secret'));
      await tester.pump();
      expect(_key('codex-oauth-error'), findsNothing);
      expect(_key('codex-oauth-connection-result'), findsNothing);
      expect(find.text('second-account@example.test'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing plan access offers explicit reauthorization', (
    tester,
  ) async {
    final auth = _FakeOAuthService();
    auth.statuses[_provider.id] = CodexOAuthStatus(
      providerId: _provider.id,
      phase: CodexOAuthPhase.error,
      accountLabel: 'creator@example.test',
      errorCode: 'permission_missing',
    );
    await _pump(tester, auth);
    expect(find.text('Authorize ChatGPT plan usage'), findsOneWidget);
    expect(_key('codex-oauth-sign-out'), findsOneWidget);
    expect(find.text('creator@example.test'), findsOneWidget);
    expect(_key('codex-oauth-check-connection'), findsNothing);
    expect(auth.loginCalls, 0);
    await _tap(tester, 'codex-oauth-sign-in');
    expect(auth.loginCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed remote revocation still shows local sign-out and clears catalog',
    (tester) async {
      final auth = _FakeOAuthService()..logoutError = 'revocation_unconfirmed';
      auth.statuses[_provider.id] = CodexOAuthStatus(
        providerId: _provider.id,
        phase: CodexOAuthPhase.signedIn,
      );
      final remote = await _pump(tester, auth);
      await _tap(tester, 'codex-oauth-sign-out');
      await tester.pump();
      expect(_key('codex-oauth-sign-in'), findsOneWidget);
      expect(_key('codex-oauth-sign-out'), findsNothing);
      expect(find.textContaining('Signed out locally'), findsOneWidget);
      expect(find.textContaining('private server detail'), findsNothing);
      expect(remote.forgotten, contains(_provider.id));
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 600.0, 840.0, 1180.0, 1600.0]) {
    for (final textScale in [1.0, 3.0]) {
      testWidgets('OAuth card is reachable at $width / ${textScale}x', (
        tester,
      ) async {
        final auth = _FakeOAuthService();
        await _pump(tester, auth, width: width, textScale: textScale);
        expect(tester.takeException(), isNull);
        await _tap(tester, 'codex-oauth-sign-in');
        expect(tester.takeException(), isNull);
        await _tap(tester, 'codex-oauth-cancel');
        expect(tester.takeException(), isNull);
        auth.emit(
          CodexOAuthStatus(
            providerId: _provider.id,
            phase: CodexOAuthPhase.signedIn,
            accountLabel: 'long-safe-account-label@example.test',
          ),
        );
        await tester.pump();
        await _tap(tester, 'codex-oauth-check-connection');
        await tester.pump();
        await _tap(tester, 'codex-oauth-sign-out');
        expect(tester.takeException(), isNull);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
          findsOneWidget,
        );
      });
    }
  }
}

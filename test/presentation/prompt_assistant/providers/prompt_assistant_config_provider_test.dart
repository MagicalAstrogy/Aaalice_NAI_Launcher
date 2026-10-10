import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_providers.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_service.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/core/storage/secure_storage_service.dart';
import 'package:nai_launcher/data/models/prompt_assistant/prompt_assistant_models.dart';
import 'package:nai_launcher/presentation/prompt_assistant/providers/prompt_assistant_config_provider.dart';
import 'package:nai_launcher/presentation/prompt_assistant/providers/provider_remote_model_names_provider.dart';

class _MockLocalStorageService extends Mock implements LocalStorageService {}

class _MockOAuthService extends Mock implements CodexOAuthService {}

class _MemorySecureStorage extends SecureStorageService {
  final keys = <String, String>{};

  @override
  Future<String?> getPromptAssistantApiKey(String providerId) async =>
      keys[providerId];

  @override
  Future<void> savePromptAssistantApiKey(
    String providerId,
    String apiKey,
  ) async => keys[providerId] = apiKey;

  @override
  Future<void> deletePromptAssistantApiKey(String providerId) async =>
      keys.remove(providerId);
}

const _relay = ProviderConfig(
  id: 'relay',
  name: 'Relay',
  baseUrl: 'https://relay.invalid/v1',
);
const _backup = ProviderConfig(
  id: 'backup',
  name: 'Backup',
  baseUrl: 'https://backup.invalid/v1',
);

void main() {
  late ProviderContainer container;
  late _MemorySecureStorage secure;
  late PromptAssistantConfigNotifier notifier;
  late _MockOAuthService oauth;

  PromptAssistantConfigState read() =>
      container.read(promptAssistantConfigProvider);

  List<ModelConfig> copies(String providerId, String name) => [
    for (final model in read().models)
      if (model.providerId == providerId && model.name == name) model,
  ];

  Future<void> routeAllTasks(String providerId, String model) async {
    var routing = read().routing;
    for (final task in AssistantTaskType.values) {
      routing = routing.copyWithTask(
        taskType: task,
        providerId: providerId,
        model: model,
      );
    }
    await notifier.setRouting(routing);
  }

  setUp(() async {
    final local = _MockLocalStorageService();
    when(
      () => local.getSetting<String>(StorageKeys.promptAssistantConfigJson),
    ).thenReturn(null);
    when(
      () => local.setSetting<String>(
        StorageKeys.promptAssistantConfigJson,
        any(),
      ),
    ).thenAnswer((_) async {});
    secure = _MemorySecureStorage();
    oauth = _MockOAuthService();
    when(() => oauth.logout(any())).thenAnswer((_) async {});
    when(() => oauth.deleteRegistration(any())).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        localStorageServiceProvider.overrideWithValue(local),
        secureStorageServiceProvider.overrideWithValue(secure),
        codexOAuthServiceProvider.overrideWithValue(oauth),
      ],
    );
    notifier = container.read(promptAssistantConfigProvider.notifier);
    await notifier.upsertProvider(_relay);
    await notifier.upsertProvider(_backup);
  });

  tearDown(() => container.dispose());

  test(
    'OAuth channel fixes destination and never returns a saved API key',
    () async {
      secure.keys['oauth'] = 'old-key';
      await notifier.upsertProvider(
        ProviderPreset.codexOAuth
            .createConfig(id: 'oauth')
            .copyWith(
              baseUrl: 'https://untrusted.invalid',
              protocol: ProviderProtocol.openaiChatCompletions,
            ),
      );
      await notifier.setProviderApiKey('oauth', 'new-key');
      await notifier.setProviderBaseUrl('oauth', 'https://untrusted.invalid');
      final provider = read().providers.singleWhere((p) => p.id == 'oauth');
      expect(provider.baseUrl, 'https://api.openai.com/v1');
      expect(provider.protocol, ProviderProtocol.openaiResponses);
      expect(await notifier.getProviderApiKey('oauth'), isNull);
      expect(secure.keys['oauth'], isNull);
    },
  );

  test('leaving or deleting OAuth channel clears its session', () async {
    await notifier.upsertProvider(
      ProviderPreset.codexOAuth.createConfig(id: 'oauth'),
    );
    await notifier.upsertProvider(
      ProviderPreset.openaiResponses.createConfig(id: 'oauth'),
    );
    verify(() => oauth.deleteRegistration('oauth')).called(1);
    await notifier.upsertProvider(
      ProviderPreset.codexOAuth.createConfig(id: 'oauth'),
    );
    await notifier.deleteProvider('oauth');
    verify(() => oauth.deleteRegistration('oauth')).called(1);
    expect(read().providers.any((p) => p.id == 'oauth'), isFalse);
  });

  test(
    'a superseded account deletion never removes the relogged provider',
    () async {
      await notifier.upsertProvider(
        ProviderPreset.codexOAuth.createConfig(id: 'oauth'),
      );
      await notifier.addProviderModels('oauth', [
        'account-model',
      ], source: ModelSource.api);
      final revokeGate = Completer<void>();
      when(() => oauth.deleteRegistration('oauth')).thenAnswer((_) async {
        await revokeGate.future;
        // The auth service reports a generation change if login superseded the
        // deletion while old remote revocation was pending.
        throw const CodexOAuthException('cancelled', 'Sign-in was cancelled.');
      });
      when(() => oauth.login(providerId: 'oauth')).thenAnswer((_) async {
        return const CodexOAuthStatus(
          providerId: 'oauth',
          phase: CodexOAuthPhase.signedIn,
        );
      });
      final deletion = notifier.deleteProvider('oauth');
      final failed = expectLater(deletion, throwsA(isA<CodexOAuthException>()));
      await oauth.login(providerId: 'oauth');
      revokeGate.complete();
      await failed;
      expect(read().providers.any((p) => p.id == 'oauth'), isTrue);
      expect(copies('oauth', 'account-model'), isNotEmpty);
    },
  );

  test(
    'a superseded account removal never changes the provider preset',
    () async {
      await notifier.upsertProvider(
        ProviderPreset.codexOAuth.createConfig(id: 'oauth'),
      );
      final revokeGate = Completer<void>();
      when(() => oauth.deleteRegistration('oauth')).thenAnswer((_) async {
        await revokeGate.future;
        throw const CodexOAuthException('cancelled', 'Sign-in was cancelled.');
      });
      final conversion = notifier.upsertProvider(
        ProviderPreset.openaiResponses.createConfig(id: 'oauth'),
      );
      final failed = expectLater(
        conversion,
        throwsA(isA<CodexOAuthException>()),
      );
      revokeGate.complete();
      await failed;
      expect(
        read().providers.singleWhere((p) => p.id == 'oauth').preset,
        ProviderPreset.codexOAuth,
      );
    },
  );

  test('account catalog labels are preserved when adding models', () async {
    container.read(providerRemoteModelNamesProvider.notifier).state = {
      'relay': {'model-id': 'Server Display Name'},
    };
    await notifier.addProviderModels('relay', [
      'model-id',
    ], source: ModelSource.api);
    expect(
      copies(
        'relay',
        'model-id',
      ).every((model) => model.displayName == 'Server Display Name'),
      isTrue,
    );
  });

  group('addProviderModels', () {
    test('stores one copy per task and skips models already present', () async {
      await notifier.addProviderModels('relay', [
        'gpt-4o',
        ' gpt-4o ',
        '',
      ], source: ModelSource.api);
      await notifier.addProviderModels('relay', [
        'gpt-4o',
      ], source: ModelSource.manual);

      final stored = copies('relay', 'gpt-4o');
      expect(
        stored.map((model) => model.forTask).toSet(),
        AssistantTaskType.values.toSet(),
      );
      expect(stored, hasLength(AssistantTaskType.values.length));
      expect(stored.every((model) => model.source == ModelSource.api), isTrue);
    });

    test('replaces the placeholder and moves routes off it', () async {
      for (final task in AssistantTaskType.values) {
        await notifier.upsertModel(
          ModelConfig(
            providerId: 'relay',
            name: 'default-model',
            displayName: 'default-model',
            forTask: task,
            isDefault: true,
          ),
        );
      }
      await routeAllTasks('relay', 'default-model');

      await notifier.addProviderModels('relay', [
        'deepseek-flash',
      ], source: ModelSource.manual);

      expect(copies('relay', 'default-model'), isEmpty);
      for (final task in AssistantTaskType.values) {
        expect(read().routing.modelFor(task), 'deepseek-flash');
      }
    });
  });

  group('removeProviderModels', () {
    test(
      'removes every task copy and keeps routing on the same provider',
      () async {
        await notifier.addProviderModels('relay', [
          'alpha',
          'beta',
        ], source: ModelSource.manual);
        await routeAllTasks('relay', 'alpha');

        await notifier.removeProviderModels('relay', ['alpha']);

        expect(copies('relay', 'alpha'), isEmpty);
        expect(
          copies('relay', 'beta'),
          hasLength(AssistantTaskType.values.length),
        );
        for (final task in AssistantTaskType.values) {
          expect(read().routing.providerIdFor(task), 'relay');
          expect(read().routing.modelFor(task), 'beta');
        }
      },
    );

    test('falls back to another enabled provider when none remain', () async {
      await notifier.addProviderModels('relay', [
        'alpha',
      ], source: ModelSource.manual);
      await notifier.addProviderModels('backup', [
        'gamma',
      ], source: ModelSource.manual);
      await routeAllTasks('relay', 'alpha');

      await notifier.removeProviderModels('relay', ['alpha']);

      for (final task in AssistantTaskType.values) {
        expect(read().routing.providerIdFor(task), 'backup');
        expect(read().routing.modelFor(task), 'gamma');
      }
    });

    test('leaves routes to other providers and models untouched', () async {
      await notifier.addProviderModels('relay', [
        'alpha',
        'beta',
      ], source: ModelSource.manual);
      await notifier.addProviderModels('backup', [
        'alpha',
      ], source: ModelSource.manual);
      await routeAllTasks('backup', 'alpha');

      await notifier.removeProviderModels('relay', ['alpha']);

      expect(copies('backup', 'alpha'), isNotEmpty);
      expect(read().routing.providerIdFor(AssistantTaskType.llm), 'backup');
      expect(read().routing.modelFor(AssistantTaskType.llm), 'alpha');
    });
  });

  test(
    'renameProviderModel updates every copy and blank resets to the ID',
    () async {
      await notifier.addProviderModels('relay', [
        'alpha',
      ], source: ModelSource.manual);

      await notifier.renameProviderModel('relay', 'alpha', '  Alpha Pro  ');
      expect(
        copies('relay', 'alpha').map((model) => model.displayName).toSet(),
        {'Alpha Pro'},
      );

      await notifier.renameProviderModel('relay', 'alpha', '   ');
      expect(
        copies('relay', 'alpha').map((model) => model.displayName).toSet(),
        {'alpha'},
      );
    },
  );

  group('deferred connection edits', () {
    test('base URL updates the provider and trims input', () async {
      await notifier.setProviderBaseUrl('relay', '  https://new.invalid/v1 ');
      expect(
        read().providers.singleWhere((p) => p.id == 'relay').baseUrl,
        'https://new.invalid/v1',
      );
    });

    test('edits for a deleted provider are ignored', () async {
      await notifier.deleteProvider('relay');

      await notifier.setProviderBaseUrl('relay', 'https://late.invalid/v1');
      await notifier.setProviderApiKey('relay', 'sk-late');

      expect(read().providers.any((p) => p.id == 'relay'), isFalse);
      expect(secure.keys.containsKey('relay'), isFalse);
      expect(read().providerHasApiKey.containsKey('relay'), isFalse);
    });
  });
}

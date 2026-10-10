import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/data/models/prompt_assistant/prompt_assistant_models.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/prompt_assistant/providers/prompt_assistant_config_provider.dart';
import 'package:nai_launcher/presentation/prompt_assistant/providers/provider_remote_model_names_provider.dart';
import 'package:nai_launcher/presentation/prompt_assistant/providers/provider_remote_models_provider.dart';
import 'package:nai_launcher/presentation/screens/settings/sections/model_services/provider_model_manage_panel.dart';

import '../../../../../helpers/memory_local_storage.dart';

class _RemoteCatalog extends ProviderRemoteModelsNotifier {
  _RemoteCatalog(super.ref, String providerId) {
    state = {
      providerId: ['z-priority', 'a-secondary', 'z-after'],
    };
  }
}

void main() {
  testWidgets(
    'Codex model picker preserves authenticated catalog order and labels',
    (tester) async {
      final provider = ProviderPreset.codexOAuth.createConfig();
      final storage = MemoryLocalStorage();
      storage.values[StorageKeys.promptAssistantConfigJson] =
          PromptAssistantConfigState.defaults()
              .copyWith(providers: [provider], models: [])
              .encode();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localStorageServiceProvider.overrideWithValue(storage),
            providerRemoteModelsProvider.overrideWith(
              (ref) => _RemoteCatalog(ref, provider.id),
            ),
            providerRemoteModelNamesProvider.overrideWith(
              (ref) => {
                provider.id: {
                  'z-priority': 'Recommended by account',
                  'a-secondary': 'Budget by account',
                  'z-after': 'Last by account',
                },
              },
            ),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ProviderModelManagePanel(
                providerId: provider.id,
                scrollController: scroll,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final first = find.text('Recommended by account');
      final second = find.text('Budget by account');
      final third = find.text('Last by account');
      expect(
        tester.getTopLeft(first).dy,
        lessThan(tester.getTopLeft(second).dy),
      );
      expect(
        tester.getTopLeft(second).dy,
        lessThan(tester.getTopLeft(third).dy),
      );
      expect(
        find.byKey(const ValueKey('model-services-manage-group-z')),
        findsNothing,
      );
      await tester.tap(first);
      await tester.pumpAndSettle();
      final config = ProviderScope.containerOf(
        tester.element(find.byType(ProviderModelManagePanel)),
      ).read(promptAssistantConfigProvider);
      expect(
        config.models
            .where((model) => model.name == 'z-priority')
            .every((model) => model.displayName == 'Recommended by account'),
        isTrue,
      );
      expect(
        config.models.where((model) => model.name == 'z-priority'),
        isNotEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

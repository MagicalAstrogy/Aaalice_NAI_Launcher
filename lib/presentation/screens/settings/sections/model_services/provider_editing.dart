import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/codex_oauth/codex_oauth_service.dart';
import '../../../../../core/utils/localization_extension.dart';
import '../../../../../data/models/prompt_assistant/prompt_assistant_models.dart';
import '../../../../adaptive/adaptive_presenter.dart';
import '../../../../prompt_assistant/providers/prompt_assistant_config_provider.dart';
import '../../../../prompt_assistant/providers/provider_remote_models_provider.dart';
import '../../../../widgets/common/themed_confirm_dialog.dart';
import '../../widgets/prompt_assistant_settings_forms.dart';
import 'codex_oauth_error_labels.dart';

/// 新建或编辑服务商，返回保存后的服务商 ID；取消时为 null。
Future<String?> showProviderEditor(
  BuildContext context,
  WidgetRef ref, {
  ProviderConfig? provider,
}) async {
  final result =
      await AdaptivePresenter.showForm<PromptAssistantProviderFormResult>(
        context: context,
        dialogWidth: 520,
        title: provider == null
            ? context.l10n.promptAssistant_addProvider
            : context.l10n.promptAssistant_editProviderTitle,
        builder: (context, scrollController) => PromptAssistantProviderForm(
          provider: provider,
          scrollController: scrollController,
        ),
      );
  if (result == null || !context.mounted) return null;

  final notifier = ref.read(promptAssistantConfigProvider.notifier);
  final remote = ref.read(providerRemoteModelsProvider.notifier);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l10n = context.l10n;
  final state = ref.read(promptAssistantConfigProvider);
  final name = result.name.isEmpty ? result.preset.defaultName : result.name;
  final id =
      provider?.id ??
      _uniqueProviderId(
        state,
        _providerIdFromName(name, fallback: result.preset.defaultId),
      );
  final next = ProviderConfig(
    id: id,
    name: name,
    type: result.preset.legacyType,
    protocol: result.preset.defaultProtocol,
    preset: result.preset,
    baseUrl: result.baseUrl,
    enabled: provider?.enabled ?? true,
    allowImageInput: result.allowImageInput,
    concurrency: result.concurrency,
  );

  try {
    await notifier.upsertProvider(next);
  } on CodexOAuthException catch (error) {
    if (error.code == 'revocation_unconfirmed') remote.forget(id);
    if (context.mounted) {
      messenger?.showSnackBar(
        SnackBar(content: Text(codexOAuthErrorLabel(l10n, error.code))),
      );
    }
    return null;
  }
  if (result.preset == ProviderPreset.codexOAuth ||
      provider?.preset == ProviderPreset.codexOAuth) {
    await notifier.setProviderApiKey(id, '');
  } else if (result.apiKey.trim().isNotEmpty) {
    await notifier.setProviderApiKey(id, result.apiKey);
  }
  if (provider == null) {
    await notifier.addProviderModels(
      id,
      result.preset.defaultModelNames,
      source: ModelSource.manual,
    );
  } else if (provider.baseUrl != next.baseUrl) {
    remote.forget(id);
  }
  return id;
}

Future<bool> confirmDeleteProvider(
  BuildContext context,
  WidgetRef ref,
  ProviderConfig provider,
) async {
  final confirmed = await ThemedConfirmDialog.showDelete(
    context: context,
    itemName: provider.name,
  );
  if (!confirmed || !context.mounted) return false;
  final remote = ref.read(providerRemoteModelsProvider.notifier);
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref
        .read(promptAssistantConfigProvider.notifier)
        .deleteProvider(provider.id);
  } on CodexOAuthException catch (error) {
    if (error.code == 'revocation_unconfirmed') remote.forget(provider.id);
    if (context.mounted) {
      messenger?.showSnackBar(
        SnackBar(content: Text(codexOAuthErrorLabel(l10n, error.code))),
      );
    }
    return false;
  }
  remote.forget(provider.id);
  return true;
}

String _uniqueProviderId(PromptAssistantConfigState state, String baseId) {
  bool taken(String id) => state.providers.any((provider) => provider.id == id);
  if (!taken(baseId)) return baseId;
  var index = 2;
  while (taken('${baseId}_$index')) {
    index++;
  }
  return '${baseId}_$index';
}

String _providerIdFromName(String name, {required String fallback}) {
  final normalized = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return normalized.isEmpty ? fallback : normalized;
}

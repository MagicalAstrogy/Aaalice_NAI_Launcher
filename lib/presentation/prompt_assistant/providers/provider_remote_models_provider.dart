import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/prompt_assistant_service.dart';
import 'provider_remote_model_names_provider.dart';

/// 各服务商最近一次拉到的模型 ID；只在本次运行内保留，用来标出接口已不再列出的模型。
final providerRemoteModelsProvider =
    StateNotifierProvider<
      ProviderRemoteModelsNotifier,
      Map<String, List<String>>
    >((ref) => ProviderRemoteModelsNotifier(ref));

class ProviderRemoteModelsNotifier
    extends StateNotifier<Map<String, List<String>>> {
  ProviderRemoteModelsNotifier(this._ref) : super(const {});

  final Ref _ref;
  final Map<String, int> _generations = {};

  Future<List<String>> fetch(String providerId) async {
    final generation = _generations[providerId] ?? 0;
    final names = await _ref
        .read(promptAssistantServiceProvider)
        .fetchAvailableModels(providerId);
    if (!mounted || (_generations[providerId] ?? 0) != generation) {
      throw StateError('Provider changed while loading models.');
    }
    final unique = <String>{
      for (final name in names)
        if (name.trim().isNotEmpty) name.trim(),
    }.toList();
    state = {...state, providerId: unique};
    return unique;
  }

  /// 地址或密钥变化后旧列表不再代表这个服务商。
  void forget(String providerId) {
    _generations[providerId] = (_generations[providerId] ?? 0) + 1;
    _ref
        .read(providerRemoteModelNamesProvider.notifier)
        .update((names) => {...names}..remove(providerId));
    if (!state.containsKey(providerId)) return;
    state = {...state}..remove(providerId);
  }
}

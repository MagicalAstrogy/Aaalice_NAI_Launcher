import 'package:dio/dio.dart';

import '../../../../core/agent/agent_types.dart';
import '../../../../data/models/prompt_assistant/prompt_assistant_models.dart';
import '../../models/agent_protocol.dart';
import '../assistant_cancellation.dart';
import 'agent_wire_helpers.dart';
import 'openai_responses_adapter.dart';
import 'prompt_assistant_adapter.dart';
import 'reasoning_payload.dart';

typedef CodexRequestRegistrar =
    void Function() Function(String providerId, void Function() cancel);

/// Official Sign in with ChatGPT direct inference. OAuth tokens never fall
/// back to API keys or leave the fixed public OpenAI endpoints.
/// https://developers.openai.com/siwc/token-sharing-open-source
class CodexOAuthAdapter extends OpenAiResponsesAdapter {
  const CodexOAuthAdapter({
    required this.getAccessToken,
    this.onModelCatalog,
    this.registerRequest,
  });

  final Future<String> Function(String providerId) getAccessToken;
  final CodexRequestRegistrar? registerRequest;
  final void Function(String providerId, Map<String, String> names)?
  onModelCatalog;

  void Function() _register(String providerId, CancelToken token) =>
      registerRequest?.call(
        providerId,
        () => token.cancel('ChatGPT session changed'),
      ) ??
      () {};

  @override
  bool get followRedirects => false;

  @override
  String resolveEndpoint(ProviderConfig provider) =>
      'https://api.openai.com/v1/responses';

  @override
  Future<Map<String, dynamic>> agentHeaders(
    ProviderConfig provider,
    String? apiKey,
  ) async => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ${await getAccessToken(provider.id)}',
  };

  @override
  Future<List<String>> fetchModels({
    required Dio dio,
    required ProviderConfig provider,
    required String? apiKey,
  }) async {
    final cancelToken = CancelToken();
    final unregister = _register(provider.id, cancelToken);
    try {
      return await _fetchModels(dio, provider, cancelToken);
    } finally {
      unregister();
    }
  }

  Future<List<String>> _fetchModels(
    Dio dio,
    ProviderConfig provider,
    CancelToken cancelToken,
  ) async {
    final token = await getAccessToken(provider.id);
    cancelToken.throwIfCancelled();
    final response = await dio.get<Object?>(
      'https://api.openai.com/v1/models',
      options: Options(
        headers: {'Authorization': 'Bearer $token'},
        followRedirects: false,
        responseType: ResponseType.json,
      ),
      cancelToken: cancelToken,
    );
    if (await getAccessToken(provider.id) != token) {
      throw StateError('ChatGPT account changed while loading models.');
    }
    cancelToken.throwIfCancelled();
    final body = response.data;
    if (body is! Map || body['models'] is! List) {
      throw const FormatException('Invalid ChatGPT model catalog.');
    }
    final names = <String, String>{};
    for (final raw in body['models'] as List) {
      if (raw is! Map || raw['visibility'] != 'list') continue;
      final slug = raw['slug'];
      final label = raw['display_name'];
      if (slug is String && slug.trim().isNotEmpty) {
        names[slug] = label is String && label.trim().isNotEmpty ? label : slug;
      }
    }
    onModelCatalog?.call(provider.id, names);
    return names.keys.toList();
  }

  @override
  Map<String, dynamic> buildAgentPayload(AgentChatRequest request) {
    final payload = super.buildAgentPayload(request)
      ..remove('max_output_tokens');
    for (final item in payload['input'] as List) {
      if (item is Map && item['type'] == 'function_call') {
        item['namespace'] = 'functions';
      }
    }
    // The direct plan-usage route requires namespaced local tools.
    final tools = payload['tools'];
    if (tools is List && tools.isNotEmpty) {
      payload['tools'] = [
        {'type': 'namespace', 'name': 'functions', 'tools': tools},
      ];
    }
    return payload;
  }

  @override
  Stream<AgentWireEvent> completeAgent({
    required Dio dio,
    required AgentChatRequest request,
    required CancelToken cancelToken,
  }) async* {
    final unregister = _register(request.provider.id, cancelToken);
    try {
      await for (final event in super.completeAgent(
        dio: dio,
        request: request,
        cancelToken: cancelToken,
      )) {
        if (cancelToken.isCancelled) {
          yield const AgentWireError('aborted');
          return;
        }
        if (event is AgentWireFinish && event.stopReason == StopReason.length) {
          yield const AgentWireError('ChatGPT response was incomplete.');
        } else {
          yield event;
        }
      }
    } finally {
      unregister();
    }
  }

  @override
  Future<String> complete({
    required Dio dio,
    required PromptAssistantRequest request,
    required CancelToken cancelToken,
  }) async {
    final unregister = _register(request.provider.id, cancelToken);
    try {
      return await _complete(dio, request, cancelToken);
    } finally {
      unregister();
    }
  }

  Future<String> _complete(
    Dio dio,
    PromptAssistantRequest request,
    CancelToken cancelToken,
  ) async {
    final payload = {
      'model': request.model,
      'store': false,
      'stream': true,
      'instructions': request.systemPrompt,
      if (responsesReasoningEffort(request.reasoningRequest, null)
          case final effort?)
        'reasoning': {'effort': effort},
      if (request.responseFormat == PromptAssistantResponseFormat.jsonObject)
        'text': {
          'format': {'type': 'json_object'},
        },
      'input': [
        {
          'role': 'user',
          'content': [
            for (final part in request.userParts)
              if (part is PromptAssistantTextPart)
                {'type': 'input_text', 'text': part.text}
              else if (part is PromptAssistantImagePart)
                {
                  'type': 'input_image',
                  'image_url': imageDataUri(part),
                  'detail': 'auto',
                },
          ],
        },
      ],
    };
    final output = StringBuffer();
    var completed = false;
    String? failure;
    final parser = AgentSseParser(
      onEvent: (event, data) {
        final json = parseSseJson(data);
        if (json == null) return;
        switch (event.isEmpty ? json['type'] : event) {
          case 'response.output_text.delta':
            if (json['delta'] case final String delta) output.write(delta);
          case 'response.completed':
            completed = true;
          case 'response.incomplete':
            failure = 'ChatGPT response was incomplete.';
          case 'response.failed':
          case 'error':
            final response = json['response'];
            final error = response is Map ? response['error'] : json['error'];
            final code = error is Map ? error['code'] : null;
            failure =
                'ChatGPT request failed${code is String ? ': $code' : '.'}';
        }
      },
    );
    await for (final chunk in agentStreamPost(
      dio,
      endpoint: resolveEndpoint(request.provider),
      payload: payload,
      headers: await agentHeaders(request.provider, null),
      cancelToken: cancelToken,
      receiveTimeout: request.responseTimeout,
      followRedirects: false,
    )) {
      parser.push(chunk);
    }
    parser.close();
    cancelToken.throwIfCancelled();
    if (failure != null) throw StateError(failure!);
    if (!completed) {
      throw StateError('ChatGPT stream ended before response.completed.');
    }
    return output.toString();
  }
}

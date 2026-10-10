import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/agent/agent_types.dart';
import 'package:nai_launcher/data/models/prompt_assistant/prompt_assistant_models.dart';
import 'package:nai_launcher/presentation/agent_chat/services/agent_api_client.dart';
import 'package:nai_launcher/presentation/prompt_assistant/models/agent_protocol.dart';
import 'package:nai_launcher/presentation/prompt_assistant/services/prompt_assistant_api_client.dart';
import 'package:nai_launcher/presentation/prompt_assistant/services/provider_adapters/codex_oauth_adapter.dart';
import 'package:nai_launcher/presentation/prompt_assistant/services/provider_adapters/prompt_assistant_adapter.dart';

final _provider = ProviderPreset.codexOAuth.createConfig().copyWith(
  baseUrl: 'https://untrusted.example/relay',
);

String _sse(String type, [Map<String, Object?> fields = const {}]) =>
    'data: ${jsonEncode({'type': type, ...fields})}\n\n';

PromptAssistantRequest _request() => PromptAssistantRequest(
  sessionId: 'test',
  provider: _provider,
  model: 'account-model',
  systemPrompt: 'Be helpful',
  userParts: [PromptAssistantContentPart.text('hello')],
  apiKey: 'must-not-use-api-key',
  maxOutputTokens: 4096,
);

AgentChatRequest _agentRequest() => AgentChatRequest(
  sessionId: 'test',
  provider: _provider,
  model: 'account-model',
  systemPrompt: 'Be helpful',
  messages: [UserMessage.text('hello')],
  tools: const [
    Tool(
      name: 'local_tool',
      description: 'Local tool',
      parameters: {'type': 'object', 'properties': <String, Object?>{}},
    ),
  ],
  apiKey: 'must-not-use-api-key',
  maxOutputTokens: 4096,
);

void main() {
  test('sign-out cancels a pending text response and unregisters it', () async {
    final transport = _PendingTransport();
    final dio = Dio()..httpClientAdapter = transport;
    void Function()? invalidate;
    var released = false;
    final client = PromptAssistantApiClient(
      dio: dio,
      codexAccessToken: (_) async => 'token',
      codexRegisterRequest: (id, cancel) {
        expect(id, _provider.id);
        invalidate = cancel;
        return () => released = true;
      },
    );
    addTearDown(() {
      client.dispose();
      dio.close(force: true);
    });
    final result = client.complete(request: _request()).toList();
    final assertion = expectLater(result, throwsA(isA<StateError>()));
    await transport.started.future;
    invalidate!();
    transport.add(
      _sse('response.output_text.delta', {'delta': 'late'}) +
          _sse('response.completed'),
    );
    await transport.finish();
    await assertion;
    expect(released, isTrue);
  });

  test(
    'sign-out stops late agent tool calls and never reports success',
    () async {
      final transport = _PendingTransport();
      final dio = Dio()..httpClientAdapter = transport;
      void Function()? invalidate;
      var released = false;
      final client = AgentApiClient(
        dio,
        codexAccessToken: (_) async => 'token',
        codexRegisterRequest: (_, cancel) {
          invalidate = cancel;
          return () => released = true;
        },
      );
      addTearDown(() => dio.close(force: true));
      final result = client.complete(_agentRequest()).toList();
      await transport.started.future;
      invalidate!();
      transport.add(
        _sse('response.output_item.done', {
              'item': {
                'type': 'function_call',
                'call_id': 'late',
                'name': 'local_tool',
                'arguments': '{}',
              },
            }) +
            _sse('response.completed'),
      );
      await transport.finish();
      final events = await result;
      expect(events.whereType<AgentWireToolCallDone>(), isEmpty);
      expect(events.whereType<AgentWireFinish>(), isEmpty);
      expect(events.whereType<AgentWireError>().single.message, 'aborted');
      expect(released, isTrue);
    },
  );
  test('OAuth preset has no static models or API key requirement', () {
    expect(ProviderPreset.codexOAuth.requiresApiKey, isFalse);
    expect(ProviderPreset.codexOAuth.defaultModelNames, isEmpty);
    final decoded = ProviderConfig.fromJson(_provider.toJson());
    expect(decoded.preset, ProviderPreset.codexOAuth);
    expect(decoded.protocol, ProviderProtocol.openaiResponses);
  });

  test(
    'model catalog is authenticated, filtered, named and server ordered',
    () async {
      final transport = _Transport(
        jsonEncode({
          'models': [
            {
              'slug': 'model-z',
              'display_name': 'Model Z',
              'visibility': 'list',
            },
            {'slug': 'hidden', 'display_name': 'Hidden', 'visibility': 'hide'},
            {
              'slug': 'model-a',
              'display_name': 'Model A',
              'visibility': 'list',
            },
          ],
        }),
        json: true,
      );
      final dio = Dio()..httpClientAdapter = transport;
      addTearDown(() => dio.close(force: true));
      Map<String, String>? names;
      final adapter = CodexOAuthAdapter(
        getAccessToken: (_) async => 'oauth-test-token',
        onModelCatalog: (_, value) => names = value,
      );
      expect(
        await adapter.fetchModels(dio: dio, provider: _provider, apiKey: 'key'),
        ['model-z', 'model-a'],
      );
      expect(names, {'model-z': 'Model Z', 'model-a': 'Model A'});
      expect(
        transport.options!.uri.toString(),
        'https://api.openai.com/v1/models',
      );
      expect(transport.options!.followRedirects, isFalse);
      expect(
        transport.options!.headers['Authorization'],
        'Bearer oauth-test-token',
      );
    },
  );

  test(
    'prompt requests stream with store false and no unsupported output limit',
    () async {
      final transport = _Transport(
        _sse('response.output_text.delta', {'delta': 'Hello'}) +
            _sse('response.completed', {'response': <String, Object?>{}}),
      );
      final dio = Dio()..httpClientAdapter = transport;
      final client = PromptAssistantApiClient(
        dio: dio,
        codexAccessToken: (_) async => 'oauth-test-token',
      );
      addTearDown(() {
        client.dispose();
        dio.close(force: true);
      });
      final result = await client.complete(request: _request()).toList();
      expect(result.first.delta, 'Hello');
      final payload = transport.options!.data as Map;
      expect(payload['stream'], isTrue);
      expect(payload['store'], isFalse);
      expect(payload, isNot(contains('max_output_tokens')));
      expect(
        transport.options!.uri.toString(),
        'https://api.openai.com/v1/responses',
      );
      expect(transport.options!.followRedirects, isFalse);
      expect(
        transport.options!.headers['Authorization'],
        'Bearer oauth-test-token',
      );
    },
  );

  for (final terminal in ['', 'response.incomplete', 'response.failed']) {
    test('prompt rejects incomplete terminal: $terminal', () async {
      final dio = Dio()
        ..httpClientAdapter = _Transport(
          _sse('response.output_text.delta', {'delta': 'partial'}) +
              (terminal.isEmpty ? '' : _sse(terminal)),
        );
      addTearDown(() => dio.close(force: true));
      final adapter = CodexOAuthAdapter(getAccessToken: (_) async => 'token');
      await expectLater(
        adapter.complete(
          dio: dio,
          request: _request(),
          cancelToken: CancelToken(),
        ),
        throwsStateError,
      );
    });
  }

  test(
    'agent uses namespaced local tools and recognizes data-only SSE',
    () async {
      final transport = _Transport(
        _sse('response.output_item.done', {
              'item': {
                'type': 'function_call',
                'call_id': 'call',
                'name': 'local_tool',
                'namespace': 'functions',
                'arguments': '{}',
              },
            }) +
            _sse('response.completed', {'response': <String, Object?>{}}),
      );
      final dio = Dio()..httpClientAdapter = transport;
      addTearDown(() => dio.close(force: true));
      final client = AgentApiClient(
        dio,
        codexAccessToken: (_) async => 'token',
      );
      final events = await client.complete(_agentRequest()).toList();
      expect(
        events.whereType<AgentWireToolCallDone>().single.name,
        'local_tool',
      );
      expect(events.last, isA<AgentWireFinish>());
      final payload = transport.options!.data as Map;
      expect((payload['tools'] as List).single['type'], 'namespace');
      expect((payload['tools'] as List).single['name'], 'functions');
      expect(payload, isNot(contains('max_output_tokens')));
    },
  );

  test(
    'missing OAuth session never falls back to configured API key',
    () async {
      final transport = _Transport('');
      final dio = Dio()..httpClientAdapter = transport;
      final client = PromptAssistantApiClient(dio: dio);
      addTearDown(() {
        client.dispose();
        dio.close(force: true);
      });
      await expectLater(
        client.complete(request: _request()).toList(),
        throwsStateError,
      );
      expect(transport.options, isNull);
    },
  );

  test('account change discards stale catalog', () async {
    var calls = 0;
    final dio = Dio()
      ..httpClientAdapter = _Transport('{"models":[]}', json: true);
    addTearDown(() => dio.close(force: true));
    final adapter = CodexOAuthAdapter(
      getAccessToken: (_) async => '${calls++}',
    );
    await expectLater(
      adapter.fetchModels(dio: dio, provider: _provider, apiKey: null),
      throwsStateError,
    );
  });
}

class _Transport implements HttpClientAdapter {
  _Transport(this.body, {this.json = false});
  final String body;
  final bool json;
  RequestOptions? options;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    this.options = options;
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [
          json ? 'application/json' : 'text/event-stream',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _PendingTransport implements HttpClientAdapter {
  final started = Completer<void>();
  final _stream = StreamController<Uint8List>();

  void add(String data) => _stream.add(Uint8List.fromList(utf8.encode(data)));
  Future<void> finish() => _stream.close();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    started.complete();
    return ResponseBody(
      _stream.stream,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {
    if (!_stream.isClosed) unawaited(_stream.close());
  }
}

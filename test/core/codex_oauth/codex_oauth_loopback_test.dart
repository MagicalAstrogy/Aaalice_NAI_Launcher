import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_loopback.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_models.dart';

void main() {
  late CodexOAuthCallbackReceiver receiver;
  late HttpClient client;

  setUp(() async {
    receiver = await startCodexOAuthReceiver();
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await receiver.close();
  });

  test(
    'binds ephemeral IPv4 loopback and accepts one matching callback',
    () async {
      expect(receiver.redirectUri.host, '127.0.0.1');
      expect(receiver.redirectUri.scheme, 'http');
      expect(receiver.redirectUri.port, greaterThan(0));
      expect(receiver.redirectUri.path, '/auth/callback');
      final callback = receiver.receive(state: 'expected-state');
      final uri = receiver.redirectUri.replace(
        queryParameters: {
          'state': 'expected-state',
          'code': 'synthetic-code',
          'client_id': 'oaiapp_test',
        },
      );
      final response = await (await client.getUrl(uri)).close();
      expect(response.statusCode, HttpStatus.ok);
      expect(
        response.headers.value(HttpHeaders.cacheControlHeader),
        'no-store',
      );
      expect(response.headers.value('Referrer-Policy'), 'no-referrer');
      await response.drain<void>();
      expect((await callback).queryParameters['code'], 'synthetic-code');
      final replay = await (await client.getUrl(uri)).close();
      expect(replay.statusCode, HttpStatus.badRequest);
      await replay.drain<void>();
    },
  );

  test(
    'invalid state, duplicate state, wrong path and hostile host do not consume login',
    () async {
      final callback = receiver.receive(state: 'expected-state');
      for (final uri in [
        receiver.redirectUri.replace(query: 'state=wrong&code=synthetic-code'),
        receiver.redirectUri.replace(
          query: 'state=expected-state&state=other&code=synthetic-code',
        ),
        receiver.redirectUri.replace(
          path: '/unrelated',
          query: 'state=expected-state&code=synthetic-code',
        ),
      ]) {
        final response = await (await client.getUrl(uri)).close();
        expect(response.statusCode, HttpStatus.badRequest);
        await response.drain<void>();
      }
      final valid = receiver.redirectUri.replace(
        query: 'state=expected-state&code=synthetic-code',
      );
      final request = await client.getUrl(valid);
      request.headers.set(HttpHeaders.hostHeader, 'example.invalid');
      final hostile = await request.close();
      expect(hostile.statusCode, HttpStatus.badRequest);
      await hostile.drain<void>();
      final response = await (await client.getUrl(valid)).close();
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      expect((await callback).queryParameters['state'], 'expected-state');
    },
  );

  test('closing listener cancels pending callback and is idempotent', () async {
    final callback = receiver.receive(state: 'expected-state');
    final assertion = expectLater(
      callback,
      throwsA(
        isA<CodexOAuthException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
    await receiver.close();
    await assertion;
    await receiver.close();
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'codex_oauth_models.dart';

abstract interface class CodexOAuthHttp {
  Future<Map<String, dynamic>> getJson(Uri uri);
  Future<Map<String, dynamic>> postForm(
    Uri uri,
    Map<String, String> fields, {
    bool allowEmpty = false,
  });
}

/// Isolated from shared Dio interceptors so tokens are never sent to logs.
/// All credential-bearing requests stay on the official HTTPS auth origin.
final class OfficialCodexOAuthHttp implements CodexOAuthHttp {
  static const _timeout = Duration(seconds: 30);
  static const _maxBodyBytes = 1024 * 1024;

  static void validateUri(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host != 'auth.openai.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery) {
      throw const CodexOAuthException(
        'invalid_response',
        'The authentication endpoint is not trusted.',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> getJson(Uri uri) => _request('GET', uri);

  @override
  Future<Map<String, dynamic>> postForm(
    Uri uri,
    Map<String, String> fields, {
    bool allowEmpty = false,
  }) => _request('POST', uri, fields: fields, allowEmpty: allowEmpty);

  Future<Map<String, dynamic>> _request(
    String method,
    Uri uri, {
    Map<String, String>? fields,
    bool allowEmpty = false,
  }) async {
    validateUri(uri);
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      return await (() async {
        final request = await client.openUrl(method, uri);
        request.followRedirects = false;
        request.maxRedirects = 0;
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (fields != null) {
          request.headers.contentType = ContentType(
            'application',
            'x-www-form-urlencoded',
            charset: 'utf-8',
          );
          request.write(Uri(queryParameters: fields).query);
        }
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > _maxBodyBytes) {
            throw const CodexOAuthException(
              'invalid_response',
              'Authentication response is too large.',
            );
          }
          bytes.addAll(chunk);
        }
        Map<String, dynamic>? body;
        try {
          final decoded = bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
          if (decoded is Map<String, dynamic>) body = decoded;
        } catch (_) {
          // Raw bodies and decoding exceptions can contain credentials.
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final code = body?['error'];
          if (code == 'invalid_grant' ||
              code == 'invalid_refresh_token' ||
              code == 'token_expired' ||
              code == 'refresh_token_expired' ||
              code == 'refresh_token_reused' ||
              code == 'refresh_token_invalidated') {
            throw CodexOAuthException(
              'reauthentication_required',
              'Sign in with ChatGPT again.',
              oauthErrorCode: code as String,
            );
          }
          if (code == 'invalid_client') {
            throw const CodexOAuthException(
              'invalid_client',
              'The ChatGPT client registration was rejected.',
            );
          }
          throw const CodexOAuthException(
            'network_error',
            'The authentication request was not successful.',
          );
        }
        if (allowEmpty && bytes.isEmpty) return <String, dynamic>{};
        if (body == null) {
          throw const CodexOAuthException(
            'invalid_response',
            'The authentication response is invalid.',
          );
        }
        return body;
      })().timeout(_timeout);
    } on CodexOAuthException {
      rethrow;
    } catch (_) {
      throw const CodexOAuthException(
        'network_error',
        'Could not reach the authentication service.',
      );
    } finally {
      client.close(force: true);
    }
  }
}

import 'dart:convert';

import 'codex_oauth_models.dart';

/// Internal persistence model. Only encode into CodexOAuthStore.
/// Do not add this type to application settings, export, or backup models.
final class CodexOAuthSession {
  const CodexOAuthSession({
    required this.providerId,
    required this.clientId,
    required this.subject,
    required this.accountLabel,
    this.accessToken,
    this.refreshToken,
    this.idToken,
    this.expiresAt,
    this.earliestRefreshAt,
    this.scopes = const {},
    this.planPermissionMissing = false,
  });

  final String providerId;
  final String clientId;
  final String subject;
  final String accountLabel;
  final String? accessToken;
  final String? refreshToken;
  final String? idToken;
  final DateTime? expiresAt;
  final DateTime? earliestRefreshAt;
  final Set<String> scopes;
  final bool planPermissionMissing;

  bool get hasCredentials => accessToken != null && refreshToken != null;

  CodexOAuthSession withoutCredentials() => CodexOAuthSession(
    providerId: providerId,
    clientId: clientId,
    subject: subject,
    accountLabel: accountLabel,
  );

  String encodeForSecureStorage() => jsonEncode({
    'version': 1,
    'provider_id': providerId,
    'client_id': clientId,
    'subject': subject,
    'account_label': accountLabel,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'id_token': idToken,
    'expires_at': expiresAt?.toUtc().toIso8601String(),
    'earliest_refresh_at': earliestRefreshAt?.toUtc().toIso8601String(),
    'scopes': scopes.toList(),
    'plan_permission_missing': planPermissionMissing,
  });

  static CodexOAuthSession decode(String encoded, String providerId) {
    try {
      if (encoded.length > 128 * 1024) throw const FormatException();
      final json = jsonDecode(encoded) as Map<String, dynamic>;
      if (json['version'] != 1 || json['provider_id'] != providerId) {
        throw const FormatException();
      }
      final clientId = json['client_id'] as String;
      final subject = json['subject'] as String;
      final accountLabel = json['account_label'] as String;
      if (clientId.isEmpty ||
          clientId == CodexOAuthEndpoints.registrationClient ||
          subject.isEmpty ||
          accountLabel.isEmpty) {
        throw const FormatException();
      }
      final session = CodexOAuthSession(
        providerId: providerId,
        clientId: clientId,
        subject: subject,
        accountLabel: accountLabel,
        accessToken: json['access_token'] as String?,
        refreshToken: json['refresh_token'] as String?,
        idToken: json['id_token'] as String?,
        expiresAt: json['expires_at'] == null
            ? null
            : DateTime.parse(json['expires_at'] as String).toUtc(),
        earliestRefreshAt: json['earliest_refresh_at'] == null
            ? null
            : DateTime.parse(json['earliest_refresh_at'] as String).toUtc(),
        scopes: (json['scopes'] as List).cast<String>().toSet(),
        planPermissionMissing: json['plan_permission_missing'] == true,
      );
      if (session.hasCredentials &&
          (session.accessToken!.isEmpty ||
              session.refreshToken!.isEmpty ||
              session.expiresAt == null ||
              (!session.planPermissionMissing &&
                  !session.scopes.contains('chatgpt.tokens.use.direct')))) {
        throw const FormatException();
      }
      return session;
    } catch (_) {
      throw const CodexOAuthException(
        'storage_error',
        'The saved authentication record is invalid.',
      );
    }
  }
}

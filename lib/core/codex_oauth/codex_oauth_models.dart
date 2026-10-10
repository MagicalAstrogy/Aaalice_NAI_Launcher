/// Public authentication state intentionally contains no credentials.
enum CodexOAuthPhase { signedOut, signingIn, signedIn, refreshing, error }

final class CodexOAuthStatus {
  const CodexOAuthStatus({
    required this.providerId,
    this.phase = CodexOAuthPhase.signedOut,
    this.accountLabel,
    this.errorCode,
  });

  final String providerId;
  final CodexOAuthPhase phase;
  final String? accountLabel;
  final String? errorCode;
}

/// Only locally defined messages/codes may cross the authentication boundary.
final class CodexOAuthException implements Exception {
  const CodexOAuthException(this.code, this.message, {this.oauthErrorCode});

  final String code;
  final String message;

  /// An allowlisted protocol code, never the server's free-form description.
  final String? oauthErrorCode;

  @override
  String toString() => 'CodexOAuthException($code): $message';
}

final class CodexOAuthEndpoints {
  const CodexOAuthEndpoints._();

  static const issuer = 'https://auth.openai.com';
  static const resource = 'https://api.openai.com/v1';
  static const registrationClient = 'dynamic_agent_client';
  static const scopes =
      'openid profile email offline_access resource.invoke '
      'chatgpt.tokens.use.direct';
  static final authorize = Uri.parse('$issuer/api/accounts/authorize');
  static final token = Uri.parse('$issuer/api/accounts/oauth/token');
  static final discovery = Uri.parse(
    '$issuer/.well-known/openid-configuration',
  );
}

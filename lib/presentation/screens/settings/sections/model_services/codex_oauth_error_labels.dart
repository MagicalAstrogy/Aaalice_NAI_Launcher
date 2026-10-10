import '../../../../../l10n/app_localizations.dart';

/// Display only local, translated messages; never server responses or tokens.
String codexOAuthErrorLabel(AppLocalizations l10n, String code) =>
    switch (code) {
      'timeout' => l10n.modelServices_codexErrorTimeout,
      'browser_unavailable' ||
      'unsupported_platform' => l10n.modelServices_codexErrorBrowser,
      'authorization_denied' ||
      'permission_missing' => l10n.modelServices_codexErrorDenied,
      'signed_out' ||
      'reauthentication_required' => l10n.modelServices_codexErrorSignIn,
      'storage_error' => l10n.modelServices_codexErrorStorage,
      'revocation_unconfirmed' => l10n.modelServices_codexErrorRevocation,
      'network_error' => l10n.modelServices_codexErrorNetwork,
      _ => l10n.modelServices_codexErrorGeneric,
    };

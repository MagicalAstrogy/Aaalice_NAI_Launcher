import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/codex_oauth/codex_oauth_providers.dart';
import '../../../../../core/codex_oauth/codex_oauth_service.dart';
import '../../../../../core/utils/localization_extension.dart';
import '../../../../../data/models/prompt_assistant/prompt_assistant_models.dart';
import '../../../../../l10n/app_localizations.dart';
import '../../../../prompt_assistant/providers/provider_remote_models_provider.dart';
import '../../widgets/settings_card.dart';
import 'codex_oauth_error_labels.dart';

/// Account controls never receive tokens or allow a different API destination.
class CodexOAuthConnectionCard extends ConsumerStatefulWidget {
  const CodexOAuthConnectionCard({super.key, required this.provider});

  final ProviderConfig provider;

  @override
  ConsumerState<CodexOAuthConnectionCard> createState() =>
      _CodexOAuthConnectionCardState();
}

class _CodexOAuthConnectionCardState
    extends ConsumerState<CodexOAuthConnectionCard> {
  late final CodexOAuthService _auth;
  late final ProviderRemoteModelsNotifier _remote;
  StreamSubscription<CodexOAuthStatus>? _subscription;
  CodexOAuthStatus? _status;
  String? _errorCode;
  bool? _connectionOk;
  bool _signingIn = false;
  bool _signingOut = false;
  bool _checking = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _auth = ref.read(codexOAuthServiceProvider);
    _remote = ref.read(providerRemoteModelsProvider.notifier);
    _bind();
  }

  @override
  void didUpdateWidget(covariant CodexOAuthConnectionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider.id != widget.provider.id) {
      _release(oldWidget.provider.id);
      _bind();
    }
  }

  @override
  void dispose() {
    _release(widget.provider.id);
    super.dispose();
  }

  void _release(String providerId) {
    _generation++;
    _subscription?.cancel();
    _subscription = null;
    _auth.cancelLogin(providerId);
  }

  void _bind() {
    final providerId = widget.provider.id;
    _status = null;
    _errorCode = null;
    _connectionOk = null;
    _signingIn = false;
    _signingOut = false;
    _checking = false;
    _subscription = _auth
        .watchStatus(providerId)
        .listen(
          (status) {
            if (!mounted || widget.provider.id != status.providerId) return;
            setState(() {
              _status = status;
              _errorCode = status.errorCode;
            });
          },
          onError: (Object _) {
            if (!mounted || widget.provider.id != providerId) return;
            setState(() => _errorCode = 'storage_error');
          },
        );
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  Future<void> _login() async {
    if (_signingIn || _signingOut || _checking) return;
    final generation = ++_generation;
    final providerId = widget.provider.id;
    _remote.forget(providerId);
    setState(() {
      _signingIn = true;
      _errorCode = null;
      _connectionOk = null;
    });
    try {
      await _auth.login(providerId: providerId);
      if (_isCurrent(generation)) _remote.forget(providerId);
    } catch (error) {
      if (_isCurrent(generation)) {
        setState(() => _errorCode = _safeErrorCode(error));
      }
    } finally {
      if (_isCurrent(generation)) setState(() => _signingIn = false);
    }
  }

  void _cancel() {
    _generation++;
    _auth.cancelLogin(widget.provider.id);
    setState(() {
      _signingIn = false;
      _errorCode = null;
    });
  }

  Future<void> _logout() async {
    if (_signingIn || _signingOut || _checking) return;
    final generation = ++_generation;
    final providerId = widget.provider.id;
    _remote.forget(providerId);
    setState(() {
      _signingOut = true;
      _connectionOk = null;
      _errorCode = null;
    });
    try {
      await _auth.logout(providerId);
      if (_isCurrent(generation)) _remote.forget(providerId);
    } catch (error) {
      if (_isCurrent(generation)) {
        if (_safeErrorCode(error) == 'revocation_unconfirmed') {
          _remote.forget(providerId);
        }
        setState(() => _errorCode = _safeErrorCode(error));
      }
    } finally {
      if (_isCurrent(generation)) setState(() => _signingOut = false);
    }
  }

  Future<void> _checkConnection() async {
    if (_signingIn || _signingOut || _checking) return;
    final generation = ++_generation;
    final providerId = widget.provider.id;
    setState(() {
      _checking = true;
      _connectionOk = null;
      _errorCode = null;
    });
    try {
      await _remote.fetch(providerId);
      if (_isCurrent(generation)) setState(() => _connectionOk = true);
    } catch (error) {
      if (_isCurrent(generation)) {
        setState(() {
          _connectionOk = false;
          _errorCode = _safeErrorCode(error);
        });
      }
    } finally {
      if (_isCurrent(generation)) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final phase = _status?.phase;
    final signingIn = _signingIn || phase == CodexOAuthPhase.signingIn;
    final refreshing = phase == CodexOAuthPhase.refreshing;
    final signedIn = phase == CodexOAuthPhase.signedIn || refreshing;
    final restoring = _status == null && _errorCode == null;
    final busy =
        restoring || signingIn || refreshing || _signingOut || _checking;
    final errorCode = _errorCode;
    final statusText = restoring
        ? l10n.modelServices_codexRestoring
        : signingIn
        ? l10n.modelServices_codexSigningIn
        : refreshing
        ? l10n.modelServices_codexRefreshing
        : signedIn
        ? l10n.modelServices_codexSignedIn
        : errorCode == 'permission_missing'
        ? l10n.modelServices_codexNeedsPlanAuthorization
        : l10n.modelServices_codexSignedOut;

    return SettingsCard(
      key: const ValueKey('model-services-codex-oauth-card'),
      title: l10n.modelServices_codexTitle,
      description: l10n.modelServices_codexDescription,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _statusIndicator(theme, signedIn: signedIn, text: statusText),
            if (_status?.accountLabel != null) ...[
              const SizedBox(height: 4),
              Text(
                _status!.accountLabel!,
                key: const ValueKey('codex-oauth-account'),
                style: theme.textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              l10n.modelServices_codexPrivacy,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (errorCode != null && errorCode != 'cancelled') ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  codexOAuthErrorLabel(l10n, errorCode),
                  key: const ValueKey('codex-oauth-error'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ] else if (_connectionOk == true) ...[
              const SizedBox(height: 8),
              Text(
                l10n.modelServices_codexConnectionOk,
                key: const ValueKey('codex-oauth-connection-result'),
              ),
            ],
            const SizedBox(height: 12),
            _buildActions(
              l10n,
              signingIn: signingIn,
              signedIn: signedIn,
              busy: busy,
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusIndicator(
    ThemeData theme, {
    required bool signedIn,
    required String text,
  }) => Semantics(
    liveRegion: true,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          signedIn ? Icons.verified_user_outlined : Icons.person_outline,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            key: const ValueKey('codex-oauth-status'),
            style: theme.textTheme.titleSmall,
          ),
        ),
      ],
    ),
  );

  Widget _buildActions(
    AppLocalizations l10n, {
    required bool signingIn,
    required bool signedIn,
    required bool busy,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      Widget action(Widget child) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: constraints.maxWidth),
        child: child,
      );
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (signingIn)
            action(
              TextButton.icon(
                key: const ValueKey('codex-oauth-cancel'),
                onPressed: _cancel,
                icon: const Icon(Icons.close_rounded),
                label: Text(l10n.common_cancel),
              ),
            ),
          if (!signingIn && (signedIn || _errorCode == 'permission_missing'))
            action(
              TextButton.icon(
                key: const ValueKey('codex-oauth-sign-out'),
                onPressed: busy ? null : _logout,
                icon: _signingOut
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.logout_rounded),
                label: Text(l10n.modelServices_codexSignOut),
              ),
            ),
          if (!signingIn && !signedIn)
            action(
              FilledButton.icon(
                key: const ValueKey('codex-oauth-sign-in'),
                onPressed: busy ? null : _login,
                icon: const Icon(Icons.login_rounded),
                label: Text(
                  _errorCode == 'permission_missing'
                      ? l10n.modelServices_codexAuthorizePlan
                      : l10n.modelServices_codexSignIn,
                ),
              ),
            ),
          if (signedIn)
            action(
              TextButton.icon(
                key: const ValueKey('codex-oauth-check-connection'),
                onPressed: busy ? null : _checkConnection,
                icon: _checking
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check_rounded),
                label: Text(l10n.modelServices_checkConnection),
              ),
            ),
        ],
      );
    },
  );
}

String _safeErrorCode(Object error) =>
    error is CodexOAuthException ? error.code : 'generic';

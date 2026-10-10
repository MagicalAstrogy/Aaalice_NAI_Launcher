import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'codex_oauth_service.dart';

final codexOAuthServiceProvider = Provider<CodexOAuthService>((ref) {
  final service = CodexOAuthService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

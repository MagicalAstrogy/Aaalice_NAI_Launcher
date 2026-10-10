import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'codex_oauth_models.dart';

/// A dedicated secret store. Never delegates to the application's config,
/// backup, or best-effort SecureStorageService memory fallback.
abstract interface class CodexOAuthStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class SecureCodexOAuthStore implements CodexOAuthStore {
  SecureCodexOAuthStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            mOptions: MacOsOptions(useDataProtectionKeyChain: false),
          );

  final FlutterSecureStorage _storage;

  String _key(String key) =>
      'codex_oauth_v1_${sha256.convert(utf8.encode(key))}';

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: _key(key));
    } catch (_) {
      throw const CodexOAuthException(
        'storage_error',
        'Secure credential storage is unavailable.',
      );
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: _key(key), value: value);
    } catch (_) {
      throw const CodexOAuthException(
        'storage_error',
        'Could not save credentials securely.',
      );
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: _key(key));
    } catch (_) {
      throw const CodexOAuthException(
        'storage_error',
        'Could not remove credentials securely.',
      );
    }
  }
}

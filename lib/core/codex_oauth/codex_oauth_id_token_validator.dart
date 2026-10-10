import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/signers/rsa_signer.dart';

import 'codex_oauth_models.dart';

/// Only identity claims from a successfully verified OpenAI ID token.
class CodexOAuthIdentity {
  const CodexOAuthIdentity({required this.subject, this.email, this.name});

  final String subject;
  final String? email;
  final String? name;
}

/// Strict RS256/OIDC validation for Sign in with ChatGPT.
///
/// [loadJwks] must fetch the JWKS URI from OpenAI's trusted discovery document,
/// with HTTPS, an allowlisted auth.openai.com host, bounded responses and a
/// timeout. No URL or key embedded in a token is ever used for discovery.
class CodexOAuthIdTokenValidator {
  CodexOAuthIdTokenValidator({
    required Future<Map<String, dynamic>> Function() loadJwks,
    DateTime Function()? clock,
  }) : _loadJwks = loadJwks,
       _clock = clock ?? DateTime.now;

  static const issuer = CodexOAuthEndpoints.issuer;
  static const _maxTokenLength = 32 * 1024;
  static const _maxJwksKeys = 64;
  static final _base64UrlCharacters = RegExp(r'^[A-Za-z0-9_-]+$');

  final Future<Map<String, dynamic>> Function() _loadJwks;
  final DateTime Function() _clock;

  Future<CodexOAuthIdentity> validate(
    String idToken, {
    required String clientId,
    required String nonce,
    String? expectedSubject,
  }) => _validate(
    idToken,
    clientId: clientId,
    expectedNonce: nonce,
    expectedSubject: expectedSubject,
  );

  /// A refresh has no new authorization nonce, but must retain the identity.
  Future<CodexOAuthIdentity> validateRefresh(
    String idToken, {
    required String clientId,
    required String expectedSubject,
  }) => _validate(
    idToken,
    clientId: clientId,
    expectedNonce: null,
    expectedSubject: expectedSubject,
  );

  Future<CodexOAuthIdentity> _validate(
    String idToken, {
    required String clientId,
    required String? expectedNonce,
    required String? expectedSubject,
  }) async {
    try {
      if (!_boundedString(clientId, 512) ||
          clientId == 'dynamic_agent_client' ||
          (expectedNonce != null && !_boundedString(expectedNonce, 1024)) ||
          (expectedSubject != null && !_boundedString(expectedSubject, 512))) {
        _fail('invalid_validation_context');
      }
      final parts = _splitToken(idToken);
      final header = _decodeObject(parts[0], 4096);
      final kid = _validateHeader(header);
      final key = await _loadVerificationKey(kid);
      _verifySignature(parts, key);
      final claims = _decodeObject(parts[1], 16 * 1024);
      return _validateClaims(
        claims,
        clientId: clientId,
        expectedNonce: expectedNonce,
        expectedSubject: expectedSubject,
      );
    } on _IdTokenValidationFailure catch (failure) {
      throw CodexOAuthException(
        'invalid_id_token',
        'OpenAI ID token validation failed (${failure.reason}).',
      );
    } catch (_) {
      // Parser/library/transport errors may contain raw token or response data.
      throw const CodexOAuthException(
        'invalid_id_token',
        'OpenAI ID token validation failed.',
      );
    }
  }

  List<String> _splitToken(String token) {
    if (token.isEmpty || token.length > _maxTokenLength) {
      _fail('invalid_token_format');
    }
    final parts = token.split('.');
    if (parts.length != 3 || parts.any((part) => part.isEmpty)) {
      _fail('invalid_token_format');
    }
    return parts;
  }

  String _validateHeader(Map<String, dynamic> header) {
    if (header['alg'] != 'RS256') _fail('unsupported_algorithm');
    if (header.containsKey('crit') ||
        header.containsKey('b64') ||
        header.containsKey('jku') ||
        header.containsKey('jwk') ||
        header.containsKey('x5u') ||
        header.containsKey('x5c') ||
        header.containsKey('zip')) {
      _fail('unsupported_header');
    }
    if (header.containsKey('typ') && header['typ'] != 'JWT') {
      _fail('unsupported_header');
    }
    final kid = header['kid'];
    if (!_boundedString(kid, 256)) _fail('invalid_key_id');
    return kid as String;
  }

  Future<RSAPublicKey> _loadVerificationKey(String kid) async {
    final Map<String, dynamic> jwks;
    try {
      jwks = await _loadJwks();
    } catch (_) {
      _fail('jwks_unavailable');
    }
    _checkJwksBounds(jwks);
    final keys = jwks['keys'];
    if (keys is! List || keys.isEmpty || keys.length > _maxJwksKeys) {
      _fail('invalid_jwks');
    }
    final seenIds = <String>{};
    Map<String, dynamic>? selected;
    for (final key in keys) {
      if (key is! Map<String, dynamic> || !_boundedString(key['kid'], 256)) {
        _fail('invalid_jwks');
      }
      final keyId = key['kid'] as String;
      if (!seenIds.add(keyId)) _fail('ambiguous_key_id');
      if (keyId == kid) selected = key;
    }
    if (selected == null) _fail('unknown_key_id');
    return _parsePublicKey(selected);
  }

  RSAPublicKey _parsePublicKey(Map<String, dynamic> key) {
    final operations = key['key_ops'];
    if (key['kty'] != 'RSA' ||
        (key.containsKey('alg') && key['alg'] != 'RS256') ||
        (key.containsKey('use') && key['use'] != 'sig') ||
        (key.containsKey('key_ops') &&
            (operations is! List ||
                operations.length != 1 ||
                operations.single != 'verify')) ||
        const ['d', 'p', 'q', 'dp', 'dq', 'qi', 'oth'].any(key.containsKey)) {
      _fail('invalid_signing_key');
    }
    final modulus = _decodeUnsignedInteger(key['n'], 1024);
    final exponent = _decodeUnsignedInteger(key['e'], 4);
    if (modulus.bitLength < 2048 ||
        modulus.bitLength > 8192 ||
        modulus.isEven ||
        exponent < BigInt.from(3) ||
        exponent.isEven) {
      _fail('invalid_signing_key');
    }
    return RSAPublicKey(modulus, exponent);
  }

  void _verifySignature(List<String> parts, RSAPublicKey key) {
    try {
      final signature = _decodeBase64Url(parts[2], 1024);
      if (signature.length != (key.modulus!.bitLength + 7) ~/ 8) {
        _fail('invalid_signature');
      }
      final verifier = RSASigner(SHA256Digest(), '0609608648016503040201')
        ..init(false, PublicKeyParameter<RSAPublicKey>(key));
      if (!verifier.verifySignature(
        Uint8List.fromList(ascii.encode('${parts[0]}.${parts[1]}')),
        RSASignature(signature),
      )) {
        _fail('invalid_signature');
      }
    } on _IdTokenValidationFailure {
      rethrow;
    } catch (_) {
      _fail('invalid_signature');
    }
  }

  CodexOAuthIdentity _validateClaims(
    Map<String, dynamic> claims, {
    required String clientId,
    required String? expectedNonce,
    required String? expectedSubject,
  }) {
    if (claims['iss'] != issuer) _fail('issuer_mismatch');
    _validateAudience(claims, clientId);
    final now = _clock().toUtc().millisecondsSinceEpoch / 1000;
    final expiration = _numericDate(claims['exp']);
    final issuedAt = _numericDate(claims['iat']);
    if (expiration <= now) _fail('expired_token');
    if (issuedAt > now || issuedAt >= expiration) _fail('invalid_issued_at');
    if (claims.containsKey('nbf')) {
      final notBefore = _numericDate(claims['nbf']);
      if (notBefore > now || notBefore >= expiration) {
        _fail('token_not_yet_valid');
      }
    }
    if (expectedNonce != null) {
      final tokenNonce = claims['nonce'];
      if (!_boundedString(tokenNonce, 1024) ||
          !_equalNonce(tokenNonce as String, expectedNonce)) {
        _fail('nonce_mismatch');
      }
    }
    final subject = claims['sub'];
    if (!_boundedString(subject, 512)) _fail('invalid_subject');
    if (expectedSubject != null && subject != expectedSubject) {
      _fail('subject_mismatch');
    }
    return CodexOAuthIdentity(
      subject: subject as String,
      email: _optionalText(claims['email'], 320),
      name: _optionalText(claims['name'], 512),
    );
  }

  void _validateAudience(Map<String, dynamic> claims, String clientId) {
    final audience = claims['aud'];
    final List<String> audiences;
    if (_boundedString(audience, 512)) {
      audiences = [audience as String];
    } else if (audience is List &&
        audience.isNotEmpty &&
        audience.length <= 16 &&
        audience.every((value) => _boundedString(value, 512))) {
      audiences = audience.cast<String>();
    } else {
      _fail('audience_mismatch');
    }
    if (!audiences.contains(clientId) ||
        audiences.toSet().length != audiences.length) {
      _fail('audience_mismatch');
    }
    if ((audiences.length > 1 || claims.containsKey('azp')) &&
        claims['azp'] != clientId) {
      _fail('authorized_party_mismatch');
    }
  }

  Map<String, dynamic> _decodeObject(String encoded, int maxBytes) {
    final source = utf8.decode(_decodeBase64Url(encoded, maxBytes));
    _checkJsonDepth(source);
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic>) _fail('invalid_token_format');
    return value;
  }

  Uint8List _decodeBase64Url(String encoded, int maxBytes) {
    if (encoded.isEmpty ||
        encoded.length > (maxBytes * 4 + 2) ~/ 3 ||
        !_base64UrlCharacters.hasMatch(encoded)) {
      _fail('invalid_token_format');
    }
    final decoded = base64Url.decode(base64Url.normalize(encoded));
    if (decoded.length > maxBytes ||
        base64Url.encode(decoded).replaceAll('=', '') != encoded) {
      _fail('invalid_token_format');
    }
    return decoded;
  }

  BigInt _decodeUnsignedInteger(dynamic encoded, int maxBytes) {
    if (encoded is! String) _fail('invalid_signing_key');
    final bytes = _decodeBase64Url(encoded, maxBytes);
    if (bytes.isEmpty || bytes.first == 0) _fail('invalid_signing_key');
    // Only JWK Base64urlUInt decoding; RSA is implemented by PointyCastle.
    var value = BigInt.zero;
    for (final byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  void _checkJsonDepth(String source) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (final code in source.codeUnits) {
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (code == 0x5c) {
          escaped = true;
        } else if (code == 0x22) {
          inString = false;
        }
      } else if (code == 0x22) {
        inString = true;
      } else if (code == 0x7b || code == 0x5b) {
        if (++depth > 16) _fail('invalid_token_format');
      } else if (code == 0x7d || code == 0x5d) {
        depth--;
      }
    }
  }

  void _checkJwksBounds(Map<String, dynamic> jwks) {
    var nodes = 0;
    var characters = 0;
    void visit(dynamic value, int depth) {
      if (++nodes > 4096 || depth > 8) _fail('invalid_jwks');
      if (value is String) {
        characters += value.length;
        if (characters > 256 * 1024) _fail('invalid_jwks');
      } else if (value is List) {
        if (value.length > 4096) _fail('invalid_jwks');
        for (final entry in value) {
          visit(entry, depth + 1);
        }
      } else if (value is Map<String, dynamic>) {
        if (value.length > 4096) _fail('invalid_jwks');
        for (final entry in value.entries) {
          visit(entry.key, depth + 1);
          visit(entry.value, depth + 1);
        }
      } else if (value != null && value is! num && value is! bool) {
        _fail('invalid_jwks');
      }
    }

    visit(jwks, 0);
  }

  num _numericDate(dynamic value) {
    if (value is! num || !value.isFinite || value < 0 || value > 253402300799) {
      _fail('invalid_time_claim');
    }
    return value;
  }

  String? _optionalText(dynamic value, int maxLength) {
    if (value == null) return null;
    if (value is! String || value.length > maxLength) {
      _fail('invalid_profile_claim');
    }
    return value.isEmpty ? null : value;
  }

  bool _boundedString(dynamic value, int maxLength) =>
      value is String && value.isNotEmpty && value.length <= maxLength;

  bool _equalNonce(String actual, String expected) {
    var difference = actual.length ^ expected.length;
    for (var index = 0; index < expected.length; index++) {
      difference |=
          expected.codeUnitAt(index) ^
          (index < actual.length ? actual.codeUnitAt(index) : 0);
    }
    return difference == 0;
  }

  // All callers supply local constants; never interpolate provider data here.
  Never _fail(String reason) => throw _IdTokenValidationFailure(reason);
}

/// Distinguishes our local failure codes from untrusted dependency exceptions.
class _IdTokenValidationFailure implements Exception {
  const _IdTokenValidationFailure(this.reason);

  final String reason;
}

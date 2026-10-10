import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_id_token_validator.dart';
import 'package:nai_launcher/core/codex_oauth/codex_oauth_models.dart';
import 'package:pointycastle/export.dart';

const _clientId = 'oaiapp_test_client';
const _nonce = 'test-only-oidc-nonce';
const _subject = 'test-only-subject';
const _kid = 'test-only-key-id';
const _nowSeconds = 1800000000;

void main() {
  late _TokenFixture fixture;

  setUpAll(() {
    fixture = _TokenFixture();
  });

  Future<CodexOAuthIdentity> validate(
    String token, {
    Map<String, dynamic>? jwks,
    String clientId = _clientId,
    String nonce = _nonce,
    String? expectedSubject,
  }) =>
      CodexOAuthIdTokenValidator(
        loadJwks: () async => jwks ?? fixture.jwks(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(
          _nowSeconds * 1000,
          isUtc: true,
        ),
      ).validate(
        token,
        clientId: clientId,
        nonce: nonce,
        expectedSubject: expectedSubject,
      );

  Matcher rejected([String? reason]) => throwsA(
    isA<CodexOAuthException>()
        .having((error) => error.code, 'code', 'invalid_id_token')
        .having(
          (error) => error.message,
          'safe failure reason',
          reason == null ? isNotEmpty : contains('($reason)'),
        ),
  );

  Future<CodexOAuthIdentity> validateRefresh(
    String token, {
    String expectedSubject = _subject,
  }) =>
      CodexOAuthIdTokenValidator(
        loadJwks: () async => fixture.jwks(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(
          _nowSeconds * 1000,
          isUtc: true,
        ),
      ).validateRefresh(
        token,
        clientId: _clientId,
        expectedSubject: expectedSubject,
      );

  group('refreshed ID tokens', () {
    test('accepts the verified same account without a new nonce', () async {
      final claims = fixture.claims()..remove('nonce');
      final result = await validateRefresh(fixture.token(claims: claims));
      expect(result.subject, _subject);
    });

    test('accepts a retained authorization nonce during refresh', () async {
      final result = await validateRefresh(fixture.token());
      expect(result.subject, _subject);
    });

    test('rejects a refreshed token for a different account', () async {
      await expectLater(
        validateRefresh(fixture.token(), expectedSubject: 'another-subject'),
        rejected('subject_mismatch'),
      );
    });

    test('requires a nonempty previously verified subject', () async {
      await expectLater(
        validateRefresh(fixture.token(), expectedSubject: ''),
        rejected('invalid_validation_context'),
      );
    });

    test('continues to verify signatures during refresh', () async {
      final parts = fixture.token().split('.')..[2] = _encode([1, 2, 3]);
      await expectLater(
        validateRefresh(parts.join('.')),
        rejected('invalid_signature'),
      );
    });

    test('continues to reject expired tokens during refresh', () async {
      final claims = fixture.claims()..['exp'] = _nowSeconds;
      await expectLater(
        validateRefresh(fixture.token(claims: claims)),
        rejected('expired_token'),
      );
    });
  });

  test(
    'returns only the verified subject and optional display claims',
    () async {
      final result = await validate(fixture.token());
      expect(result.subject, _subject);
      expect(result.email, 'test@example.invalid');
      expect(result.name, 'Test Account');
    },
  );

  test('accepts absent optional display claims and JWT type', () async {
    final claims = fixture.claims()
      ..remove('email')
      ..remove('name');
    final header = fixture.header()..remove('typ');
    final result = await validate(
      fixture.token(claims: claims, header: header),
    );
    expect(result.email, isNull);
    expect(result.name, isNull);
  });

  test('accepts the same returning identity', () async {
    final result = await validate(fixture.token(), expectedSubject: _subject);
    expect(result.subject, _subject);
  });

  test('rejects switching the returning account identity', () async {
    await expectLater(
      validate(fixture.token(), expectedSubject: 'another-subject'),
      rejected('subject_mismatch'),
    );
  });

  test('accepts audience arrays with a matching authorized party', () async {
    final claims = fixture.claims()
      ..['aud'] = [_clientId, 'another-trusted-audience']
      ..['azp'] = _clientId;
    expect((await validate(fixture.token(claims: claims))).subject, _subject);
  });

  test('accepts a one-element audience array without azp', () async {
    final claims = fixture.claims()..['aud'] = [_clientId];
    expect((await validate(fixture.token(claims: claims))).subject, _subject);
  });

  test('accepts optional nbf at the current time', () async {
    final claims = fixture.claims()..['nbf'] = _nowSeconds;
    expect((await validate(fixture.token(claims: claims))).subject, _subject);
  });

  test('accepts standards-compliant fractional NumericDate values', () async {
    final claims = fixture.claims()
      ..['iat'] = _nowSeconds - 0.5
      ..['exp'] = _nowSeconds + 0.5;
    expect((await validate(fixture.token(claims: claims))).subject, _subject);
  });

  group('signature and algorithm checks', () {
    test('rejects a signature forged by changing its bytes', () async {
      final parts = fixture.token().split('.');
      final signature = base64Url.decode(base64Url.normalize(parts[2]));
      signature[0] ^= 0x80;
      parts[2] = _encode(signature);
      await expectLater(
        validate(parts.join('.')),
        rejected('invalid_signature'),
      );
    });

    test('rejects claims altered after signing', () async {
      final parts = fixture.token().split('.');
      parts[1] = _encode(
        utf8.encode(
          jsonEncode(fixture.claims()..['sub'] = 'attacker-controlled-subject'),
        ),
      );
      await expectLater(
        validate(parts.join('.')),
        rejected('invalid_signature'),
      );
    });

    test('rejects truncated signatures', () async {
      final parts = fixture.token().split('.')..[2] = _encode([1, 2, 3]);
      await expectLater(
        validate(parts.join('.')),
        rejected('invalid_signature'),
      );
    });

    for (final algorithm in ['none', 'HS256', 'HS384', 'RS512', 'PS256', '']) {
      test('rejects $algorithm rather than trusting the header', () async {
        final header = fixture.header()..['alg'] = algorithm;
        await expectLater(
          validate(fixture.token(header: header)),
          rejected('unsupported_algorithm'),
        );
      });
    }

    for (final extension in [
      'crit',
      'b64',
      'jku',
      'jwk',
      'x5u',
      'x5c',
      'zip',
    ]) {
      test('rejects unsupported JOSE $extension headers', () async {
        final header = fixture.header()..[extension] = 'untrusted';
        await expectLater(
          validate(fixture.token(header: header)),
          rejected('unsupported_header'),
        );
      });
    }

    test('does not treat an access token type as an ID token', () async {
      final header = fixture.header()..['typ'] = 'at+jwt';
      await expectLater(
        validate(fixture.token(header: header)),
        rejected('unsupported_header'),
      );
    });
  });

  group('key selection and trust', () {
    test('rejects a missing kid', () async {
      final header = fixture.header()..remove('kid');
      await expectLater(
        validate(fixture.token(header: header)),
        rejected('invalid_key_id'),
      );
    });

    test('rejects an unknown kid', () async {
      final header = fixture.header()..['kid'] = 'unknown';
      await expectLater(
        validate(fixture.token(header: header)),
        rejected('unknown_key_id'),
      );
    });

    test('rejects duplicate kid values even for the same public key', () async {
      await expectLater(
        validate(
          fixture.token(),
          jwks: {
            'keys': [fixture.publicJwk(), fixture.publicJwk()],
          },
        ),
        rejected('ambiguous_key_id'),
      );
    });

    test(
      'rejects ambiguous unrelated keys instead of first-match selection',
      () async {
        await expectLater(
          validate(
            fixture.token(),
            jwks: {
              'keys': [
                fixture.publicJwk(),
                fixture.publicJwk()..['kid'] = 'duplicate',
                fixture.publicJwk()..['kid'] = 'duplicate',
              ],
            },
          ),
          rejected('ambiguous_key_id'),
        );
      },
    );

    for (final entry in <String, dynamic>{
      'kty': 'oct',
      'alg': 'HS256',
      'use': 'enc',
      'key_ops': ['sign'],
      'd': 'test-only-private-material',
      'n': _encodeBigInt((BigInt.one << 1023) | BigInt.one),
      'e': _encodeBigInt(BigInt.two),
    }.entries) {
      test('rejects invalid public key ${entry.key}', () async {
        final key = fixture.publicJwk()..[entry.key] = entry.value;
        await expectLater(
          validate(
            fixture.token(),
            jwks: {
              'keys': [key],
            },
          ),
          rejected('invalid_signing_key'),
        );
      });
    }

    test('rejects non-canonical RSA integer encoding', () async {
      final key = fixture.publicJwk()..['e'] = _encode([0, 1, 0, 1]);
      await expectLater(
        validate(
          fixture.token(),
          jwks: {
            'keys': [key],
          },
        ),
        rejected('invalid_signing_key'),
      );
    });

    test('accepts absent optional JWK usage metadata', () async {
      final key = fixture.publicJwk()
        ..remove('alg')
        ..remove('use')
        ..remove('key_ops');
      expect(
        (await validate(
          fixture.token(),
          jwks: {
            'keys': [key],
          },
        )).subject,
        _subject,
      );
    });

    test('does not cache an obsolete key set across validations', () async {
      var calls = 0;
      final validator = CodexOAuthIdTokenValidator(
        loadJwks: () async {
          calls++;
          return {
            'keys': [fixture.publicJwk()..['kid'] = 'rotation-$calls'],
          };
        },
        clock: () => DateTime.fromMillisecondsSinceEpoch(_nowSeconds * 1000),
      );
      for (var attempt = 1; attempt <= 2; attempt++) {
        await validator.validate(
          fixture.token(
            header: fixture.header()..['kid'] = 'rotation-$attempt',
          ),
          clientId: _clientId,
          nonce: _nonce,
        );
      }
      expect(calls, 2);
    });
  });

  group('OIDC claims', () {
    for (final invalidIssuer in [
      'https://auth.openai.com/',
      'http://auth.openai.com',
      'https://auth.openai.com.attacker.invalid',
      'https://attacker.invalid',
      null,
    ]) {
      test('rejects an issuer mismatch: $invalidIssuer', () async {
        final claims = fixture.claims()..['iss'] = invalidIssuer;
        await expectLater(
          validate(fixture.token(claims: claims)),
          rejected('issuer_mismatch'),
        );
      });
    }

    for (final invalidAudience in <dynamic>[
      'another-client',
      [],
      [123, _clientId],
      [_clientId, _clientId],
      {'aud': _clientId},
      null,
    ]) {
      test('rejects invalid audience $invalidAudience', () async {
        final claims = fixture.claims()..['aud'] = invalidAudience;
        await expectLater(
          validate(fixture.token(claims: claims)),
          rejected('audience_mismatch'),
        );
      });
    }

    test('requires azp for a multi-audience token', () async {
      final claims = fixture.claims()..['aud'] = [_clientId, 'another-client'];
      await expectLater(
        validate(fixture.token(claims: claims)),
        rejected('authorized_party_mismatch'),
      );
    });

    test('rejects mismatched azp even with one audience', () async {
      final claims = fixture.claims()..['azp'] = 'another-client';
      await expectLater(
        validate(fixture.token(claims: claims)),
        rejected('authorized_party_mismatch'),
      );
    });

    for (final expiration in [_nowSeconds, _nowSeconds - 1]) {
      test('rejects expiration at or before now: $expiration', () async {
        final claims = fixture.claims()..['exp'] = expiration;
        await expectLater(
          validate(fixture.token(claims: claims)),
          rejected('expired_token'),
        );
      });
    }

    for (final field in ['exp', 'iat', 'nbf']) {
      for (final value in <dynamic>['1800000000', null, -1, 253402300800]) {
        test('rejects invalid numeric $field: $value', () async {
          final claims = fixture.claims()..[field] = value;
          await expectLater(
            validate(fixture.token(claims: claims)),
            rejected('invalid_time_claim'),
          );
        });
      }
    }

    test('rejects tokens that are not yet valid', () async {
      final claims = fixture.claims()..['nbf'] = _nowSeconds + 1;
      await expectLater(
        validate(fixture.token(claims: claims)),
        rejected('token_not_yet_valid'),
      );
    });

    test('rejects future-issued tokens', () async {
      final claims = fixture.claims()..['iat'] = _nowSeconds + 1;
      await expectLater(
        validate(fixture.token(claims: claims)),
        rejected('invalid_issued_at'),
      );
    });

    for (final nonce in <dynamic>['wrong-nonce', '', null, 123]) {
      test('rejects missing or mismatched nonce: $nonce', () async {
        final claims = fixture.claims()..['nonce'] = nonce;
        await expectLater(
          validate(fixture.token(claims: claims)),
          rejected('nonce_mismatch'),
        );
      });
    }

    for (final subject in <dynamic>['', null, 123]) {
      test('rejects invalid subjects: $subject', () async {
        final claims = fixture.claims()..['sub'] = subject;
        await expectLater(
          validate(fixture.token(claims: claims)),
          rejected('invalid_subject'),
        );
      });
    }

    test('does not coerce profile objects into display strings', () async {
      final claims = fixture.claims()..['email'] = {'value': 'untrusted'};
      await expectLater(
        validate(fixture.token(claims: claims)),
        rejected('invalid_profile_claim'),
      );
    });
  });

  group('bounded input and safe failures', () {
    for (final token in ['', 'a.b', 'a.b.c.d', 'a.b.', 'a.b.c=']) {
      test('rejects malformed compact serialization: $token', () async {
        await expectLater(validate(token), rejected());
      });
    }

    test('rejects oversized tokens before loading keys', () async {
      var didLoadKeys = false;
      final validator = CodexOAuthIdTokenValidator(
        loadJwks: () async {
          didLoadKeys = true;
          return fixture.jwks();
        },
      );
      await expectLater(
        validator.validate(
          'a' * (32 * 1024 + 1),
          clientId: _clientId,
          nonce: _nonce,
        ),
        rejected('invalid_token_format'),
      );
      expect(didLoadKeys, isFalse);
    });

    test('rejects a deeply nested but correctly signed JSON payload', () async {
      final nesting = '${'[' * 17}0${']' * 17}';
      await expectLater(
        validate(fixture.token(rawClaims: '{"nested":$nesting}')),
        rejected('invalid_token_format'),
      );
    });

    test('rejects non-object JSON payloads', () async {
      await expectLater(
        validate(fixture.token(rawClaims: '[]')),
        rejected('invalid_token_format'),
      );
    });

    test('bounds the number of JWKS entries', () async {
      final keys = List.generate(
        65,
        (index) => fixture.publicJwk()..['kid'] = '$index',
      );
      await expectLater(
        validate(fixture.token(), jwks: {'keys': keys}),
        rejected('invalid_jwks'),
      );
    });

    test('bounds JWKS string data', () async {
      final jwks = fixture.jwks()..['extra'] = 'a' * (256 * 1024 + 1);
      await expectLater(
        validate(fixture.token(), jwks: jwks),
        rejected('invalid_jwks'),
      );
    });

    test('rejects the dynamic registration ID as a token audience', () async {
      await expectLater(
        validate(fixture.token(), clientId: 'dynamic_agent_client'),
        rejected('invalid_validation_context'),
      );
    });

    test('rejects an empty expected nonce', () async {
      await expectLater(
        validate(fixture.token(), nonce: ''),
        rejected('invalid_validation_context'),
      );
    });

    test('transport exceptions never expose their payload', () async {
      final token = fixture.token();
      final validator = CodexOAuthIdTokenValidator(
        loadJwks: () async {
          throw FormatException('untrusted-http-error $token');
        },
      );
      try {
        await validator.validate(token, clientId: _clientId, nonce: _nonce);
        fail('The key load should fail.');
      } on CodexOAuthException catch (error) {
        expect(error.code, 'invalid_id_token');
        expect(error.message, contains('(jwks_unavailable)'));
        expect(error.toString(), isNot(contains(token)));
        expect(error.toString(), isNot(contains('untrusted-http-error')));
      }
    });

    test('JSON parser exceptions never expose token data', () async {
      const marker = 'sensitive-test-token-marker';
      final token = fixture.token(rawClaims: '{"nonce":"$marker"');
      try {
        await validate(token);
        fail('The malformed JSON should fail.');
      } on CodexOAuthException catch (error) {
        expect(error.code, 'invalid_id_token');
        expect(error.toString(), isNot(contains(marker)));
        expect(error.toString(), isNot(contains(token)));
      }
    });
  });
}

/// Deterministic mock-only RSA material; never connects to a real account.
class _TokenFixture {
  _TokenFixture() {
    final random = FortunaRandom()
      ..seed(
        KeyParameter(Uint8List.fromList(List.generate(32, (index) => index))),
      );
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
          random,
        ),
      );
    final pair = generator.generateKeyPair();
    _publicKey = pair.publicKey;
    _privateKey = pair.privateKey;
  }

  late final RSAPublicKey _publicKey;
  late final RSAPrivateKey _privateKey;

  Map<String, dynamic> claims() => {
    'iss': 'https://auth.openai.com',
    'aud': _clientId,
    'sub': _subject,
    'nonce': _nonce,
    'iat': _nowSeconds - 60,
    'exp': _nowSeconds + 600,
    'email': 'test@example.invalid',
    'name': 'Test Account',
  };

  Map<String, dynamic> header() => {'alg': 'RS256', 'kid': _kid, 'typ': 'JWT'};

  Map<String, dynamic> publicJwk() => {
    'kty': 'RSA',
    'kid': _kid,
    'alg': 'RS256',
    'use': 'sig',
    'key_ops': ['verify'],
    'n': _encodeBigInt(_publicKey.modulus!),
    'e': _encodeBigInt(_publicKey.exponent!),
  };

  Map<String, dynamic> jwks() => {
    'keys': [publicJwk()],
  };

  String token({
    Map<String, dynamic>? header,
    Map<String, dynamic>? claims,
    String? rawClaims,
  }) {
    final encodedHeader = _encode(
      utf8.encode(jsonEncode(header ?? this.header())),
    );
    final encodedClaims = _encode(
      utf8.encode(rawClaims ?? jsonEncode(claims ?? this.claims())),
    );
    final message = '$encodedHeader.$encodedClaims';
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(_privateKey));
    final signature = signer.generateSignature(
      Uint8List.fromList(ascii.encode(message)),
    );
    return '$message.${_encode(signature.bytes)}';
  }
}

String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String _encodeBigInt(BigInt value) {
  final bytes = <int>[];
  var remaining = value;
  while (remaining > BigInt.zero) {
    bytes.add((remaining & BigInt.from(255)).toInt());
    remaining >>= 8;
  }
  return _encode(bytes.reversed.toList());
}

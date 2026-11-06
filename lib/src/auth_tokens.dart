import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:uuid/uuid.dart';

class VerifiedAccessToken {
  final String userId;
  final String sessionId;

  const VerifiedAccessToken(this.userId, this.sessionId);
}

class AuthTokens {
  final String _secret;
  static const issuer = 'onta-my-money';
  static const audience = 'onta-my-money-api';
  static const accessLifetime = Duration(minutes: 15);
  static const refreshLifetime = Duration(days: 30);

  AuthTokens(String secret) : _secret = secret {
    if (utf8.encode(secret).length < 32) {
      throw StateError('JWT_SECRET debe tener al menos 32 bytes');
    }
  }

  factory AuthTokens.forDevelopment() =>
      AuthTokens(base64UrlEncode(_randomBytes(48)));

  static List<int> _randomBytes(int count) {
    final random = Random.secure();
    return List<int>.generate(count, (_) => random.nextInt(256));
  }

  String newRefreshToken() => base64UrlEncode(_randomBytes(48));

  String hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  String issueAccessToken(String userId, String sessionId, {DateTime? now}) {
    final issued = (now ?? DateTime.now()).toUtc();
    final jwt = JWT(
      <String, dynamic>{
        'sid': sessionId,
        'nbf': issued.millisecondsSinceEpoch ~/ 1000,
        'exp': issued.add(accessLifetime).millisecondsSinceEpoch ~/ 1000,
        'iat': issued.millisecondsSinceEpoch ~/ 1000,
      },
      issuer: issuer,
      audience: Audience.one(audience),
      subject: userId,
      jwtId: const Uuid().v4(),
    );
    return jwt.sign(SecretKey(_secret),
        algorithm: JWTAlgorithm.HS256, noIssueAt: true);
  }

  VerifiedAccessToken? verifyAccessClaims(String token, {DateTime? now}) {
    try {
      // Reject algorithm/key-confusion before handing the token to the verifier.
      final untrusted = JWT.decode(token);
      if (untrusted.header?['alg'] != 'HS256' ||
          untrusted.header?['typ'] != 'JWT') return null;
      final verified = JWT.verify(token, SecretKey(_secret),
          audience: Audience.one(audience),
          issuer: issuer,
          checkExpiresIn: true,
          checkNotBefore: true);
      if (verified.payload is! Map) return null;
      final claims = Map<String, dynamic>.from(verified.payload as Map);
      final sub = claims['sub'];
      final sid = claims['sid'];
      final jti = claims['jti'];
      final iat = claims['iat'];
      final nbf = claims['nbf'];
      final exp = claims['exp'];
      final aud = claims['aud'];
      final seconds =
          (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
      if (sub is! String ||
          sub.isEmpty ||
          sid is! String ||
          sid.isEmpty ||
          jti is! String ||
          jti.isEmpty ||
          iat is! num ||
          nbf is! num ||
          exp is! num ||
          (aud != audience &&
              !(aud is List && aud.length == 1 && aud.first == audience)) ||
          iat > seconds + 60 ||
          nbf > seconds ||
          exp <= seconds) return null;
      return VerifiedAccessToken(sub, sid);
    } catch (_) {
      return null;
    }
  }

  String? verifyAccessToken(String token, {DateTime? now}) =>
      verifyAccessClaims(token, now: now)?.userId;
}

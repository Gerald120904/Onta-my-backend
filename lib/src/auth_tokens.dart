import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

class AuthTokens {
  final List<int> _secret;
  static const issuer = 'onta-my-money';
  static const accessLifetime = Duration(minutes: 15);
  static const refreshLifetime = Duration(days: 30);

  AuthTokens(String secret) : _secret = utf8.encode(secret) {
    if (_secret.length < 32) {
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

  String hashToken(String token) => sha256.convert(utf8.encode(token)).toString();

  String issueAccessToken(String userId, {DateTime? now}) {
    final time = (now ?? DateTime.now()).toUtc();
    final header = _part({'alg': 'HS256', 'typ': 'JWT'});
    final payload = _part({
      'iss': issuer,
      'sub': userId,
      'jti': const Uuid().v4(),
      'iat': time.millisecondsSinceEpoch ~/ 1000,
      'exp': time.add(accessLifetime).millisecondsSinceEpoch ~/ 1000,
    });
    final message = '$header.$payload';
    final signature = Hmac(sha256, _secret).convert(utf8.encode(message)).bytes;
    return '$message.${base64UrlEncode(signature).replaceAll('=', '')}';
  }

  String? verifyAccessToken(String token, {DateTime? now}) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final expected = Hmac(sha256, _secret)
          .convert(utf8.encode('${parts[0]}.${parts[1]}'))
          .bytes;
      final supplied = base64Url.decode(base64Url.normalize(parts[2]));
      if (!_sameBytes(expected, supplied)) return null;
      final header = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))));
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      if (header is! Map || header['alg'] != 'HS256' ||
          payload is! Map || payload['iss'] != issuer ||
          payload['sub'] is! String || payload['jti'] is! String ||
          payload['exp'] is! int || payload['iat'] is! int) return null;
      final seconds = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
      if (payload['exp'] <= seconds || payload['iat'] > seconds + 60) return null;
      return payload['sub'] as String;
    } catch (_) {
      return null;
    }
  }

  static String _part(Map<String, Object> data) =>
      base64UrlEncode(utf8.encode(jsonEncode(data))).replaceAll('=', '');

  static bool _sameBytes(List<int> a, List<int> b) {
    var difference = a.length ^ b.length;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ (i < b.length ? b[i] : 0);
    }
    return difference == 0;
  }
}

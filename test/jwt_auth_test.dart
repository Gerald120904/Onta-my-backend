import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

import '../lib/src/api.dart';
import '../lib/src/auth_tokens.dart';
import '../lib/src/database.dart';

void main() {
  late AppDatabase db;
  late Api api;
  String? resetLink;

  Future<Response> send(String path,
          {String? token,
          Map<String, Object?>? body,
          String method = 'POST'}) =>
      api.router.call(Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {
          'content-type': 'application/json',
          if (token != null) 'authorization': 'Bearer $token',
        },
        body: body == null ? null : jsonEncode(body),
      ));

  Future<Map<String, dynamic>> login() async {
    final response = await send('/api/auth/login', body: {
      'email': 'auth@test.example',
      'password': 'StrongPassword123!',
    });
    expect(response.statusCode, 200);
    return Map<String, dynamic>.from(jsonDecode(await response.readAsString()));
  }

  setUp(() async {
    resetLink = null;
    db = AppDatabase.inMemory();
    api = Api(db, passwordResetSender: (email, link) async {
      expect(email, 'auth@test.example');
      resetLink = link;
    });
    final registered = await send('/api/auth/register', body: {
      'name': 'Auth Test',
      'email': 'auth@test.example',
      'password': 'StrongPassword123!',
    });
    expect(registered.statusCode, 201);
  });

  tearDown(() async => db.close());

  test('JWT firmado y sesión antigua siguen autorizando al usuario correcto',
      () async {
    final credentials = await login();
    final token = credentials['token'] as String;
    expect(token.split('.'), hasLength(3));
    expect(api.authTokens.verifyAccessToken(token), isNotNull);
    expect(
        (await send('/api/me', method: 'GET', token: token)).statusCode, 200);
    expect(
        (await send('/api/me', method: 'GET', token: '${token}x')).statusCode,
        401);

    final userId = api.authTokens.verifyAccessToken(token)!;
    await db.execute(
        'INSERT INTO sessions(token,user_id,created_at,expires_at) VALUES(?,?,?,?)',
        [
          'legacy-opaque',
          userId,
          DateTime.now().toUtc().toIso8601String(),
          DateTime.now().toUtc().add(const Duration(days: 1)).toIso8601String()
        ]);
    expect(
        (await send('/api/me', method: 'GET', token: 'legacy-opaque'))
            .statusCode,
        200);
  });

  test('Refresh rota una sola vez y logout-all revoca todo', () async {
    final first = await login();
    final rotated = await send('/api/auth/refresh',
        body: {'refresh_token': first['refresh_token']});
    expect(rotated.statusCode, 200);
    final next =
        jsonDecode(await rotated.readAsString()) as Map<String, dynamic>;
    expect(
        (await send('/api/me', method: 'GET', token: first['token'] as String))
            .statusCode,
        401);
    expect(
        (await send('/api/me', method: 'GET', token: next['token'] as String))
            .statusCode,
        200);
    expect(
        (await send('/api/auth/logout-all', token: next['token'] as String))
            .statusCode,
        200);
    expect(
        (await send('/api/me', method: 'GET', token: next['token'] as String))
            .statusCode,
        401);
  });

  test('Replay de refresh revoca toda la familia de sesiÃ³n', () async {
    final first = await login();
    final rotated = await send('/api/auth/refresh',
        body: {'refresh_token': first['refresh_token']});
    final next = jsonDecode(await rotated.readAsString()) as Map<String, dynamic>;
    expect(rotated.statusCode, 200);
    expect(
        (await send('/api/auth/refresh',
                body: {'refresh_token': first['refresh_token']}))
            .statusCode,
        401);
    expect(
        (await send('/api/me', method: 'GET', token: next['token'] as String))
            .statusCode,
        401);
  });

  test('Dos refresh concurrentes revocan la familia al detectar replay',
      () async {
    final first = await login();
    final responses = await Future.wait([
      send('/api/auth/refresh',
          body: {'refresh_token': first['refresh_token']}),
      send('/api/auth/refresh',
          body: {'refresh_token': first['refresh_token']}),
    ]);
    expect(responses.map((response) => response.statusCode).toList(),
        containsAll([200, 401]));
    final successful = responses.firstWhere((response) => response.statusCode == 200);
    final next = jsonDecode(await successful.readAsString()) as Map<String, dynamic>;
    expect(
        (await send('/api/me', method: 'GET', token: next['token'] as String))
            .statusCode,
        401);
  });

  test('Cinco credenciales erróneas bloquean temporalmente el acceso',
      () async {
    final failures = await Future.wait(List.generate(
        5,
        (_) => send('/api/auth/login', body: {
              'email': 'auth@test.example',
              'password': 'wrong',
            })));
    expect(failures.map((response) => response.statusCode), everyElement(401));
    expect(
        (await send('/api/auth/login', body: {
          'email': 'auth@test.example',
          'password': 'StrongPassword123!',
        }))
            .statusCode,
        429);
  });

  test('Recuperación con correo simulado consume el enlace y revoca sesiones',
      () async {
    final old = await login();
    final requested = await send('/api/auth/forgot-password',
        body: {'email': 'auth@test.example'});
    expect(requested.statusCode, 200);
    final raw = Uri.parse(resetLink!).queryParameters['reset_token']!;
    expect(raw, isNotEmpty);
    final reset = await send('/api/auth/reset-password',
        body: {'token': raw, 'new_password': 'NewStrongPassword456!'});
    expect(reset.statusCode, 200);
    expect(
        (await send('/api/auth/reset-password', body: {
          'token': raw,
          'new_password': 'AgainStrongPassword456!'
        }))
            .statusCode,
        400);
    expect(
        (await send('/api/me', method: 'GET', token: old['token'] as String))
            .statusCode,
        401);
    expect(
        (await send('/api/auth/refresh',
                body: {'refresh_token': old['refresh_token']}))
            .statusCode,
        401);
    expect(
        (await send('/api/auth/login', body: {
          'email': 'auth@test.example',
          'password': 'NewStrongPassword456!',
        }))
            .statusCode,
        200);
  });

  test('Error de envío no revela si existe la cuenta', () async {
    final broken = Api(db, passwordResetSender: (_, __) async {
      throw StateError('mail unavailable');
    });
    Future<Response> request(String email) => broken.router.call(Request(
          'POST',
          Uri.parse('http://localhost/api/auth/forgot-password'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'email': email}),
        ));
    final known = await request('auth@test.example');
    final unknown = await request('missing@test.example');
    expect(known.statusCode, unknown.statusCode);
    expect(await known.readAsString(), await unknown.readAsString());
  });

  test('Firma inválida y expiración JWT se rechazan', () {
    final tokens = AuthTokens('a' * 32);
    final now = DateTime.now().toUtc();
    final token = tokens.issueAccessToken('user', 'session-1', now: now);
    expect(tokens.verifyAccessToken(token, now: now), 'user');
    expect(tokens.verifyAccessToken(token, now: now.add(const Duration(minutes: 16))), isNull);
    expect(AuthTokens('b' * 32).verifyAccessToken(token), isNull);
    expect(tokens.verifyAccessClaims(token)?.sessionId, 'session-1');

    final alternativeAlgorithm = JWT({
      'sid': 'session-1',
      'nbf': now.millisecondsSinceEpoch ~/ 1000,
      'exp': now.add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
    }, issuer: AuthTokens.issuer, audience: Audience.one(AuthTokens.audience), subject: 'user', jwtId: 'jti')
        .sign(SecretKey('a' * 32), algorithm: JWTAlgorithm.HS512);
    expect(tokens.verifyAccessToken(alternativeAlgorithm), isNull);
  });
}

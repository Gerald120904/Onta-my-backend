import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/api.dart';
import '../lib/src/database.dart';
import '../lib/src/gmail_service.dart';
import '../lib/src/mail_templates.dart';

void main() {
  late AppDatabase db;
  late GmailService gmail;
  late Api api;
  late String adminToken;
  late String adminId;
  final requests = <http.Request>[];
  var authorizedEmail = 'receptor847@gmail.com';

  Future<Response> send(String method, String path,
          {String? token, Map<String, Object?>? body}) =>
      api.router.call(Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {
          'content-type': 'application/json',
          if (token != null) 'authorization': 'Bearer $token'
        },
        body: body == null ? null : jsonEncode(body),
      ));

  setUp(() async {
    requests.clear();
    authorizedEmail = 'receptor847@gmail.com';
    db = AppDatabase.inMemory();
    adminId = 'admin-1';
    final now = DateTime.now().toUtc().toIso8601String();
    await db.execute(
        'INSERT INTO users(id,name,email,password_hash,opening_balance,created_at,updated_at) '
        'VALUES(?,?,?,?,?,?,?)',
        [
          adminId,
          'Admin',
          'admin@example.com',
          db.hashPassword('StrongPassword123!'),
          0,
          now,
          now
        ]);
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.host == 'oauth2.googleapis.com') {
        if (request.bodyFields['grant_type'] == 'refresh_token') {
          return http.Response(
              jsonEncode(
                  {'access_token': 'renewed-access', 'expires_in': 3600}),
              200);
        }
        return http.Response(
            jsonEncode({
              'access_token': 'first-access',
              'refresh_token': 'private-refresh-token',
              'expires_in': 3600,
              'scope': 'https://www.googleapis.com/auth/gmail.send openid email'
            }),
            200);
      }
      if (request.url.host == 'openidconnect.googleapis.com') {
        return http.Response(
            jsonEncode({'email': authorizedEmail, 'email_verified': true}),
            200);
      }
      if (request.url.host == 'gmail.googleapis.com') {
        return http.Response('{"id":"message-1"}', 200);
      }
      return http.Response('', 404);
    });
    final config = GmailConfig(
        clientId: 'client',
        clientSecret: 'secret',
        redirectUri:
            'https://onta-my-money-api.gerald.prod.page/api/oauth/google/callback',
        from: 'receptor847@gmail.com',
        adminUserId: adminId,
        encryptionKey: base64UrlEncode(List<int>.generate(32, (i) => i)));
    gmail = GmailService(db, config, client: client);
    api = Api(db, gmailService: gmail);
    final login = await send('POST', '/api/auth/login', body: {
      'email': 'admin@example.com',
      'password': 'StrongPassword123!',
    });
    expect(login.statusCode, 200);
    adminToken =
        (jsonDecode(await login.readAsString()) as Map)['token'] as String;
  });

  tearDown(() async => db.close());

  test('Inicio exige sesión, usa offline y state aleatorio de un solo uso',
      () async {
    expect((await send('GET', '/api/oauth/google/start')).statusCode, 401);
    final start =
        await send('GET', '/api/oauth/google/start', token: adminToken);
    expect(start.statusCode, 200);
    final url = Uri.parse((jsonDecode(await start.readAsString())
        as Map)['authorization_url'] as String);
    expect(url.queryParameters['access_type'], 'offline');
    expect(url.queryParameters['scope'],
        contains('https://www.googleapis.com/auth/gmail.send'));
    final state = url.queryParameters['state']!;
    expect(state.length, greaterThan(30));
    final rows = await db.query('SELECT state_hash FROM gmail_oauth_states');
    expect(rows.single['state_hash'], isNot(state));
    final callback = await send(
        'GET', '/api/oauth/google/callback?state=$state&code=code-1');
    expect(callback.statusCode, 200);
    expect(
        (await send(
                'GET', '/api/oauth/google/callback?state=$state&code=code-1'))
            .statusCode,
        400);
    final stored = await db
        .query('SELECT encrypted_refresh_token FROM gmail_oauth_tokens');
    expect(stored.single['encrypted_refresh_token'].toString(),
        isNot(contains('private-refresh-token')));
    expect(
        await gmail.decryptRefreshToken(
            stored.single['encrypted_refresh_token'] as String),
        'private-refresh-token');
  });

  test('Rechaza remitente distinto y no guarda refresh token', () async {
    authorizedEmail = 'other@gmail.com';
    final start =
        await send('GET', '/api/oauth/google/start', token: adminToken);
    final state = Uri.parse((jsonDecode(await start.readAsString())
            as Map)['authorization_url'] as String)
        .queryParameters['state']!;
    expect(
        (await send(
                'GET', '/api/oauth/google/callback?state=$state&code=code-1'))
            .statusCode,
        400);
    expect(await db.query('SELECT * FROM gmail_oauth_tokens'), isEmpty);
  });

  test('Envía MIME texto y HTML y renueva access token desde refresh cifrado',
      () async {
    final encrypted = await gmail.encryptRefreshToken('private-refresh-token');
    await db.execute(
        'INSERT INTO gmail_oauth_tokens(id,encrypted_refresh_token,authorized_email,updated_at) '
        'VALUES(?,?,?,?)',
        [
          'primary',
          encrypted,
          'receptor847@gmail.com',
          DateTime.now().toUtc().toIso8601String()
        ]);
    await gmail.sendMail(
        'recipient@example.com',
        MailTemplates.passwordReset(
            'https://onta-my-money.pages.dev/?reset_token=test'));
    expect(
        requests.where((r) => r.url.host == 'oauth2.googleapis.com').length, 1);
    final sent =
        requests.singleWhere((r) => r.url.host == 'gmail.googleapis.com');
    expect(sent.headers['authorization'], 'Bearer renewed-access');
    final raw = (jsonDecode(sent.body) as Map)['raw'] as String;
    final mime = utf8.decode(base64Url.decode(base64Url.normalize(raw)));
    expect(mime, contains('multipart/alternative'));
    expect(mime, contains('text/plain'));
    expect(mime, contains('text/html'));
    expect(mime, contains('From: receptor847@gmail.com'));
  });

  test('Solo el administrador puede iniciar OAuth y el state vence', () async {
    final now = DateTime.now().toUtc().toIso8601String();
    await db.execute(
        'INSERT INTO users(id,name,email,password_hash,opening_balance,created_at,updated_at) '
        'VALUES(?,?,?,?,?,?,?)',
        [
          'other-1',
          'Other',
          'other@example.com',
          db.hashPassword('StrongPassword123!'),
          0,
          now,
          now
        ]);
    final login = await send('POST', '/api/auth/login', body: {
      'email': 'other@example.com',
      'password': 'StrongPassword123!',
    });
    final otherToken =
        (jsonDecode(await login.readAsString()) as Map)['token'] as String;
    expect(
        (await send('GET', '/api/oauth/google/start', token: otherToken))
            .statusCode,
        403);
    final start =
        await send('GET', '/api/oauth/google/start', token: adminToken);
    final state = Uri.parse((jsonDecode(await start.readAsString())
            as Map)['authorization_url'] as String)
        .queryParameters['state']!;
    await db.execute('UPDATE gmail_oauth_states SET expires_at=?', [
      DateTime.now()
          .toUtc()
          .subtract(const Duration(minutes: 1))
          .toIso8601String()
    ]);
    expect(
        (await send(
                'GET', '/api/oauth/google/callback?state=$state&code=code-1'))
            .statusCode,
        400);
    expect(requests, isEmpty);
  });

  test('Registro requiere verificación de un solo uso', () async {
    final encrypted = await gmail.encryptRefreshToken('private-refresh-token');
    await db.execute(
        'INSERT INTO gmail_oauth_tokens(id,encrypted_refresh_token,authorized_email,updated_at) '
        'VALUES(?,?,?,?)',
        [
          'primary',
          encrypted,
          'receptor847@gmail.com',
          DateTime.now().toUtc().toIso8601String()
        ]);
    final registration = await send('POST', '/api/auth/register', body: {
      'name': 'New User',
      'email': 'new@example.com',
      'password': 'StrongPassword123!',
    });
    expect(registration.statusCode, 201);
    expect(
        (await send('POST', '/api/auth/login', body: {
          'email': 'new@example.com',
          'password': 'StrongPassword123!',
        }))
            .statusCode,
        403);
    final sent =
        requests.singleWhere((r) => r.url.host == 'gmail.googleapis.com');
    final raw = (jsonDecode(sent.body) as Map)['raw'] as String;
    final mime = utf8.decode(base64Url.decode(base64Url.normalize(raw)));
    final verification = RegExp(r'(?<=verify_token=)[A-Za-z0-9_-]+')
        .firstMatch(utf8.decode(base64.decode(RegExp(
                r'(?<=Content-Transfer-Encoding: base64\r\n\r\n)[A-Za-z0-9+/=]+')
            .firstMatch(mime)!
            .group(0)!)))
        ?.group(0);
    expect(verification, isNotNull);
    expect(
        (await send('POST', '/api/auth/verify-email',
                body: {'token': verification}))
            .statusCode,
        200);
    expect(
        (await send('POST', '/api/auth/verify-email',
                body: {'token': verification}))
            .statusCode,
        400);
    expect(
        (await send('POST', '/api/auth/login', body: {
          'email': 'new@example.com',
          'password': 'StrongPassword123!',
        }))
            .statusCode,
        200);
  });
}

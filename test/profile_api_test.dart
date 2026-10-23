import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/api.dart';
import '../lib/src/database.dart';

void main() {
  group('Perfil y Gestión de Cuenta API Tests', () {
    late AppDatabase db;
    late Api api;
    String userToken = '';
    String otherToken = '';
    String userId = '';

    Future<Response> send(
      String method,
      String path, {
      String? token,
      Map<String, dynamic>? body,
    }) async {
      final headers = <String, String>{
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };
      final uri = Uri.parse('http://localhost$path');
      final request = Request(
        method,
        uri,
        headers: headers,
        body: body != null ? jsonEncode(body) : null,
      );
      return await api.router.call(request);
    }

    setUp(() async {
      db = AppDatabase.inMemory();
      api = Api(db);

      // Register primary user
      final reg1 = await send('POST', '/api/auth/register', body: {
        'name': 'Carlos Perez',
        'email': 'carlos@test.com',
        'password': 'Password123!',
        'opening_balance': 100000.0,
      });
      expect(reg1.statusCode, 201);
      final b1 = jsonDecode(await reg1.readAsString());
      userId = b1['id'] as String;

      // Register second user (for isolation testing)
      final reg2 = await send('POST', '/api/auth/register', body: {
        'name': 'Maria Lopez',
        'email': 'maria@test.com',
        'password': 'Password456!',
        'opening_balance': 50000.0,
      });
      expect(reg2.statusCode, 201);

      // Login primary user
      final login1 = await send('POST', '/api/auth/login', body: {
        'email': 'carlos@test.com',
        'password': 'Password123!',
      });
      expect(login1.statusCode, 200);
      userToken = jsonDecode(await login1.readAsString())['token'] as String;

      // Login second user
      final login2 = await send('POST', '/api/auth/login', body: {
        'email': 'maria@test.com',
        'password': 'Password456!',
      });
      expect(login2.statusCode, 200);
      otherToken = jsonDecode(await login2.readAsString())['token'] as String;
    });

    tearDown(() {
      db.close();
    });

    test('GET /api/me retorna datos de perfil del usuario autenticado', () async {
      final res = await send('GET', '/api/me', token: userToken);
      expect(res.statusCode, 200);
      final data = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(data['id'], userId);
      expect(data['name'], 'Carlos Perez');
      expect(data['email'], 'carlos@test.com');
      expect(data['opening_balance'], 100000.0);
      expect(data['created_at'], isNotNull);
    });

    test('PATCH /api/me actualiza el nombre y genera sync_log', () async {
      final res = await send(
        'PATCH',
        '/api/me',
        token: userToken,
        body: {'name': 'Carlos A. Perez'},
      );
      expect(res.statusCode, 200);
      final data = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(data['name'], 'Carlos A. Perez');

      // Verify db updated
      final row = db.db.select('SELECT name FROM users WHERE id=?', [userId]).first;
      expect(row['name'], 'Carlos A. Perez');

      // Verify sync_log has record
      final logs = db.db.select(
        "SELECT * FROM sync_log WHERE user_id=? AND entity_type='user' AND action='update'",
        [userId],
      );
      expect(logs, isNotEmpty);
      final payload = jsonDecode(logs.first['payload'] as String);
      expect(payload['name'], 'Carlos A. Perez');
    });

    test('PATCH /api/me rechaza nombre vacío con código 400', () async {
      final res = await send(
        'PATCH',
        '/api/me',
        token: userToken,
        body: {'name': '   '},
      );
      expect(res.statusCode, 400);
    });

    test('Aislamiento: usuario no puede modificar perfil de otra cuenta', () async {
      // Maria modifies her own profile
      await send(
        'PATCH',
        '/api/me',
        token: otherToken,
        body: {'name': 'Maria Elena Lopez'},
      );

      // Verify Carlos' profile remained untouched
      final carlosRow = db.db.select('SELECT name FROM users WHERE id=?', [userId]).first;
      expect(carlosRow['name'], 'Carlos Perez');
    });

    test('POST /api/me/change-password valida contraseña actual y actualiza con BCrypt', () async {
      // 1. Fails with incorrect current password
      final fail1 = await send(
        'POST',
        '/api/me/change-password',
        token: userToken,
        body: {
          'current_password': 'WrongPassword!',
          'new_password': 'NewPassword123!',
          'confirm_password': 'NewPassword123!',
        },
      );
      expect(fail1.statusCode, 400);

      // 2. Fails when confirmation does not match
      final fail2 = await send(
        'POST',
        '/api/me/change-password',
        token: userToken,
        body: {
          'current_password': 'Password123!',
          'new_password': 'NewPassword123!',
          'confirm_password': 'DifferentPassword123!',
        },
      );
      expect(fail2.statusCode, 400);

      // 3. Fails when new password is too short (< 6)
      final fail3 = await send(
        'POST',
        '/api/me/change-password',
        token: userToken,
        body: {
          'current_password': 'Password123!',
          'new_password': '123',
          'confirm_password': '123',
        },
      );
      expect(fail3.statusCode, 400);

      // 4. Create an extra session for Carlos to test revocation
      final extraLogin = await send('POST', '/api/auth/login', body: {
        'email': 'carlos@test.com',
        'password': 'Password123!',
      });
      final extraToken = jsonDecode(await extraLogin.readAsString())['token'] as String;

      // 5. Successfully changes password and revokes extra session
      final okRes = await send(
        'POST',
        '/api/me/change-password',
        token: userToken,
        body: {
          'current_password': 'Password123!',
          'new_password': 'NewSuperPassword2026!',
          'confirm_password': 'NewSuperPassword2026!',
          'revoke_other_sessions': true,
        },
      );
      expect(okRes.statusCode, 200);

      // 6. Old extraToken is revoked (401)
      final checkExtra = await send('GET', '/api/me', token: extraToken);
      expect(checkExtra.statusCode, 401);

      // 7. Current userToken is still valid (200)
      final checkCurrent = await send('GET', '/api/me', token: userToken);
      expect(checkCurrent.statusCode, 200);

      // 8. Can login with new password
      final newLogin = await send('POST', '/api/auth/login', body: {
        'email': 'carlos@test.com',
        'password': 'NewSuperPassword2026!',
      });
      expect(newLogin.statusCode, 200);
    });
  });
}

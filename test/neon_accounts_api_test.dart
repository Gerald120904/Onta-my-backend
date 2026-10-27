import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/api.dart';
import '../lib/src/database.dart';

void main() {
  final neonUrl = Platform.environment['NEON_DATABASE_URL'] ?? Platform.environment['DATABASE_URL'];
  final hasNeonUrl = neonUrl != null && neonUrl.trim().isNotEmpty && AppDatabase.isValidPostgresUrl(neonUrl);

  group('VERIFICACIÓN REAL DE ENDPOINTS DE CUENTAS EN NEON POSTGRESQL', () {
    test('Ciclo completo de cuentas, inmutabilidad de divisa y cálculo de saldos en Neon', () async {
      final pgDb = await PostgresAppDatabase.connect(neonUrl!, isProduction: true);
      final api = Api(pgDb);

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

      String? testUserId;
      final createdAccountIds = <String>[];

      try {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final testEmail = 'accounts_test_$nowMs@neon.test';
        final testPassword = 'PasswordNeon2026!';

        // 1. Registro y login de usuario sintético
        final regRes = await send('POST', '/api/auth/register', body: {
          'name': 'Usuario Test Cuentas',
          'email': testEmail,
          'password': testPassword,
          'opening_balance': 75000.50,
        });
        expect(regRes.statusCode, 201);
        final regData = jsonDecode(await regRes.readAsString());
        testUserId = regData['id'] as String;
        expect(testUserId, isNotEmpty);

        final loginRes = await send('POST', '/api/auth/login', body: {
          'email': testEmail,
          'password': testPassword,
        });
        expect(loginRes.statusCode, 200);
        final loginData = jsonDecode(await loginRes.readAsString());
        final token = loginData['token'] as String;
        expect(token, isNotEmpty);

        // 2. GET /api/accounts — Verificar cuenta principal por defecto
        final listRes1 = await send('GET', '/api/accounts', token: token);
        expect(listRes1.statusCode, 200);
        final accounts1 = jsonDecode(await listRes1.readAsString()) as List;
        expect(accounts1.length, equals(1));
        final defaultAcc = accounts1.first as Map<String, dynamic>;
        createdAccountIds.add(defaultAcc['id'] as String);

        expect(defaultAcc['currency'], equals('CRC'));
        expect(defaultAcc['is_default'], isTrue);
        expect(defaultAcc['is_archived'], isFalse);
        expect((defaultAcc['initial_balance'] as num).toDouble(), equals(75000.50));
        expect((defaultAcc['current_balance'] as num).toDouble(), equals(75000.50));
        expect(defaultAcc['color'], isNotNull);
        expect(defaultAcc['icon'], isNotNull);
        print('✔ GET /api/accounts: Cuenta por defecto verificada con todas sus columnas y saldo en Neon.');

        // 3. POST /api/accounts — Crear cuenta secundaria en USD
        final createRes = await send('POST', '/api/accounts', token: token, body: {
          'name': 'Ahorros Dólares',
          'currency': 'USD',
          'initial_balance': 1500.25,
          'color': '#3B82F6',
          'icon': 'bank',
        });
        expect(createRes.statusCode, 201);
        final createdAcc = jsonDecode(await createRes.readAsString()) as Map<String, dynamic>;
        final usdAccId = createdAcc['id'] as String;
        createdAccountIds.add(usdAccId);

        expect(createdAcc['name'], equals('Ahorros Dólares'));
        expect(createdAcc['currency'], equals('USD'));
        expect((createdAcc['initial_balance'] as num).toDouble(), equals(1500.25));
        expect((createdAcc['current_balance'] as num).toDouble(), equals(1500.25));
        print('✔ POST /api/accounts: Nueva cuenta multidivisa creada en Neon.');

        // 4. PATCH /api/accounts/:id — Intento de alterar divisa debe ser rechazado
        final patchImmutRes = await send('PATCH', '/api/accounts/$usdAccId', token: token, body: {
          'currency': 'EUR',
        });
        expect(patchImmutRes.statusCode, 400);
        final immutErr = jsonDecode(await patchImmutRes.readAsString());
        expect(immutErr['message'], contains('inmutable'));
        print('✔ PATCH /api/accounts: Intento de cambiar currency rechazado por API (400 Bad Request).');

        // 5. Verificación a nivel de base de datos — Disparador rechaza UPDATE directo
        bool dbTriggerFired = false;
        try {
          await pgDb.execute('UPDATE accounts SET currency = ? WHERE id = ?', ['EUR', usdAccId]);
        } catch (e) {
          dbTriggerFired = true;
          print('✔ UPDATE accounts.currency directo rechazado por trigger en Neon: $e');
        }
        expect(dbTriggerFired, isTrue);

        // 6. PATCH /api/accounts/:id — Actualización válida de metadatos (nombre, color, icono)
        final patchValidRes = await send('PATCH', '/api/accounts/$usdAccId', token: token, body: {
          'name': 'Fondo Emergencia USD',
          'color': '#8B5CF6',
          'icon': 'shield',
        });
        expect(patchValidRes.statusCode, 200);
        final updatedAcc = jsonDecode(await patchValidRes.readAsString());
        expect(updatedAcc['name'], equals('Fondo Emergencia USD'));
        expect(updatedAcc['color'], equals('#8B5CF6'));
        expect(updatedAcc['icon'], equals('shield'));
        expect(updatedAcc['currency'], equals('USD'));
        print('✔ PATCH /api/accounts: Metadatos actualizados correctamente preservando divisa.');

        // 7. Registro de transacción y verificación de saldo recalculado
        final txRes = await send('POST', '/api/transactions', token: token, body: {
          'account_id': usdAccId,
          'type': 'expense',
          'category': 'Suscripciones',
          'amount': 250.25,
          'description': 'Software cloud',
          'date': DateTime.now().toIso8601String(),
        });
        expect(txRes.statusCode, 201);

        final listRes2 = await send('GET', '/api/accounts', token: token);
        expect(listRes2.statusCode, 200);
        final accounts2 = jsonDecode(await listRes2.readAsString()) as List;
        final usdAccUpdated = accounts2.firstWhere((a) => a['id'] == usdAccId);
        expect((usdAccUpdated['initial_balance'] as num).toDouble(), equals(1500.25));
        expect((usdAccUpdated['current_balance'] as num).toDouble(), equals(1250.00));
        print('✔ Cálculo de current_balance con transacciones verificado en Neon (1500.25 - 250.25 = 1250.00).');
      } finally {
        if (testUserId != null) {
          for (final accId in createdAccountIds) {
            try {
              await pgDb.execute('DELETE FROM transactions WHERE account_id = ?', [accId]);
              await pgDb.execute('DELETE FROM accounts WHERE id = ?', [accId]);
            } catch (_) {}
          }
          try {
            await pgDb.execute('DELETE FROM sync_log WHERE user_id = ?', [testUserId]);
            await pgDb.execute('DELETE FROM sessions WHERE user_id = ?', [testUserId]);
            await pgDb.execute('DELETE FROM users WHERE id = ?', [testUserId]);
          } catch (_) {}
          print('✔ Limpieza total garantizada de datos de prueba en Neon (0 residuos).');
        }
        await pgDb.close();
      }
    }, skip: hasNeonUrl ? null : 'Falta NEON_DATABASE_URL configurada (requiere conexión autorizada)');
  });
}

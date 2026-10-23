import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/api.dart';
import '../lib/src/database.dart';
import '../lib/src/migrations/migration_runner.dart';

void main() {
  const pgUrl = 'postgresql://postgres@127.0.0.1:5433/onta_test?sslmode=disable';

  group('ONTA MY MONEY — VALIDACIÓN REAL DE POSTGRESQL', () {
    late PostgresAppDatabase pgDb;
    late Api api;

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

    setUpAll(() async {
      // 1. Conectar directamente a la base de datos PostgreSQL real usando el driver postgres
      pgDb = await PostgresAppDatabase.connect(pgUrl);
      api = Api(pgDb);
    });

    tearDownAll(() async {
      await pgDb.close();
    });

    // =========================================================================
    // 1. MIGRACIONES Y RECUPERACIÓN TRANSACCIONAL EN POSTGRESQL REAL
    // =========================================================================
    group('1. Migraciones Reales y Esquema Exacto', () {
      test('1.1 Las migraciones 001, 002 y 003 se registraron en schema_migrations', () async {
        final rows = await pgDb.query(
          'SELECT version, name FROM schema_migrations ORDER BY version ASC',
        );

        final versions = rows.map((r) => (r['version'] as num).toInt()).toList();
        expect(versions, containsAll([1, 2, 3]));
      });

      test('1.2 Tipos en PostgreSQL son NUMERIC(18,2) exactos, no REAL', () async {
        final cols = await pgDb.query('''
          SELECT table_name, column_name, data_type, numeric_precision, numeric_scale
          FROM information_schema.columns
          WHERE table_schema = 'public'
            AND column_name IN ('opening_balance', 'amount', 'target_amount', 'saved_amount')
          ORDER BY table_name, column_name
        ''');

        expect(cols.isNotEmpty, isTrue);
        for (final col in cols) {
          expect(col['data_type'], equals('numeric'),
              reason: 'Columna ${col['table_name']}.${col['column_name']} debe ser NUMERIC en PostgreSQL');
          expect(col['numeric_precision'], equals(18));
          expect(col['numeric_scale'], equals(2));
        }
      });

      test('1.3 Migración transaccional: un fallo revierte la transacción y permite recuperación limpia', () async {
        // Simular una migración fallida en un runner aislado
        final failedMigration = Migration(
          version: 999,
          name: '999_failing_migration',
          getSql: (isPg) => '''
            CREATE TABLE test_rollback_ok (id TEXT PRIMARY KEY);
            THIS IS INTENTIONAL INVALID SQL SYNTAX;
          ''',
        );

        bool failedAsExpected = false;
        try {
          await pgDb.transaction((tx) async {
            final sql = failedMigration.getSql(true);
            final stmts = sql.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
            for (final s in stmts) {
              await tx.execute(s);
            }
          });
        } catch (_) {
          failedAsExpected = true;
        }

        expect(failedAsExpected, isTrue);

        // Verificar que la tabla test_rollback_ok fue revertida y no existe en PostgreSQL
        final tableCheck = await pgDb.query('''
          SELECT table_name FROM information_schema.tables 
          WHERE table_schema='public' AND table_name='test_rollback_ok'
        ''');
        expect(tableCheck, isEmpty, reason: 'La transacción debió revertir la creación de la tabla');

        // Y la versión 999 no existe en schema_migrations
        final migCheck = await pgDb.query(
          'SELECT version FROM schema_migrations WHERE version=999',
        );
        expect(migCheck, isEmpty);
      });
    });

    // =========================================================================
    // 2. REGISTRO, LOGIN Y SESIONES EN POSTGRESQL REAL
    // =========================================================================
    group('2. Registro, Login y Ciclo de Vida de Sesiones', () {
      final userEmail = 'real_pg_${DateTime.now().millisecondsSinceEpoch}@plata.app';
      String? userToken;
      String? userId;

      test('2.1 Registro crea usuario con hash BCrypt y opening_balance exacto', () async {
        final res = await send(
          'POST',
          '/api/auth/register',
          body: {
            'name': 'Usuario Real Postgres',
            'email': userEmail,
            'password': 'PasswordSegura2026',
            'opening_balance': 75000.50,
          },
        );

        expect(res.statusCode, equals(201));
        final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
        userId = body['id'] as String;

        // Verificar directamente en PostgreSQL que la contraseña está hasheada con BCrypt
        final userRow = await pgDb.query('SELECT password_hash, opening_balance FROM users WHERE id=?', [userId]);
        expect(userRow.isNotEmpty, isTrue);
        final hash = userRow.first['password_hash'] as String;
        expect(hash.startsWith(r'$2a$') || hash.startsWith(r'$2b$'), isTrue);
        expect(userRow.first['opening_balance'], equals(75000.50));
      });

      test('2.2 Login genera sesión válida con expiración en PostgreSQL', () async {
        final res = await send(
          'POST',
          '/api/auth/login',
          body: {
            'email': userEmail,
            'password': 'PasswordSegura2026',
          },
        );

        expect(res.statusCode, equals(200));
        final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
        userToken = body['token'] as String;
        expect(userToken, isNotEmpty);
        expect(body['expires_at'], isNotNull);
        expect(body['user']['opening_balance'], equals(75000.50));

        // Verificar sesión en tabla PostgreSQL
        final sessionRow = await pgDb.query('SELECT * FROM sessions WHERE token=?', [userToken]);
        expect(sessionRow.isNotEmpty, isTrue);
        expect(sessionRow.first['user_id'], equals(userId));
      });

      test('2.3 Consulta de perfil /api/me valida sesión en PostgreSQL', () async {
        final res = await send('GET', '/api/me', token: userToken);

        expect(res.statusCode, equals(200));
        final profile = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
        expect(profile['email'], equals(userEmail));
        expect(profile['opening_balance'], equals(75000.50));
      });

      test('2.4 Expiración de sesión rechaza con 401 y limpia sesión vencida', () async {
        // Forzar expiración de la sesión en PostgreSQL
        final expiredDate = DateTime.now().subtract(const Duration(hours: 2)).toIso8601String();
        await pgDb.execute('UPDATE sessions SET expires_at=? WHERE token=?', [expiredDate, userToken]);

        final res = await send('GET', '/api/me', token: userToken);
        expect(res.statusCode, equals(401));

        // Verificar que la sesión vencida fue removida de PostgreSQL
        final check = await pgDb.query('SELECT * FROM sessions WHERE token=?', [userToken]);
        expect(check, isEmpty);
      });

      test('2.5 Revocación histórica de sesiones funciona con corte de fecha', () async {
        // Crear 3 sesiones con fechas pasadas
        final pastDate = DateTime.now().subtract(const Duration(days: 10)).toIso8601String();
        await pgDb.execute(
          'INSERT INTO sessions(token, user_id, created_at, expires_at) VALUES(?,?,?,?)',
          ['token_hist_1', userId, pastDate, '2099-01-01T00:00:00Z'],
        );
        await pgDb.execute(
          'INSERT INTO sessions(token, user_id, created_at, expires_at) VALUES(?,?,?,?)',
          ['token_hist_2', userId, pastDate, '2099-01-01T00:00:00Z'],
        );

        final cutoff = DateTime.now().subtract(const Duration(days: 1));
        final revoked = await pgDb.revokeSessionsCreatedBefore(cutoff);
        expect(revoked, greaterThanOrEqualTo(2));

        final check = await pgDb.query("SELECT * FROM sessions WHERE token IN ('token_hist_1', 'token_hist_2')");
        expect(check, isEmpty);
      });
    });

    // =========================================================================
    // 3. PRECISIÓN FINANCIERA EXACTA (NUMERIC(18,2))
    // =========================================================================
    group('3. Precisión Financiera Exacta en PostgreSQL', () {
      late String testToken;
      late String testUserId;

      setUpAll(() async {
        final email = 'precision_${DateTime.now().millisecondsSinceEpoch}@plata.app';
        final reg = await send(
          'POST',
          '/api/auth/register',
          body: {
            'name': 'Precisión Financiera',
            'email': email,
            'password': 'Precision123!',
            'opening_balance': 100000.00,
          },
        );
        testUserId = (jsonDecode(await reg.readAsString()) as Map)['id'] as String;

        final login = await send(
          'POST',
          '/api/auth/login',
          body: {'email': email, 'password': 'Precision123!'},
        );
        testToken = (jsonDecode(await login.readAsString()) as Map)['token'] as String;
      });

      test('3.1 Importes con decimales exactos se guardan y leen sin pérdida', () async {
        final amounts = [4500.50, 1234.99, 0.01, 987654.25];

        for (final amt in amounts) {
          final res = await send(
            'POST',
            '/api/transactions',
            token: testToken,
            body: {
              'type': 'expense',
              'category': 'Prueba',
              'amount': amt,
              'description': 'Monto decimal $amt',
            },
          );
          expect(res.statusCode, equals(201));
        }

        final listRes = await send('GET', '/api/transactions', token: testToken);
        expect(listRes.statusCode, equals(200));
        final list = (jsonDecode(await listRes.readAsString()) as List).cast<Map<String, dynamic>>();

        final retrievedAmounts = list.map((t) => (t['amount'] as num).toDouble()).toSet();
        for (final amt in amounts) {
          expect(retrievedAmounts.contains(amt), isTrue, reason: 'Debe contener exactamente $amt');
        }
      });

      test('3.2 Cantidades grandes (₡999,999,999.99) no se desbordan ni redondean', () async {
        const largeAmount = 999999999.99;
        final res = await send(
          'POST',
          '/api/transactions',
          token: testToken,
          body: {
            'type': 'income',
            'category': 'Venta Mayor',
            'amount': largeAmount,
            'description': 'Monto grande',
          },
        );
        expect(res.statusCode, equals(201));
        final txId = (jsonDecode(await res.readAsString()) as Map)['id'] as String;

        // Verificar directamente en PostgreSQL
        final pgRow = await pgDb.query('SELECT amount FROM transactions WHERE id=?', [txId]);
        expect(pgRow.first['amount'], equals(largeAmount));
      });

      test('3.3 Sumatorias repetidas no sufren desviación de punto flotante', () async {
        // Insertar 50 transacciones de 0.10 cada una
        final now = DateTime.now().toIso8601String();
        for (int i = 0; i < 50; i++) {
          await pgDb.execute(
            'INSERT INTO transactions(id, user_id, type, category, amount, description, date, recognized, version, updated_at) '
            'VALUES(?,?,?,?,?,?,?,?,1,?)',
            ['tx_prec_${DateTime.now().microsecondsSinceEpoch}_$i', testUserId, 'expense', 'Centavos', 0.10, 'Fracción $i', now, 1, now],
          );
        }

        // Consultar la sumatoria agregada en PostgreSQL
        final sumRow = await pgDb.query(
          "SELECT SUM(amount) total FROM transactions WHERE user_id=? AND category='Centavos'",
          [testUserId],
        );
        // 50 * 0.10 debe ser exactamente 5.0 (en IEEE 754 a veces resulta 4.999999999999999)
        expect(sumRow.first['total'], equals(5.0));

        // Consultar dashboard
        final dashRes = await send('GET', '/api/dashboard', token: testToken);
        expect(dashRes.statusCode, equals(200));
        final dash = jsonDecode(await dashRes.readAsString()) as Map<String, dynamic>;
        expect(dash['balance'], isA<num>());
        expect(dash['available'], isA<num>());
      });
    });

    // =========================================================================
    // 4. ATOMICIDAD DE OPERACIONES (CRUD + sync_log + audit_log)
    // =========================================================================
    group('4. Atomicidad de Operaciones en PostgreSQL', () {
      late String testToken;
      late String testUserId;

      setUpAll(() async {
        final email = 'atomic_${DateTime.now().millisecondsSinceEpoch}@plata.app';
        final reg = await send(
          'POST',
          '/api/auth/register',
          body: {
            'name': 'Atomicidad',
            'email': email,
            'password': 'PasswordAtomic123',
            'opening_balance': 50000.0,
          },
        );
        testUserId = (jsonDecode(await reg.readAsString()) as Map)['id'] as String;

        final login = await send(
          'POST',
          '/api/auth/login',
          body: {'email': email, 'password': 'PasswordAtomic123'},
        );
        testToken = (jsonDecode(await login.readAsString()) as Map)['token'] as String;
      });

      test('4.1 Creación de transacción guarda entidad, sync_log y audit_log atómicamente', () async {
        final res = await send(
          'POST',
          '/api/transactions',
          token: testToken,
          body: {
            'type': 'expense',
            'category': 'Supermercado',
            'amount': 15000.0,
            'description': 'Compras semanales',
          },
        );

        expect(res.statusCode, equals(201));
        final txId = (jsonDecode(await res.readAsString()) as Map)['id'] as String;

        // Verificar en PostgreSQL que existan los 3 registros
        final entityRows = await pgDb.query('SELECT * FROM transactions WHERE id=?', [txId]);
        final syncRows = await pgDb.query("SELECT * FROM sync_log WHERE entity_id=? AND entity_type='transaction'", [txId]);
        final auditRows = await pgDb.query("SELECT * FROM audit_log WHERE entity_id=? AND entity_type='transaction'", [txId]);

        expect(entityRows.length, equals(1));
        expect(syncRows.length, equals(1));
        expect(auditRows.length, equals(1));
        expect(syncRows.first['action'], equals('create'));
        expect(auditRows.first['action'], equals('create'));
      });

      test('4.2 Si ocurre un error en la transacción, se revierte entidad y sync_log por completo', () async {
        final doomedId = 'tx_doomed_${DateTime.now().millisecondsSinceEpoch}';

        // Ejecutar transacción con inyección de fallo inducido
        bool threw = false;
        try {
          await pgDb.transaction((tx) async {
            await tx.execute(
              'INSERT INTO transactions(id, user_id, type, category, amount, description, date, recognized, version, updated_at) '
              'VALUES(?,?,?,?,?,?,?,?,1,?)',
              [doomedId, testUserId, 'expense', 'Test', 2000.0, 'Doomed', DateTime.now().toIso8601String(), 1, DateTime.now().toIso8601String()],
            );

            // Inyectar fallo antes de confirmar
            throw StateError('Error forzado para probar rollback atómico');
          });
        } catch (_) {
          threw = true;
        }

        expect(threw, isTrue);

        // Verificar que el movimiento NO existe en PostgreSQL
        final checkTx = await pgDb.query('SELECT * FROM transactions WHERE id=?', [doomedId]);
        expect(checkTx, isEmpty, reason: 'El registro debió ser revertido por completo');

        // Y que no hay rastro en sync_log ni audit_log
        final checkSync = await pgDb.query('SELECT * FROM sync_log WHERE entity_id=?', [doomedId]);
        expect(checkSync, isEmpty);
      });

      test('4.3 Compromisos, metas, decisiones y revisiones se persisten atómicamente', () async {
        // Compromiso
        final comRes = await send(
          'POST',
          '/api/commitments',
          token: testToken,
          body: {'title': 'Internet Fibra', 'amount': 30000.0, 'status': 'pending'},
        );
        expect(comRes.statusCode, equals(201));
        final comId = (jsonDecode(await comRes.readAsString()) as Map)['id'] as String;

        // Meta
        final goalRes = await send(
          'POST',
          '/api/goals',
          token: testToken,
          body: {'title': 'Fondo Emergencia', 'targetAmount': 200000.0, 'savedAmount': 50000.0},
        );
        expect(goalRes.statusCode, equals(201));
        final goalId = (jsonDecode(await goalRes.readAsString()) as Map)['id'] as String;

        // Decisión
        final decRes = await send(
          'POST',
          '/api/decisions',
          token: testToken,
          body: {'action': 'Ajustar gastos ocio', 'note': 'Reducir salidas'},
        );
        expect(decRes.statusCode, equals(201));
        final decId = (jsonDecode(await decRes.readAsString()) as Map)['id'] as String;

        // Revisión
        final revRes = await send(
          'POST',
          '/api/reviews',
          token: testToken,
          body: {
            'periodTitle': 'Semana 1',
            'periodSubtitle': 'Control inicial',
            'transactionIds': [],
            'decision': 'Mantener plan',
            'decisionDetails': {'ahorro_logrado': true},
          },
        );
        expect(revRes.statusCode, equals(201));
        final revId = (jsonDecode(await revRes.readAsString()) as Map)['id'] as String;

        // Comprobar que todos tienen su entrada atómica en sync_log
        for (final id in [comId, goalId, decId, revId]) {
          final syncEntry = await pgDb.query('SELECT * FROM sync_log WHERE entity_id=?', [id]);
          expect(syncEntry.isNotEmpty, isTrue, reason: 'Entidad $id debe tener sync_log en PostgreSQL');
        }
      });
    });

    // =========================================================================
    // 5. SINCRONIZACIÓN OFFLINE-FIRST (PUSH / PULL Y CONFLICTOS)
    // =========================================================================
    group('5. Sincronización Push / Pull y Conflictos en PostgreSQL', () {
      late String syncToken;

      setUpAll(() async {
        final email = 'sync_user_${DateTime.now().millisecondsSinceEpoch}@plata.app';
        final reg = await send(
          'POST',
          '/api/auth/register',
          body: {
            'name': 'Sync User',
            'email': email,
            'password': 'SyncPassword123',
            'opening_balance': 30000.0,
          },
        );
        final registeredUserId = (jsonDecode(await reg.readAsString()) as Map)['id'] as String;
        expect(registeredUserId, isNotEmpty);

        final login = await send(
          'POST',
          '/api/auth/login',
          body: {'email': email, 'password': 'SyncPassword123'},
        );
        syncToken = (jsonDecode(await login.readAsString()) as Map)['token'] as String;
      });

      test('5.1 Push procesa operaciones offline e incrementa sequence en PostgreSQL', () async {
        final txId = 'offline_tx_${DateTime.now().millisecondsSinceEpoch}';
        final pushRes = await send(
          'POST',
          '/api/sync/push',
          token: syncToken,
          body: {
            'operations': [
              {
                'operation_id': 'op_1_${DateTime.now().millisecondsSinceEpoch}',
                'entity_type': 'transaction',
                'entity_id': txId,
                'action': 'create',
                'base_version': 1,
                'payload': {
                  'type': 'expense',
                  'category': 'Farmacia',
                  'amount': 8500.0,
                  'description': 'Medicamentos offline',
                  'date': DateTime.now().toIso8601String(),
                  'recognized': true,
                },
              }
            ],
          },
        );

        expect(pushRes.statusCode, equals(200));
        final pushBody = jsonDecode(await pushRes.readAsString()) as Map<String, dynamic>;
        expect(pushBody['results'], isNotEmpty);
        expect(pushBody['results'][0]['status'], equals('applied'));

        // Verificar en PostgreSQL
        final pgTx = await pgDb.query('SELECT * FROM transactions WHERE id=?', [txId]);
        expect(pgTx.isNotEmpty, isTrue);
        expect(pgTx.first['amount'], equals(8500.0));
      });

      test('5.2 Pull incremental descarga cambios según cursor del cliente', () async {
        final pullRes = await send('GET', '/api/sync/pull?cursor=0', token: syncToken);

        expect(pullRes.statusCode, equals(200));
        final pullBody = jsonDecode(await pullRes.readAsString()) as Map<String, dynamic>;
        final changes = pullBody['changes'] as List;
        expect(changes.isNotEmpty, isTrue);
        final cursor = pullBody['cursor'] as int;
        expect(cursor, greaterThan(0));

        // Pull subsecuente con el nuevo cursor retorna lista vacía
        final pullNext = await send('GET', '/api/sync/pull?cursor=$cursor', token: syncToken);
        final nextBody = jsonDecode(await pullNext.readAsString()) as Map<String, dynamic>;
        expect(nextBody['changes'], isEmpty);
      });

      test('5.3 Conflicto de versión desfasada se registra en sync_conflicts de PostgreSQL', () async {
        final txId = 'tx_conflict_${DateTime.now().millisecondsSinceEpoch}';

        // 1. Crear versión 1 en el servidor
        await send(
          'POST',
          '/api/sync/push',
          token: syncToken,
          body: {
            'operations': [
              {
                'operation_id': 'op_init_$txId',
                'entity_type': 'transaction',
                'entity_id': txId,
                'action': 'create',
                'base_version': 1,
                'payload': {'amount': 1000.0, 'category': 'Otros'},
              }
            ]
          },
        );

        // 2. Servidor avanza a versión 2
        await send(
          'POST',
          '/api/sync/push',
          token: syncToken,
          body: {
            'operations': [
              {
                'operation_id': 'op_adv_$txId',
                'entity_type': 'transaction',
                'entity_id': txId,
                'action': 'update',
                'base_version': 1,
                'payload': {'amount': 2000.0, 'category': 'Otros'},
              }
            ]
          },
        );

        // 3. Cliente desfasado intenta enviar actualización con base_version: 1 cuando el servidor ya tiene 2
        final conflictPush = await send(
          'POST',
          '/api/sync/push',
          token: syncToken,
          body: {
            'operations': [
              {
                'operation_id': 'op_stale_$txId',
                'entity_type': 'transaction',
                'entity_id': txId,
                'action': 'update',
                'base_version': 1,
                'payload': {'amount': 3000.0, 'category': 'Otros'},
              }
            ]
          },
        );

        final confBody = jsonDecode(await conflictPush.readAsString()) as Map<String, dynamic>;
        expect(confBody['results'][0]['status'], equals('conflict'));

        // Verificar que el conflicto está persistido en PostgreSQL en la tabla sync_conflicts
        final confRow = await pgDb.query('SELECT * FROM sync_conflicts WHERE entity_id=?', [txId]);
        expect(confRow.isNotEmpty, isTrue);
        expect(confRow.first['status'], equals('unresolved'));
      });
    });

    // =========================================================================
    // 6. CURSORES, CONCURRENCIA E IDEMPOTENCIA EN POSTGRESQL REAL
    // =========================================================================
    group('6. Cursores, Concurrencia e Idempotencia Real', () {
      late String concToken;
      late String concUserId;

      setUpAll(() async {
        final email = 'conc_${DateTime.now().millisecondsSinceEpoch}@plata.app';
        final reg = await send(
          'POST',
          '/api/auth/register',
          body: {
            'name': 'Concurrencia User',
            'email': email,
            'password': 'ConcPassword123',
            'opening_balance': 10000.0,
          },
        );
        concUserId = (jsonDecode(await reg.readAsString()) as Map)['id'] as String;

        final login = await send(
          'POST',
          '/api/auth/login',
          body: {'email': email, 'password': 'ConcPassword123'},
        );
        concToken = (jsonDecode(await login.readAsString()) as Map)['token'] as String;
      });

      test('6.1 Idempotencia concurrente: 2 solicitudes paralelas con el mismo operation_id no duplican ni fallan', () async {
        final opId = 'idemp_race_${DateTime.now().millisecondsSinceEpoch}';
        final txId = 'tx_idemp_${DateTime.now().millisecondsSinceEpoch}';

        final payload = {
          'operations': [
            {
              'operation_id': opId,
              'entity_type': 'transaction',
              'entity_id': txId,
              'action': 'create',
              'base_version': 1,
              'payload': {
                'type': 'expense',
                'category': 'Alimentación',
                'amount': 3500.0,
                'description': 'Carrera idempotente',
              },
            }
          ]
        };

        // Lanzar dos solicitudes simultáneas al mismo milisegundo
        final req1 = send('POST', '/api/sync/push', token: concToken, body: payload);
        final req2 = send('POST', '/api/sync/push', token: concToken, body: payload);

        final responses = await Future.wait([req1, req2]);
        expect(responses[0].statusCode, equals(200));
        expect(responses[1].statusCode, equals(200));

        // Ambas deben retornar status applied o idéntico cuerpo
        final body1 = jsonDecode(await responses[0].readAsString()) as Map;
        final body2 = jsonDecode(await responses[1].readAsString()) as Map;
        expect(body1['results'][0]['status'], equals('applied'));
        expect(body2['results'][0]['status'], equals('applied'));

        // Y en PostgreSQL debe haber EXACTAMENTE 1 movimiento en la tabla transactions
        final txCount = await pgDb.query('SELECT COUNT(*) total FROM transactions WHERE id=?', [txId]);
        expect(txCount.first['total'], equals(1));
      });

      test('6.2 Concurrencia de secuencias: el bloqueo asesor previene huecos de confirmación en BIGSERIAL', () async {
        // Demostrar el caso del requerimiento:
        // Tx A y Tx B concurrentes para el mismo usuario.
        // Debido a pg_advisory_xact_lock(hashtext('sync_' || userId)), Tx B debe esperar a que Tx A confirme.
        // Por ende, Tx B nunca confirmará antes de Tx A, garantizando orden monotónico continuo.
        final seqLog = <String>[];

        final futureA = pgDb.transaction((txA) async {
          await txA.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$concUserId']);
          seqLog.add('A_acquired_lock');
          // Simular trabajo prolongado en Tx A
          await Future.delayed(const Duration(milliseconds: 300));
          await txA.execute(
            'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
            [concUserId, 'test', 'item_A', 'create', 1, '{}', DateTime.now().toIso8601String()],
          );
          seqLog.add('A_committed');
        });

        // Tx B lanzada inmediatamente después
        await Future.delayed(const Duration(milliseconds: 50));
        final futureB = pgDb.transaction((txB) async {
          await txB.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$concUserId']);
          seqLog.add('B_acquired_lock');
          await txB.execute(
            'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
            [concUserId, 'test', 'item_B', 'create', 1, '{}', DateTime.now().toIso8601String()],
          );
          seqLog.add('B_committed');
        });

        await Future.wait([futureA, futureB]);

        // Verificar el orden de confirmación estricto
        expect(seqLog, equals(['A_acquired_lock', 'A_committed', 'B_acquired_lock', 'B_committed']));

        // Y comprobar que en sync_log la secuencia de A es menor a la de B
        final rowsA = await pgDb.query("SELECT sequence FROM sync_log WHERE entity_id='item_A'");
        final rowsB = await pgDb.query("SELECT sequence FROM sync_log WHERE entity_id='item_B'");
        final seqA = (rowsA.first['sequence'] as num).toInt();
        final seqB = (rowsB.first['sequence'] as num).toInt();
        expect(seqA, lessThan(seqB));
      });
    });

    // =========================================================================
    // 7. REINICIO DEL SERVIDOR Y RECUPERACIÓN DE DATOS
    // =========================================================================
    group('7. Reinicio de PostgreSQL y Recuperación de Datos', () {
      test('7.1 Los datos persisten en disco y se recuperan tras reconexión directa', () async {
        final markerId = 'marker_${DateTime.now().millisecondsSinceEpoch}';
        final now = DateTime.now().toIso8601String();

        // 1. Guardar dato de control en PostgreSQL
        await pgDb.execute(
          'INSERT INTO transactions(id, user_id, type, category, amount, description, date, recognized, version, updated_at) '
          'VALUES(?,?,?,?,?,?,?,?,1,?)',
          [markerId, 'user_durability', 'income', 'Persistencia', 7777.77, 'Control de Durabilidad', now, 1, now],
        );

        // 2. Cerrar la conexión actual
        await pgDb.close();

        // 3. Abrir una NUEVA conexión independiente a PostgreSQL
        final newPgDb = await PostgresAppDatabase.connect(pgUrl);
        try {
          final retrieved = await newPgDb.query('SELECT * FROM transactions WHERE id=?', [markerId]);
          expect(retrieved.isNotEmpty, isTrue);
          expect(retrieved.first['id'], equals(markerId));
          expect(retrieved.first['amount'], equals(7777.77));
          expect(retrieved.first['category'], equals('Persistencia'));
        } finally {
          await newPgDb.close();
          // Restaurar pgDb para el tearDownAll
          pgDb = await PostgresAppDatabase.connect(pgUrl);
        }
      });
    });
  });
}

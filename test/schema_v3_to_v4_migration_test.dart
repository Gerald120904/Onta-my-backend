import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import '../lib/src/api.dart';
import '../lib/src/database.dart';

void main() {
  group('1. MIGRACIÓN SCHEMA V3 A V4 EN SQLITE (Simulación Base Preexistente)', () {
    late Directory tempDir;
    late String dbPath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('plata_mig_v3_to_v4_');
      dbPath = '${tempDir.path}/legacy_v3.db';
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test('Migra base con únicamente versiones 001, 002 y 003 a 004 sin pérdida de datos', () async {
      // 1. Crear manualmente una base de datos con únicamente migraciones 001, 002 y 003
      final rawDb = sqlite.sqlite3.open(dbPath);
      rawDb.execute('''
        CREATE TABLE schema_migrations (
          version INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          applied_at TEXT NOT NULL
        );
        INSERT INTO schema_migrations VALUES (1, '001_initial_schema', '2026-01-01T00:00:00Z');
        INSERT INTO schema_migrations VALUES (2, '002_sync_log_and_indexes', '2026-01-01T00:00:00Z');
        INSERT INTO schema_migrations VALUES (3, '003_session_expiration_and_security', '2026-01-01T00:00:00Z');

        CREATE TABLE users (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          email TEXT UNIQUE NOT NULL,
          password_hash TEXT NOT NULL,
          opening_balance NUMERIC(18,2) NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT,
          version INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE sessions (
          token TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          created_at TEXT NOT NULL,
          expires_at TEXT NOT NULL DEFAULT '9999-12-31T23:59:59.999Z'
        );

        CREATE TABLE transactions (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          type TEXT NOT NULL,
          category TEXT NOT NULL,
          amount NUMERIC(18,2) NOT NULL,
          description TEXT NOT NULL,
          date TEXT NOT NULL,
          recognized INTEGER NOT NULL DEFAULT 1,
          version INTEGER NOT NULL DEFAULT 1,
          updated_at TEXT,
          deleted_at TEXT
        );

        CREATE TABLE commitments (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          title TEXT NOT NULL,
          amount NUMERIC(18,2) NOT NULL,
          due_date TEXT NOT NULL,
          status TEXT NOT NULL,
          version INTEGER NOT NULL DEFAULT 1,
          updated_at TEXT,
          deleted_at TEXT
        );

        CREATE TABLE goals (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          title TEXT NOT NULL,
          target_amount NUMERIC(18,2) NOT NULL,
          saved_amount NUMERIC(18,2) NOT NULL,
          version INTEGER NOT NULL DEFAULT 1,
          updated_at TEXT,
          deleted_at TEXT
        );

        CREATE TABLE decisions (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          action TEXT NOT NULL,
          note TEXT NOT NULL,
          created_at TEXT NOT NULL,
          version INTEGER NOT NULL DEFAULT 1,
          updated_at TEXT,
          deleted_at TEXT
        );

        CREATE TABLE reviews (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          start_date TEXT NOT NULL,
          end_date TEXT NOT NULL,
          period_title TEXT NOT NULL,
          period_subtitle TEXT NOT NULL,
          transaction_ids TEXT NOT NULL,
          decision TEXT NOT NULL,
          decision_details TEXT NOT NULL,
          created_at TEXT NOT NULL,
          version INTEGER NOT NULL DEFAULT 1,
          updated_at TEXT,
          deleted_at TEXT
        );
      ''');

      // 2. Insertar datos legacy preexistentes de usuarios reales sin accounts ni account_id
      const userId1 = 'u_legacy_001';
      const userId2 = 'u_legacy_002';

      rawDb.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        [userId1, 'Carlos Monge', 'carlos@plata.cr', 'hash123', 143300.0, '2026-01-10T10:00:00Z'],
      );
      rawDb.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        [userId2, 'María Mora', 'maria@plata.cr', 'hash456', 250000.0, '2026-01-12T10:00:00Z'],
      );

      rawDb.execute(
        'INSERT INTO sessions(token, user_id, created_at) VALUES (?, ?, ?)',
        ['tok_carlos', userId1, '2026-01-10T10:05:00Z'],
      );

      // Movimientos de Carlos (Sin account_id en tabla)
      rawDb.execute(
        'INSERT INTO transactions(id, user_id, type, category, amount, description, date) VALUES (?, ?, ?, ?, ?, ?, ?)',
        ['tx_1', userId1, 'income', 'Salario', 500000.0, 'Pago quincenal', '2026-01-15T08:00:00Z'],
      );
      rawDb.execute(
        'INSERT INTO transactions(id, user_id, type, category, amount, description, date) VALUES (?, ?, ?, ?, ?, ?, ?)',
        ['tx_2', userId1, 'expense', 'Supermercado', 75000.0, 'Compras quincena', '2026-01-16T12:00:00Z'],
      );

      // Compromisos y metas
      rawDb.execute(
        'INSERT INTO commitments(id, user_id, title, amount, due_date, status) VALUES (?, ?, ?, ?, ?, ?)',
        ['comm_1', userId1, 'Alquiler', 200000.0, '2026-01-30T00:00:00Z', 'pending'],
      );
      rawDb.execute(
        'INSERT INTO goals(id, user_id, title, target_amount, saved_amount) VALUES (?, ?, ?, ?, ?)',
        ['goal_1', userId1, 'Ahorro Navideño', 300000.0, 50000.0],
      );

      rawDb.dispose();

      // 3. Abrir la base con AppDatabase.open() que ejecuta las migraciones pendientes
      final appDb = AppDatabase.open(customPath: dbPath);

      // 4. Verificar que la versión 4 se registró en schema_migrations
      final migRows = appDb.db.select('SELECT version, name FROM schema_migrations ORDER BY version ASC');
      final versions = migRows.map((r) => r['version'] as int).toList();
      expect(versions, containsAll([1, 2, 3, 4]), reason: 'Debe contener las 4 migraciones registradas');

      // 5. Verificar que la tabla accounts existe y contiene todas las columnas esperadas
      final accTableInfo = appDb.db.select('PRAGMA table_info(accounts)');
      final columnNames = accTableInfo.map((r) => (r['name'] as String).toLowerCase()).toSet();
      expect(columnNames, contains('id'));
      expect(columnNames, contains('user_id'));
      expect(columnNames, contains('name'));
      expect(columnNames, contains('currency'));
      expect(columnNames, contains('initial_balance'));
      expect(columnNames, contains('opening_balance'));
      expect(columnNames, contains('color'));
      expect(columnNames, contains('icon'));
      expect(columnNames, contains('is_default'));
      expect(columnNames, contains('is_archived'));
      expect(columnNames, contains('version'));

      // 6. Verificar backfill automático para Carlos y María
      final accountsCarlos = appDb.db.select('SELECT * FROM accounts WHERE user_id=?', [userId1]);
      expect(accountsCarlos, hasLength(1));
      final accC = accountsCarlos.first;
      expect(accC['id'], 'acc_default_$userId1');
      expect(accC['currency'], 'CRC');
      expect(accC['name'], 'Cuenta Principal');
      expect(accC['initial_balance'], 143300.0);
      expect(accC['opening_balance'], 143300.0);
      expect(accC['is_default'], 1);
      expect(accC['is_archived'], 0);
      expect(accC['color'], '#10B981');
      expect(accC['icon'], 'wallet');

      // 7. Verificar que los movimientos existentes fueron vinculados a la cuenta sin pérdida de datos
      final txCarlos = appDb.db.select('SELECT id, amount, account_id FROM transactions WHERE user_id=?', [userId1]);
      expect(txCarlos, hasLength(2));
      for (final tx in txCarlos) {
        expect(tx['account_id'], 'acc_default_$userId1', reason: 'Movimiento histórico debe vincularse a la cuenta creada');
      }

      final commCarlos = appDb.db.select('SELECT id, account_id FROM commitments WHERE user_id=?', [userId1]);
      expect(commCarlos.first['account_id'], 'acc_default_$userId1');

      final goalCarlos = appDb.db.select('SELECT id, account_id FROM goals WHERE user_id=?', [userId1]);
      expect(goalCarlos.first['account_id'], 'acc_default_$userId1');

      // 8. Verificar inmutabilidad de divisa a nivel de base de datos (Trigger SQLite)
      expect(
        () => appDb.db.execute("UPDATE accounts SET currency='USD' WHERE id='acc_default_$userId1'"),
        throwsA(isA<Exception>()),
        reason: 'El trigger de base de datos DEBE abortar cualquier UPDATE directo que intente cambiar la moneda',
      );

      // Modificar otros campos sí está permitido
      expect(
        () => appDb.db.execute("UPDATE accounts SET name='Cuenta Ahorro CRC' WHERE id='acc_default_$userId1'"),
        returnsNormally,
      );
      final updatedName = appDb.db.select('SELECT name FROM accounts WHERE id=?', ['acc_default_$userId1']).first['name'];
      expect(updatedName, 'Cuenta Ahorro CRC');

      // 9. Simulación de reinicio del servidor: cerrar y volver a abrir la base de datos
      await appDb.close();

      final restartedDb = AppDatabase.open(customPath: dbPath);
      final api = Api(restartedDb);

      // Consultar endpoint de cuentas con la sesión existente
      final accReq = Request('GET', Uri.parse('http://localhost/api/accounts'), headers: {
        'authorization': 'Bearer tok_carlos',
      });
      final accRes = await api.router.call(accReq);
      expect(accRes.statusCode, 200);

      final accountsJson = jsonDecode(await accRes.readAsString()) as List;
      expect(accountsJson, hasLength(1));
      final accJson = accountsJson.first;
      expect(accJson['currency'], 'CRC');
      expect(accJson['initial_balance'], 143300.0);
      // Saldo actual = 143300 + 500000 - 75000 = 568300
      expect(accJson['current_balance'], 568300.0);

      // Consultar dashboard de Carlos
      final dashReq = Request('GET', Uri.parse('http://localhost/api/dashboard'), headers: {
        'authorization': 'Bearer tok_carlos',
      });
      final dashRes = await api.router.call(dashReq);
      expect(dashRes.statusCode, 200);
      final dashJson = jsonDecode(await dashRes.readAsString());
      expect(dashJson['currency'], 'CRC');
      expect(dashJson['balance'], 568300.0);
      expect(dashJson['income'], 500000.0);
      expect(dashJson['expenses'], 75000.0);
      expect(dashJson['committed'], 200000.0);
      expect(dashJson['saved'], 50000.0);
      // Disponible real = 568300 - 200000 - 50000 = 318300
      expect(dashJson['available'], 318300.0);

      await restartedDb.close();
    });
  });

  group('2. MIGRACIÓN SCHEMA V3 A V4 EN POSTGRESQL REAL (Port 5433)', () {
    const pgUrl = 'postgresql://postgres@127.0.0.1:5433/onta_test?sslmode=disable';

    test('Ejecuta migración 004, crea trigger PostgreSQL y valida inmutabilidad y columnas', () async {
      bool isAvailable = false;
      try {
        final s = await Socket.connect('127.0.0.1', 5433, timeout: const Duration(milliseconds: 300));
        s.destroy();
        isAvailable = true;
      } catch (_) {
        isAvailable = false;
      }

      if (!isAvailable) {
        // En ausencia de PostgreSQL local en puerto 5433, se omite de forma segura
        return;
      }

      final pgDb = await PostgresAppDatabase.connect(pgUrl);

      try {
        // 1. Validar que la migración 004 está registrada en schema_migrations de PostgreSQL
        final migs = await pgDb.query(
          'SELECT version, name FROM schema_migrations WHERE version=4',
        );
        expect(migs, isNotEmpty, reason: 'Migración 4 debe estar registrada en schema_migrations');
        expect(migs.first['name'], '004_multi_currency_accounts');

        // 2. Verificar que la tabla accounts existe en PostgreSQL con las columnas requeridas
        final cols = await pgDb.query('''
          SELECT column_name, data_type 
          FROM information_schema.columns 
          WHERE table_schema='public' AND table_name='accounts'
        ''');
        final pgColNames = cols.map((c) => (c['column_name'] as String).toLowerCase()).toSet();
        expect(pgColNames, contains('id'));
        expect(pgColNames, contains('user_id'));
        expect(pgColNames, contains('name'));
        expect(pgColNames, contains('currency'));
        expect(pgColNames, contains('initial_balance'));
        expect(pgColNames, contains('opening_balance'));
        expect(pgColNames, contains('color'));
        expect(pgColNames, contains('icon'));
        expect(pgColNames, contains('is_default'));
        expect(pgColNames, contains('is_archived'));

        // 3. Crear usuario y cuenta sintética en PostgreSQL
        final synthUserId = 'pg_user_${DateTime.now().millisecondsSinceEpoch}';
        final synthAccId = 'pg_acc_${DateTime.now().millisecondsSinceEpoch}';
        final now = DateTime.now().toIso8601String();

        await pgDb.execute(
          'INSERT INTO users (id, name, email, password_hash, opening_balance, created_at) VALUES (?, ?, ?, ?, ?, ?)',
          [synthUserId, 'Usuario PG Test', 'pg_${DateTime.now().millisecondsSinceEpoch}@test.cr', 'hash_pw', 50000.0, now],
        );

        await pgDb.execute(
          'INSERT INTO accounts (id, user_id, name, currency, initial_balance, opening_balance, color, icon, is_default, is_archived, version, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 0, 1, ?, ?)',
          [synthAccId, synthUserId, 'Cuenta Demo CRC', 'CRC', 50000.0, 50000.0, '#10B981', 'wallet', now, now],
        );

        // 4. Verificar que el trigger trg_account_currency_immutable rechaza UPDATE de currency
        bool updateBlocked = false;
        try {
          await pgDb.execute(
            "UPDATE accounts SET currency='USD' WHERE id=?",
            [synthAccId],
          );
        } catch (e) {
          updateBlocked = true;
          expect(e.toString().toLowerCase(), contains('immutable'));
        }
        expect(updateBlocked, isTrue, reason: 'El trigger de PostgreSQL DEBE bloquear el cambio de moneda');

        // 5. Verificar que actualizar nombre u otros atributos sí funciona
        await pgDb.execute(
          "UPDATE accounts SET name='Cuenta Ahorro Costa Rica' WHERE id=?",
          [synthAccId],
        );
        final checkRow = await pgDb.query('SELECT name, currency FROM accounts WHERE id=?', [synthAccId]);
        expect(checkRow.first['name'], 'Cuenta Ahorro Costa Rica');
        expect(checkRow.first['currency'], 'CRC');

        // Limpieza de datos sintéticos
        await pgDb.execute('DELETE FROM accounts WHERE id=?', [synthAccId]);
        await pgDb.execute('DELETE FROM users WHERE id=?', [synthUserId]);
      } finally {
        await pgDb.close();
      }
    });
  });
}

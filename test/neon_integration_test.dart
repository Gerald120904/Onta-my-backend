import 'dart:io';
import 'package:test/test.dart';

import '../lib/src/database.dart';

/// Prueba de integración real contra Neon PostgreSQL (proyecto onta-my-money-test).
/// Se conecta mediante TLS obligatorio, ejecuta migraciones 001, 002 y 003,
/// valida el esquema NUMERIC(18,2), realiza CRUD sintético y garantiza
/// la limpieza total en bloque try/finally sin tocar datos financieros reales.
void main() {
  final neonUrl = Platform.environment['NEON_DATABASE_URL'] ?? Platform.environment['DATABASE_URL'];

  String maskUrl(String? raw) {
    if (raw == null) return '(no configurada)';
    try {
      final uri = Uri.parse(raw);
      final host = uri.host.isNotEmpty ? uri.host : '***';
      final port = uri.hasPort ? ':${uri.port}' : '';
      final path = uri.path;
      final ssl = uri.queryParameters['sslmode'] != null ? '?sslmode=${uri.queryParameters['sslmode']}' : '';
      return 'postgresql://***:***@$host$port$path$ssl';
    } catch (_) {
      return 'postgresql://***:***@masked-endpoint/neondb';
    }
  }

  group('PRUEBA DE INTEGRACIÓN NEON POSTGRESQL (onta-my-money-test)', () {
    test('Conexión real TLS, migraciones, precisión NUMERIC(18,2), CRUD sintético y limpieza garantizada', () async {
      // 1. Falla expresamente si no existe NEON_DATABASE_URL
      if (neonUrl == null || neonUrl.trim().isEmpty) {
        fail(
          'Falta configurar la variable de entorno NEON_DATABASE_URL.\n'
          'La prueba requiere la conexión real a Neon para validar el proyecto onta-my-money-test.\n'
          'Configura en tu terminal:\n'
          '  \$env:NEON_DATABASE_URL="postgresql://[user]:[password]@[endpoint].neon.tech/neondb?sslmode=require"\n'
          '  dart test test/neon_integration_test.dart',
        );
      }

      if (!AppDatabase.isValidPostgresUrl(neonUrl)) {
        fail(
          'La variable NEON_DATABASE_URL no contiene una URL de PostgreSQL válida: "$neonUrl"',
        );
      }

      // 2. Verificar que exija TLS (prohibido sslmode=disable)
      final uri = Uri.parse(neonUrl);
      final sslParam = uri.queryParameters['sslmode']?.toLowerCase();
      expect(
        sslParam != 'disable',
        isTrue,
        reason: 'Neon exige conexión TLS (sslmode=require). No se permite sslmode=disable en producción.',
      );

      // 3. Salvaguarda de aislamiento: rechazar cualquier conexión accidental al proyecto 'geocampo'
      final host = uri.host.toLowerCase();
      expect(
        host.contains('geocampo'),
        isFalse,
        reason: 'SEGURIDAD: Prohibido conectar al proyecto geocampo. Debe utilizarse exclusivamente onta-my-money-test.',
      );

      print('Iniciando prueba de integración con Neon: ${maskUrl(neonUrl)}');

      PostgresAppDatabase? pgDb;
      String? testUserId;

      try {
        // 3. Conexión en modo producción (aplica migraciones y TLS obligatorio)
        pgDb = await PostgresAppDatabase.connect(neonUrl, isProduction: true);
        expect(pgDb.isPostgres, isTrue);
        print('✔ Conexión TLS a Neon establecida con éxito.');

        // 4. Verificar migraciones aplicadas
        final migs = await pgDb.query('SELECT version, name FROM schema_migrations ORDER BY version ASC');
        final versions = migs.map((m) => (m['version'] as num).toInt()).toList();
        expect(versions, containsAll([1, 2, 3]), reason: 'Deben estar aplicadas las migraciones 001, 002 y 003 en Neon');
        print('✔ Migraciones 001, 002 y 003 verificadas en Neon: $versions');

        // 5. Verificar que todas las tablas del esquema existan
        final tables = await pgDb.query('''
          SELECT table_name FROM information_schema.tables 
          WHERE table_schema = 'public'
        ''');
        final tableNames = tables.map((t) => t['table_name'] as String).toSet();
        final expectedTables = [
          'users',
          'sessions',
          'transactions',
          'commitments',
          'goals',
          'decisions',
          'reviews',
          'idempotency_keys',
          'sync_log',
          'audit_log',
          'sync_conflicts',
          'schema_migrations',
        ];
        for (final t in expectedTables) {
          expect(tableNames.contains(t), isTrue, reason: 'Tabla $t debe existir en Neon');
        }
        print('✔ Las 12 tablas del Backend existen en Neon.');

        // 6. Verificar tipos exactos NUMERIC(18,2) en Neon
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
              reason: 'Columna ${col['table_name']}.${col['column_name']} debe ser NUMERIC en Neon');
          expect(col['numeric_precision'], equals(18));
          expect(col['numeric_scale'], equals(2));
        }
        print('✔ Columnas financieras en Neon son NUMERIC(18,2) exactas.');

        // 7. Crear usuario sintético aislado
        testUserId = 'synthetic_neon_${DateTime.now().millisecondsSinceEpoch}';
        final testEmail = 'synthetic_${DateTime.now().millisecondsSinceEpoch}@neon.test';
        final now = DateTime.now().toIso8601String();
        final hash = pgDb.hashPassword('NeonSecretTestPass2026!');

        await pgDb.execute(
          'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at, version) '
          'VALUES(?,?,?,?,?, ?, 1)',
          [testUserId, 'Usuario Sintético Neon', testEmail, hash, 150000.50, now],
        );

        // 8. Crear y verificar movimiento sintético con decimales exactos
        final testTxId = 'synthetic_tx_${DateTime.now().millisecondsSinceEpoch}';
        await pgDb.execute(
          'INSERT INTO transactions(id, user_id, type, category, amount, description, date, recognized, version, updated_at) '
          'VALUES(?,?,?,?,?,?,?,?,1,?)',
          [testTxId, testUserId, 'expense', 'Prueba Neon', 18450.75, 'Movimiento sintético de prueba', now, 1, now],
        );

        final txRows = await pgDb.query('SELECT amount, description FROM transactions WHERE id=?', [testTxId]);
        expect(txRows.isNotEmpty, isTrue);
        expect(txRows.first['amount'], equals(18450.75));

        // 9. Actualización y verificación de precisión
        await pgDb.execute(
          'UPDATE transactions SET amount=?, version=2, updated_at=? WHERE id=?',
          [24999.99, now, testTxId],
        );
        final txUpdated = await pgDb.query('SELECT amount FROM transactions WHERE id=?', [testTxId]);
        expect(txUpdated.first['amount'], equals(24999.99));

        print('✔ Inserción, consulta, actualización y precisión decimal validadas en Neon.');
      } finally {
        // Garantizar limpieza de usuario y movimientos sintéticos incluso ante excepciones
        if (pgDb != null && testUserId != null) {
          try {
            await pgDb.execute('DELETE FROM transactions WHERE user_id=?', [testUserId]);
            await pgDb.execute('DELETE FROM sync_log WHERE user_id=?', [testUserId]);
            await pgDb.execute('DELETE FROM audit_log WHERE user_id=?', [testUserId]);
            await pgDb.execute('DELETE FROM users WHERE id=?', [testUserId]);
            print('✔ Limpieza garantizada de entidades sintéticas en Neon completada (0 residuos).');
          } catch (e) {
            print('Advertencia en limpieza: $e');
          }
        }
        await pgDb?.close();
      }
    });
  });
}

import 'dart:io';
import 'package:test/test.dart';

import '../lib/src/database.dart';

/// Prueba de integración contra Neon PostgreSQL (proyecto onta-my-money-test).
/// Se ejecuta cuando la variable de entorno NEON_DATABASE_URL o DATABASE_URL está definida.
/// Nunca copia credenciales a Git ni migra datos financieros reales.
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
    test('Verificación de conexión segura y ejecución sintética en Neon', () async {
      if (neonUrl == null || neonUrl.trim().isEmpty || !AppDatabase.isValidPostgresUrl(neonUrl)) {
        print('');
        print('========================================================================');
        print(' AVISO: NEON_DATABASE_URL no configurada en el entorno.');
        print(' Para ejecutar contra el cluster remoto de Neon:');
        print('   \$env:NEON_DATABASE_URL="postgresql://user:pass@ep-xxx.neon.tech/neondb?sslmode=require"');
        print('   dart test test/neon_integration_test.dart');
        print('========================================================================');
        print('');
        // No fallar la suite si se ejecuta en CI o local sin credenciales remotas
        return;
      }

      print('Iniciando prueba de integración con Neon: ${maskUrl(neonUrl)}');

      // 1. Validar que exija TLS
      final uri = Uri.parse(neonUrl);
      final sslParam = uri.queryParameters['sslmode']?.toLowerCase();
      expect(
        sslParam != 'disable',
        isTrue,
        reason: 'Neon exige conexión TLS (sslmode=require)',
      );

      // 2. Conectar en modo producción (TLS obligatorio)
      final pgDb = await PostgresAppDatabase.connect(neonUrl, isProduction: true);

      try {
        expect(pgDb.isPostgres, isTrue);

        // 3. Verificar migraciones aplicadas
        final migs = await pgDb.query('SELECT version FROM schema_migrations ORDER BY version ASC');
        final versions = migs.map((m) => (m['version'] as num).toInt()).toList();
        expect(versions, containsAll([1, 2, 3]));
        print('✔ Migraciones 001, 002 y 003 verificadas en Neon.');

        // 4. Verificar tipos exactos NUMERIC(18,2) en Neon
        final cols = await pgDb.query('''
          SELECT column_name, data_type, numeric_precision, numeric_scale
          FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'transactions' AND column_name = 'amount'
        ''');
        expect(cols.isNotEmpty, isTrue);
        expect(cols.first['data_type'], equals('numeric'));
        expect(cols.first['numeric_precision'], equals(18));
        expect(cols.first['numeric_scale'], equals(2));
        print('✔ Esquema verificado en Neon: columna amount es NUMERIC(18,2).');

        // 5. Crear usuario sintético de prueba (nunca datos reales)
        final testEmail = 'synthetic_${DateTime.now().millisecondsSinceEpoch}@neon.test';
        final testUserId = 'neon_user_${DateTime.now().millisecondsSinceEpoch}';
        final now = DateTime.now().toIso8601String();
        final hash = pgDb.hashPassword('NeonTestPassword2026!');

        await pgDb.execute(
          'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at, version) '
          'VALUES(?,?,?,?,?, ?, 1)',
          [testUserId, 'Usuario Sintético Neon', testEmail, hash, 100000.00, now],
        );

        // 6. Registrar movimiento sintético con decimales exactos
        final testTxId = 'neon_tx_${DateTime.now().millisecondsSinceEpoch}';
        await pgDb.execute(
          'INSERT INTO transactions(id, user_id, type, category, amount, description, date, recognized, version, updated_at) '
          'VALUES(?,?,?,?,?,?,?,?,1,?)',
          [testTxId, testUserId, 'income', 'Prueba Neon', 15450.75, 'Ingreso sintético de prueba', now, 1, now],
        );

        // 7. Leer y verificar precisión
        final txRows = await pgDb.query('SELECT amount FROM transactions WHERE id=?', [testTxId]);
        expect(txRows.first['amount'], equals(15450.75));

        // 8. Limpiar datos sintéticos (cero residuos, sin tocar datos reales)
        await pgDb.execute('DELETE FROM transactions WHERE user_id=?', [testUserId]);
        await pgDb.execute('DELETE FROM users WHERE id=?', [testUserId]);
        print('✔ Ciclo sintético completado y limpiado exitosamente en Neon.');
      } finally {
        await pgDb.close();
      }
    });
  });
}

import 'dart:io';

import 'package:postgres/postgres.dart';

import '../lib/src/migrations/migration_runner.dart';

Future<void> main() async {
  final raw = Platform.environment['NEON_DATABASE_URL'];
  if (raw == null || raw.isEmpty) {
    stderr.writeln('NEON_DATABASE_URL faltante. Usá solo una base de prueba aislada.');
    exitCode = 2;
    return;
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || !['postgres', 'postgresql'].contains(uri.scheme) ||
      uri.host.isEmpty || uri.queryParameters['sslmode'] == 'disable') {
    stderr.writeln('NEON_DATABASE_URL inválida o sin TLS obligatorio.');
    exitCode = 2;
    return;
  }
  final userInfo = uri.userInfo.split(':');
  final pool = Pool.withEndpoints([
    Endpoint(
      host: uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: uri.pathSegments.isEmpty ? 'neondb' : uri.pathSegments.first,
      username: Uri.decodeComponent(userInfo.first),
      password: userInfo.length > 1 ? Uri.decodeComponent(userInfo[1]) : '',
    ),
  ], settings: const PoolSettings(maxConnectionCount: 1, sslMode: SslMode.require));
  try {
    await pool.execute(Sql('SELECT 1'));
    final exists = await pool.execute(Sql("SELECT to_regclass('public.schema_migrations')"));
    final applied = <int>{};
    if (exists.first[0] != null) {
      final rows = await pool.execute(Sql('SELECT version FROM schema_migrations ORDER BY version'));
      applied.addAll(rows.map((row) => (row[0] as num).toInt()));
    }
    final expected = MigrationRunner.migrations.map((m) => m.version).toSet();
    final pending = expected.difference(applied).toList()..sort();
    stdout.writeln('Conexión PostgreSQL TLS correcta. Migraciones aplicadas: ${applied.length}.');
    if (pending.isNotEmpty) {
      stdout.writeln('Migraciones pendientes: ${pending.join(', ')}. No se aplicaron cambios.');
    }
  } catch (error) {
    stderr.writeln('No se pudo validar PostgreSQL: ${error.runtimeType}.');
    exitCode = 1;
  } finally {
    await pool.close();
  }
}

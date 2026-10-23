import 'dart:io';
import '../lib/src/database.dart';

Future<void> main(List<String> args) async {
  final databaseUrl = Platform.environment['DATABASE_URL'];
  final dbPath = Platform.environment['DATABASE_PATH'];

  print('========================================================');
  print(' ONTA MY MONEY — PROCEDIMIENTO DE REVOCACIÓN DE SESIONES');
  print('========================================================');

  final AppDatabase db;
  if (databaseUrl != null && databaseUrl.trim().isNotEmpty) {
    print('Conectando a PostgreSQL para revocación segura...');
    db = await AppDatabase.openAsync(databaseUrl: databaseUrl);
  } else {
    print('Abriendo base de datos SQLite local...');
    db = AppDatabase.open(customPath: dbPath);
  }

  try {
    final bool revokeAll = args.contains('--all') || args.isEmpty;
    final cutoffArg = args.firstWhere(
      (a) => a.startsWith('--cutoff='),
      orElse: () => '',
    );

    if (cutoffArg.isNotEmpty) {
      final cutoffStr = cutoffArg.substring('--cutoff='.length);
      final cutoff = DateTime.tryParse(cutoffStr) ?? DateTime.now();
      print('Revocando sesiones heredadas creadas antes de: ${cutoff.toIso8601String()}');
      final count = await db.revokeSessionsCreatedBefore(cutoff);
      print('✓ Se revocaron exitosamente $count sesión(es) heredada(s).');
    } else if (revokeAll) {
      print('Revocando TODAS las sesiones activas...');
      await db.revokeAllSessions();
      print('✓ Todas las sesiones fueron revocadas exitosamente.');
    }

    print('Procedimiento completado de forma segura.');
  } catch (e) {
    print('Error ejecutando revocación de sesiones: $e');
    exit(1);
  } finally {
    await db.close();
  }
}

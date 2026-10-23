import 'dart:io';
import 'package:test/test.dart';
import '../lib/src/database.dart';
import '../lib/src/sync_service.dart';

void main() {
  group('Tarea 1 - Verificación del Backfill de SQLite y SyncLog', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('plata_backfill_test_');
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test('1. Base de datos SQLite completamente nueva: orden migrate -> seed -> sync_log y cursor 0', () {
      final freshDbPath = '${tempDir.path}/fresh_plata.db';

      // 1. Abrir con migrate() y ejecutar seed() tal como lo hace server.dart
      final db = AppDatabase.open(customPath: freshDbPath)..seed();

      // Verificar que el usuario fue creado
      final users = db.db.select('SELECT id, email, opening_balance FROM users WHERE email=?', ['demo@plata.app']);
      expect(users, hasLength(1));
      final userId = users.first['id'] as String;

      // Verificar conteos de tablas de negocio
      final txRows = db.db.select('SELECT * FROM transactions WHERE user_id=?', [userId]);
      final commRows = db.db.select('SELECT * FROM commitments WHERE user_id=?', [userId]);
      final goalRows = db.db.select('SELECT * FROM goals WHERE user_id=?', [userId]);

      expect(txRows, hasLength(5), reason: 'Seed debe crear 5 transacciones');
      expect(commRows, hasLength(1), reason: 'Seed debe crear 1 compromiso');
      expect(goalRows, hasLength(1), reason: 'Seed debe crear 1 meta de ahorro');

      // 2. Verificar que sync_log contiene exactamente los 7 registros del seed
      final syncRows = db.db.select('SELECT * FROM sync_log WHERE user_id=? ORDER BY sequence ASC', [userId]);
      expect(syncRows, hasLength(7), reason: 'sync_log debe contener los 7 registros sembrados');

      // 3. Probar descarga con SyncService.pullChanges desde cursor 0
      final syncService = SyncService(db);
      final pullResult = syncService.pullChanges(userId: userId, cursor: 0);

      expect(pullResult['changes'], hasLength(7));
      expect(pullResult['cursor'], greaterThan(0));

      final changes = pullResult['changes'] as List<Map<String, dynamic>>;
      final txChanges = changes.where((c) => c['entity_type'] == 'transaction').toList();
      final commChanges = changes.where((c) => c['entity_type'] == 'commitment').toList();
      final goalChanges = changes.where((c) => c['entity_type'] == 'goal').toList();

      expect(txChanges, hasLength(5));
      expect(commChanges, hasLength(1));
      expect(goalChanges, hasLength(1));

      // Verificar que los importes y datos coinciden exactamente
      final firstTx = txChanges.first;
      expect(firstTx['payload']['amount'], isIn([4500.0, 2100.0, 8000.0, 5500.0, 3200.0]));

      // 4. Idempotencia: ejecutar seed() y backfillSyncLog() nuevamente
      db.seed();
      db.backfillSyncLog();

      final syncRowsAfterSecondBackfill = db.db.select('SELECT * FROM sync_log WHERE user_id=?', [userId]);
      expect(syncRowsAfterSecondBackfill, hasLength(7), reason: 'Backfill posterior NO debe duplicar registros');

      final txRowsAfterSecondSeed = db.db.select('SELECT * FROM transactions WHERE user_id=?', [userId]);
      expect(txRowsAfterSecondSeed, hasLength(5), reason: 'Seed no debe duplicar transacciones');

      db.close();
    });

    test('2. Base de datos con datos preexistentes sin sync_log: backfill idempotente y no destructivo', () {
      final existingDbPath = '${tempDir.path}/existing_plata.db';

      // Simular base de datos legacy antigua creada antes de existir sync_log
      final rawDb = AppDatabase.open(customPath: existingDbPath);
      // Borrar entradas de sync_log para simular datos legacy sin sincronizar
      rawDb.db.execute('DELETE FROM sync_log');

      // Insertar transacciones, compromisos, metas, decisiones y reviews legacy sin entrada en sync_log
      const legacyUserId = 'legacy-user-123';
      const legacyTxId = 'tx-legacy-999';
      const legacyCommId = 'comm-legacy-888';
      const legacyGoalId = 'goal-legacy-777';
      const legacyDecId = 'dec-legacy-666';
      const legacyRevId = 'rev-legacy-555';

      rawDb.db.execute(
        'INSERT OR REPLACE INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES(?,?,?,?,?,?)',
        [legacyUserId, 'Legacy User', 'legacy@plata.app', 'hash123', 50000.0, '2025-01-01T00:00:00.000Z'],
      );

      rawDb.db.execute(
        'INSERT INTO transactions(id, user_id, type, category, amount, description, date, recognized) VALUES(?,?,?,?,?,?,?,?)',
        [legacyTxId, legacyUserId, 'expense', 'Servicios', 15750.50, 'Luz eléctrica', '2025-01-10T12:00:00.000Z', 1],
      );

      rawDb.db.execute(
        'INSERT INTO commitments(id, user_id, title, amount, due_date, status) VALUES(?,?,?,?,?,?)',
        [legacyCommId, legacyUserId, 'Internet fibra', 25000.0, '2025-01-20T00:00:00.000Z', 'pending'],
      );

      rawDb.db.execute(
        'INSERT INTO goals(id, user_id, title, target_amount, saved_amount) VALUES(?,?,?,?,?)',
        [legacyGoalId, legacyUserId, 'Fondo de emergencia', 200000.0, 45000.0],
      );

      rawDb.db.execute(
        'INSERT INTO decisions(id, user_id, action, note, created_at) VALUES(?,?,?,?,?)',
        [legacyDecId, legacyUserId, 'reduce_dining', 'Reducir salidas a restaurantes', '2025-01-15T00:00:00.000Z'],
      );

      rawDb.db.execute(
        'INSERT INTO reviews(id, user_id, start_date, end_date, period_title, period_subtitle, transaction_ids, decision, decision_details, created_at) VALUES(?,?,?,?,?,?,?,?,?,?)',
        [legacyRevId, legacyUserId, '2025-01-01', '2025-01-31', 'Enero 2025', 'Cierre mensual', '["$legacyTxId"]', 'approved', '{"note":"Aprobado"}', '2025-01-31T23:59:59.000Z'],
      );

      rawDb.close();

      // Ahora reabrimos la base de datos con AppDatabase.open() que ejecuta _migrate() y backfillSyncLog()
      final openedDb = AppDatabase.open(customPath: existingDbPath);

      // Verificar que sync_log fue poblado con todas las entidades legacy
      final syncEntries = openedDb.db.select('SELECT * FROM sync_log WHERE user_id=? ORDER BY sequence ASC', [legacyUserId]);
      expect(syncEntries, hasLength(5), reason: 'Debe haber 5 entradas en sync_log (tx, compromiso, meta, decisión, review)');

      final types = syncEntries.map((e) => e['entity_type'] as String).toList();
      expect(types, containsAll(['transaction', 'commitment', 'goal', 'decision', 'review']));

      // Verificar que los importes y los IDs originales están intactos (no modificados)
      final txCheck = openedDb.db.select('SELECT * FROM transactions WHERE id=?', [legacyTxId]).first;
      expect(txCheck['amount'], equals(15750.50));
      expect(txCheck['description'], equals('Luz eléctrica'));
      expect(txCheck['id'], equals(legacyTxId));

      final commCheck = openedDb.db.select('SELECT * FROM commitments WHERE id=?', [legacyCommId]).first;
      expect(commCheck['amount'], equals(25000.0));
      expect(commCheck['id'], equals(legacyCommId));

      // Verificar descarga con cursor 0
      final syncService = SyncService(openedDb);
      final pull = syncService.pullChanges(userId: legacyUserId, cursor: 0);
      expect(pull['changes'], hasLength(5));

      // Verificar idempotencia: invocar backfillSyncLog() una y otra vez
      openedDb.backfillSyncLog();
      openedDb.backfillSyncLog();

      final syncEntriesAfter = openedDb.db.select('SELECT * FROM sync_log WHERE user_id=?', [legacyUserId]);
      expect(syncEntriesAfter, hasLength(5), reason: 'Llamar múltiples veces a backfillSyncLog() NO debe crear duplicados');

      openedDb.close();
    });
  });
}

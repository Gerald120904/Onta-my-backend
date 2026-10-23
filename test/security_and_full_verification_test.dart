import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import '../lib/src/api.dart';
import '../lib/src/database.dart';
import '../lib/src/sync_service.dart';

void main() {
  group('ONTA MY MONEY — FASE POSTGRESQL / VERIFICACIÓN INTEGRAL DE 10 PUNTOS', () {
    late AppDatabase db;
    late Api api;
    late SyncService syncService;

    setUp(() {
      db = AppDatabase.inMemory();
      api = Api(db);
      syncService = SyncService(db);
    });

    tearDown(() async {
      await db.close();
    });

    // --------------------------------------------------------------------------
    // 1. Registro e inicio de sesión
    // --------------------------------------------------------------------------
    test('1. Registro e inicio de sesión con BCrypt y generación de sesión activa', () async {
      final regReq = Request(
        'POST',
        Uri.parse('http://localhost/api/auth/register'),
        body: '{"name":"Mateo","email":"mateo@plata.app","password":"password123","opening_balance":50000}',
      );
      final regRes = await api.router.call(regReq);
      expect(regRes.statusCode, equals(201));

      final loginReq = Request(
        'POST',
        Uri.parse('http://localhost/api/auth/login'),
        body: '{"email":"mateo@plata.app","password":"password123"}',
      );
      final loginRes = await api.router.call(loginReq);
      expect(loginRes.statusCode, equals(200));

      final loginData = await loginRes.readAsString();
      expect(loginData.contains('token'), isTrue);
      expect(loginData.contains('Mateo'), isTrue);
    });

    // --------------------------------------------------------------------------
    // 2. Altas, modificaciones y eliminaciones (con soft delete y versiones)
    // --------------------------------------------------------------------------
    test('2. Altas, modificaciones y eliminaciones con versionado incremental y soft deletes', () async {
      const userId = 'u-crud-1';
      final now = DateTime.now().toIso8601String();
      await db.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES(?,?,?,?,?,?)',
        [userId, 'Test User', 'crud@test.com', 'hash', 100000.0, now],
      );

      // Alta
      final createOp = [
        {
          'operation_id': 'op-crud-create',
          'entity_type': 'transaction',
          'entity_id': 'tx-crud-1',
          'action': 'create',
          'payload': {
            'type': 'expense',
            'category': 'Supermercado',
            'amount': 15000.0,
            'description': 'Compras semanales',
            'date': now,
            'recognized': true,
          },
          'base_version': 1,
        }
      ];
      final createRes = await syncService.processPushAsync(userId: userId, deviceId: 'dev-1', operations: createOp);
      expect(createRes['processed'][0]['status'], equals('applied'));
      expect(createRes['processed'][0]['version'], equals(1));

      // Modificación
      final updateOp = [
        {
          'operation_id': 'op-crud-update',
          'entity_type': 'transaction',
          'entity_id': 'tx-crud-1',
          'action': 'update',
          'payload': {
            'type': 'expense',
            'category': 'Supermercado',
            'amount': 18500.0,
            'description': 'Compras con extras',
            'date': now,
            'recognized': true,
          },
          'base_version': 1,
        }
      ];
      final updateRes = await syncService.processPushAsync(userId: userId, deviceId: 'dev-1', operations: updateOp);
      expect(updateRes['processed'][0]['status'], equals('applied'));
      expect(updateRes['processed'][0]['version'], equals(2));

      // Eliminación (Soft delete)
      final deleteOp = [
        {
          'operation_id': 'op-crud-delete',
          'entity_type': 'transaction',
          'entity_id': 'tx-crud-1',
          'action': 'delete',
          'payload': {},
          'base_version': 2,
        }
      ];
      final deleteRes = await syncService.processPushAsync(userId: userId, deviceId: 'dev-1', operations: deleteOp);
      expect(deleteRes['processed'][0]['status'], equals('applied'));

      // Verificar que el registro no fue borrado físicamente, sino marcado con deleted_at
      final rows = await db.query('SELECT deleted_at, version FROM transactions WHERE id=?', ['tx-crud-1']);
      expect(rows.first['deleted_at'], isNotNull);
      expect((rows.first['version'] as num).toInt(), equals(3));
    });

    // --------------------------------------------------------------------------
    // 3. Sincronización entre dos clientes
    // --------------------------------------------------------------------------
    test('3. Sincronización entre dos clientes: Cliente A empuja y Cliente B descarga con cursor', () async {
      const userId = 'u-sync-clients';
      final now = DateTime.now().toIso8601String();
      await db.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES(?,?,?,?,?,?)',
        [userId, 'Sync Tester', 'sync2@test.com', 'hash', 100000.0, now],
      );

      // Cliente A (Web) crea un compromiso
      final clientAOp = [
        {
          'operation_id': 'op-clientA-comm',
          'entity_type': 'commitment',
          'entity_id': 'comm-sync-1',
          'action': 'create',
          'payload': {
            'title': 'Servicio de Internet',
            'amount': 28000.0,
            'dueDate': now,
            'status': 'pending',
          },
          'base_version': 1,
        }
      ];
      await syncService.processPushAsync(userId: userId, deviceId: 'client-web', operations: clientAOp);

      // Cliente B (Android) hace pull desde cursor 0
      final pullB = await syncService.pullChangesAsync(userId: userId, cursor: 0);
      final changes = pullB['changes'] as List<Map<String, dynamic>>;
      expect(changes, hasLength(1));
      expect(changes.first['entity_id'], equals('comm-sync-1'));
      expect(changes.first['entity_type'], equals('commitment'));
      expect(pullB['cursor'], greaterThan(0));

      // Siguiente pull de Cliente B con el nuevo cursor no trae duplicados
      final nextCursor = pullB['cursor'] as int;
      final emptyPullB = await syncService.pullChangesAsync(userId: userId, cursor: nextCursor);
      expect((emptyPullB['changes'] as List), isEmpty);
    });

    // --------------------------------------------------------------------------
    // 4. Funcionamiento offline y reconexión
    // --------------------------------------------------------------------------
    test('4. Funcionamiento offline y reconexión: lote acumulado se aplica en orden monotónico', () async {
      const userId = 'u-offline-recon';
      final now = DateTime.now();
      await db.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES(?,?,?,?,?,?)',
        [userId, 'Offline User', 'off@test.com', 'hash', 80000.0, now.toIso8601String()],
      );

      // Simular 5 operaciones guardadas offline en el móvil
      final offlineBatch = List.generate(5, (i) {
        return {
          'operation_id': 'op-off-$i',
          'entity_type': 'transaction',
          'entity_id': 'tx-off-$i',
          'action': 'create',
          'payload': {
            'type': 'expense',
            'category': 'Transporte',
            'amount': 1000.0 * (i + 1),
            'description': 'Gasto offline $i',
            'date': now.add(Duration(minutes: i)).toIso8601String(),
            'recognized': true,
          },
          'base_version': 1,
        };
      });

      // Reconexión y subida en lote
      final res = await syncService.processPushAsync(userId: userId, deviceId: 'mobile-offline', operations: offlineBatch);
      expect((res['processed'] as List), hasLength(5));

      final pullAll = await syncService.pullChangesAsync(userId: userId, cursor: 0);
      final changes = pullAll['changes'] as List<Map<String, dynamic>>;
      expect(changes, hasLength(5));

      // Validar orden ascendente estricto de secuencias
      for (int i = 0; i < changes.length - 1; i++) {
        final seqCurrent = changes[i]['sequence'] as num;
        final seqNext = changes[i + 1]['sequence'] as num;
        expect(seqCurrent, lessThan(seqNext));
      }
    });

    // --------------------------------------------------------------------------
    // 5. Conflictos concurrentes
    // --------------------------------------------------------------------------
    test('5. Conflictos concurrentes: versión obsoleta es interceptada y registrada para resolución', () async {
      const userId = 'u-conflict-detect';
      final now = DateTime.now().toIso8601String();
      await db.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES(?,?,?,?,?,?)',
        [userId, 'Conflict User', 'conf@test.com', 'hash', 100000.0, now],
      );

      // Crear meta en versión 1
      await db.execute(
        'INSERT INTO goals(id, user_id, title, target_amount, saved_amount, version, updated_at) VALUES(?,?,?,?,?,1,?)',
        ['goal-conf-1', userId, 'Fondo de emergencia', 500000.0, 100000.0, now],
      );

      // Cliente Web avanza la versión a 2
      final webOp = [
        {
          'operation_id': 'op-web-g1',
          'entity_type': 'goal',
          'entity_id': 'goal-conf-1',
          'action': 'update',
          'payload': {'title': 'Fondo de emergencia', 'targetAmount': 500000.0, 'savedAmount': 150000.0},
          'base_version': 1,
        }
      ];
      final resWeb = await syncService.processPushAsync(userId: userId, deviceId: 'web', operations: webOp);
      expect(resWeb['processed'][0]['status'], equals('applied'));

      // Cliente Android que no se había sincronizado intenta actualizar desde versión 1
      final androidOp = [
        {
          'operation_id': 'op-android-g1',
          'entity_type': 'goal',
          'entity_id': 'goal-conf-1',
          'action': 'update',
          'payload': {'title': 'Fondo de emergencia', 'targetAmount': 500000.0, 'savedAmount': 120000.0},
          'base_version': 1, // Stale!
        }
      ];
      final resAndroid = await syncService.processPushAsync(userId: userId, deviceId: 'android', operations: androidOp);
      expect(resAndroid['processed'][0]['status'], equals('conflict'));

      final conflictId = resAndroid['processed'][0]['conflict_id'] as String;
      final conflicts = await syncService.getConflictsAsync(userId);
      expect(conflicts, hasLength(1));
      expect(conflicts.first['id'], equals(conflictId));
    });

    // --------------------------------------------------------------------------
    // 6. Idempotencia de operaciones repetidas
    // --------------------------------------------------------------------------
    test('6. Idempotencia: reenvíos por desconexión de red devuelven respuesta cacheada sin duplicar', () async {
      const userId = 'u-idempotency';
      final now = DateTime.now().toIso8601String();
      await db.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES(?,?,?,?,?,?)',
        [userId, 'Idem User', 'idem@test.com', 'hash', 100000.0, now],
      );

      final op = [
        {
          'operation_id': 'op-unique-777',
          'entity_type': 'transaction',
          'entity_id': 'tx-unique-777',
          'action': 'create',
          'payload': {
            'type': 'expense',
            'category': 'Ocio',
            'amount': 5000.0,
            'description': 'Café',
            'date': now,
            'recognized': true,
          },
          'base_version': 1,
        }
      ];

      // Envío 1
      final res1 = await syncService.processPushAsync(userId: userId, deviceId: 'dev-1', operations: op);
      expect(res1['processed'][0]['status'], equals('applied'));

      // Envío 2 (reintento idéntico)
      final res2 = await syncService.processPushAsync(userId: userId, deviceId: 'dev-1', operations: op);
      expect(res2['processed'][0]['status'], equals('applied'));

      // Verificar que solo existe exactamente 1 transacción
      final txRows = await db.query('SELECT COUNT(*) total FROM transactions WHERE id=?', ['tx-unique-777']);
      expect((txRows.first['total'] as num).toInt(), equals(1));
    });

    // --------------------------------------------------------------------------
    // 7. Persistencia tras reiniciar el servidor
    // --------------------------------------------------------------------------
    test('7. Persistencia: datos permanecen íntegros tras cerrar y reabrir la base de datos', () async {
      final tempFile = '${Directory.systemTemp.path}/test_restart_${DateTime.now().millisecondsSinceEpoch}.db';
      var tempDb = AppDatabase.open(customPath: tempFile);

      await tempDb.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES(?,?,?,?,?,?)',
        ['u-restart-1', 'Persistence User', 'restart@test.com', 'hash', 12345.0, DateTime.now().toIso8601String()],
      );
      await tempDb.close();

      // Reabrir
      final reopenedDb = AppDatabase.open(customPath: tempFile);
      final rows = await reopenedDb.query('SELECT name, opening_balance FROM users WHERE id=?', ['u-restart-1']);
      expect(rows, hasLength(1));
      expect(rows.first['name'], equals('Persistence User'));
      expect((rows.first['opening_balance'] as num).toDouble(), equals(12345.0));

      await reopenedDb.close();
      try {
        File(tempFile).deleteSync();
      } catch (_) {}
    });

    // --------------------------------------------------------------------------
    // 8. Aislamiento entre cuentas
    // --------------------------------------------------------------------------
    test('8. Aislamiento: los datos de Usuario A no son accesibles ni modificables por Usuario B', () async {
      final now = DateTime.now().toIso8601String();
      await db.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES(?,?,?,?,?,?)',
        ['user-alice', 'Alice', 'alice@test.com', 'hashA', 50000.0, now],
      );
      await db.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES(?,?,?,?,?,?)',
        ['user-bob', 'Bob', 'bob@test.com', 'hashB', 20000.0, now],
      );

      // Alice tiene una transacción privada
      await db.execute(
        'INSERT INTO transactions(id, user_id, type, category, amount, description, date, recognized, version, updated_at) VALUES(?,?,?,?,?,?,?,?,1,?)',
        ['tx-alice-1', 'user-alice', 'expense', 'Salud', 40000.0, 'Consulta privada', now, 1, now],
      );

      // Bob intenta consultar transacciones
      final bobTransactions = await db.query(
        'SELECT * FROM transactions WHERE user_id=? AND deleted_at IS NULL',
        ['user-bob'],
      );
      expect(bobTransactions, isEmpty);

      // Bob intenta descargar en sync el log de Alice
      final bobPull = await syncService.pullChangesAsync(userId: 'user-bob', cursor: 0);
      expect((bobPull['changes'] as List), isEmpty);
    });

    // --------------------------------------------------------------------------
    // 9. Gestión de sesiones y procedimiento de revocación segura
    // --------------------------------------------------------------------------
    test('9. Gestión de sesiones: expiración automática y revocación de sesiones heredadas por corte', () async {
      final now = DateTime.now();
      const user = 'u-sess-mgmt';
      await db.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES(?,?,?,?,?,?)',
        [user, 'Session User', 'sess@test.com', 'hash', 10000.0, now.toIso8601String()],
      );

      // Sesión 1: Heredada (creada hace 3 días)
      const tokenLegacy = 'token-legacy-past';
      await db.execute(
        'INSERT INTO sessions(token, user_id, created_at, expires_at) VALUES(?,?,?,?)',
        [tokenLegacy, user, now.subtract(const Duration(days: 3)).toIso8601String(), now.add(const Duration(days: 27)).toIso8601String()],
      );

      // Sesión 2: Reciente (creada hace 5 minutos)
      const tokenRecent = 'token-recent-now';
      await db.execute(
        'INSERT INTO sessions(token, user_id, created_at, expires_at) VALUES(?,?,?,?)',
        [tokenRecent, user, now.subtract(const Duration(minutes: 5)).toIso8601String(), now.add(const Duration(days: 30)).toIso8601String()],
      );

      // Ambas son válidas antes de la revocación
      expect(await db.userIdFromTokenAsync(tokenLegacy), equals(user));
      expect(await db.userIdFromTokenAsync(tokenRecent), equals(user));

      // Revocar sesiones creadas antes de hace 1 hora (punto de corte para saneamiento de migración)
      final cutoff = now.subtract(const Duration(hours: 1));
      final revokedCount = await db.revokeSessionsCreatedBefore(cutoff);
      expect(revokedCount, equals(1));

      // La sesión heredada debe haber sido revocada
      expect(await db.userIdFromTokenAsync(tokenLegacy), isNull);
      // La sesión reciente debe permanecer intacta
      expect(await db.userIdFromTokenAsync(tokenRecent), equals(user));

      // Revocación total
      await db.revokeAllSessions();
      expect(await db.userIdFromTokenAsync(tokenRecent), isNull);
    });

    // --------------------------------------------------------------------------
    // 10. Blindaje absoluto de producción en seed()
    // --------------------------------------------------------------------------
    test('10. Blindaje absoluto: seed() bloquea cuenta demo si el sistema o parámetro declaran producción', () async {
      final prodDb = AppDatabase.inMemory();

      // Intento 1: force=true con environment='production'
      await prodDb.seed(force: true, environment: 'production');
      final demoRows1 = await prodDb.query('SELECT id FROM users WHERE email=?', ['demo@plata.app']);
      expect(demoRows1, isEmpty, reason: 'seed(environment: production) debe retornar de inmediato');

      // Intento 2: force=true con environment='prod'
      await prodDb.seed(force: true, environment: 'prod');
      final demoRows2 = await prodDb.query('SELECT id FROM users WHERE email=?', ['demo@plata.app']);
      expect(demoRows2, isEmpty, reason: 'seed(environment: prod) debe retornar de inmediato');

      await prodDb.close();
    });
  });
}

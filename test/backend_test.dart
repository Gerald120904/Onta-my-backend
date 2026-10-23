import 'package:test/test.dart';
import '../lib/src/database.dart';
import '../lib/src/sync_service.dart';

void main() {
  group('Backend Database & Security Tests', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.inMemory();
    });

    tearDown(() {
      db.close();
    });

    test('BCrypt password hashing generates valid bcrypt hash', () {
      final hash = db.hashPassword('secret123');
      expect(hash.startsWith(r'$2a$') || hash.startsWith(r'$2b$'), isTrue);
      expect(db.verifyPassword('secret123', hash), isTrue);
      expect(db.verifyPassword('wrong', hash), isFalse);
    });

    test('Legacy SHA-256 passwords verify and can be upgraded to BCrypt', () {
      final legacy = db.legacySha256('old_pass');
      expect(db.isLegacyHash(legacy), isTrue);
      expect(db.verifyPassword('old_pass', legacy), isTrue);

      // Create test user with legacy hash
      const userId = 'u-legacy-1';
      db.db.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES(?,?,?,?,?,?)',
        [userId, 'Legacy User', 'legacy@test.com', legacy, 1000.0, DateTime.now().toIso8601String()],
      );

      // Upgrade hash
      db.upgradePasswordHash(userId, 'old_pass');
      final updated = db.db.select('SELECT password_hash FROM users WHERE id=?', [userId]).first;
      final newHash = updated['password_hash'] as String;

      expect(db.isLegacyHash(newHash), isFalse);
      expect(db.verifyPassword('old_pass', newHash), isTrue);
    });

    test('Session expiration rejects expired tokens', () {
      const token = 'valid-token';
      const expiredToken = 'expired-token';
      const userId = 'user-sess-1';
      final now = DateTime.now();

      // Active session (valid for 30 days)
      db.db.execute(
        'INSERT INTO sessions(token, user_id, created_at, expires_at) VALUES(?,?,?,?)',
        [token, userId, now.toIso8601String(), now.add(const Duration(days: 30)).toIso8601String()],
      );

      // Expired session (expired 1 hour ago)
      db.db.execute(
        'INSERT INTO sessions(token, user_id, created_at, expires_at) VALUES(?,?,?,?)',
        [expiredToken, userId, now.subtract(const Duration(days: 2)).toIso8601String(), now.subtract(const Duration(hours: 1)).toIso8601String()],
      );

      expect(db.userIdFromToken(token), equals(userId));
      expect(db.userIdFromToken(expiredToken), isNull);
    });
  });

  group('Sync Engine Tests', () {
    late AppDatabase db;
    late SyncService sync;
    const userId = 'user-sync-test';

    setUp(() {
      db = AppDatabase.inMemory();
      sync = SyncService(db);
      // Seed user
      db.db.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at) VALUES(?,?,?,?,?,?)',
        [userId, 'Sync Tester', 'sync@test.com', 'dummy_hash', 50000.0, DateTime.now().toIso8601String()],
      );
    });

    tearDown(() {
      db.close();
    });

    test('Idempotency: repeating identical push returns identical cached result without duplicates', () {
      const opId = 'op-1001';
      const txId = 'tx-1001';

      final operations = [
        {
          'operation_id': opId,
          'entity_type': 'transaction',
          'entity_id': txId,
          'action': 'create',
          'payload': {
            'type': 'expense',
            'category': 'Comida',
            'amount': 4500.0,
            'description': 'Almuerzo',
            'date': DateTime.now().toIso8601String(),
            'recognized': true,
          },
          'base_version': 1,
        }
      ];

      // First push
      final res1 = sync.processPush(userId: userId, deviceId: 'device-A', operations: operations);
      expect(res1['processed'], hasLength(1));
      expect(res1['processed'][0]['status'], equals('applied'));

      // Second push (e.g. after network retry)
      final res2 = sync.processPush(userId: userId, deviceId: 'device-A', operations: operations);
      expect(res2['processed'], hasLength(1));
      expect(res2['processed'][0]['status'], equals('applied'));

      // Verify only 1 record exists in DB
      final rows = db.db.select('SELECT COUNT(*) total FROM transactions WHERE id=?', [txId]);
      expect((rows.first['total'] as num).toInt(), equals(1));
    });

    test('Conflict Detection: concurrent edit on modified version registers conflict', () {
      const txId = 'tx-conflict-1';
      final now = DateTime.now().toIso8601String();

      // Create transaction at version 1
      db.db.execute(
        'INSERT INTO transactions(id, user_id, type, category, amount, description, date, recognized, version, updated_at) '
        'VALUES(?,?,?,?,?,?,?,?,1,?)',
        [txId, userId, 'expense', 'Ocio', 5000.0, 'Cine', now, 1, now],
      );

      // Web updates it to 6000 (advancing version to 2)
      final webOp = [
        {
          'operation_id': 'op-web-update',
          'entity_type': 'transaction',
          'entity_id': txId,
          'action': 'update',
          'payload': {
            'type': 'expense',
            'category': 'Ocio',
            'amount': 6000.0,
            'description': 'Cine VIP',
          },
          'base_version': 1,
        }
      ];
      final resWeb = sync.processPush(userId: userId, deviceId: 'device-web', operations: webOp);
      expect(resWeb['processed'][0]['status'], equals('applied'));
      expect(resWeb['processed'][0]['version'], equals(2));

      // Android offline also updated from version 1 to 4500. When it syncs, base_version is still 1!
      final androidOp = [
        {
          'operation_id': 'op-android-update',
          'entity_type': 'transaction',
          'entity_id': txId,
          'action': 'update',
          'payload': {
            'type': 'expense',
            'category': 'Ocio',
            'amount': 4500.0,
            'description': 'Cine descuento',
          },
          'base_version': 1, // Stale! Server is at version 2
        }
      ];
      final resAndroid = sync.processPush(userId: userId, deviceId: 'device-android', operations: androidOp);
      expect(resAndroid['processed'][0]['status'], equals('conflict'));

      final conflictId = resAndroid['processed'][0]['conflict_id'] as String;
      expect(conflictId, isNotEmpty);

      // Verify conflict is listed in getConflicts
      final conflicts = sync.getConflicts(userId);
      expect(conflicts, hasLength(1));
      expect(conflicts.first['id'], equals(conflictId));

      // Resolve conflict: client_wins
      final resolveRes = sync.resolveConflict(
        userId: userId,
        conflictId: conflictId,
        strategy: 'client_wins',
      );
      expect(resolveRes['ok'], isTrue);

      final updatedTx = db.db.select('SELECT amount, version FROM transactions WHERE id=?', [txId]).first;
      expect((updatedTx['amount'] as num).toDouble(), equals(4500.0));
      expect((updatedTx['version'] as num).toInt(), equals(3));
    });

    test('Incremental pull returns changes in monotonic sequence order', () {
      // Record 3 operations
      sync.recordChange(
        userId: userId,
        entityType: 'transaction',
        entityId: 'tx-1',
        action: 'create',
        version: 1,
        payload: {'amount': 1000.0},
      );
      sync.recordChange(
        userId: userId,
        entityType: 'commitment',
        entityId: 'com-1',
        action: 'create',
        version: 1,
        payload: {'title': 'Renta'},
      );
      sync.recordChange(
        userId: userId,
        entityType: 'transaction',
        entityId: 'tx-1',
        action: 'update',
        version: 2,
        payload: {'amount': 1200.0},
      );

      // Pull from cursor 0
      final pull0 = sync.pullChanges(userId: userId, cursor: 0);
      final changes0 = pull0['changes'] as List;
      expect(changes0, hasLength(3));
      final cursorAfter = pull0['cursor'] as int;

      // Pull from latest cursor returns 0 new changes
      final pullNext = sync.pullChanges(userId: userId, cursor: cursorAfter);
      expect(pullNext['changes'] as List, isEmpty);
    });

    test('Soft delete flags record without destroying it', () {
      const txId = 'tx-to-delete';
      final now = DateTime.now().toIso8601String();
      db.db.execute(
        'INSERT INTO transactions(id, user_id, type, category, amount, description, date, recognized, version, updated_at) '
        'VALUES(?,?,?,?,?,?,?,?,1,?)',
        [txId, userId, 'expense', 'Otros', 2000.0, 'Gasto', now, 1, now],
      );

      final deleteOp = [
        {
          'operation_id': 'op-del-1',
          'entity_type': 'transaction',
          'entity_id': txId,
          'action': 'delete',
          'payload': {},
          'base_version': 1,
        }
      ];

      final res = sync.processPush(userId: userId, deviceId: 'device-test', operations: deleteOp);
      expect(res['processed'][0]['status'], equals('applied'));

      final txRow = db.db.select('SELECT deleted_at, version FROM transactions WHERE id=?', [txId]).first;
      expect(txRow['deleted_at'], isNotNull);
      expect((txRow['version'] as num).toInt(), equals(2));
    });
  });
}

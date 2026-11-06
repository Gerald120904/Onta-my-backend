import 'package:test/test.dart';

import '../lib/src/database.dart';
import '../lib/src/migrations/migration_runner.dart';

void main() {
  test('Migración JWT es aditiva y conserva sesiones opacas antiguas',
      () async {
    final db = AppDatabase.inMemory();
    try {
      final now = DateTime.now().toUtc();
      await db.execute(
          'INSERT INTO users(id,name,email,password_hash,opening_balance,created_at) '
          'VALUES(?,?,?,?,?,?)',
          [
            'legacy-user',
            'Legacy',
            'legacy@example.test',
            db.hashPassword('legacy-pass'),
            42,
            now.toIso8601String()
          ]);
      await db.execute(
          'INSERT INTO sessions(token,user_id,created_at,expires_at) VALUES(?,?,?,?)',
          [
            'legacy-token',
            'legacy-user',
            now.toIso8601String(),
            now.add(const Duration(days: 1)).toIso8601String()
          ]);
      await MigrationRunner(db).runMigrations();
      expect(await db.userIdFromTokenAsync('legacy-token'), 'legacy-user');
      expect(
          (await db.query(
                  'SELECT version FROM schema_migrations WHERE version=5'))
              .length,
          1);
      expect(
          (await db.query(
                  'SELECT version FROM schema_migrations WHERE version=6'))
              .length,
          1);
      expect(
          (await db.query('SELECT email_verified FROM users WHERE id=?',
                  ['legacy-user']))
              .single['email_verified'],
          1);
      expect(
          (await db.query(
                  "SELECT name FROM sqlite_master WHERE name='refresh_tokens'"))
              .length,
          1);
      expect(
          (await db.query(
                  "SELECT name FROM sqlite_master WHERE name='gmail_oauth_tokens'"))
              .length,
          1);
      await MigrationRunner(db).runMigrations();
      expect(await db.userIdFromTokenAsync('legacy-token'), 'legacy-user');
    } finally {
      await db.close();
    }
  });
}

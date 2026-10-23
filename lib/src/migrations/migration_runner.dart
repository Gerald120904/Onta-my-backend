import 'dart:async';

abstract class MigrationExecutor {
  Future<List<Map<String, dynamic>>> query(String sql, [List<dynamic>? params]);
  Future<void> execute(String sql, [List<dynamic>? params]);
  Future<T> transaction<T>(Future<T> Function(dynamic tx) action);
  bool get isPostgres;
}

class Migration {
  final int version;
  final String name;
  final String Function(bool isPostgres) getSql;

  const Migration({
    required this.version,
    required this.name,
    required this.getSql,
  });
}

class MigrationRunner {
  final MigrationExecutor executor;

  MigrationRunner(this.executor);

  static final List<Migration> migrations = [
    Migration(
      version: 1,
      name: '001_initial_schema',
      getSql: (isPostgres) => '''
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          applied_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS users (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          email TEXT UNIQUE NOT NULL,
          password_hash TEXT NOT NULL,
          opening_balance NUMERIC(18,2) NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT,
          version INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE IF NOT EXISTS sessions (
          token TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          created_at TEXT NOT NULL,
          expires_at TEXT NOT NULL DEFAULT '9999-12-31T23:59:59.999Z'
        );

        CREATE TABLE IF NOT EXISTS transactions (
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

        CREATE TABLE IF NOT EXISTS commitments (
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

        CREATE TABLE IF NOT EXISTS goals (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          title TEXT NOT NULL,
          target_amount NUMERIC(18,2) NOT NULL,
          saved_amount NUMERIC(18,2) NOT NULL,
          version INTEGER NOT NULL DEFAULT 1,
          updated_at TEXT,
          deleted_at TEXT
        );

        CREATE TABLE IF NOT EXISTS decisions (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          action TEXT NOT NULL,
          note TEXT NOT NULL,
          created_at TEXT NOT NULL,
          version INTEGER NOT NULL DEFAULT 1,
          updated_at TEXT,
          deleted_at TEXT
        );

        CREATE TABLE IF NOT EXISTS reviews (
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

        CREATE TABLE IF NOT EXISTS idempotency_keys (
          operation_id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          action TEXT NOT NULL,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          response_code INTEGER NOT NULL,
          response_body TEXT NOT NULL,
          created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS sync_conflicts (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          client_version INTEGER NOT NULL,
          server_version INTEGER NOT NULL,
          client_payload TEXT NOT NULL,
          server_payload TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'unresolved',
          created_at TEXT NOT NULL,
          resolved_at TEXT
        );

        CREATE TABLE IF NOT EXISTS audit_log (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          action TEXT NOT NULL,
          previous_values TEXT,
          new_values TEXT,
          device_id TEXT,
          client_timestamp TEXT,
          server_timestamp TEXT NOT NULL
        );
      ''',
    ),
    Migration(
      version: 2,
      name: '002_sync_log_and_indexes',
      getSql: (isPostgres) {
        final autoIncPk = isPostgres ? 'BIGSERIAL PRIMARY KEY' : 'INTEGER PRIMARY KEY AUTOINCREMENT';
        return '''
          CREATE TABLE IF NOT EXISTS sync_log (
            sequence $autoIncPk,
            user_id TEXT NOT NULL,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            action TEXT NOT NULL,
            version INTEGER NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT NOT NULL
          );

          CREATE INDEX IF NOT EXISTS idx_sync_log_user_seq ON sync_log(user_id, sequence);
          CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id);
          CREATE INDEX IF NOT EXISTS idx_transactions_user_date ON transactions(user_id, date);
          CREATE INDEX IF NOT EXISTS idx_commitments_user_due ON commitments(user_id, due_date);
          CREATE INDEX IF NOT EXISTS idx_sync_conflicts_unresolved ON sync_conflicts(user_id, status);
        ''';
      },
    ),
    Migration(
      version: 3,
      name: '003_session_expiration_and_security',
      getSql: (isPostgres) => '''
        CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at);
      ''',
    ),
  ];

  Future<void> runMigrations() async {
    // 1. Ensure schema_migrations table exists
    await executor.execute('''
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        applied_at TEXT NOT NULL
      );
    ''');

    // 2. Fetch applied migration versions
    final appliedRows = await executor.query('SELECT version FROM schema_migrations ORDER BY version ASC');
    final appliedVersions = appliedRows.map((r) => (r['version'] as num).toInt()).toSet();

    // 3. Apply pending migrations sequentially within transactions
    for (final m in migrations) {
      if (!appliedVersions.contains(m.version)) {
        await executor.transaction((tx) async {
          final sql = m.getSql(executor.isPostgres);
          // Execute statements separated by semicolons
          final statements = sql
              .split(';')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty && !s.startsWith('--'))
              .toList();

          for (final stmt in statements) {
            await tx.execute(stmt);
          }

          final now = DateTime.now().toIso8601String();
          await tx.execute(
            'INSERT INTO schema_migrations(version, name, applied_at) VALUES(?, ?, ?)',
            [m.version, m.name, now],
          );
        });
      }
    }
  }
}

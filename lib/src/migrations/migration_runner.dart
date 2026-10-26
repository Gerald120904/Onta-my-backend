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
  final List<String> Function(bool isPostgres) getStatements;

  Migration({
    required this.version,
    required this.name,
    required String Function(bool isPostgres) getSql,
  }) : getStatements = ((isPostgres) {
          final sql = getSql(isPostgres);
          return sql
              .split(';')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty && !s.startsWith('--'))
              .toList();
        });

  Migration.statements({
    required this.version,
    required this.name,
    required this.getStatements,
  });

  String Function(bool isPostgres) get getSql =>
      (isPostgres) => getStatements(isPostgres).join(';\n');
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
    Migration.statements(
      version: 4,
      name: '004_multi_currency_accounts',
      getStatements: (isPostgres) {
        final addColModifier = isPostgres ? 'IF NOT EXISTS' : '';
        final stmts = <String>[
          // 1. Crear tabla accounts con TODAS las columnas esperadas
          '''
          CREATE TABLE IF NOT EXISTS accounts (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            name TEXT NOT NULL,
            currency TEXT NOT NULL,
            initial_balance NUMERIC(18,2) NOT NULL DEFAULT 0,
            opening_balance NUMERIC(18,2) NOT NULL DEFAULT 0,
            color TEXT,
            icon TEXT,
            is_default INTEGER NOT NULL DEFAULT 0,
            is_archived INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT,
            deleted_at TEXT,
            version INTEGER NOT NULL DEFAULT 1
          )
          ''',
          'CREATE INDEX IF NOT EXISTS idx_accounts_user_id ON accounts(user_id)',

          // 2. Columnas adicionales para asegurar compatibilidad si la tabla fue creada previamente
          'ALTER TABLE accounts ADD COLUMN $addColModifier initial_balance NUMERIC(18,2) NOT NULL DEFAULT 0',
          'ALTER TABLE accounts ADD COLUMN $addColModifier opening_balance NUMERIC(18,2) NOT NULL DEFAULT 0',
          'ALTER TABLE accounts ADD COLUMN $addColModifier color TEXT',
          'ALTER TABLE accounts ADD COLUMN $addColModifier icon TEXT',
          'ALTER TABLE accounts ADD COLUMN $addColModifier is_archived INTEGER NOT NULL DEFAULT 0',

          // 3. Vincular account_id en tablas de negocio
          'ALTER TABLE transactions ADD COLUMN $addColModifier account_id TEXT',
          'ALTER TABLE commitments ADD COLUMN $addColModifier account_id TEXT',
          'ALTER TABLE goals ADD COLUMN $addColModifier account_id TEXT',
          'ALTER TABLE decisions ADD COLUMN $addColModifier account_id TEXT',
          'ALTER TABLE reviews ADD COLUMN $addColModifier account_id TEXT',

          // 4. Índices para consultas compuestas por usuario y cuenta
          'CREATE INDEX IF NOT EXISTS idx_transactions_user_account ON transactions(user_id, account_id)',
          'CREATE INDEX IF NOT EXISTS idx_commitments_user_account ON commitments(user_id, account_id)',
          'CREATE INDEX IF NOT EXISTS idx_goals_user_account ON goals(user_id, account_id)',
        ];

        // 5. Inmutabilidad estricta de divisa a nivel de base de datos
        if (isPostgres) {
          stmts.addAll([
            '''
            CREATE OR REPLACE FUNCTION check_account_currency_immutable()
            RETURNS TRIGGER AS \$\$
            BEGIN
              IF NEW.currency IS DISTINCT FROM OLD.currency THEN
                RAISE EXCEPTION 'Currency is immutable and cannot be changed for an existing account';
              END IF;
              RETURN NEW;
            END;
            \$\$ LANGUAGE plpgsql
            ''',
            'DROP TRIGGER IF EXISTS trg_account_currency_immutable ON accounts',
            '''
            CREATE TRIGGER trg_account_currency_immutable
            BEFORE UPDATE ON accounts
            FOR EACH ROW
            EXECUTE FUNCTION check_account_currency_immutable()
            ''',
          ]);
        } else {
          stmts.add('''
            CREATE TRIGGER IF NOT EXISTS trg_account_currency_immutable_sqlite
            BEFORE UPDATE OF currency ON accounts
            FOR EACH ROW
            WHEN NEW.currency IS NOT OLD.currency
            BEGIN
              SELECT RAISE(ABORT, 'Currency is immutable and cannot be changed for an existing account');
            END
          ''');
        }

        // 6. Backfill seguro de usuarios y movimientos existentes sin pérdida de datos
        stmts.addAll([
          '''
          INSERT INTO accounts (id, user_id, name, currency, initial_balance, opening_balance, color, icon, is_default, is_archived, created_at, version)
          SELECT 
            'acc_default_' || id,
            id,
            'Cuenta Principal',
            'CRC',
            opening_balance,
            opening_balance,
            '#10B981',
            'wallet',
            1,
            0,
            created_at,
            1
          FROM users
          WHERE id NOT IN (SELECT user_id FROM accounts)
          ''',
          "UPDATE accounts SET initial_balance = opening_balance WHERE (initial_balance IS NULL OR initial_balance = 0) AND opening_balance != 0",
          "UPDATE accounts SET opening_balance = initial_balance WHERE (opening_balance IS NULL OR opening_balance = 0) AND initial_balance != 0",
          "UPDATE transactions SET account_id = 'acc_default_' || user_id WHERE account_id IS NULL",
          "UPDATE commitments SET account_id = 'acc_default_' || user_id WHERE account_id IS NULL",
          "UPDATE goals SET account_id = 'acc_default_' || user_id WHERE account_id IS NULL",
          "UPDATE decisions SET account_id = 'acc_default_' || user_id WHERE account_id IS NULL",
          "UPDATE reviews SET account_id = 'acc_default_' || user_id WHERE account_id IS NULL",
        ]);

        return stmts;
      },
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
          final statements = m.getStatements(executor.isPostgres);

          for (final rawStmt in statements) {
            final stmt = rawStmt.trim();
            if (stmt.isEmpty || stmt.startsWith('--')) continue;
            try {
              await tx.execute(stmt);
            } catch (e) {
              final errStr = e.toString().toLowerCase();
              if (stmt.toUpperCase().contains('ADD COLUMN') && errStr.contains('duplicate column')) {
                // Columna ya existe en SQLite
                continue;
              }
              rethrow;
            }
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

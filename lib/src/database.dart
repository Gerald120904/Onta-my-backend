import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:uuid/uuid.dart';

import 'migrations/migration_runner.dart';

abstract class DatabaseExecutor {
  Future<List<Map<String, dynamic>>> query(String sql, [List<dynamic>? params]);
  Future<void> execute(String sql, [List<dynamic>? params]);
}

abstract class AppDatabase implements DatabaseExecutor, MigrationExecutor {
  static const uuid = Uuid();

  AppDatabase.base();

  @override
  bool get isPostgres;

  dynamic get db;

  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor tx) action);

  /// Hashes a password using bcrypt with individual salt.
  String hashPassword(String password) {
    return BCrypt.hashpw(password, BCrypt.gensalt(logRounds: 10));
  }

  /// Legacy sha256 fallback hash.
  String legacySha256(String value) => sha256.convert(utf8.encode(value)).toString();

  /// Verifies password against stored hash. Supports both BCrypt and legacy SHA-256.
  bool verifyPassword(String password, String storedHash) {
    if (storedHash.startsWith(r'$2a$') || storedHash.startsWith(r'$2b$')) {
      try {
        return BCrypt.checkpw(password, storedHash);
      } catch (_) {
        return false;
      }
    }
    return legacySha256(password) == storedHash;
  }

  /// Checks if stored hash is legacy SHA-256.
  bool isLegacyHash(String storedHash) {
    return !storedHash.startsWith(r'$2a$') && !storedHash.startsWith(r'$2b$');
  }

  /// Upgrades user's password to BCrypt hash transparently.
  Future<void> upgradePasswordHash(String userId, String plainPassword) async {
    final newHash = hashPassword(plainPassword);
    await execute('UPDATE users SET password_hash=? WHERE id=?', [newHash, userId]);
  }

  /// Synchronous user ID retrieval for SQLite.
  String? userIdFromToken(String? token);

  /// Asynchronous user ID retrieval with expiration check for both engines.
  Future<String?> userIdFromTokenAsync(String? token);

  /// Revokes all active sessions immediately.
  Future<void> revokeAllSessions() async {
    await execute('DELETE FROM sessions');
  }

  /// Revokes all sessions created before a given cutoff timestamp.
  Future<int> revokeSessionsCreatedBefore(DateTime cutoff) async {
    final cutoffIso = cutoff.toIso8601String();
    final countRows = await query('SELECT COUNT(*) total FROM sessions WHERE created_at < ?', [cutoffIso]);
    final count = (countRows.first['total'] as num).toInt();
    await execute('DELETE FROM sessions WHERE created_at < ?', [cutoffIso]);
    return count;
  }

  /// Seeds default demo user if not in production.
  Future<void> seed({bool force = false, String? environment});

  /// Backfills sync_log for entities created prior to sync engine installation.
  Future<void> backfillSyncLog();

  /// Closes database connection / pool.
  Future<void> close();

  /// Synchronous factory for SQLite (local development and existing tests).
  factory AppDatabase.open({String? customPath}) {
    return SqliteAppDatabase.open(customPath: customPath);
  }

  /// Synchronous in-memory factory for SQLite unit tests.
  factory AppDatabase.inMemory() {
    return SqliteAppDatabase.inMemory();
  }

  /// Valida si una URL corresponde a una conexión PostgreSQL sintácticamente válida.
  static bool isValidPostgresUrl(String? url) {
    if (url == null || url.trim().isEmpty) return false;
    final trimmed = url.trim();
    if (!trimmed.startsWith('postgres://') && !trimmed.startsWith('postgresql://')) {
      return false;
    }
    try {
      final uri = Uri.parse(trimmed);
      return uri.host.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Asynchronous factory supporting both PostgreSQL (Neon) and SQLite.
  /// En producción (ENVIRONMENT=production), exige una DATABASE_URL válida y nunca recurre a SQLite.
  static Future<AppDatabase> openAsync({
    String? customPath,
    String? databaseUrl,
    bool? isProduction,
    String? environment,
  }) async {
    final env = environment?.toLowerCase() ??
        Platform.environment['ENVIRONMENT']?.toLowerCase() ??
        Platform.environment['APP_ENV']?.toLowerCase() ??
        Platform.environment['NODE_ENV']?.toLowerCase() ??
        'development';
    final prod = isProduction ?? (env == 'production' || env == 'prod');
    final url = databaseUrl ?? Platform.environment['DATABASE_URL'];

    if (prod) {
      if (url == null || url.trim().isEmpty) {
        throw StateError(
          'En entorno de producción (ENVIRONMENT=production), se exige una DATABASE_URL PostgreSQL válida. '
          'No se permite SQLite como alternativa en producción.',
        );
      }
      if (!isValidPostgresUrl(url)) {
        throw ArgumentError(
          'DATABASE_URL no es una URL de PostgreSQL válida en producción: "$url". '
          'Se detiene el arranque; nunca se debe usar SQLite en producción.',
        );
      }
      return await PostgresAppDatabase.connect(
        url,
        isProduction: true,
        environment: env,
      );
    }

    if (isValidPostgresUrl(url)) {
      return await PostgresAppDatabase.connect(
        url!,
        isProduction: false,
        environment: env,
      );
    }
    return SqliteAppDatabase.open(customPath: customPath);
  }
}

// ==============================================================================
// SQLITE IMPLEMENTATION (Local Dev & Unit Tests)
// ==============================================================================

class SqliteAppDatabase extends AppDatabase {
  final sqlite.Database _sqliteDb;

  SqliteAppDatabase._(this._sqliteDb) : super.base() {
    _initMigrations();
  }

  factory SqliteAppDatabase.open({String? customPath}) {
    final dbPath = customPath ?? Platform.environment['DATABASE_PATH'] ?? 'data/plata.db';
    final file = File(dbPath);
    final dir = file.parent;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return SqliteAppDatabase._(sqlite.sqlite3.open(dbPath));
  }

  factory SqliteAppDatabase.inMemory() {
    return SqliteAppDatabase._(sqlite.sqlite3.openInMemory());
  }

  @override
  bool get isPostgres => false;

  @override
  sqlite.Database get db => _sqliteDb;

  void _addColumnIfNotExists(String table, String column, String typeWithDefault) {
    try {
      final info = _sqliteDb.select('PRAGMA table_info($table)');
      final exists = info.any((row) => (row['name'] as String).toLowerCase() == column.toLowerCase());
      if (!exists) {
        _sqliteDb.execute('ALTER TABLE $table ADD COLUMN $column $typeWithDefault');
      }
    } catch (_) {}
  }

  void _initMigrations() {
    _sqliteDb.execute('''
      CREATE TABLE IF NOT EXISTS schema_migrations(
        version INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        applied_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS users(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        opening_balance NUMERIC(18,2) NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT,
        version INTEGER NOT NULL DEFAULT 1
      );
      CREATE TABLE IF NOT EXISTS sessions(
        token TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        expires_at TEXT NOT NULL DEFAULT '9999-12-31T23:59:59.999Z'
      );
      CREATE TABLE IF NOT EXISTS transactions(
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
      CREATE TABLE IF NOT EXISTS commitments(
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
      CREATE TABLE IF NOT EXISTS goals(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        title TEXT NOT NULL,
        target_amount NUMERIC(18,2) NOT NULL,
        saved_amount NUMERIC(18,2) NOT NULL,
        version INTEGER NOT NULL DEFAULT 1,
        updated_at TEXT,
        deleted_at TEXT
      );
      CREATE TABLE IF NOT EXISTS decisions(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        action TEXT NOT NULL,
        note TEXT NOT NULL,
        created_at TEXT NOT NULL,
        version INTEGER NOT NULL DEFAULT 1,
        updated_at TEXT,
        deleted_at TEXT
      );
      CREATE TABLE IF NOT EXISTS reviews(
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
      CREATE TABLE IF NOT EXISTS sync_log(
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
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
      CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at);
      CREATE TABLE IF NOT EXISTS idempotency_keys(
        operation_id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        action TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        response_code INTEGER NOT NULL,
        response_body TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sync_conflicts(
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
      CREATE TABLE IF NOT EXISTS audit_log(
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
      );

      CREATE INDEX IF NOT EXISTS idx_accounts_user_id ON accounts(user_id);
    ''');

    _addColumnIfNotExists('sessions', 'expires_at', "TEXT NOT NULL DEFAULT '9999-12-31T23:59:59.999Z'");
    _addColumnIfNotExists('accounts', 'initial_balance', 'NUMERIC(18,2) NOT NULL DEFAULT 0');
    _addColumnIfNotExists('accounts', 'opening_balance', 'NUMERIC(18,2) NOT NULL DEFAULT 0');
    _addColumnIfNotExists('accounts', 'color', 'TEXT');
    _addColumnIfNotExists('accounts', 'icon', 'TEXT');
    _addColumnIfNotExists('accounts', 'is_archived', 'INTEGER NOT NULL DEFAULT 0');

    for (final table in ['transactions', 'commitments', 'goals', 'decisions', 'reviews']) {
      _addColumnIfNotExists(table, 'version', 'INTEGER NOT NULL DEFAULT 1');
      _addColumnIfNotExists(table, 'updated_at', 'TEXT');
      _addColumnIfNotExists(table, 'deleted_at', 'TEXT');
      _addColumnIfNotExists(table, 'account_id', 'TEXT');
    }
    _addColumnIfNotExists('users', 'updated_at', 'TEXT');
    _addColumnIfNotExists('users', 'version', 'INTEGER NOT NULL DEFAULT 1');

    try {
      _sqliteDb.execute('''
        INSERT INTO accounts (id, user_id, name, currency, initial_balance, opening_balance, is_default, is_archived, created_at, version)
        SELECT 
          'acc_default_' || id,
          id,
          'Cuenta Principal',
          'CRC',
          opening_balance,
          opening_balance,
          1,
          0,
          created_at,
          1
        FROM users
        WHERE id NOT IN (SELECT user_id FROM accounts);

        UPDATE transactions SET account_id = 'acc_default_' || user_id WHERE account_id IS NULL;
        UPDATE commitments SET account_id = 'acc_default_' || user_id WHERE account_id IS NULL;
        UPDATE goals SET account_id = 'acc_default_' || user_id WHERE account_id IS NULL;
        UPDATE decisions SET account_id = 'acc_default_' || user_id WHERE account_id IS NULL;
        UPDATE reviews SET account_id = 'acc_default_' || user_id WHERE account_id IS NULL;
      ''');
    } catch (_) {}

    _syncBackfillSyncLog();
  }

  @override
  Future<List<Map<String, dynamic>>> query(String sql, [List<dynamic>? params]) async {
    final resultSet = _sqliteDb.select(sql, params ?? const []);
    return resultSet.map((row) => PostgresAppDatabase.normalizeRow(Map<String, dynamic>.from(row))).toList();
  }

  @override
  Future<void> execute(String sql, [List<dynamic>? params]) async {
    _sqliteDb.execute(sql, params ?? const []);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor tx) action) async {
    _sqliteDb.execute('BEGIN TRANSACTION');
    try {
      final result = await action(this);
      _sqliteDb.execute('COMMIT');
      return result;
    } catch (e) {
      _sqliteDb.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  String? userIdFromToken(String? token) {
    if (token == null || token.isEmpty) return null;
    final r = _sqliteDb.select('SELECT user_id, expires_at FROM sessions WHERE token=?', [token]);
    if (r.isEmpty) return null;

    final expiresAtStr = r.first['expires_at'] as String?;
    if (expiresAtStr != null) {
      final expiresAt = DateTime.tryParse(expiresAtStr);
      if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
        _sqliteDb.execute('DELETE FROM sessions WHERE token=?', [token]);
        return null;
      }
    }
    return r.first['user_id'] as String;
  }

  @override
  Future<String?> userIdFromTokenAsync(String? token) async {
    return userIdFromToken(token);
  }

  @override
  Future<void> seed({bool force = false, String? environment}) async {
    final systemEnv = Platform.environment['ENVIRONMENT']?.toLowerCase() ??
        Platform.environment['APP_ENV']?.toLowerCase() ??
        Platform.environment['NODE_ENV']?.toLowerCase();
    final isSystemProduction = systemEnv == 'production' || systemEnv == 'prod';

    if (isSystemProduction) {
      return;
    }

    final effectiveEnv = environment?.toLowerCase() ?? systemEnv ?? 'development';
    if (effectiveEnv == 'production' || effectiveEnv == 'prod') {
      return;
    }

    if (_sqliteDb.select('SELECT id FROM users WHERE email=?', ['demo@plata.app']).isNotEmpty) return;

    final userId = AppDatabase.uuid.v4();
    final now = DateTime.now().toIso8601String();
    _sqliteDb.execute(
      'INSERT INTO users(id,name,email,password_hash,opening_balance,created_at,updated_at) VALUES(?,?,?,?,?,?,?)',
      [userId, 'Sofía', 'demo@plata.app', hashPassword('123456'), 143300.0, now, now],
    );

    final txs = <List<dynamic>>[
      ['Comida', 4500.0, 'Alimentación', 1],
      ['Transporte', 2100.0, 'Bus / movilidad', 1],
      ['Compras', 8000.0, 'Compra personal', 1],
      ['Ocio', 5500.0, 'Entretenimiento', 1],
      ['Otros', 3200.0, 'Movimiento sin identificar', 0],
    ];

    for (final t in txs) {
      final txId = AppDatabase.uuid.v4();
      _sqliteDb.execute(
        'INSERT INTO transactions(id,user_id,type,category,amount,description,date,recognized,version,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)',
        [txId, userId, 'expense', t[0], t[1], t[2], now, t[3], 1, now],
      );
    }

    _sqliteDb.execute(
      'INSERT INTO commitments(id,user_id,title,amount,due_date,status,version,updated_at) VALUES(?,?,?,?,?,?,?,?)',
      [AppDatabase.uuid.v4(), userId, 'Pago pendiente', 35000.0, DateTime.now().add(const Duration(days: 5)).toIso8601String(), 'pending', 1, now],
    );

    _sqliteDb.execute(
      'INSERT INTO goals(id,user_id,title,target_amount,saved_amount,version,updated_at) VALUES(?,?,?,?,?,?,?)',
      [AppDatabase.uuid.v4(), userId, 'Ahorro reservado', 100000.0, 20000.0, 1, now],
    );

    await backfillSyncLog();
  }

  void _syncBackfillSyncLog() {
    unawaited(backfillSyncLog());
  }

  @override
  Future<void> backfillSyncLog() async {
    try {
      final txs = _sqliteDb.select(
        "SELECT * FROM transactions WHERE deleted_at IS NULL AND id NOT IN (SELECT entity_id FROM sync_log WHERE entity_type='transaction')",
      );
      for (final t in txs) {
        final now = (t['updated_at'] ?? t['date'] ?? DateTime.now().toIso8601String()).toString();
        final payload = jsonEncode({
          'type': t['type'],
          'category': t['category'],
          'amount': t['amount'],
          'description': t['description'],
          'date': t['date'],
          'recognized': t['recognized'] == 1,
        });
        _sqliteDb.execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [t['user_id'], 'transaction', t['id'], 'create', t['version'] ?? 1, payload, now],
        );
      }

      final commitments = _sqliteDb.select(
        "SELECT * FROM commitments WHERE deleted_at IS NULL AND id NOT IN (SELECT entity_id FROM sync_log WHERE entity_type='commitment')",
      );
      for (final c in commitments) {
        final now = (c['updated_at'] ?? DateTime.now().toIso8601String()).toString();
        final payload = jsonEncode({
          'title': c['title'],
          'amount': c['amount'],
          'dueDate': c['due_date'],
          'status': c['status'],
        });
        _sqliteDb.execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [c['user_id'], 'commitment', c['id'], 'create', c['version'] ?? 1, payload, now],
        );
      }

      final goals = _sqliteDb.select(
        "SELECT * FROM goals WHERE deleted_at IS NULL AND id NOT IN (SELECT entity_id FROM sync_log WHERE entity_type='goal')",
      );
      for (final g in goals) {
        final now = (g['updated_at'] ?? DateTime.now().toIso8601String()).toString();
        final payload = jsonEncode({
          'title': g['title'],
          'targetAmount': g['target_amount'],
          'savedAmount': g['saved_amount'],
        });
        _sqliteDb.execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [g['user_id'], 'goal', g['id'], 'create', g['version'] ?? 1, payload, now],
        );
      }

      final decisions = _sqliteDb.select(
        "SELECT * FROM decisions WHERE deleted_at IS NULL AND id NOT IN (SELECT entity_id FROM sync_log WHERE entity_type='decision')",
      );
      for (final d in decisions) {
        final now = (d['updated_at'] ?? d['created_at'] ?? DateTime.now().toIso8601String()).toString();
        final payload = jsonEncode({
          'action': d['action'],
          'note': d['note'],
          'created_at': d['created_at'],
        });
        _sqliteDb.execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [d['user_id'], 'decision', d['id'], 'create', d['version'] ?? 1, payload, now],
        );
      }

      final reviews = _sqliteDb.select(
        "SELECT * FROM reviews WHERE deleted_at IS NULL AND id NOT IN (SELECT entity_id FROM sync_log WHERE entity_type='review')",
      );
      for (final r in reviews) {
        final now = (r['updated_at'] ?? r['created_at'] ?? DateTime.now().toIso8601String()).toString();
        List<dynamic> txIds = [];
        Map<String, dynamic> details = {};
        try {
          txIds = jsonDecode(r['transaction_ids'] as String? ?? '[]') as List;
        } catch (_) {}
        try {
          details = jsonDecode(r['decision_details'] as String? ?? '{}') as Map<String, dynamic>;
        } catch (_) {}

        final payload = jsonEncode({
          'start': r['start_date'],
          'end': r['end_date'],
          'periodTitle': r['period_title'],
          'periodSubtitle': r['period_subtitle'],
          'transactionIds': txIds,
          'decision': r['decision'],
          'decisionDetails': details,
          'createdAt': r['created_at'],
        });
        _sqliteDb.execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [r['user_id'], 'review', r['id'], 'create', r['version'] ?? 1, payload, now],
        );
      }
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    _sqliteDb.dispose();
  }
}

// ==============================================================================
// POSTGRESQL IMPLEMENTATION (Neon Free & Render Deployment)
// ==============================================================================

class PostgresAppDatabase extends AppDatabase {
  final Pool _pool;

  PostgresAppDatabase._(this._pool) : super.base();

  static Future<PostgresAppDatabase> connect(
    String databaseUrl, {
    bool? isProduction,
    String? environment,
  }) async {
    final env = environment?.toLowerCase() ??
        Platform.environment['ENVIRONMENT']?.toLowerCase() ??
        Platform.environment['APP_ENV']?.toLowerCase() ??
        Platform.environment['NODE_ENV']?.toLowerCase() ??
        'development';
    final prod = isProduction ?? (env == 'production' || env == 'prod');

    final uri = Uri.parse(databaseUrl);
    final sslModeParam = uri.queryParameters['sslmode']?.toLowerCase();

    // Condición 1: Cuando ENVIRONMENT=production, rechaza cualquier conexión PostgreSQL con TLS desactivado.
    // No permitir sslmode=disable aunque aparezca en DATABASE_URL.
    if (prod && sslModeParam == 'disable') {
      throw StateError(
        'Conexión PostgreSQL con TLS desactivado (sslmode=disable) rechazada en entorno de producción. '
        'TLS es obligatorio en producción.',
      );
    }

    // En producción se exige TLS estrictamente. En desarrollo se permite sslmode=disable para pruebas locales aisladas.
    final SslMode sslMode = prod
        ? SslMode.require
        : ((sslModeParam == 'disable') ? SslMode.disable : SslMode.require);

    final userInfoParts = uri.userInfo.split(':');
    final username = userInfoParts.isNotEmpty ? Uri.decodeComponent(userInfoParts[0]) : '';
    final password = userInfoParts.length > 1 ? Uri.decodeComponent(userInfoParts[1]) : '';
    final database = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : 'neondb';
    final host = uri.host;
    final port = uri.hasPort ? uri.port : 5432;

    final endpoint = Endpoint(
      host: host,
      port: port,
      database: database,
      username: username,
      password: password,
    );

    // Neon exige conexión cifrada TLS y pool de conexiones apropiado al plan Free
    final pool = Pool.withEndpoints(
      [endpoint],
      settings: PoolSettings(
        maxConnectionCount: 5,
        sslMode: sslMode,
      ),
    );

    final app = PostgresAppDatabase._(pool);
    final runner = MigrationRunner(app);
    await runner.runMigrations();

    for (final stmt in [
      'ALTER TABLE accounts ADD COLUMN IF NOT EXISTS initial_balance NUMERIC(18,2) NOT NULL DEFAULT 0',
      'ALTER TABLE accounts ADD COLUMN IF NOT EXISTS opening_balance NUMERIC(18,2) NOT NULL DEFAULT 0',
      'ALTER TABLE accounts ADD COLUMN IF NOT EXISTS color TEXT',
      'ALTER TABLE accounts ADD COLUMN IF NOT EXISTS icon TEXT',
      'ALTER TABLE accounts ADD COLUMN IF NOT EXISTS is_archived INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE transactions ADD COLUMN IF NOT EXISTS account_id TEXT',
      'ALTER TABLE commitments ADD COLUMN IF NOT EXISTS account_id TEXT',
      'ALTER TABLE goals ADD COLUMN IF NOT EXISTS account_id TEXT',
      'ALTER TABLE decisions ADD COLUMN IF NOT EXISTS account_id TEXT',
      'ALTER TABLE reviews ADD COLUMN IF NOT EXISTS account_id TEXT',
    ]) {
      try {
        await app.execute(stmt);
      } catch (_) {}
    }

    return app;
  }

  @override
  bool get isPostgres => true;

  @override
  dynamic get db => throw UnsupportedError(
        'Acceso directo síncrono no soportado en PostgreSQL. Utilice query(), execute() o transaction().',
      );

  /// Normaliza valores numéricos y exactos de las filas para asegurar compatibilidad con JSON y frontend.
  static Map<String, dynamic> normalizeRow(Map<String, dynamic> row) {
    final out = <String, dynamic>{};
    for (final entry in row.entries) {
      final k = entry.key;
      final v = entry.value;
      if (v != null &&
          (k == 'amount' ||
           k == 'initial_balance' ||
           k == 'opening_balance' ||
           k == 'current_balance' ||
           k == 'target_amount' ||
           k == 'saved_amount' ||
           k == 'total' ||
           k == 'income' ||
           k == 'expenses' ||
           k == 'balance' ||
           k == 'committed' ||
           k == 'saved' ||
           k == 'available')) {
        if (v is num) {
          out[k] = v.toDouble();
        } else {
          out[k] = double.tryParse(v.toString()) ?? v;
        }
      } else {
        out[k] = v;
      }
    }
    return out;
  }

  /// Convierte los marcadores '?' de estilo SQLite a los marcadores '$1, $2, ...' de PostgreSQL.
  static String convertPlaceholders(String sql) {
    int index = 1;
    return sql.replaceAllMapped(RegExp(r'\?'), (_) => '\$${index++}');
  }

  @override
  Future<List<Map<String, dynamic>>> query(String sql, [List<dynamic>? params]) async {
    final pgSql = convertPlaceholders(sql);
    final result = await _pool.execute(Sql(pgSql), parameters: params ?? const []);
    return result.map((row) => normalizeRow(row.toColumnMap())).toList();
  }

  @override
  Future<void> execute(String sql, [List<dynamic>? params]) async {
    final pgSql = convertPlaceholders(sql);
    await _pool.execute(Sql(pgSql), parameters: params ?? const []);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor tx) action) async {
    return await _pool.withConnection((connection) async {
      return await connection.runTx((session) async {
        final txExecutor = _PostgresSessionExecutor(session);
        return await action(txExecutor);
      });
    });
  }

  @override
  String? userIdFromToken(String? token) {
    throw UnsupportedError('Utilice userIdFromTokenAsync() en PostgreSQL.');
  }

  @override
  Future<String?> userIdFromTokenAsync(String? token) async {
    if (token == null || token.isEmpty) return null;
    final rows = await query('SELECT user_id, expires_at FROM sessions WHERE token=?', [token]);
    if (rows.isEmpty) return null;

    final expiresAtStr = rows.first['expires_at'] as String?;
    if (expiresAtStr != null) {
      final expiresAt = DateTime.tryParse(expiresAtStr);
      if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
        await execute('DELETE FROM sessions WHERE token=?', [token]);
        return null;
      }
    }
    return rows.first['user_id'] as String;
  }

  @override
  Future<void> seed({bool force = false, String? environment}) async {
    final systemEnv = Platform.environment['ENVIRONMENT']?.toLowerCase() ??
        Platform.environment['APP_ENV']?.toLowerCase() ??
        Platform.environment['NODE_ENV']?.toLowerCase();
    final isSystemProduction = systemEnv == 'production' || systemEnv == 'prod';

    if (isSystemProduction) {
      return;
    }

    final effectiveEnv = environment?.toLowerCase() ?? systemEnv ?? 'development';
    if (effectiveEnv == 'production' || effectiveEnv == 'prod') {
      return;
    }

    final existing = await query('SELECT id FROM users WHERE email=?', ['demo@plata.app']);
    if (existing.isNotEmpty) return;

    final userId = AppDatabase.uuid.v4();
    final now = DateTime.now().toIso8601String();
    await execute(
      'INSERT INTO users(id,name,email,password_hash,opening_balance,created_at,updated_at) VALUES(?,?,?,?,?,?,?)',
      [userId, 'Sofía', 'demo@plata.app', hashPassword('123456'), 143300.0, now, now],
    );

    final txs = <List<dynamic>>[
      ['Comida', 4500.0, 'Alimentación', 1],
      ['Transporte', 2100.0, 'Bus / movilidad', 1],
      ['Compras', 8000.0, 'Compra personal', 1],
      ['Ocio', 5500.0, 'Entretenimiento', 1],
      ['Otros', 3200.0, 'Movimiento sin identificar', 0],
    ];

    for (final t in txs) {
      final txId = AppDatabase.uuid.v4();
      await execute(
        'INSERT INTO transactions(id,user_id,type,category,amount,description,date,recognized,version,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)',
        [txId, userId, 'expense', t[0], t[1], t[2], now, t[3], 1, now],
      );
    }

    await execute(
      'INSERT INTO commitments(id,user_id,title,amount,due_date,status,version,updated_at) VALUES(?,?,?,?,?,?,?,?)',
      [AppDatabase.uuid.v4(), userId, 'Pago pendiente', 35000.0, DateTime.now().add(const Duration(days: 5)).toIso8601String(), 'pending', 1, now],
    );

    await execute(
      'INSERT INTO goals(id,user_id,title,target_amount,saved_amount,version,updated_at) VALUES(?,?,?,?,?,?,?)',
      [AppDatabase.uuid.v4(), userId, 'Ahorro reservado', 100000.0, 20000.0, 1, now],
    );

    await backfillSyncLog();
  }

  @override
  Future<void> backfillSyncLog() async {
    try {
      final txs = await query(
        "SELECT * FROM transactions WHERE deleted_at IS NULL AND id NOT IN (SELECT entity_id FROM sync_log WHERE entity_type='transaction')",
      );
      for (final t in txs) {
        final now = (t['updated_at'] ?? t['date'] ?? DateTime.now().toIso8601String()).toString();
        final payload = jsonEncode({
          'type': t['type'],
          'category': t['category'],
          'amount': t['amount'],
          'description': t['description'],
          'date': t['date'],
          'recognized': t['recognized'] == 1 || t['recognized'] == true,
        });
        await execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [t['user_id'], 'transaction', t['id'], 'create', t['version'] ?? 1, payload, now],
        );
      }

      final commitments = await query(
        "SELECT * FROM commitments WHERE deleted_at IS NULL AND id NOT IN (SELECT entity_id FROM sync_log WHERE entity_type='commitment')",
      );
      for (final c in commitments) {
        final now = (c['updated_at'] ?? DateTime.now().toIso8601String()).toString();
        final payload = jsonEncode({
          'title': c['title'],
          'amount': c['amount'],
          'dueDate': c['due_date'],
          'status': c['status'],
        });
        await execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [c['user_id'], 'commitment', c['id'], 'create', c['version'] ?? 1, payload, now],
        );
      }

      final goals = await query(
        "SELECT * FROM goals WHERE deleted_at IS NULL AND id NOT IN (SELECT entity_id FROM sync_log WHERE entity_type='goal')",
      );
      for (final g in goals) {
        final now = (g['updated_at'] ?? DateTime.now().toIso8601String()).toString();
        final payload = jsonEncode({
          'title': g['title'],
          'targetAmount': g['target_amount'],
          'savedAmount': g['saved_amount'],
        });
        await execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [g['user_id'], 'goal', g['id'], 'create', g['version'] ?? 1, payload, now],
        );
      }

      final decisions = await query(
        "SELECT * FROM decisions WHERE deleted_at IS NULL AND id NOT IN (SELECT entity_id FROM sync_log WHERE entity_type='decision')",
      );
      for (final d in decisions) {
        final now = (d['updated_at'] ?? d['created_at'] ?? DateTime.now().toIso8601String()).toString();
        final payload = jsonEncode({
          'action': d['action'],
          'note': d['note'],
          'created_at': d['created_at'],
        });
        await execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [d['user_id'], 'decision', d['id'], 'create', d['version'] ?? 1, payload, now],
        );
      }

      final reviews = await query(
        "SELECT * FROM reviews WHERE deleted_at IS NULL AND id NOT IN (SELECT entity_id FROM sync_log WHERE entity_type='review')",
      );
      for (final r in reviews) {
        final now = (r['updated_at'] ?? r['created_at'] ?? DateTime.now().toIso8601String()).toString();
        List<dynamic> txIds = [];
        Map<String, dynamic> details = {};
        try {
          txIds = jsonDecode(r['transaction_ids'] as String? ?? '[]') as List;
        } catch (_) {}
        try {
          details = jsonDecode(r['decision_details'] as String? ?? '{}') as Map<String, dynamic>;
        } catch (_) {}

        final payload = jsonEncode({
          'start': r['start_date'],
          'end': r['end_date'],
          'periodTitle': r['period_title'],
          'periodSubtitle': r['period_subtitle'],
          'transactionIds': txIds,
          'decision': r['decision'],
          'decisionDetails': details,
          'createdAt': r['created_at'],
        });
        await execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [r['user_id'], 'review', r['id'], 'create', r['version'] ?? 1, payload, now],
        );
      }
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    await _pool.close();
  }
}

class _PostgresSessionExecutor implements DatabaseExecutor {
  final TxSession _session;

  _PostgresSessionExecutor(this._session);

  @override
  Future<List<Map<String, dynamic>>> query(String sql, [List<dynamic>? params]) async {
    final pgSql = PostgresAppDatabase.convertPlaceholders(sql);
    final result = await _session.execute(Sql(pgSql), parameters: params ?? const []);
    return result.map((row) => PostgresAppDatabase.normalizeRow(row.toColumnMap())).toList();
  }

  @override
  Future<void> execute(String sql, [List<dynamic>? params]) async {
    final pgSql = PostgresAppDatabase.convertPlaceholders(sql);
    await _session.execute(Sql(pgSql), parameters: params ?? const []);
  }
}

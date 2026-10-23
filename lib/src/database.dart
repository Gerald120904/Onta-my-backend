import 'dart:convert';
import 'dart:io';
import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

class AppDatabase {
  final Database db;
  static const uuid = Uuid();
  AppDatabase._(this.db);

  factory AppDatabase.open({String? customPath}) {
    final dbPath = customPath ?? Platform.environment['DATABASE_PATH'] ?? 'data/plata.db';
    final file = File(dbPath);
    final dir = file.parent;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final app = AppDatabase._(sqlite3.open(dbPath));
    app._migrate();
    return app;
  }

  factory AppDatabase.inMemory() {
    final app = AppDatabase._(sqlite3.openInMemory());
    app._migrate();
    return app;
  }

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
    // Fallback for legacy sha256
    return legacySha256(password) == storedHash;
  }

  /// Checks if stored hash is legacy SHA-256.
  bool isLegacyHash(String storedHash) {
    return !storedHash.startsWith(r'$2a$') && !storedHash.startsWith(r'$2b$');
  }

  /// Upgrades user's password to BCrypt hash transparently.
  void upgradePasswordHash(String userId, String plainPassword) {
    final newHash = hashPassword(plainPassword);
    db.execute('UPDATE users SET password_hash=? WHERE id=?', [newHash, userId]);
  }

  void _addColumnIfNotExists(String table, String column, String typeWithDefault) {
    final info = db.select('PRAGMA table_info($table)');
    final exists = info.any((row) => (row['name'] as String).toLowerCase() == column.toLowerCase());
    if (!exists) {
      db.execute('ALTER TABLE $table ADD COLUMN $column $typeWithDefault');
    }
  }

  void _migrate() {
    // 1. Initial base tables
    db.execute('''
      CREATE TABLE IF NOT EXISTS users(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        opening_balance REAL NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
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
        amount REAL NOT NULL,
        description TEXT NOT NULL,
        date TEXT NOT NULL,
        recognized INTEGER NOT NULL DEFAULT 1
      );
      CREATE TABLE IF NOT EXISTS commitments(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        title TEXT NOT NULL,
        amount REAL NOT NULL,
        due_date TEXT NOT NULL,
        status TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS goals(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        title TEXT NOT NULL,
        target_amount REAL NOT NULL,
        saved_amount REAL NOT NULL
      );
      CREATE TABLE IF NOT EXISTS decisions(
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        action TEXT NOT NULL,
        note TEXT NOT NULL,
        created_at TEXT NOT NULL
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
    ''');

    // Safe, non-destructive column additions for existing installations
    _addColumnIfNotExists('sessions', 'expires_at', "TEXT NOT NULL DEFAULT '9999-12-31T23:59:59.999Z'");

    for (final table in ['transactions', 'commitments', 'goals', 'decisions', 'reviews']) {
      _addColumnIfNotExists(table, 'version', 'INTEGER NOT NULL DEFAULT 1');
      _addColumnIfNotExists(table, 'updated_at', 'TEXT');
      _addColumnIfNotExists(table, 'deleted_at', 'TEXT');
    }
    _addColumnIfNotExists('users', 'updated_at', 'TEXT');
    _addColumnIfNotExists('users', 'version', 'INTEGER NOT NULL DEFAULT 1');
    backfillSyncLog();
  }

  void backfillSyncLog() {
    try {
      final txs = db.select(
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
        db.execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [t['user_id'], 'transaction', t['id'], 'create', t['version'] ?? 1, payload, now],
        );
      }

      final commitments = db.select(
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
        db.execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [c['user_id'], 'commitment', c['id'], 'create', c['version'] ?? 1, payload, now],
        );
      }

      final goals = db.select(
        "SELECT * FROM goals WHERE deleted_at IS NULL AND id NOT IN (SELECT entity_id FROM sync_log WHERE entity_type='goal')",
      );
      for (final g in goals) {
        final now = (g['updated_at'] ?? DateTime.now().toIso8601String()).toString();
        final payload = jsonEncode({
          'title': g['title'],
          'targetAmount': g['target_amount'],
          'savedAmount': g['saved_amount'],
        });
        db.execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [g['user_id'], 'goal', g['id'], 'create', g['version'] ?? 1, payload, now],
        );
      }

      final decisions = db.select(
        "SELECT * FROM decisions WHERE deleted_at IS NULL AND id NOT IN (SELECT entity_id FROM sync_log WHERE entity_type='decision')",
      );
      for (final d in decisions) {
        final now = (d['updated_at'] ?? d['created_at'] ?? DateTime.now().toIso8601String()).toString();
        final payload = jsonEncode({
          'action': d['action'],
          'note': d['note'],
          'created_at': d['created_at'],
        });
        db.execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [d['user_id'], 'decision', d['id'], 'create', d['version'] ?? 1, payload, now],
        );
      }

      final reviews = db.select(
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
        db.execute(
          'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) VALUES(?,?,?,?,?,?,?)',
          [r['user_id'], 'review', r['id'], 'create', r['version'] ?? 1, payload, now],
        );
      }
    } catch (_) {}
  }

  void seed({bool force = false, String? environment}) {
    final env = environment?.toLowerCase() ??
        Platform.environment['ENVIRONMENT']?.toLowerCase() ??
        Platform.environment['APP_ENV']?.toLowerCase() ??
        Platform.environment['NODE_ENV']?.toLowerCase() ??
        'development';
    final isProduction = env == 'production' || env == 'prod';
    if (isProduction) {
      return; // Desactivado absolutamente en producción (incluso si force: true)
    }
    if (db.select('SELECT id FROM users WHERE email=?', ['demo@plata.app']).isNotEmpty) return;
    final userId = uuid.v4();
    final now = DateTime.now().toIso8601String();
    db.execute(
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
      final txId = uuid.v4();
      db.execute(
        'INSERT INTO transactions(id,user_id,type,category,amount,description,date,recognized,version,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)',
        [txId, userId, 'expense', t[0], t[1], t[2], now, t[3], 1, now],
      );
    }
    db.execute(
      'INSERT INTO commitments(id,user_id,title,amount,due_date,status,version,updated_at) VALUES(?,?,?,?,?,?,?,?)',
      [uuid.v4(), userId, 'Pago pendiente', 35000.0, DateTime.now().add(const Duration(days: 5)).toIso8601String(), 'pending', 1, now],
    );
    db.execute(
      'INSERT INTO goals(id,user_id,title,target_amount,saved_amount,version,updated_at) VALUES(?,?,?,?,?,?,?)',
      [uuid.v4(), userId, 'Ahorro reservado', 100000.0, 20000.0, 1, now],
    );

    // Sincronizar inmediatamente los registros generados por seed()
    backfillSyncLog();
  }

  String? userIdFromToken(String? token) {
    if (token == null || token.isEmpty) return null;
    final r = db.select('SELECT user_id, expires_at FROM sessions WHERE token=?', [token]);
    if (r.isEmpty) return null;

    final expiresAtStr = r.first['expires_at'] as String?;
    if (expiresAtStr != null) {
      final expiresAt = DateTime.tryParse(expiresAtStr);
      if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
        // Expired session: revoke immediately
        db.execute('DELETE FROM sessions WHERE token=?', [token]);
        return null;
      }
    }
    return r.first['user_id'] as String;
  }

  void close() {
    db.dispose();
  }
}

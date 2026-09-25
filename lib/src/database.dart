import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

class AppDatabase {
  final Database db;
  static const uuid = Uuid();
  AppDatabase._(this.db);

  factory AppDatabase.open() {
    final dir = Directory('data');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final app = AppDatabase._(sqlite3.open('data/plata.db'));
    app._migrate();
    return app;
  }

  String hash(String value) => sha256.convert(utf8.encode(value)).toString();

  void _migrate() {
    db.execute('''
      CREATE TABLE IF NOT EXISTS users(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL, opening_balance REAL NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sessions(
        token TEXT PRIMARY KEY, user_id TEXT NOT NULL, created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS transactions(
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL, type TEXT NOT NULL,
        category TEXT NOT NULL, amount REAL NOT NULL, description TEXT NOT NULL,
        date TEXT NOT NULL, recognized INTEGER NOT NULL DEFAULT 1
      );
      CREATE TABLE IF NOT EXISTS commitments(
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL, title TEXT NOT NULL,
        amount REAL NOT NULL, due_date TEXT NOT NULL, status TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS goals(
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL, title TEXT NOT NULL,
        target_amount REAL NOT NULL, saved_amount REAL NOT NULL
      );
      CREATE TABLE IF NOT EXISTS decisions(
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL, action TEXT NOT NULL,
        note TEXT NOT NULL, created_at TEXT NOT NULL
      );
    ''');
  }

  void seed() {
    if (db.select('SELECT id FROM users WHERE email=?', ['demo@plata.app']).isNotEmpty) return;
    final userId = uuid.v4();
    db.execute(
      'INSERT INTO users(id,name,email,password_hash,opening_balance,created_at) VALUES(?,?,?,?,?,?)',
      [userId, 'Sofía', 'demo@plata.app', hash('123456'), 143300.0, DateTime.now().toIso8601String()],
    );
    final txs = <List<dynamic>>[
      ['Comida', 4500.0, 'Alimentación', 1],
      ['Transporte', 2100.0, 'Bus / movilidad', 1],
      ['Compras', 8000.0, 'Compra personal', 1],
      ['Ocio', 5500.0, 'Entretenimiento', 1],
      ['Otros', 3200.0, 'Movimiento sin identificar', 0],
    ];
    for (final t in txs) {
      db.execute(
        'INSERT INTO transactions(id,user_id,type,category,amount,description,date,recognized) VALUES(?,?,?,?,?,?,?,?)',
        [uuid.v4(), userId, 'expense', t[0], t[1], t[2], DateTime.now().toIso8601String(), t[3]],
      );
    }
    db.execute(
      'INSERT INTO commitments(id,user_id,title,amount,due_date,status) VALUES(?,?,?,?,?,?)',
      [uuid.v4(), userId, 'Pago pendiente', 35000.0, DateTime.now().add(const Duration(days: 5)).toIso8601String(), 'pending'],
    );
    db.execute(
      'INSERT INTO goals(id,user_id,title,target_amount,saved_amount) VALUES(?,?,?,?,?)',
      [uuid.v4(), userId, 'Ahorro reservado', 100000.0, 20000.0],
    );
  }

  String? userIdFromToken(String? token) {
    if (token == null || token.isEmpty) return null;
    final r = db.select('SELECT user_id FROM sessions WHERE token=?', [token]);
    return r.isEmpty ? null : r.first['user_id'] as String;
  }
}

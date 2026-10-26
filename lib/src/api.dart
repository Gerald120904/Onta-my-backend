import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';
import 'database.dart';
import 'sync_service.dart';

class Api {
  final AppDatabase database;
  final SyncService syncService;
  final _uuid = const Uuid();

  Api(this.database) : syncService = SyncService(database);

  Router get router {
    final r = Router();
    r.options('/<ignored|.*>', (_) => Response.ok(''));
    r.get('/api/health', _health);

    // Auth
    r.post('/api/auth/login', _login);
    r.post('/api/auth/register', _register);
    r.post('/api/auth/logout', _auth(_logout));
    r.get('/api/auth/me', _auth(_currentUser));
    r.get('/api/me', _auth(_currentUser));
    r.patch('/api/me', _auth(_updateProfile));
    r.post('/api/me/change-password', _auth(_changePassword));

    // Accounts
    r.get('/api/accounts', _auth(_accounts));
    r.post('/api/accounts', _auth(_createAccount));
    r.get('/api/accounts/<id>', _auth(_getAccount));
    r.patch('/api/accounts/<id>', _auth(_updateAccount));
    r.put('/api/accounts/<id>', _auth(_updateAccount));
    r.delete('/api/accounts/<id>', _auth(_deleteAccount));

    // Dashboard
    r.get('/api/dashboard', _auth(_dashboard));

    // Transactions
    r.get('/api/transactions', _auth(_transactions));
    r.post('/api/transactions', _auth(_createTransaction));
    r.put('/api/transactions/<id>', _auth(_updateTransaction));
    r.delete('/api/transactions/<id>', _auth(_deleteTransaction));

    // Commitments
    r.get('/api/commitments', _auth(_commitments));
    r.post('/api/commitments', _auth(_createCommitment));
    r.put('/api/commitments/<id>', _auth(_updateCommitment));
    r.delete('/api/commitments/<id>', _auth(_deleteCommitment));

    // Goals
    r.get('/api/goals', _auth(_goals));
    r.post('/api/goals', _auth(_createGoal));
    r.put('/api/goals/<id>', _auth(_updateGoal));
    r.delete('/api/goals/<id>', _auth(_deleteGoal));

    // Decisions & Reviews
    r.post('/api/decisions', _auth(_createDecision));
    r.get('/api/reviews', _auth(_reviews));
    r.post('/api/reviews', _auth(_createReview));

    // Sync Engine Endpoints
    r.post('/api/sync/push', _auth(_syncPush));
    r.get('/api/sync/pull', _auth(_syncPull));
    r.get('/api/sync/status', _auth(_syncStatus));
    r.get('/api/sync/conflicts', _auth(_syncConflicts));
    r.post('/api/sync/conflicts/<id>/resolve', _auth(_resolveConflict));

    return r;
  }

  Response _health(Request request) {
    return _json({
      'ok': true,
      'status': 'healthy',
      'engine': database.isPostgres ? 'postgresql-neon' : 'sqlite3-local',
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  Future<Map<String, dynamic>> _body(Request request) async {
    final raw = await request.readAsString();
    return raw.isEmpty ? {} : Map<String, dynamic>.from(jsonDecode(raw));
  }

  Response _json(Object value, {int status = 200}) => Response(
        status,
        body: jsonEncode(value),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  String? _token(Request request) {
    final auth = request.headers['authorization'];
    return auth != null && auth.startsWith('Bearer ') ? auth.substring(7) : null;
  }

  Handler _auth(Function callback) {
    return (Request request) async {
      final token = _token(request);
      final userId = await database.userIdFromTokenAsync(token);
      if (userId == null) {
        return _json({'message': 'Sesión inválida o expirada'}, status: 401);
      }
      final route = request.url.pathSegments;
      final nonEntityRoutes = {
        'accounts',
        'transactions',
        'commitments',
        'goals',
        'decisions',
        'reviews',
        'push',
        'pull',
        'status',
        'conflicts',
        'dashboard',
        'me',
        'logout',
        'change-password',
      };

      if (route.isNotEmpty && !nonEntityRoutes.contains(route.last)) {
        return await Function.apply(callback, [request, userId, route.last]);
      }
      return await Function.apply(callback, [request, userId]);
    };
  }

  Future<Response> _login(Request request) async {
    final b = await _body(request);
    final email = (b['email'] ?? '').toString().trim().toLowerCase();
    final password = (b['password'] ?? '').toString();

    final rows = await database.query(
      'SELECT id, name, email, password_hash, opening_balance FROM users WHERE email=?',
      [email],
    );

    if (rows.isEmpty) {
      return _json({'message': 'Credenciales inválidas'}, status: 401);
    }

    final user = rows.first;
    final storedHash = user['password_hash'] as String;

    if (!database.verifyPassword(password, storedHash)) {
      return _json({'message': 'Credenciales inválidas'}, status: 401);
    }

    // Transparent progressive migration from legacy SHA-256 to BCrypt
    if (database.isLegacyHash(storedHash)) {
      await database.upgradePasswordHash(user['id'] as String, password);
    }

    final token = _uuid.v4();
    final now = DateTime.now();
    final expiresAt = now.add(const Duration(days: 30)).toIso8601String();

    await database.execute(
      'INSERT INTO sessions(token, user_id, created_at, expires_at) VALUES(?,?,?,?)',
      [token, user['id'], now.toIso8601String(), expiresAt],
    );

    return _json({
      'token': token,
      'user': {
        'id': user['id'],
        'name': user['name'],
        'email': user['email'],
        'opening_balance': _amount(user['opening_balance']),
      },
      'expires_at': expiresAt,
    });
  }

  Future<Response> _register(Request request) async {
    final b = await _body(request);
    final name = (b['name'] ?? '').toString().trim();
    final email = (b['email'] ?? '').toString().trim().toLowerCase();
    final password = (b['password'] ?? '').toString();
    final openingBalance = _amount(b['opening_balance'] ?? 0.0);

    if (name.isEmpty || !email.contains('@') || password.length < 6) {
      return _json({'message': 'Datos inválidos. La contraseña debe tener al menos 6 caracteres.'}, status: 400);
    }
    final existing = await database.query('SELECT id FROM users WHERE email=?', [email]);
    if (existing.isNotEmpty) {
      return _json({'message': 'El correo ya existe'}, status: 409);
    }

    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final cleanId = id.replaceAll('-', '');
    final prefix = cleanId.length >= 8 ? cleanId.substring(0, 8) : cleanId;
    final accountId = 'acc_${prefix}_crc';

    await database.transaction((tx) async {
      await tx.execute(
        'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at, updated_at) VALUES(?,?,?,?,?,?,?)',
        [id, name, email, database.hashPassword(password), openingBalance, now, now],
      );

      await tx.execute(
        'INSERT INTO accounts(id, user_id, name, currency, initial_balance, opening_balance, color, icon, is_default, is_archived, version, created_at, updated_at, deleted_at) '
        'VALUES(?,?,?,?,?,?,?,?,1,0,1,?,?,NULL)',
        [accountId, id, 'Efectivo Costa Rica', 'CRC', openingBalance, openingBalance, '#10B981', 'wallet', now, now],
      );
    });

    return _json({'message': 'Cuenta creada exitosamente', 'id': id}, status: 201);
  }

  Future<Response> _currentUser(Request request, String userId, [String? ignored]) async {
    final rows = await database.query(
      'SELECT id, name, email, opening_balance, created_at FROM users WHERE id=?',
      [userId],
    );
    if (rows.isEmpty) return _json({'message': 'Usuario no encontrado'}, status: 404);
    final user = rows.first;
    return _json({
      'id': user['id'],
      'name': user['name'],
      'email': user['email'],
      'opening_balance': _amount(user['opening_balance']),
      'created_at': user['created_at'],
    });
  }

  Future<Response> _updateProfile(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final name = (b['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return _json({'message': 'El nombre no puede estar vacío'}, status: 400);
    }
    final rows = await database.query(
      'SELECT id, name, email, opening_balance, created_at FROM users WHERE id=?',
      [userId],
    );
    if (rows.isEmpty) return _json({'message': 'Usuario no encontrado'}, status: 404);
    final user = rows.first;
    final now = DateTime.now().toIso8601String();

    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      await tx.execute(
        'UPDATE users SET name=?, updated_at=? WHERE id=?',
        [name, now, userId],
      );

      // Record in sync engine for incremental pull & audit trail atomically
      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'user',
        entityId: userId,
        action: 'update',
        version: 1,
        payload: {'name': name},
        previousValues: {'name': user['name']},
        executor: tx,
      );

      return _json({
        'id': user['id'],
        'name': name,
        'email': user['email'],
        'opening_balance': _amount(user['opening_balance']),
        'created_at': user['created_at'],
        'updated_at': now,
      });
    });
  }

  Future<Response> _changePassword(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final currentPassword = (b['current_password'] ?? '').toString();
    final newPassword = (b['new_password'] ?? '').toString();
    final confirmPassword = (b['confirm_password'] ?? '').toString();
    final revokeOtherSessions = b['revoke_other_sessions'] == true || b['revoke_other_sessions'] == null;

    if (currentPassword.isEmpty) {
      return _json({'message': 'Debes ingresar tu contraseña actual'}, status: 400);
    }
    if (newPassword.length < 6) {
      return _json({'message': 'La nueva contraseña debe tener al menos 6 caracteres'}, status: 400);
    }
    if (newPassword != confirmPassword) {
      return _json({'message': 'La confirmación de la contraseña no coincide'}, status: 400);
    }

    final rows = await database.query('SELECT id, password_hash FROM users WHERE id=?', [userId]);
    if (rows.isEmpty) return _json({'message': 'Usuario no encontrado'}, status: 404);

    final storedHash = rows.first['password_hash'] as String;
    if (!database.verifyPassword(currentPassword, storedHash)) {
      return _json({'message': 'La contraseña actual no es correcta'}, status: 400);
    }

    final newHash = database.hashPassword(newPassword);
    final now = DateTime.now().toIso8601String();
    final currentToken = _token(request);

    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      await tx.execute('UPDATE users SET password_hash=?, updated_at=? WHERE id=?', [newHash, now, userId]);

      if (revokeOtherSessions && currentToken != null) {
        await tx.execute('DELETE FROM sessions WHERE user_id=? AND token != ?', [userId, currentToken]);
      }

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'user',
        entityId: userId,
        action: 'change_password',
        version: 1,
        payload: {'changed_password': true, 'sessions_revoked': revokeOtherSessions},
        executor: tx,
      );

      return _json({
        'ok': true,
        'message': 'Contraseña actualizada correctamente',
        'sessions_revoked': revokeOtherSessions,
      });
    });
  }

  Future<Response> _logout(Request request, String userId, [String? ignored]) async {
    final token = _token(request);
    if (token != null) {
      await database.execute('DELETE FROM sessions WHERE token=?', [token]);
    }
    return _json({'message': 'Sesión cerrada exitosamente'});
  }

  Future<Response> _dashboard(Request request, String userId, [String? ignored]) async {
    final accountIdParam = request.url.queryParameters['account_id'];

    String accountId;
    Map<String, dynamic> account;

    if (accountIdParam != null && accountIdParam.isNotEmpty) {
      final acc = await _getUserAccount(database, accountIdParam, userId);
      if (acc == null) {
        return _json({'message': 'Cuenta no encontrada o no pertenece al usuario'}, status: 404);
      }
      accountId = accountIdParam;
      account = acc;
    } else {
      final defaultAccId = await _ensureUserDefaultAccountId(database, userId);
      final acc = await _getUserAccount(database, defaultAccId, userId);
      if (acc == null) return _json({'message': 'Cuenta no disponible'}, status: 404);
      accountId = defaultAccId;
      account = acc;
    }

    final openingBalance = _amount(account['initial_balance']);
    final currency = (account['currency'] ?? 'CRC').toString();

    final income = await _sum(
      "SELECT COALESCE(SUM(amount),0) total FROM transactions WHERE user_id=? AND account_id=? AND type='income' AND deleted_at IS NULL",
      [userId, accountId],
    );
    final expenses = await _sum(
      "SELECT COALESCE(SUM(amount),0) total FROM transactions WHERE user_id=? AND account_id=? AND type='expense' AND deleted_at IS NULL",
      [userId, accountId],
    );
    final committed = await _sum(
      "SELECT COALESCE(SUM(amount),0) total FROM commitments WHERE user_id=? AND (account_id=? OR account_id IS NULL) AND status='pending' AND deleted_at IS NULL",
      [userId, accountId],
    );
    final saved = await _sum(
      "SELECT COALESCE(SUM(saved_amount),0) total FROM goals WHERE user_id=? AND (account_id=? OR account_id IS NULL) AND deleted_at IS NULL",
      [userId, accountId],
    );

    final balance = openingBalance + income - expenses;
    final available = balance - committed - saved;
    final categories = await database.query(
      "SELECT category, SUM(amount) total FROM transactions WHERE user_id=? AND account_id=? AND type='expense' AND deleted_at IS NULL GROUP BY category ORDER BY total DESC",
      [userId, accountId],
    );

    return _json({
      'account_id': accountId,
      'account_name': account['name'],
      'currency': currency,
      'opening_balance': openingBalance,
      'income': income,
      'expenses': expenses,
      'balance': balance,
      'committed': committed,
      'saved': saved,
      'available': available,
      'byCategory': [for (final r in categories) {'category': r['category'], 'total': _amount(r['total'])}],
    });
  }

  Future<double> _sum(String sql, dynamic params) async {
    final list = params is List ? params : [params];
    final rows = await database.query(sql, list);
    return rows.isNotEmpty ? _amount(rows.first['total']) : 0.0;
  }

  double _amount(dynamic v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0.0;

  Future<String> _ensureUserDefaultAccountId(dynamic executor, String userId) async {
    final rows = await executor.query(
      'SELECT id FROM accounts WHERE user_id=? AND deleted_at IS NULL ORDER BY is_default DESC, created_at ASC LIMIT 1',
      [userId],
    );
    if (rows.isNotEmpty) {
      return rows.first['id'].toString();
    }
    final cleanId = userId.replaceAll('-', '');
    final prefix = cleanId.length >= 8 ? cleanId.substring(0, 8) : cleanId;
    final accountId = 'acc_${prefix}_crc';
    final now = DateTime.now().toIso8601String();
    final userRows = await executor.query('SELECT opening_balance FROM users WHERE id=?', [userId]);
    final initBalance = userRows.isNotEmpty ? _amount(userRows.first['opening_balance']) : 0.0;

    await executor.execute(
      'INSERT INTO accounts(id, user_id, name, currency, initial_balance, color, icon, is_default, is_archived, version, created_at, updated_at, deleted_at) '
      'VALUES(?,?,?,?,?,?,?,1,0,1,?,?,NULL)',
      [accountId, userId, 'Efectivo Costa Rica', 'CRC', initBalance, '#10B981', 'wallet', now, now],
    );
    return accountId;
  }

  Future<Map<String, dynamic>?> _getUserAccount(dynamic executor, String accountId, String userId) async {
    final rows = await executor.query(
      'SELECT * FROM accounts WHERE id=? AND user_id=? AND deleted_at IS NULL',
      [accountId, userId],
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  // ==========================================
  // ACCOUNTS
  // ==========================================

  Future<Response> _accounts(Request request, String userId, [String? ignored]) async {
    await database.transaction((tx) async {
      await _ensureUserDefaultAccountId(tx, userId);
    });

    final rows = await database.query(
      'SELECT a.id, a.user_id, a.name, a.currency, a.initial_balance, a.color, a.icon, '
      'a.is_default, a.is_archived, a.version, a.created_at, a.updated_at, '
      'COALESCE((SELECT SUM(amount) FROM transactions WHERE account_id=a.id AND user_id=a.user_id AND type=\'income\' AND deleted_at IS NULL), 0) as total_income, '
      'COALESCE((SELECT SUM(amount) FROM transactions WHERE account_id=a.id AND user_id=a.user_id AND type=\'expense\' AND deleted_at IS NULL), 0) as total_expense '
      'FROM accounts a WHERE a.user_id=? AND a.deleted_at IS NULL '
      'ORDER BY a.is_default DESC, a.created_at ASC',
      [userId],
    );

    final list = <Map<String, dynamic>>[];
    for (final r in rows) {
      final init = _amount(r['initial_balance']);
      final inc = _amount(r['total_income']);
      final exp = _amount(r['total_expense']);
      final currentBalance = init + inc - exp;

      list.add({
        'id': r['id'],
        'user_id': r['user_id'],
        'name': r['name'],
        'currency': r['currency'],
        'initial_balance': init,
        'current_balance': currentBalance,
        'color': r['color'],
        'icon': r['icon'],
        'is_default': (r['is_default'] == 1 || r['is_default'] == true),
        'is_archived': (r['is_archived'] == 1 || r['is_archived'] == true),
        'version': r['version'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      });
    }

    return _json(list);
  }

  Future<Response> _createAccount(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final name = (b['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return _json({'message': 'El nombre de la cuenta no puede estar vacío'}, status: 400);
    }

    final rawCurrency = (b['currency'] ?? '').toString().trim().toUpperCase();
    final validCurrencyRegex = RegExp(r'^[A-Z]{3}$');
    if (!validCurrencyRegex.hasMatch(rawCurrency)) {
      return _json({
        'message': 'El código de moneda debe tener 3 letras ISO 4217 (por ejemplo CRC, USD o EUR)'
      }, status: 400);
    }

    final initialBalance = _amount(b['initial_balance'] ?? b['initialBalance'] ?? 0);
    if (initialBalance < 0) {
      return _json({'message': 'El saldo inicial no puede ser negativo'}, status: 400);
    }

    final id = b['id']?.toString() ?? _uuid.v4();
    final color = b['color']?.toString() ?? '#2563EB';
    final icon = b['icon']?.toString() ?? 'wallet';
    final isDefault = b['is_default'] == true || b['isDefault'] == true ? 1 : 0;
    final now = DateTime.now().toIso8601String();

    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      if (isDefault == 1) {
        await tx.execute('UPDATE accounts SET is_default=0 WHERE user_id=?', [userId]);
      }

      final payload = {
        'name': name,
        'currency': rawCurrency,
        'initial_balance': initialBalance,
        'color': color,
        'icon': icon,
        'is_default': isDefault,
        'is_archived': 0,
      };

      await tx.execute(
        'INSERT INTO accounts(id, user_id, name, currency, initial_balance, color, icon, is_default, is_archived, version, created_at, updated_at, deleted_at) '
        'VALUES(?,?,?,?,?,?,?,?,0,1,?,?,NULL)',
        [id, userId, name, rawCurrency, initialBalance, color, icon, isDefault, now, now],
      );

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'account',
        entityId: id,
        action: 'create',
        version: 1,
        payload: payload,
        executor: tx,
      );

      return _json({
        'id': id,
        'user_id': userId,
        'name': name,
        'currency': rawCurrency,
        'initial_balance': initialBalance,
        'current_balance': initialBalance,
        'color': color,
        'icon': icon,
        'is_default': isDefault == 1,
        'is_archived': false,
        'version': 1,
        'created_at': now,
        'updated_at': now,
      }, status: 201);
    });
  }

  Future<Response> _getAccount(Request request, String userId, String id) async {
    final account = await _getUserAccount(database, id, userId);
    if (account == null) {
      return _json({'message': 'Cuenta no encontrada o no pertenece al usuario'}, status: 404);
    }

    final inc = await _sum(
      "SELECT COALESCE(SUM(amount),0) total FROM transactions WHERE account_id=? AND user_id=? AND type='income' AND deleted_at IS NULL",
      [account['id'], userId],
    );
    final exp = await _sum(
      "SELECT COALESCE(SUM(amount),0) total FROM transactions WHERE account_id=? AND user_id=? AND type='expense' AND deleted_at IS NULL",
      [account['id'], userId],
    );
    final init = _amount(account['initial_balance']);
    final currentBalance = init + inc - exp;

    return _json({
      'id': account['id'],
      'user_id': account['user_id'],
      'name': account['name'],
      'currency': account['currency'],
      'initial_balance': init,
      'current_balance': currentBalance,
      'color': account['color'],
      'icon': account['icon'],
      'is_default': account['is_default'] == 1 || account['is_default'] == true,
      'is_archived': account['is_archived'] == 1 || account['is_archived'] == true,
      'version': account['version'],
      'created_at': account['created_at'],
      'updated_at': account['updated_at'],
    });
  }

  Future<Response> _updateAccount(Request request, String userId, String id) async {
    final b = await _body(request);

    // CRITICAL: Strict currency immutability check!
    // "Prohibido cambiar una cuenta CRC a USD, EUR o cualquier otra moneda después de su creación"
    if (b.containsKey('currency')) {
      final requestedCurrency = b['currency']?.toString().trim().toUpperCase();
      final existingRows = await database.query(
        'SELECT currency FROM accounts WHERE id=? AND user_id=? AND deleted_at IS NULL',
        [id, userId],
      );
      if (existingRows.isNotEmpty) {
        final existingCurrency = existingRows.first['currency']?.toString().toUpperCase();
        if (requestedCurrency != null && requestedCurrency != existingCurrency) {
          return _json({
            'message': 'Prohibido cambiar la moneda de una cuenta después de su creación. Cada cuenta tiene una moneda inmutable.'
          }, status: 400);
        }
      }
    }

    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      final existing = await _getUserAccount(tx, id, userId);
      if (existing == null) {
        return _json({'message': 'Cuenta no encontrada o no pertenece al usuario'}, status: 404);
      }

      final newVersion = ((existing['version'] as num?)?.toInt() ?? 1) + 1;
      final now = DateTime.now().toIso8601String();

      final name = b.containsKey('name') ? (b['name'] ?? '').toString().trim() : existing['name'];
      if (name.isEmpty) {
        return _json({'message': 'El nombre de la cuenta no puede estar vacío'}, status: 400);
      }
      final color = b.containsKey('color') ? b['color']?.toString() : existing['color'];
      final icon = b.containsKey('icon') ? b['icon']?.toString() : existing['icon'];
      final isArchived = b.containsKey('is_archived')
          ? (b['is_archived'] == true || b['is_archived'] == 1 ? 1 : 0)
          : (existing['is_archived'] == 1 || existing['is_archived'] == true ? 1 : 0);

      int isDefault = existing['is_default'] == 1 || existing['is_default'] == true ? 1 : 0;
      if (b.containsKey('is_default') || b.containsKey('isDefault')) {
        final val = b['is_default'] ?? b['isDefault'];
        if (val == true || val == 1) {
          isDefault = 1;
          await tx.execute('UPDATE accounts SET is_default=0 WHERE user_id=? AND id != ?', [userId, id]);
        } else {
          isDefault = 0;
        }
      }

      // Currency is NEVER updated.
      await tx.execute(
        'UPDATE accounts SET name=?, color=?, icon=?, is_default=?, is_archived=?, version=?, updated_at=? '
        'WHERE id=? AND user_id=?',
        [name, color, icon, isDefault, isArchived, newVersion, now, id, userId],
      );

      final payload = {
        'name': name,
        'color': color,
        'icon': icon,
        'is_default': isDefault,
        'is_archived': isArchived,
      };

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'account',
        entityId: id,
        action: 'update',
        version: newVersion,
        payload: payload,
        previousValues: existing,
        executor: tx,
      );

      return _json({
        'id': id,
        'name': name,
        'currency': existing['currency'],
        'color': color,
        'icon': icon,
        'is_default': isDefault == 1,
        'is_archived': isArchived == 1,
        'version': newVersion,
        'updated_at': now,
      });
    });
  }

  Future<Response> _deleteAccount(Request request, String userId, String id) async {
    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      final existing = await _getUserAccount(tx, id, userId);
      if (existing == null) {
        return _json({'message': 'Cuenta no encontrada o no pertenece al usuario'}, status: 404);
      }

      final otherAccounts = await tx.query(
        'SELECT id FROM accounts WHERE user_id=? AND id != ? AND deleted_at IS NULL',
        [userId, id],
      );
      if (otherAccounts.isEmpty) {
        return _json({'message': 'No puedes eliminar la única cuenta financiera activa'}, status: 400);
      }

      final newVersion = ((existing['version'] as num?)?.toInt() ?? 1) + 1;
      final now = DateTime.now().toIso8601String();

      await tx.execute(
        'UPDATE accounts SET deleted_at=?, version=?, updated_at=? WHERE id=? AND user_id=?',
        [now, newVersion, now, id, userId],
      );

      if (existing['is_default'] == 1 || existing['is_default'] == true) {
        final newDefaultId = otherAccounts.first['id'];
        await tx.execute(
          'UPDATE accounts SET is_default=1, version=version+1, updated_at=? WHERE id=? AND user_id=?',
          [now, newDefaultId, userId],
        );
      }

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'account',
        entityId: id,
        action: 'delete',
        version: newVersion,
        payload: {'deleted': true},
        previousValues: existing,
        executor: tx,
      );

      return _json({'message': 'Cuenta eliminada exitosamente', 'version': newVersion});
    });
  }

  // ==========================================
  // TRANSACTIONS
  // ==========================================

  Future<Response> _transactions(Request request, String userId, [String? ignored]) async {
    final accountId = request.url.queryParameters['account_id'];
    List<Map<String, dynamic>> rows;

    if (accountId != null && accountId.isNotEmpty) {
      final acc = await _getUserAccount(database, accountId, userId);
      if (acc == null) {
        return _json({'message': 'Cuenta no encontrada o no pertenece al usuario'}, status: 404);
      }
      rows = await database.query(
        'SELECT id, user_id, account_id, type, category, amount, description, date, recognized, version, updated_at '
        'FROM transactions WHERE user_id=? AND account_id=? AND deleted_at IS NULL ORDER BY date DESC',
        [userId, accountId],
      );
    } else {
      rows = await database.query(
        'SELECT id, user_id, account_id, type, category, amount, description, date, recognized, version, updated_at '
        'FROM transactions WHERE user_id=? AND deleted_at IS NULL ORDER BY date DESC',
        [userId],
      );
    }
    return _json([for (final r in rows) Map<String, Object?>.from(r)]);
  }

  Future<Response> _createTransaction(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final amount = _amount(b['amount']);
    if (amount <= 0) return _json({'message': 'El monto debe ser mayor a 0'}, status: 400);

    String? accountId = (b['account_id'] ?? b['accountId'])?.toString();
    if (accountId != null && accountId.isNotEmpty) {
      final acc = await _getUserAccount(database, accountId, userId);
      if (acc == null) {
        return _json({'message': 'La cuenta especificada no pertenece al usuario o no existe'}, status: 400);
      }
    } else {
      accountId = await _ensureUserDefaultAccountId(database, userId);
    }

    final id = b['id']?.toString() ?? _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final payload = {
      'account_id': accountId,
      'type': b['type'] ?? 'expense',
      'category': b['category'] ?? 'Otros',
      'amount': amount,
      'description': b['description'] ?? '',
      'date': b['date'] ?? now,
      'recognized': (b['recognized'] ?? true) == true ? 1 : 0,
    };

    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      await tx.execute(
        'INSERT INTO transactions(id, user_id, account_id, type, category, amount, description, date, recognized, version, updated_at, deleted_at) '
        'VALUES(?,?,?,?,?,?,?,?,?,1,?,NULL)',
        [id, userId, accountId, payload['type'], payload['category'], amount, payload['description'], payload['date'], payload['recognized'], now],
      );

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'transaction',
        entityId: id,
        action: 'create',
        version: 1,
        payload: payload,
        executor: tx,
      );

      return _json({'id': id, 'version': 1, 'account_id': accountId}, status: 201);
    });
  }

  Future<Response> _updateTransaction(Request request, String userId, String id) async {
    final b = await _body(request);
    final amount = _amount(b['amount']);
    if (amount <= 0) return _json({'message': 'El monto debe ser mayor a 0'}, status: 400);

    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      final existing = await tx.query('SELECT * FROM transactions WHERE id=? AND user_id=? AND deleted_at IS NULL', [id, userId]);
      if (existing.isEmpty) return _json({'message': 'Movimiento no encontrado'}, status: 404);

      final current = existing.first;
      final newVersion = ((current['version'] as num?)?.toInt() ?? 1) + 1;
      final now = DateTime.now().toIso8601String();

      String? targetAccountId = (b['account_id'] ?? b['accountId'])?.toString() ?? current['account_id']?.toString();
      if (targetAccountId != null && targetAccountId != current['account_id']?.toString()) {
        final acc = await _getUserAccount(tx, targetAccountId, userId);
        if (acc == null) {
          return _json({'message': 'La cuenta especificada no pertenece al usuario'}, status: 400);
        }
      }

      final payload = {
        'account_id': targetAccountId,
        'type': b['type'] ?? current['type'],
        'category': b['category'] ?? current['category'],
        'amount': amount,
        'description': b['description'] ?? current['description'],
        'date': b['date'] ?? current['date'],
        'recognized': (b['recognized'] ?? true) == true ? 1 : 0,
      };

      await tx.execute(
        'UPDATE transactions SET account_id=?, type=?, category=?, amount=?, description=?, date=?, recognized=?, version=?, updated_at=? '
        'WHERE id=? AND user_id=?',
        [targetAccountId, payload['type'], payload['category'], amount, payload['description'], payload['date'], payload['recognized'], newVersion, now, id, userId],
      );

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'transaction',
        entityId: id,
        action: 'update',
        version: newVersion,
        payload: payload,
        previousValues: Map<String, dynamic>.from(current),
        executor: tx,
      );

      return _json({'message': 'Movimiento actualizado', 'version': newVersion});
    });
  }

  Future<Response> _deleteTransaction(Request request, String userId, String id) async {
    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      final existing = await tx.query('SELECT * FROM transactions WHERE id=? AND user_id=? AND deleted_at IS NULL', [id, userId]);
      if (existing.isEmpty) return _json({'message': 'Movimiento no encontrado o ya eliminado'}, status: 404);

      final current = existing.first;
      final newVersion = ((current['version'] as num?)?.toInt() ?? 1) + 1;
      final now = DateTime.now().toIso8601String();

      await tx.execute(
        'UPDATE transactions SET deleted_at=?, version=?, updated_at=? WHERE id=? AND user_id=?',
        [now, newVersion, now, id, userId],
      );

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'transaction',
        entityId: id,
        action: 'delete',
        version: newVersion,
        payload: {'deleted': true},
        previousValues: Map<String, dynamic>.from(current),
        executor: tx,
      );

      return _json({'message': 'Movimiento eliminado', 'version': newVersion});
    });
  }

  // ==========================================
  // COMMITMENTS
  // ==========================================

  Future<Response> _commitments(Request request, String userId, [String? ignored]) async {
    final accountId = request.url.queryParameters['account_id'];
    List<Map<String, dynamic>> rows;

    if (accountId != null && accountId.isNotEmpty) {
      final acc = await _getUserAccount(database, accountId, userId);
      if (acc == null) {
        return _json({'message': 'Cuenta no encontrada o no pertenece al usuario'}, status: 404);
      }
      rows = await database.query(
        'SELECT id, user_id, account_id, title, amount, due_date, status, version, updated_at '
        'FROM commitments WHERE user_id=? AND (account_id=? OR account_id IS NULL) AND deleted_at IS NULL ORDER BY due_date',
        [userId, accountId],
      );
    } else {
      rows = await database.query(
        'SELECT id, user_id, account_id, title, amount, due_date, status, version, updated_at '
        'FROM commitments WHERE user_id=? AND deleted_at IS NULL ORDER BY due_date',
        [userId],
      );
    }
    return _json([for (final r in rows) Map<String, Object?>.from(r)]);
  }

  Future<Response> _createCommitment(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final amount = _amount(b['amount']);
    if (amount <= 0) return _json({'message': 'Monto inválido'}, status: 400);

    String? accountId = (b['account_id'] ?? b['accountId'])?.toString();
    if (accountId != null && accountId.isNotEmpty) {
      final acc = await _getUserAccount(database, accountId, userId);
      if (acc == null) {
        return _json({'message': 'La cuenta especificada no pertenece al usuario'}, status: 400);
      }
    } else {
      accountId = await _ensureUserDefaultAccountId(database, userId);
    }

    final id = b['id']?.toString() ?? _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final payload = {
      'account_id': accountId,
      'title': b['title'] ?? 'Compromiso',
      'amount': amount,
      'dueDate': b['dueDate'] ?? b['due_date'] ?? now,
      'status': b['status'] ?? 'pending',
    };

    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      await tx.execute(
        'INSERT INTO commitments(id, user_id, account_id, title, amount, due_date, status, version, updated_at, deleted_at) '
        'VALUES(?,?,?,?,?,?,?,1,?,NULL)',
        [id, userId, accountId, payload['title'], amount, payload['dueDate'], payload['status'], now],
      );

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'commitment',
        entityId: id,
        action: 'create',
        version: 1,
        payload: payload,
        executor: tx,
      );

      return _json({'id': id, 'version': 1, 'account_id': accountId}, status: 201);
    });
  }

  Future<Response> _updateCommitment(Request request, String userId, String id) async {
    final b = await _body(request);
    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      final existing = await tx.query('SELECT * FROM commitments WHERE id=? AND user_id=? AND deleted_at IS NULL', [id, userId]);
      if (existing.isEmpty) return _json({'message': 'Compromiso no encontrado'}, status: 404);

      final current = existing.first;
      final newVersion = ((current['version'] as num?)?.toInt() ?? 1) + 1;
      final now = DateTime.now().toIso8601String();

      String? targetAccountId = (b['account_id'] ?? b['accountId'])?.toString() ?? current['account_id']?.toString();
      if (targetAccountId != null && targetAccountId != current['account_id']?.toString()) {
        final acc = await _getUserAccount(tx, targetAccountId, userId);
        if (acc == null) {
          return _json({'message': 'La cuenta especificada no pertenece al usuario'}, status: 400);
        }
      }

      final payload = {
        'account_id': targetAccountId,
        'title': b['title'] ?? current['title'],
        'amount': _amount(b['amount']),
        'dueDate': b['dueDate'] ?? b['due_date'] ?? current['due_date'],
        'status': b['status'] ?? current['status'],
      };

      await tx.execute(
        'UPDATE commitments SET account_id=?, title=?, amount=?, due_date=?, status=?, version=?, updated_at=? WHERE id=? AND user_id=?',
        [targetAccountId, payload['title'], payload['amount'], payload['dueDate'], payload['status'], newVersion, now, id, userId],
      );

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'commitment',
        entityId: id,
        action: 'update',
        version: newVersion,
        payload: payload,
        previousValues: Map<String, dynamic>.from(current),
        executor: tx,
      );

      return _json({'message': 'Compromiso actualizado', 'version': newVersion});
    });
  }

  Future<Response> _deleteCommitment(Request request, String userId, String id) async {
    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      final existing = await tx.query('SELECT * FROM commitments WHERE id=? AND user_id=? AND deleted_at IS NULL', [id, userId]);
      if (existing.isEmpty) return _json({'message': 'Compromiso no encontrado'}, status: 404);

      final current = existing.first;
      final newVersion = ((current['version'] as num?)?.toInt() ?? 1) + 1;
      final now = DateTime.now().toIso8601String();

      await tx.execute(
        'UPDATE commitments SET deleted_at=?, version=?, updated_at=? WHERE id=? AND user_id=?',
        [now, newVersion, now, id, userId],
      );

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'commitment',
        entityId: id,
        action: 'delete',
        version: newVersion,
        payload: {'deleted': true},
        previousValues: Map<String, dynamic>.from(current),
        executor: tx,
      );

      return _json({'message': 'Compromiso eliminado', 'version': newVersion});
    });
  }

  // ==========================================
  // GOALS
  // ==========================================

  Future<Response> _goals(Request request, String userId, [String? ignored]) async {
    final accountId = request.url.queryParameters['account_id'];
    List<Map<String, dynamic>> rows;

    if (accountId != null && accountId.isNotEmpty) {
      final acc = await _getUserAccount(database, accountId, userId);
      if (acc == null) {
        return _json({'message': 'Cuenta no encontrada o no pertenece al usuario'}, status: 404);
      }
      rows = await database.query(
        'SELECT id, user_id, account_id, title, target_amount, saved_amount, version, updated_at '
        'FROM goals WHERE user_id=? AND (account_id=? OR account_id IS NULL) AND deleted_at IS NULL ORDER BY title',
        [userId, accountId],
      );
    } else {
      rows = await database.query(
        'SELECT id, user_id, account_id, title, target_amount, saved_amount, version, updated_at '
        'FROM goals WHERE user_id=? AND deleted_at IS NULL ORDER BY title',
        [userId],
      );
    }
    return _json([for (final r in rows) Map<String, Object?>.from(r)]);
  }

  Future<Response> _createGoal(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final id = b['id']?.toString() ?? _uuid.v4();
    final now = DateTime.now().toIso8601String();

    String? accountId = (b['account_id'] ?? b['accountId'])?.toString();
    if (accountId != null && accountId.isNotEmpty) {
      final acc = await _getUserAccount(database, accountId, userId);
      if (acc == null) {
        return _json({'message': 'La cuenta especificada no pertenece al usuario'}, status: 400);
      }
    } else {
      accountId = await _ensureUserDefaultAccountId(database, userId);
    }

    final payload = {
      'account_id': accountId,
      'title': b['title'] ?? 'Meta',
      'targetAmount': _amount(b['targetAmount'] ?? b['target_amount']),
      'savedAmount': _amount(b['savedAmount'] ?? b['saved_amount']),
    };

    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      await tx.execute(
        'INSERT INTO goals(id, user_id, account_id, title, target_amount, saved_amount, version, updated_at, deleted_at) '
        'VALUES(?,?,?,?,?,?,1,?,NULL)',
        [id, userId, accountId, payload['title'], payload['targetAmount'], payload['savedAmount'], now],
      );

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'goal',
        entityId: id,
        action: 'create',
        version: 1,
        payload: payload,
        executor: tx,
      );

      return _json({'id': id, 'version': 1, 'account_id': accountId}, status: 201);
    });
  }

  Future<Response> _updateGoal(Request request, String userId, String id) async {
    final b = await _body(request);
    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      final existing = await tx.query('SELECT * FROM goals WHERE id=? AND user_id=? AND deleted_at IS NULL', [id, userId]);
      if (existing.isEmpty) return _json({'message': 'Meta no encontrada'}, status: 404);

      final current = existing.first;
      final newVersion = ((current['version'] as num?)?.toInt() ?? 1) + 1;
      final now = DateTime.now().toIso8601String();

      String? targetAccountId = (b['account_id'] ?? b['accountId'])?.toString() ?? current['account_id']?.toString();
      if (targetAccountId != null && targetAccountId != current['account_id']?.toString()) {
        final acc = await _getUserAccount(tx, targetAccountId, userId);
        if (acc == null) {
          return _json({'message': 'La cuenta especificada no pertenece al usuario'}, status: 400);
        }
      }

      final payload = {
        'account_id': targetAccountId,
        'title': b['title'] ?? current['title'],
        'targetAmount': _amount(b['targetAmount'] ?? b['target_amount'] ?? current['target_amount']),
        'savedAmount': _amount(b['savedAmount'] ?? b['saved_amount'] ?? current['saved_amount']),
      };

      await tx.execute(
        'UPDATE goals SET account_id=?, title=?, target_amount=?, saved_amount=?, version=?, updated_at=? WHERE id=? AND user_id=?',
        [targetAccountId, payload['title'], payload['targetAmount'], payload['savedAmount'], newVersion, now, id, userId],
      );

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'goal',
        entityId: id,
        action: 'update',
        version: newVersion,
        payload: payload,
        previousValues: Map<String, dynamic>.from(current),
        executor: tx,
      );

      return _json({'message': 'Meta actualizada', 'version': newVersion});
    });
  }

  Future<Response> _deleteGoal(Request request, String userId, String id) async {
    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      final existing = await tx.query('SELECT * FROM goals WHERE id=? AND user_id=? AND deleted_at IS NULL', [id, userId]);
      if (existing.isEmpty) return _json({'message': 'Meta no encontrada'}, status: 404);

      final current = existing.first;
      final newVersion = ((current['version'] as num?)?.toInt() ?? 1) + 1;
      final now = DateTime.now().toIso8601String();

      await tx.execute(
        'UPDATE goals SET deleted_at=?, version=?, updated_at=? WHERE id=? AND user_id=?',
        [now, newVersion, now, id, userId],
      );

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'goal',
        entityId: id,
        action: 'delete',
        version: newVersion,
        payload: {'deleted': true},
        previousValues: Map<String, dynamic>.from(current),
        executor: tx,
      );

      return _json({'message': 'Meta eliminada', 'version': newVersion});
    });
  }

  // ==========================================
  // DECISIONS & REVIEWS
  // ==========================================

  Future<Response> _createDecision(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final action = (b['action'] ?? '').toString();
    if (action.isEmpty) return _json({'message': 'Seleccioná una decisión'}, status: 400);

    String? accountId = (b['account_id'] ?? b['accountId'])?.toString();
    if (accountId != null && accountId.isNotEmpty) {
      final acc = await _getUserAccount(database, accountId, userId);
      if (acc == null) {
        return _json({'message': 'La cuenta especificada no pertenece al usuario'}, status: 400);
      }
    } else {
      accountId = await _ensureUserDefaultAccountId(database, userId);
    }

    final id = b['id']?.toString() ?? _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final payload = {
      'account_id': accountId,
      'action': action,
      'note': b['note'] ?? '',
      'created_at': now,
    };

    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      await tx.execute(
        'INSERT INTO decisions(id, user_id, account_id, action, note, created_at, version, updated_at, deleted_at) '
        'VALUES(?,?,?,?,?,?,1,?,NULL)',
        [id, userId, accountId, action, payload['note'], now, now],
      );

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'decision',
        entityId: id,
        action: 'create',
        version: 1,
        payload: payload,
        executor: tx,
      );

      return _json({'message': 'Decisión guardada', 'id': id, 'version': 1, 'account_id': accountId}, status: 201);
    });
  }

  Future<Response> _reviews(Request request, String userId, [String? ignored]) async {
    final accountId = request.url.queryParameters['account_id'];
    List<Map<String, dynamic>> rows;

    if (accountId != null && accountId.isNotEmpty) {
      final acc = await _getUserAccount(database, accountId, userId);
      if (acc == null) {
        return _json({'message': 'Cuenta no encontrada o no pertenece al usuario'}, status: 404);
      }
      rows = await database.query(
        'SELECT id, user_id, account_id, start_date, end_date, period_title, period_subtitle, transaction_ids, decision, decision_details, created_at, version, updated_at '
        'FROM reviews WHERE user_id=? AND (account_id=? OR account_id IS NULL) AND deleted_at IS NULL ORDER BY created_at DESC',
        [userId, accountId],
      );
    } else {
      rows = await database.query(
        'SELECT id, user_id, account_id, start_date, end_date, period_title, period_subtitle, transaction_ids, decision, decision_details, created_at, version, updated_at '
        'FROM reviews WHERE user_id=? AND deleted_at IS NULL ORDER BY created_at DESC',
        [userId],
      );
    }

    return _json([
      for (final r in rows)
        {
          'id': r['id'],
          'account_id': r['account_id'],
          'start': r['start_date'],
          'end': r['end_date'],
          'periodTitle': r['period_title'],
          'periodSubtitle': r['period_subtitle'],
          'transactionIds': jsonDecode(r['transaction_ids'] as String? ?? '[]'),
          'decision': r['decision'],
          'decisionDetails': jsonDecode(r['decision_details'] as String? ?? '{}'),
          'createdAt': r['created_at'],
          'version': r['version'],
        }
    ]);
  }

  Future<Response> _createReview(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final id = b['id']?.toString() ?? _uuid.v4();
    final now = DateTime.now().toIso8601String();

    String? accountId = (b['account_id'] ?? b['accountId'])?.toString();
    if (accountId != null && accountId.isNotEmpty) {
      final acc = await _getUserAccount(database, accountId, userId);
      if (acc == null) {
        return _json({'message': 'La cuenta especificada no pertenece al usuario'}, status: 400);
      }
    } else {
      accountId = await _ensureUserDefaultAccountId(database, userId);
    }

    final payload = {
      'account_id': accountId,
      'start': b['start'] ?? now,
      'end': b['end'] ?? now,
      'periodTitle': b['periodTitle'] ?? '',
      'periodSubtitle': b['periodSubtitle'] ?? '',
      'transactionIds': b['transactionIds'] ?? [],
      'decision': b['decision'] ?? 'Mantener mi plan',
      'decisionDetails': b['decisionDetails'] ?? {},
      'createdAt': b['createdAt'] ?? now,
    };

    return await database.transaction((tx) async {
      if (database.isPostgres) {
        await tx.execute('SELECT pg_advisory_xact_lock(hashtext(?))', ['sync_$userId']);
      }

      await tx.execute(
        'INSERT INTO reviews(id, user_id, account_id, start_date, end_date, period_title, period_subtitle, transaction_ids, decision, decision_details, created_at, version, updated_at, deleted_at) '
        'VALUES(?,?,?,?,?,?,?,?,?,?,?,1,?,NULL)',
        [
          id,
          userId,
          accountId,
          payload['start'],
          payload['end'],
          payload['periodTitle'],
          payload['periodSubtitle'],
          jsonEncode(payload['transactionIds']),
          payload['decision'],
          jsonEncode(payload['decisionDetails']),
          payload['createdAt'],
          now,
        ],
      );

      await syncService.recordChangeAsync(
        userId: userId,
        entityType: 'review',
        entityId: id,
        action: 'create',
        version: 1,
        payload: payload,
        executor: tx,
      );

      return _json({'message': 'Revisión guardada', 'id': id, 'version': 1, 'account_id': accountId}, status: 201);
    });
  }

  // ==========================================
  // SYNC ENGINE ENDPOINTS
  // ==========================================

  Future<Response> _syncPush(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final deviceId = b['device_id']?.toString();
    final operationsRaw = b['operations'] as List? ?? [];
    final operations = operationsRaw.map((e) => Map<String, dynamic>.from(e as Map)).toList();

    final result = await syncService.processPushAsync(
      userId: userId,
      deviceId: deviceId,
      operations: operations,
    );

    return _json(result);
  }

  Future<Response> _syncPull(Request request, String userId, [String? ignored]) async {
    final cursorParam = request.url.queryParameters['cursor'];
    final cursor = int.tryParse(cursorParam ?? '0') ?? 0;
    final limitParam = request.url.queryParameters['limit'];
    final limit = int.tryParse(limitParam ?? '200') ?? 200;

    final result = await syncService.pullChangesAsync(
      userId: userId,
      cursor: cursor,
      limit: limit,
    );

    return _json(result);
  }

  Future<Response> _syncStatus(Request request, String userId, [String? ignored]) async {
    final status = await syncService.getStatusAsync(userId);
    return _json(status);
  }

  Future<Response> _syncConflicts(Request request, String userId, [String? ignored]) async {
    final conflicts = await syncService.getConflictsAsync(userId);
    return _json({'conflicts': conflicts});
  }

  Future<Response> _resolveConflict(Request request, String userId, String conflictId) async {
    final b = await _body(request);
    final strategy = (b['strategy'] ?? 'client_wins').toString();
    final merged = b['merged_payload'] != null ? Map<String, dynamic>.from(b['merged_payload'] as Map) : null;

    final result = await syncService.resolveConflictAsync(
      userId: userId,
      conflictId: conflictId,
      strategy: strategy,
      mergedPayload: merged,
    );

    if (result['ok'] == false) {
      return _json(result, status: 400);
    }
    return _json(result);
  }
}

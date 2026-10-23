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
      final userId = database.userIdFromToken(token);
      if (userId == null) {
        return _json({'message': 'Sesión inválida o expirada'}, status: 401);
      }
      final route = request.url.pathSegments;
      final nonEntityRoutes = {
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

    final rows = database.db.select(
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
      database.upgradePasswordHash(user['id'] as String, password);
    }

    final token = _uuid.v4();
    final now = DateTime.now();
    final expiresAt = now.add(const Duration(days: 30)).toIso8601String();

    database.db.execute(
      'INSERT INTO sessions(token, user_id, created_at, expires_at) VALUES(?,?,?,?)',
      [token, user['id'], now.toIso8601String(), expiresAt],
    );

    return _json({
      'token': token,
      'user': {
        'id': user['id'],
        'name': user['name'],
        'email': user['email'],
        'opening_balance': (user['opening_balance'] as num).toDouble(),
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
    if (database.db.select('SELECT id FROM users WHERE email=?', [email]).isNotEmpty) {
      return _json({'message': 'El correo ya existe'}, status: 409);
    }

    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    database.db.execute(
      'INSERT INTO users(id, name, email, password_hash, opening_balance, created_at, updated_at) VALUES(?,?,?,?,?,?,?)',
      [id, name, email, database.hashPassword(password), openingBalance, now, now],
    );
    return _json({'message': 'Cuenta creada exitosamente', 'id': id}, status: 201);
  }

  Future<Response> _currentUser(Request request, String userId, [String? ignored]) async {
    final rows = database.db.select(
      'SELECT id, name, email, opening_balance, created_at FROM users WHERE id=?',
      [userId],
    );
    if (rows.isEmpty) return _json({'message': 'Usuario no encontrado'}, status: 404);
    final user = rows.first;
    return _json({
      'id': user['id'],
      'name': user['name'],
      'email': user['email'],
      'opening_balance': (user['opening_balance'] as num).toDouble(),
      'created_at': user['created_at'],
    });
  }

  Future<Response> _logout(Request request, String userId, [String? ignored]) async {
    final token = _token(request);
    if (token != null) {
      database.db.execute('DELETE FROM sessions WHERE token=?', [token]);
    }
    return _json({'message': 'Sesión cerrada exitosamente'});
  }

  Future<Response> _dashboard(Request request, String userId, [String? ignored]) async {
    final user = database.db.select('SELECT opening_balance FROM users WHERE id=?', [userId]).first;
    final openingBalance = (user['opening_balance'] as num).toDouble();

    final income = _sum("SELECT COALESCE(SUM(amount),0) total FROM transactions WHERE user_id=? AND type='income' AND deleted_at IS NULL", userId);
    final expenses = _sum("SELECT COALESCE(SUM(amount),0) total FROM transactions WHERE user_id=? AND type='expense' AND deleted_at IS NULL", userId);
    final committed = _sum("SELECT COALESCE(SUM(amount),0) total FROM commitments WHERE user_id=? AND status='pending' AND deleted_at IS NULL", userId);
    final saved = _sum("SELECT COALESCE(SUM(saved_amount),0) total FROM goals WHERE user_id=? AND deleted_at IS NULL", userId);

    final balance = openingBalance + income - expenses;
    final categories = database.db.select(
      "SELECT category, SUM(amount) total FROM transactions WHERE user_id=? AND type='expense' AND deleted_at IS NULL GROUP BY category ORDER BY total DESC",
      [userId],
    );

    return _json({
      'opening_balance': openingBalance,
      'income': income,
      'expenses': expenses,
      'balance': balance,
      'committed': committed,
      'saved': saved,
      'available': balance - committed - saved,
      'byCategory': [for (final r in categories) {'category': r['category'], 'total': r['total']}],
    });
  }

  double _sum(String sql, String userId) => (database.db.select(sql, [userId]).first['total'] as num).toDouble();
  double _amount(dynamic v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0;

  // ==========================================
  // TRANSACTIONS
  // ==========================================

  Future<Response> _transactions(Request request, String userId, [String? ignored]) async {
    final rows = database.db.select(
      'SELECT id, user_id, type, category, amount, description, date, recognized, version, updated_at '
      'FROM transactions WHERE user_id=? AND deleted_at IS NULL ORDER BY date DESC',
      [userId],
    );
    return _json([for (final r in rows) Map<String, Object?>.from(r)]);
  }

  Future<Response> _createTransaction(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final amount = _amount(b['amount']);
    if (amount <= 0) return _json({'message': 'El monto debe ser mayor a ₡0'}, status: 400);

    final id = b['id']?.toString() ?? _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final payload = {
      'type': b['type'] ?? 'expense',
      'category': b['category'] ?? 'Otros',
      'amount': amount,
      'description': b['description'] ?? '',
      'date': b['date'] ?? now,
      'recognized': (b['recognized'] ?? true) == true ? 1 : 0,
    };

    database.db.execute(
      'INSERT INTO transactions(id, user_id, type, category, amount, description, date, recognized, version, updated_at, deleted_at) '
      'VALUES(?,?,?,?,?,?,?,?,1,?,NULL)',
      [id, userId, payload['type'], payload['category'], amount, payload['description'], payload['date'], payload['recognized'], now],
    );

    syncService.recordChange(
      userId: userId,
      entityType: 'transaction',
      entityId: id,
      action: 'create',
      version: 1,
      payload: payload,
    );

    return _json({'id': id, 'version': 1}, status: 201);
  }

  Future<Response> _updateTransaction(Request request, String userId, String id) async {
    final b = await _body(request);
    final amount = _amount(b['amount']);
    if (amount <= 0) return _json({'message': 'El monto debe ser mayor a ₡0'}, status: 400);

    final existing = database.db.select('SELECT * FROM transactions WHERE id=? AND user_id=? AND deleted_at IS NULL', [id, userId]);
    if (existing.isEmpty) return _json({'message': 'Movimiento no encontrado'}, status: 404);

    final current = existing.first;
    final newVersion = ((current['version'] as num?)?.toInt() ?? 1) + 1;
    final now = DateTime.now().toIso8601String();

    final payload = {
      'type': b['type'] ?? current['type'],
      'category': b['category'] ?? current['category'],
      'amount': amount,
      'description': b['description'] ?? current['description'],
      'date': b['date'] ?? current['date'],
      'recognized': (b['recognized'] ?? true) == true ? 1 : 0,
    };

    database.db.execute(
      'UPDATE transactions SET type=?, category=?, amount=?, description=?, date=?, recognized=?, version=?, updated_at=? '
      'WHERE id=? AND user_id=?',
      [payload['type'], payload['category'], amount, payload['description'], payload['date'], payload['recognized'], newVersion, now, id, userId],
    );

    syncService.recordChange(
      userId: userId,
      entityType: 'transaction',
      entityId: id,
      action: 'update',
      version: newVersion,
      payload: payload,
      previousValues: Map<String, dynamic>.from(current),
    );

    return _json({'message': 'Movimiento actualizado', 'version': newVersion});
  }

  Future<Response> _deleteTransaction(Request request, String userId, String id) async {
    final existing = database.db.select('SELECT * FROM transactions WHERE id=? AND user_id=? AND deleted_at IS NULL', [id, userId]);
    if (existing.isEmpty) return _json({'message': 'Movimiento no encontrado o ya eliminado'}, status: 404);

    final current = existing.first;
    final newVersion = ((current['version'] as num?)?.toInt() ?? 1) + 1;
    final now = DateTime.now().toIso8601String();

    database.db.execute(
      'UPDATE transactions SET deleted_at=?, version=?, updated_at=? WHERE id=? AND user_id=?',
      [now, newVersion, now, id, userId],
    );

    syncService.recordChange(
      userId: userId,
      entityType: 'transaction',
      entityId: id,
      action: 'delete',
      version: newVersion,
      payload: {'deleted': true},
      previousValues: Map<String, dynamic>.from(current),
    );

    return _json({'message': 'Movimiento eliminado', 'version': newVersion});
  }

  // ==========================================
  // COMMITMENTS
  // ==========================================

  Future<Response> _commitments(Request request, String userId, [String? ignored]) async {
    final rows = database.db.select(
      'SELECT id, user_id, title, amount, due_date, status, version, updated_at '
      'FROM commitments WHERE user_id=? AND deleted_at IS NULL ORDER BY due_date',
      [userId],
    );
    return _json([for (final r in rows) Map<String, Object?>.from(r)]);
  }

  Future<Response> _createCommitment(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final amount = _amount(b['amount']);
    if (amount <= 0) return _json({'message': 'Monto inválido'}, status: 400);

    final id = b['id']?.toString() ?? _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final payload = {
      'title': b['title'] ?? 'Compromiso',
      'amount': amount,
      'dueDate': b['dueDate'] ?? b['due_date'] ?? now,
      'status': b['status'] ?? 'pending',
    };

    database.db.execute(
      'INSERT INTO commitments(id, user_id, title, amount, due_date, status, version, updated_at, deleted_at) '
      'VALUES(?,?,?,?,?,?,1,?,NULL)',
      [id, userId, payload['title'], amount, payload['dueDate'], payload['status'], now],
    );

    syncService.recordChange(
      userId: userId,
      entityType: 'commitment',
      entityId: id,
      action: 'create',
      version: 1,
      payload: payload,
    );

    return _json({'id': id, 'version': 1}, status: 201);
  }

  Future<Response> _updateCommitment(Request request, String userId, String id) async {
    final b = await _body(request);
    final existing = database.db.select('SELECT * FROM commitments WHERE id=? AND user_id=? AND deleted_at IS NULL', [id, userId]);
    if (existing.isEmpty) return _json({'message': 'Compromiso no encontrado'}, status: 404);

    final current = existing.first;
    final newVersion = ((current['version'] as num?)?.toInt() ?? 1) + 1;
    final now = DateTime.now().toIso8601String();

    final payload = {
      'title': b['title'] ?? current['title'],
      'amount': _amount(b['amount']),
      'dueDate': b['dueDate'] ?? b['due_date'] ?? current['due_date'],
      'status': b['status'] ?? current['status'],
    };

    database.db.execute(
      'UPDATE commitments SET title=?, amount=?, due_date=?, status=?, version=?, updated_at=? WHERE id=? AND user_id=?',
      [payload['title'], payload['amount'], payload['dueDate'], payload['status'], newVersion, now, id, userId],
    );

    syncService.recordChange(
      userId: userId,
      entityType: 'commitment',
      entityId: id,
      action: 'update',
      version: newVersion,
      payload: payload,
      previousValues: Map<String, dynamic>.from(current),
    );

    return _json({'message': 'Compromiso actualizado', 'version': newVersion});
  }

  Future<Response> _deleteCommitment(Request request, String userId, String id) async {
    final existing = database.db.select('SELECT * FROM commitments WHERE id=? AND user_id=? AND deleted_at IS NULL', [id, userId]);
    if (existing.isEmpty) return _json({'message': 'Compromiso no encontrado'}, status: 404);

    final current = existing.first;
    final newVersion = ((current['version'] as num?)?.toInt() ?? 1) + 1;
    final now = DateTime.now().toIso8601String();

    database.db.execute(
      'UPDATE commitments SET deleted_at=?, version=?, updated_at=? WHERE id=? AND user_id=?',
      [now, newVersion, now, id, userId],
    );

    syncService.recordChange(
      userId: userId,
      entityType: 'commitment',
      entityId: id,
      action: 'delete',
      version: newVersion,
      payload: {'deleted': true},
      previousValues: Map<String, dynamic>.from(current),
    );

    return _json({'message': 'Compromiso eliminado', 'version': newVersion});
  }

  // ==========================================
  // GOALS
  // ==========================================

  Future<Response> _goals(Request request, String userId, [String? ignored]) async {
    final rows = database.db.select(
      'SELECT id, user_id, title, target_amount, saved_amount, version, updated_at '
      'FROM goals WHERE user_id=? AND deleted_at IS NULL ORDER BY title',
      [userId],
    );
    return _json([for (final r in rows) Map<String, Object?>.from(r)]);
  }

  Future<Response> _createGoal(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final id = b['id']?.toString() ?? _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final payload = {
      'title': b['title'] ?? 'Meta',
      'targetAmount': _amount(b['targetAmount'] ?? b['target_amount']),
      'savedAmount': _amount(b['savedAmount'] ?? b['saved_amount']),
    };

    database.db.execute(
      'INSERT INTO goals(id, user_id, title, target_amount, saved_amount, version, updated_at, deleted_at) '
      'VALUES(?,?,?,?,?,1,?,NULL)',
      [id, userId, payload['title'], payload['targetAmount'], payload['savedAmount'], now],
    );

    syncService.recordChange(
      userId: userId,
      entityType: 'goal',
      entityId: id,
      action: 'create',
      version: 1,
      payload: payload,
    );

    return _json({'id': id, 'version': 1}, status: 201);
  }

  Future<Response> _updateGoal(Request request, String userId, String id) async {
    final b = await _body(request);
    final existing = database.db.select('SELECT * FROM goals WHERE id=? AND user_id=? AND deleted_at IS NULL', [id, userId]);
    if (existing.isEmpty) return _json({'message': 'Meta no encontrada'}, status: 404);

    final current = existing.first;
    final newVersion = ((current['version'] as num?)?.toInt() ?? 1) + 1;
    final now = DateTime.now().toIso8601String();

    final payload = {
      'title': b['title'] ?? current['title'],
      'targetAmount': _amount(b['targetAmount'] ?? b['target_amount'] ?? current['target_amount']),
      'savedAmount': _amount(b['savedAmount'] ?? b['saved_amount'] ?? current['saved_amount']),
    };

    database.db.execute(
      'UPDATE goals SET title=?, target_amount=?, saved_amount=?, version=?, updated_at=? WHERE id=? AND user_id=?',
      [payload['title'], payload['targetAmount'], payload['savedAmount'], newVersion, now, id, userId],
    );

    syncService.recordChange(
      userId: userId,
      entityType: 'goal',
      entityId: id,
      action: 'update',
      version: newVersion,
      payload: payload,
      previousValues: Map<String, dynamic>.from(current),
    );

    return _json({'message': 'Meta actualizada', 'version': newVersion});
  }

  Future<Response> _deleteGoal(Request request, String userId, String id) async {
    final existing = database.db.select('SELECT * FROM goals WHERE id=? AND user_id=? AND deleted_at IS NULL', [id, userId]);
    if (existing.isEmpty) return _json({'message': 'Meta no encontrada'}, status: 404);

    final current = existing.first;
    final newVersion = ((current['version'] as num?)?.toInt() ?? 1) + 1;
    final now = DateTime.now().toIso8601String();

    database.db.execute(
      'UPDATE goals SET deleted_at=?, version=?, updated_at=? WHERE id=? AND user_id=?',
      [now, newVersion, now, id, userId],
    );

    syncService.recordChange(
      userId: userId,
      entityType: 'goal',
      entityId: id,
      action: 'delete',
      version: newVersion,
      payload: {'deleted': true},
      previousValues: Map<String, dynamic>.from(current),
    );

    return _json({'message': 'Meta eliminada', 'version': newVersion});
  }

  // ==========================================
  // DECISIONS & REVIEWS
  // ==========================================

  Future<Response> _createDecision(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final action = (b['action'] ?? '').toString();
    if (action.isEmpty) return _json({'message': 'Seleccioná una decisión'}, status: 400);

    final id = b['id']?.toString() ?? _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final payload = {
      'action': action,
      'note': b['note'] ?? '',
      'created_at': now,
    };

    database.db.execute(
      'INSERT INTO decisions(id, user_id, action, note, created_at, version, updated_at, deleted_at) '
      'VALUES(?,?,?,?,?,1,?,NULL)',
      [id, userId, action, payload['note'], now, now],
    );

    syncService.recordChange(
      userId: userId,
      entityType: 'decision',
      entityId: id,
      action: 'create',
      version: 1,
      payload: payload,
    );

    return _json({'message': 'Decisión guardada', 'id': id, 'version': 1}, status: 201);
  }

  Future<Response> _reviews(Request request, String userId, [String? ignored]) async {
    final rows = database.db.select(
      'SELECT id, user_id, start_date, end_date, period_title, period_subtitle, transaction_ids, decision, decision_details, created_at, version, updated_at '
      'FROM reviews WHERE user_id=? AND deleted_at IS NULL ORDER BY created_at DESC',
      [userId],
    );

    return _json([
      for (final r in rows)
        {
          'id': r['id'],
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
    final payload = {
      'start': b['start'] ?? now,
      'end': b['end'] ?? now,
      'periodTitle': b['periodTitle'] ?? '',
      'periodSubtitle': b['periodSubtitle'] ?? '',
      'transactionIds': b['transactionIds'] ?? [],
      'decision': b['decision'] ?? 'Mantener mi plan',
      'decisionDetails': b['decisionDetails'] ?? {},
      'createdAt': b['createdAt'] ?? now,
    };

    database.db.execute(
      'INSERT INTO reviews(id, user_id, start_date, end_date, period_title, period_subtitle, transaction_ids, decision, decision_details, created_at, version, updated_at, deleted_at) '
      'VALUES(?,?,?,?,?,?,?,?,?,?,1,?,NULL)',
      [
        id,
        userId,
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

    syncService.recordChange(
      userId: userId,
      entityType: 'review',
      entityId: id,
      action: 'create',
      version: 1,
      payload: payload,
    );

    return _json({'message': 'Revisión guardada', 'id': id, 'version': 1}, status: 201);
  }

  // ==========================================
  // SYNC ENGINE ENDPOINTS
  // ==========================================

  Future<Response> _syncPush(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final deviceId = b['device_id']?.toString();
    final operationsRaw = b['operations'] as List? ?? [];
    final operations = operationsRaw.map((e) => Map<String, dynamic>.from(e as Map)).toList();

    final result = syncService.processPush(
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

    final result = syncService.pullChanges(
      userId: userId,
      cursor: cursor,
      limit: limit,
    );

    return _json(result);
  }

  Future<Response> _syncStatus(Request request, String userId, [String? ignored]) async {
    final status = syncService.getStatus(userId);
    return _json(status);
  }

  Future<Response> _syncConflicts(Request request, String userId, [String? ignored]) async {
    final conflicts = syncService.getConflicts(userId);
    return _json({'conflicts': conflicts});
  }

  Future<Response> _resolveConflict(Request request, String userId, String conflictId) async {
    final b = await _body(request);
    final strategy = (b['strategy'] ?? 'client_wins').toString();
    final merged = b['merged_payload'] != null ? Map<String, dynamic>.from(b['merged_payload'] as Map) : null;

    final result = syncService.resolveConflict(
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

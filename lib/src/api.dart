import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';
import 'database.dart';

class Api {
  final AppDatabase database;
  final _uuid = const Uuid();
  Api(this.database);

  Router get router {
    final r = Router();
    r.options('/<ignored|.*>', (_) => Response.ok(''));
    r.get('/api/health', (_) => _json({'ok': true}));
    r.post('/api/auth/login', _login);
    r.post('/api/auth/register', _register);
    r.post('/api/auth/logout', _auth(_logout));

    r.get('/api/dashboard', _auth(_dashboard));

    r.get('/api/transactions', _auth(_transactions));
    r.post('/api/transactions', _auth(_createTransaction));
    r.put('/api/transactions/<id>', _auth(_updateTransaction));
    r.delete('/api/transactions/<id>', _auth(_deleteTransaction));

    r.get('/api/commitments', _auth(_commitments));
    r.post('/api/commitments', _auth(_createCommitment));
    r.put('/api/commitments/<id>', _auth(_updateCommitment));
    r.delete('/api/commitments/<id>', _auth(_deleteCommitment));

    r.get('/api/goals', _auth(_goals));
    r.post('/api/goals', _auth(_createGoal));
    r.put('/api/goals/<id>', _auth(_updateGoal));
    r.delete('/api/goals/<id>', _auth(_deleteGoal));

    r.post('/api/decisions', _auth(_createDecision));
    return r;
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
      final userId = database.userIdFromToken(_token(request));
      if (userId == null) return _json({'message': 'No autorizado'}, status: 401);
      final route = request.url.pathSegments;
      if (route.isNotEmpty && (route.last != 'transactions' && route.last != 'commitments' && route.last != 'goals')) {
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
      'SELECT id,name,email FROM users WHERE email=? AND password_hash=?',
      [email, database.hash(password)],
    );
    if (rows.isEmpty) return _json({'message': 'Credenciales inválidas'}, status: 401);
    final token = _uuid.v4();
    database.db.execute(
      'INSERT INTO sessions(token,user_id,created_at) VALUES(?,?,?)',
      [token, rows.first['id'], DateTime.now().toIso8601String()],
    );
    return _json({
      'token': token,
      'user': {'id': rows.first['id'], 'name': rows.first['name'], 'email': rows.first['email']}
    });
  }

  Future<Response> _register(Request request) async {
    final b = await _body(request);
    final name = (b['name'] ?? '').toString().trim();
    final email = (b['email'] ?? '').toString().trim().toLowerCase();
    final password = (b['password'] ?? '').toString();
    if (name.isEmpty || !email.contains('@') || password.length < 6) {
      return _json({'message': 'Datos inválidos'}, status: 400);
    }
    if (database.db.select('SELECT id FROM users WHERE email=?', [email]).isNotEmpty) {
      return _json({'message': 'El correo ya existe'}, status: 409);
    }
    final id = _uuid.v4();
    database.db.execute(
      'INSERT INTO users(id,name,email,password_hash,opening_balance,created_at) VALUES(?,?,?,?,?,?)',
      [id, name, email, database.hash(password), 0.0, DateTime.now().toIso8601String()],
    );
    return _json({'message': 'Cuenta creada'}, status: 201);
  }

  Future<Response> _logout(Request request, String userId, [String? ignored]) async {
    database.db.execute('DELETE FROM sessions WHERE token=?', [_token(request)]);
    return _json({'message': 'Sesión cerrada'});
  }

  Future<Response> _dashboard(Request request, String userId, [String? ignored]) async {
    final user = database.db.select('SELECT opening_balance FROM users WHERE id=?', [userId]).first;
    final income = _sum("SELECT COALESCE(SUM(amount),0) total FROM transactions WHERE user_id=? AND type='income'", userId);
    final expenses = _sum("SELECT COALESCE(SUM(amount),0) total FROM transactions WHERE user_id=? AND type='expense'", userId);
    final committed = _sum("SELECT COALESCE(SUM(amount),0) total FROM commitments WHERE user_id=? AND status='pending'", userId);
    final saved = _sum('SELECT COALESCE(SUM(saved_amount),0) total FROM goals WHERE user_id=?', userId);
    final balance = (user['opening_balance'] as num).toDouble() + income - expenses;
    final categories = database.db.select(
      "SELECT category,SUM(amount) total FROM transactions WHERE user_id=? AND type='expense' GROUP BY category ORDER BY total DESC",
      [userId],
    );
    return _json({
      'balance': balance,
      'committed': committed,
      'saved': saved,
      'available': balance - committed - saved,
      'byCategory': [for (final r in categories) {'category': r['category'], 'total': r['total']}],
    });
  }

  double _sum(String sql, String userId) => (database.db.select(sql, [userId]).first['total'] as num).toDouble();
  double _amount(dynamic v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0;

  Future<Response> _transactions(Request request, String userId, [String? ignored]) async {
    final rows = database.db.select('SELECT * FROM transactions WHERE user_id=? ORDER BY date DESC', [userId]);
    return _json([for (final r in rows) Map<String, Object?>.from(r)]);
  }

  Future<Response> _createTransaction(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final amount = _amount(b['amount']);
    if (amount <= 0) return _json({'message': 'El monto debe ser mayor a ₡0'}, status: 400);
    final id = _uuid.v4();
    database.db.execute(
      'INSERT INTO transactions(id,user_id,type,category,amount,description,date,recognized) VALUES(?,?,?,?,?,?,?,?)',
      [id, userId, b['type'] ?? 'expense', b['category'] ?? 'Otros', amount, b['description'] ?? '', b['date'] ?? DateTime.now().toIso8601String(), (b['recognized'] ?? true) == true ? 1 : 0],
    );
    return _json({'id': id}, status: 201);
  }

  Future<Response> _updateTransaction(Request request, String userId, String id) async {
    final b = await _body(request);
    final amount = _amount(b['amount']);
    if (amount <= 0) return _json({'message': 'El monto debe ser mayor a ₡0'}, status: 400);
    database.db.execute(
      'UPDATE transactions SET type=?,category=?,amount=?,description=?,date=?,recognized=? WHERE id=? AND user_id=?',
      [b['type'] ?? 'expense', b['category'] ?? 'Otros', amount, b['description'] ?? '', b['date'] ?? DateTime.now().toIso8601String(), (b['recognized'] ?? true) == true ? 1 : 0, id, userId],
    );
    return _json({'message': 'Movimiento actualizado'});
  }

  Future<Response> _deleteTransaction(Request request, String userId, String id) async {
    database.db.execute('DELETE FROM transactions WHERE id=? AND user_id=?', [id, userId]);
    return _json({'message': 'Movimiento eliminado'});
  }

  Future<Response> _commitments(Request request, String userId, [String? ignored]) async {
    final rows = database.db.select('SELECT * FROM commitments WHERE user_id=? ORDER BY due_date', [userId]);
    return _json([for (final r in rows) Map<String, Object?>.from(r)]);
  }

  Future<Response> _createCommitment(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final amount = _amount(b['amount']);
    if (amount <= 0) return _json({'message': 'Monto inválido'}, status: 400);
    final id = _uuid.v4();
    database.db.execute(
      'INSERT INTO commitments(id,user_id,title,amount,due_date,status) VALUES(?,?,?,?,?,?)',
      [id, userId, b['title'] ?? 'Compromiso', amount, b['dueDate'] ?? DateTime.now().toIso8601String(), b['status'] ?? 'pending'],
    );
    return _json({'id': id}, status: 201);
  }

  Future<Response> _updateCommitment(Request request, String userId, String id) async {
    final b = await _body(request);
    database.db.execute(
      'UPDATE commitments SET title=?,amount=?,due_date=?,status=? WHERE id=? AND user_id=?',
      [b['title'] ?? '', _amount(b['amount']), b['dueDate'] ?? DateTime.now().toIso8601String(), b['status'] ?? 'pending', id, userId],
    );
    return _json({'message': 'Compromiso actualizado'});
  }

  Future<Response> _deleteCommitment(Request request, String userId, String id) async {
    database.db.execute('DELETE FROM commitments WHERE id=? AND user_id=?', [id, userId]);
    return _json({'message': 'Compromiso eliminado'});
  }

  Future<Response> _goals(Request request, String userId, [String? ignored]) async {
    final rows = database.db.select('SELECT * FROM goals WHERE user_id=? ORDER BY title', [userId]);
    return _json([for (final r in rows) Map<String, Object?>.from(r)]);
  }

  Future<Response> _createGoal(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final id = _uuid.v4();
    database.db.execute(
      'INSERT INTO goals(id,user_id,title,target_amount,saved_amount) VALUES(?,?,?,?,?)',
      [id, userId, b['title'] ?? 'Meta', _amount(b['targetAmount']), _amount(b['savedAmount'])],
    );
    return _json({'id': id}, status: 201);
  }

  Future<Response> _updateGoal(Request request, String userId, String id) async {
    final b = await _body(request);
    database.db.execute(
      'UPDATE goals SET title=?,target_amount=?,saved_amount=? WHERE id=? AND user_id=?',
      [b['title'] ?? '', _amount(b['targetAmount']), _amount(b['savedAmount']), id, userId],
    );
    return _json({'message': 'Meta actualizada'});
  }

  Future<Response> _deleteGoal(Request request, String userId, String id) async {
    database.db.execute('DELETE FROM goals WHERE id=? AND user_id=?', [id, userId]);
    return _json({'message': 'Meta eliminada'});
  }

  Future<Response> _createDecision(Request request, String userId, [String? ignored]) async {
    final b = await _body(request);
    final action = (b['action'] ?? '').toString();
    if (action.isEmpty) return _json({'message': 'Seleccioná una decisión'}, status: 400);
    database.db.execute(
      'INSERT INTO decisions(id,user_id,action,note,created_at) VALUES(?,?,?,?,?)',
      [_uuid.v4(), userId, action, b['note'] ?? '', DateTime.now().toIso8601String()],
    );
    return _json({'message': 'Decisión guardada'}, status: 201);
  }
}

import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'database.dart';

class SyncService {
  final AppDatabase database;
  final _uuid = const Uuid();

  SyncService(this.database);

  /// Synchronous push processing for SQLite local development and tests.
  Map<String, dynamic> processPush({
    required String userId,
    required String? deviceId,
    required List<Map<String, dynamic>> operations,
  }) {
    return _processPushSync(userId: userId, deviceId: deviceId, operations: operations);
  }

  /// Asynchronous push processing for PostgreSQL (Neon) and production.
  Future<Map<String, dynamic>> processPushAsync({
    required String userId,
    required String? deviceId,
    required List<Map<String, dynamic>> operations,
  }) async {
    if (database.isPostgres) {
      return await _processPushAsync(userId: userId, deviceId: deviceId, operations: operations);
    }
    return _processPushSync(userId: userId, deviceId: deviceId, operations: operations);
  }

  Map<String, dynamic> _processPushSync({
    required String userId,
    required String? deviceId,
    required List<Map<String, dynamic>> operations,
  }) {
    final results = <Map<String, dynamic>>[];
    final db = database.db;

    for (final op in operations) {
      final opId = op['operation_id']?.toString() ?? '';
      final entityType = op['entity_type']?.toString().toLowerCase() ?? '';
      final entityId = op['entity_id']?.toString() ?? '';
      final action = op['action']?.toString().toLowerCase() ?? '';
      final payload = Map<String, dynamic>.from(op['payload'] as Map? ?? {});
      final baseVersion = (op['base_version'] as num?)?.toInt() ?? 1;
      final clientTimestamp = op['created_at']?.toString() ?? DateTime.now().toIso8601String();

      if (opId.isEmpty || entityType.isEmpty || entityId.isEmpty || action.isEmpty) {
        results.add({
          'operation_id': opId,
          'status': 'error',
          'message': 'Campos de operación incompletos',
        });
        continue;
      }

      // 1. Idempotency check
      final existingKey = db.select(
        'SELECT response_code, response_body FROM idempotency_keys WHERE operation_id=? AND user_id=?',
        [opId, userId],
      );

      if (existingKey.isNotEmpty) {
        final cached = jsonDecode(existingKey.first['response_body'] as String);
        results.add(Map<String, dynamic>.from(cached as Map));
        continue;
      }

      // 2. Process operation within database transaction
      db.execute('BEGIN TRANSACTION');
      try {
        final opResult = _applyOperationSync(
          userId: userId,
          deviceId: deviceId,
          opId: opId,
          entityType: entityType,
          entityId: entityId,
          action: action,
          payload: payload,
          baseVersion: baseVersion,
          clientTimestamp: clientTimestamp,
        );

        db.execute(
          'INSERT INTO idempotency_keys(operation_id, user_id, action, entity_type, entity_id, response_code, response_body, created_at) '
          'VALUES(?,?,?,?,?,?,?,?)',
          [
            opId,
            userId,
            action,
            entityType,
            entityId,
            200,
            jsonEncode(opResult),
            DateTime.now().toIso8601String(),
          ],
        );

        db.execute('COMMIT');
        results.add(opResult);
      } catch (e) {
        db.execute('ROLLBACK');
        results.add({
          'operation_id': opId,
          'status': 'error',
          'message': 'Error al procesar operación: $e',
        });
      }
    }

    final latestSeq = getLatestSequence(userId);

    return {
      'processed': results,
      'server_cursor': latestSeq,
      'server_time': DateTime.now().toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> _processPushAsync({
    required String userId,
    required String? deviceId,
    required List<Map<String, dynamic>> operations,
  }) async {
    final results = <Map<String, dynamic>>[];

    for (final op in operations) {
      final opId = op['operation_id']?.toString() ?? '';
      final entityType = op['entity_type']?.toString().toLowerCase() ?? '';
      final entityId = op['entity_id']?.toString() ?? '';
      final action = op['action']?.toString().toLowerCase() ?? '';
      final payload = Map<String, dynamic>.from(op['payload'] as Map? ?? {});
      final baseVersion = (op['base_version'] as num?)?.toInt() ?? 1;
      final clientTimestamp = op['created_at']?.toString() ?? DateTime.now().toIso8601String();

      if (opId.isEmpty || entityType.isEmpty || entityId.isEmpty || action.isEmpty) {
        results.add({
          'operation_id': opId,
          'status': 'error',
          'message': 'Campos de operación incompletos',
        });
        continue;
      }

      // 1. Idempotency check
      final existingKey = await database.query(
        'SELECT response_code, response_body FROM idempotency_keys WHERE operation_id=? AND user_id=?',
        [opId, userId],
      );

      if (existingKey.isNotEmpty) {
        final cached = jsonDecode(existingKey.first['response_body'] as String);
        results.add(Map<String, dynamic>.from(cached as Map));
        continue;
      }

      // 2. Process operation within transaction
      try {
        final opResult = await database.transaction((tx) async {
          final res = await _applyOperationAsync(
            tx: tx,
            userId: userId,
            deviceId: deviceId,
            opId: opId,
            entityType: entityType,
            entityId: entityId,
            action: action,
            payload: payload,
            baseVersion: baseVersion,
            clientTimestamp: clientTimestamp,
          );

          await tx.execute(
            'INSERT INTO idempotency_keys(operation_id, user_id, action, entity_type, entity_id, response_code, response_body, created_at) '
            'VALUES(?,?,?,?,?,?,?,?)',
            [
              opId,
              userId,
              action,
              entityType,
              entityId,
              200,
              jsonEncode(res),
              DateTime.now().toIso8601String(),
            ],
          );

          return res;
        });

        results.add(opResult);
      } catch (e) {
        results.add({
          'operation_id': opId,
          'status': 'error',
          'message': 'Error al procesar operación: $e',
        });
      }
    }

    final latestSeq = await getLatestSequenceAsync(userId);

    return {
      'processed': results,
      'server_cursor': latestSeq,
      'server_time': DateTime.now().toIso8601String(),
    };
  }

  Map<String, dynamic> _applyOperationSync({
    required String userId,
    required String? deviceId,
    required String opId,
    required String entityType,
    required String entityId,
    required String action,
    required Map<String, dynamic> payload,
    required int baseVersion,
    required String clientTimestamp,
  }) {
    final now = DateTime.now().toIso8601String();
    final tableName = _tableNameFor(entityType);
    final db = database.db;

    if (tableName == null) {
      return {
        'operation_id': opId,
        'status': 'error',
        'message': 'Tipo de entidad no soportado: $entityType',
      };
    }

    final existingRows = db.select(
      'SELECT * FROM $tableName WHERE id=? AND user_id=?',
      [entityId, userId],
    );

    if (action == 'create') {
      if (existingRows.isNotEmpty) {
        final existing = existingRows.first;
        if (existing['deleted_at'] == null) {
          return {
            'operation_id': opId,
            'status': 'applied',
            'entity_type': entityType,
            'entity_id': entityId,
            'version': existing['version'] ?? 1,
            'note': 'Entidad ya existía previamente',
          };
        }
      }

      _insertEntitySync(tableName, entityId, userId, payload, version: 1, now: now);
      _recordSyncLogSync(userId, entityType, entityId, 'create', 1, payload, now);
      _recordAuditLogSync(userId, entityType, entityId, 'create', null, payload, deviceId, clientTimestamp, now);

      return {
        'operation_id': opId,
        'status': 'applied',
        'entity_type': entityType,
        'entity_id': entityId,
        'version': 1,
      };
    } else if (action == 'update') {
      if (existingRows.isEmpty || existingRows.first['deleted_at'] != null) {
        return {
          'operation_id': opId,
          'status': 'error',
          'message': 'No se encontró la entidad para actualizar o fue eliminada',
        };
      }

      final existing = existingRows.first;
      final serverVersion = (existing['version'] as num?)?.toInt() ?? 1;

      if (serverVersion != baseVersion) {
        final conflictId = _uuid.v4();
        final serverPayload = Map<String, dynamic>.from(existing);

        db.execute(
          'INSERT INTO sync_conflicts(id, user_id, entity_type, entity_id, client_version, server_version, client_payload, server_payload, status, created_at) '
          'VALUES(?,?,?,?,?,?,?,?,?,?)',
          [
            conflictId,
            userId,
            entityType,
            entityId,
            baseVersion,
            serverVersion,
            jsonEncode(payload),
            jsonEncode(serverPayload),
            'unresolved',
            now,
          ],
        );

        return {
          'operation_id': opId,
          'status': 'conflict',
          'conflict_id': conflictId,
          'entity_type': entityType,
          'entity_id': entityId,
          'base_version': baseVersion,
          'server_version': serverVersion,
          'server_payload': serverPayload,
        };
      }

      final newVersion = serverVersion + 1;
      _updateEntitySync(tableName, entityId, userId, payload, version: newVersion, now: now);
      _recordSyncLogSync(userId, entityType, entityId, 'update', newVersion, payload, now);
      _recordAuditLogSync(userId, entityType, entityId, 'update', Map<String, dynamic>.from(existing), payload, deviceId, clientTimestamp, now);

      return {
        'operation_id': opId,
        'status': 'applied',
        'entity_type': entityType,
        'entity_id': entityId,
        'version': newVersion,
      };
    } else if (action == 'delete') {
      if (existingRows.isEmpty) {
        return {
          'operation_id': opId,
          'status': 'applied',
          'entity_type': entityType,
          'entity_id': entityId,
          'version': 0,
          'note': 'Ya no existe en servidor',
        };
      }

      final existing = existingRows.first;
      if (existing['deleted_at'] != null) {
        return {
          'operation_id': opId,
          'status': 'applied',
          'entity_type': entityType,
          'entity_id': entityId,
          'version': existing['version'] ?? 1,
          'note': 'Ya estaba eliminada',
        };
      }

      final serverVersion = (existing['version'] as num?)?.toInt() ?? 1;
      final newVersion = serverVersion + 1;

      db.execute(
        'UPDATE $tableName SET deleted_at=?, version=?, updated_at=? WHERE id=? AND user_id=?',
        [now, newVersion, now, entityId, userId],
      );

      _recordSyncLogSync(userId, entityType, entityId, 'delete', newVersion, {'deleted': true}, now);
      _recordAuditLogSync(userId, entityType, entityId, 'delete', Map<String, dynamic>.from(existing), {'deleted': true}, deviceId, clientTimestamp, now);

      return {
        'operation_id': opId,
        'status': 'applied',
        'entity_type': entityType,
        'entity_id': entityId,
        'version': newVersion,
      };
    }

    return {
      'operation_id': opId,
      'status': 'error',
      'message': 'Acción no reconocida: $action',
    };
  }

  Future<Map<String, dynamic>> _applyOperationAsync({
    required DatabaseExecutor tx,
    required String userId,
    required String? deviceId,
    required String opId,
    required String entityType,
    required String entityId,
    required String action,
    required Map<String, dynamic> payload,
    required int baseVersion,
    required String clientTimestamp,
  }) async {
    final now = DateTime.now().toIso8601String();
    final tableName = _tableNameFor(entityType);

    if (tableName == null) {
      return {
        'operation_id': opId,
        'status': 'error',
        'message': 'Tipo de entidad no soportado: $entityType',
      };
    }

    final existingRows = await tx.query(
      'SELECT * FROM $tableName WHERE id=? AND user_id=?',
      [entityId, userId],
    );

    if (action == 'create') {
      if (existingRows.isNotEmpty) {
        final existing = existingRows.first;
        if (existing['deleted_at'] == null) {
          return {
            'operation_id': opId,
            'status': 'applied',
            'entity_type': entityType,
            'entity_id': entityId,
            'version': existing['version'] ?? 1,
            'note': 'Entidad ya existía previamente',
          };
        }
      }

      await _insertEntityAsync(tx, tableName, entityId, userId, payload, version: 1, now: now);
      await _recordSyncLogAsync(tx, userId, entityType, entityId, 'create', 1, payload, now);
      await _recordAuditLogAsync(tx, userId, entityType, entityId, 'create', null, payload, deviceId, clientTimestamp, now);

      return {
        'operation_id': opId,
        'status': 'applied',
        'entity_type': entityType,
        'entity_id': entityId,
        'version': 1,
      };
    } else if (action == 'update') {
      if (existingRows.isEmpty || existingRows.first['deleted_at'] != null) {
        return {
          'operation_id': opId,
          'status': 'error',
          'message': 'No se encontró la entidad para actualizar o fue eliminada',
        };
      }

      final existing = existingRows.first;
      final serverVersion = (existing['version'] as num?)?.toInt() ?? 1;

      if (serverVersion != baseVersion) {
        final conflictId = _uuid.v4();
        final serverPayload = Map<String, dynamic>.from(existing);

        await tx.execute(
          'INSERT INTO sync_conflicts(id, user_id, entity_type, entity_id, client_version, server_version, client_payload, server_payload, status, created_at) '
          'VALUES(?,?,?,?,?,?,?,?,?,?)',
          [
            conflictId,
            userId,
            entityType,
            entityId,
            baseVersion,
            serverVersion,
            jsonEncode(payload),
            jsonEncode(serverPayload),
            'unresolved',
            now,
          ],
        );

        return {
          'operation_id': opId,
          'status': 'conflict',
          'conflict_id': conflictId,
          'entity_type': entityType,
          'entity_id': entityId,
          'base_version': baseVersion,
          'server_version': serverVersion,
          'server_payload': serverPayload,
        };
      }

      final newVersion = serverVersion + 1;
      await _updateEntityAsync(tx, tableName, entityId, userId, payload, version: newVersion, now: now);
      await _recordSyncLogAsync(tx, userId, entityType, entityId, 'update', newVersion, payload, now);
      await _recordAuditLogAsync(tx, userId, entityType, entityId, 'update', Map<String, dynamic>.from(existing), payload, deviceId, clientTimestamp, now);

      return {
        'operation_id': opId,
        'status': 'applied',
        'entity_type': entityType,
        'entity_id': entityId,
        'version': newVersion,
      };
    } else if (action == 'delete') {
      if (existingRows.isEmpty) {
        return {
          'operation_id': opId,
          'status': 'applied',
          'entity_type': entityType,
          'entity_id': entityId,
          'version': 0,
          'note': 'Ya no existe en servidor',
        };
      }

      final existing = existingRows.first;
      if (existing['deleted_at'] != null) {
        return {
          'operation_id': opId,
          'status': 'applied',
          'entity_type': entityType,
          'entity_id': entityId,
          'version': existing['version'] ?? 1,
          'note': 'Ya estaba eliminada',
        };
      }

      final serverVersion = (existing['version'] as num?)?.toInt() ?? 1;
      final newVersion = serverVersion + 1;

      await tx.execute(
        'UPDATE $tableName SET deleted_at=?, version=?, updated_at=? WHERE id=? AND user_id=?',
        [now, newVersion, now, entityId, userId],
      );

      await _recordSyncLogAsync(tx, userId, entityType, entityId, 'delete', newVersion, {'deleted': true}, now);
      await _recordAuditLogAsync(tx, userId, entityType, entityId, 'delete', Map<String, dynamic>.from(existing), {'deleted': true}, deviceId, clientTimestamp, now);

      return {
        'operation_id': opId,
        'status': 'applied',
        'entity_type': entityType,
        'entity_id': entityId,
        'version': newVersion,
      };
    }

    return {
      'operation_id': opId,
      'status': 'error',
      'message': 'Acción no reconocida: $action',
    };
  }

  /// Pulls changes that occurred after a given sequence cursor (Sync).
  Map<String, dynamic> pullChanges({
    required String userId,
    required int cursor,
    int limit = 200,
  }) {
    return _pullChangesSync(userId: userId, cursor: cursor, limit: limit);
  }

  /// Pulls changes that occurred after a given sequence cursor (Async).
  Future<Map<String, dynamic>> pullChangesAsync({
    required String userId,
    required int cursor,
    int limit = 200,
  }) async {
    if (database.isPostgres) {
      return await _pullChangesAsync(userId: userId, cursor: cursor, limit: limit);
    }
    return _pullChangesSync(userId: userId, cursor: cursor, limit: limit);
  }

  Map<String, dynamic> _pullChangesSync({
    required String userId,
    required int cursor,
    int limit = 200,
  }) {
    final rows = database.db.select(
      'SELECT sequence, entity_type, entity_id, action, version, payload, created_at '
      'FROM sync_log '
      'WHERE user_id=? AND sequence > ? '
      'ORDER BY sequence ASC LIMIT ?',
      [userId, cursor, limit + 1],
    );

    final hasMore = rows.length > limit;
    final changesList = rows.take(limit).map<Map<String, dynamic>>((r) {
      dynamic decodedPayload;
      try {
        decodedPayload = jsonDecode(r['payload'] as String);
      } catch (_) {
        decodedPayload = {};
      }

      return {
        'sequence': r['sequence'],
        'entity_type': r['entity_type'],
        'entity_id': r['entity_id'],
        'action': r['action'],
        'version': r['version'],
        'payload': decodedPayload,
        'created_at': r['created_at'],
      };
    }).toList();

    final nextCursor = changesList.isNotEmpty
        ? (changesList.last['sequence'] as num).toInt()
        : cursor;

    return {
      'changes': changesList,
      'cursor': nextCursor,
      'has_more': hasMore,
      'server_time': DateTime.now().toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> _pullChangesAsync({
    required String userId,
    required int cursor,
    int limit = 200,
  }) async {
    final rows = await database.query(
      'SELECT sequence, entity_type, entity_id, action, version, payload, created_at '
      'FROM sync_log '
      'WHERE user_id=? AND sequence > ? '
      'ORDER BY sequence ASC LIMIT ?',
      [userId, cursor, limit + 1],
    );

    final hasMore = rows.length > limit;
    final changesList = rows.take(limit).map<Map<String, dynamic>>((r) {
      dynamic decodedPayload;
      try {
        decodedPayload = jsonDecode(r['payload'] as String);
      } catch (_) {
        decodedPayload = {};
      }

      return {
        'sequence': r['sequence'],
        'entity_type': r['entity_type'],
        'entity_id': r['entity_id'],
        'action': r['action'],
        'version': r['version'],
        'payload': decodedPayload,
        'created_at': r['created_at'],
      };
    }).toList();

    final nextCursor = changesList.isNotEmpty
        ? (changesList.last['sequence'] as num).toInt()
        : cursor;

    return {
      'changes': changesList,
      'cursor': nextCursor,
      'has_more': hasMore,
      'server_time': DateTime.now().toIso8601String(),
    };
  }

  /// Returns sync status including server cursor and pending conflicts (Sync).
  Map<String, dynamic> getStatus(String userId) {
    return _getStatusSync(userId);
  }

  /// Returns sync status including server cursor and pending conflicts (Async).
  Future<Map<String, dynamic>> getStatusAsync(String userId) async {
    if (database.isPostgres) {
      return await _getStatusAsync(userId);
    }
    return _getStatusSync(userId);
  }

  Map<String, dynamic> _getStatusSync(String userId) {
    final latestSeq = getLatestSequence(userId);
    final conflicts = database.db.select(
      "SELECT COUNT(*) total FROM sync_conflicts WHERE user_id=? AND status='unresolved'",
      [userId],
    );
    final conflictCount = (conflicts.first['total'] as num).toInt();

    return {
      'server_cursor': latestSeq,
      'unresolved_conflicts': conflictCount,
      'server_time': DateTime.now().toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> _getStatusAsync(String userId) async {
    final latestSeq = await getLatestSequenceAsync(userId);
    final conflicts = await database.query(
      "SELECT COUNT(*) total FROM sync_conflicts WHERE user_id=? AND status='unresolved'",
      [userId],
    );
    final conflictCount = (conflicts.first['total'] as num).toInt();

    return {
      'server_cursor': latestSeq,
      'unresolved_conflicts': conflictCount,
      'server_time': DateTime.now().toIso8601String(),
    };
  }

  /// Lists unresolved conflicts for a user (Sync).
  List<Map<String, dynamic>> getConflicts(String userId) {
    return _getConflictsSync(userId);
  }

  /// Lists unresolved conflicts for a user (Async).
  Future<List<Map<String, dynamic>>> getConflictsAsync(String userId) async {
    if (database.isPostgres) {
      return await _getConflictsAsync(userId);
    }
    return _getConflictsSync(userId);
  }

  List<Map<String, dynamic>> _getConflictsSync(String userId) {
    final rows = database.db.select(
      "SELECT * FROM sync_conflicts WHERE user_id=? AND status='unresolved' ORDER BY created_at DESC",
      [userId],
    );

    return rows.map<Map<String, dynamic>>((r) => _mapConflict(r)).toList();
  }

  Future<List<Map<String, dynamic>>> _getConflictsAsync(String userId) async {
    final rows = await database.query(
      "SELECT * FROM sync_conflicts WHERE user_id=? AND status='unresolved' ORDER BY created_at DESC",
      [userId],
    );

    return rows.map<Map<String, dynamic>>((r) => _mapConflict(r)).toList();
  }

  Map<String, dynamic> _mapConflict(Map<dynamic, dynamic> r) {
    dynamic clientPayload;
    dynamic serverPayload;
    try {
      clientPayload = jsonDecode(r['client_payload'] as String);
    } catch (_) {
      clientPayload = {};
    }
    try {
      serverPayload = jsonDecode(r['server_payload'] as String);
    } catch (_) {
      serverPayload = {};
    }

    return {
      'id': r['id'],
      'entity_type': r['entity_type'],
      'entity_id': r['entity_id'],
      'client_version': r['client_version'],
      'server_version': r['server_version'],
      'client_payload': clientPayload,
      'server_payload': serverPayload,
      'status': r['status'],
      'created_at': r['created_at'],
    };
  }

  /// Resolves a conflict using specified strategy (Sync).
  Map<String, dynamic> resolveConflict({
    required String userId,
    required String conflictId,
    required String strategy,
    Map<String, dynamic>? mergedPayload,
  }) {
    return _resolveConflictSync(userId: userId, conflictId: conflictId, strategy: strategy, mergedPayload: mergedPayload);
  }

  /// Resolves a conflict using specified strategy (Async).
  Future<Map<String, dynamic>> resolveConflictAsync({
    required String userId,
    required String conflictId,
    required String strategy,
    Map<String, dynamic>? mergedPayload,
  }) async {
    if (database.isPostgres) {
      return await _resolveConflictAsync(userId: userId, conflictId: conflictId, strategy: strategy, mergedPayload: mergedPayload);
    }
    return _resolveConflictSync(userId: userId, conflictId: conflictId, strategy: strategy, mergedPayload: mergedPayload);
  }

  Map<String, dynamic> _resolveConflictSync({
    required String userId,
    required String conflictId,
    required String strategy,
    Map<String, dynamic>? mergedPayload,
  }) {
    final db = database.db;
    final rows = db.select(
      "SELECT * FROM sync_conflicts WHERE id=? AND user_id=? AND status='unresolved'",
      [conflictId, userId],
    );

    if (rows.isEmpty) {
      return {'ok': false, 'message': 'Conflicto no encontrado o ya resuelto'};
    }

    final conflict = rows.first;
    final entityType = conflict['entity_type'] as String;
    final entityId = conflict['entity_id'] as String;
    final tableName = _tableNameFor(entityType);
    final now = DateTime.now().toIso8601String();

    if (tableName == null) {
      return {'ok': false, 'message': 'Entidad no válida'};
    }

    final currentRows = db.select(
      'SELECT version FROM $tableName WHERE id=? AND user_id=?',
      [entityId, userId],
    );
    final currentVersion = currentRows.isNotEmpty ? (currentRows.first['version'] as num).toInt() : 1;
    final newVersion = currentVersion + 1;

    db.execute('BEGIN TRANSACTION');
    try {
      if (strategy == 'client_wins') {
        final clientPayload = Map<String, dynamic>.from(jsonDecode(conflict['client_payload'] as String) as Map);
        _updateEntitySync(tableName, entityId, userId, clientPayload, version: newVersion, now: now);
        _recordSyncLogSync(userId, entityType, entityId, 'update', newVersion, clientPayload, now);
      } else if (strategy == 'merge' && mergedPayload != null) {
        _updateEntitySync(tableName, entityId, userId, mergedPayload, version: newVersion, now: now);
        _recordSyncLogSync(userId, entityType, entityId, 'update', newVersion, mergedPayload, now);
      }

      db.execute(
        'UPDATE sync_conflicts SET status=?, resolved_at=? WHERE id=?',
        ['resolved_$strategy', now, conflictId],
      );

      db.execute('COMMIT');
      return {'ok': true, 'strategy': strategy, 'version': newVersion};
    } catch (e) {
      db.execute('ROLLBACK');
      return {'ok': false, 'message': 'Error al resolver conflicto: $e'};
    }
  }

  Future<Map<String, dynamic>> _resolveConflictAsync({
    required String userId,
    required String conflictId,
    required String strategy,
    Map<String, dynamic>? mergedPayload,
  }) async {
    final rows = await database.query(
      "SELECT * FROM sync_conflicts WHERE id=? AND user_id=? AND status='unresolved'",
      [conflictId, userId],
    );

    if (rows.isEmpty) {
      return {'ok': false, 'message': 'Conflicto no encontrado o ya resuelto'};
    }

    final conflict = rows.first;
    final entityType = conflict['entity_type'] as String;
    final entityId = conflict['entity_id'] as String;
    final tableName = _tableNameFor(entityType);
    final now = DateTime.now().toIso8601String();

    if (tableName == null) {
      return {'ok': false, 'message': 'Entidad no válida'};
    }

    return await database.transaction((tx) async {
      final currentRows = await tx.query(
        'SELECT version FROM $tableName WHERE id=? AND user_id=?',
        [entityId, userId],
      );
      final currentVersion = currentRows.isNotEmpty ? (currentRows.first['version'] as num).toInt() : 1;
      final newVersion = currentVersion + 1;

      if (strategy == 'client_wins') {
        final clientPayload = Map<String, dynamic>.from(jsonDecode(conflict['client_payload'] as String) as Map);
        await _updateEntityAsync(tx, tableName, entityId, userId, clientPayload, version: newVersion, now: now);
        await _recordSyncLogAsync(tx, userId, entityType, entityId, 'update', newVersion, clientPayload, now);
      } else if (strategy == 'merge' && mergedPayload != null) {
        await _updateEntityAsync(tx, tableName, entityId, userId, mergedPayload, version: newVersion, now: now);
        await _recordSyncLogAsync(tx, userId, entityType, entityId, 'update', newVersion, mergedPayload, now);
      }

      await tx.execute(
        'UPDATE sync_conflicts SET status=?, resolved_at=? WHERE id=?',
        ['resolved_$strategy', now, conflictId],
      );

      return {'ok': true, 'strategy': strategy, 'version': newVersion};
    });
  }

  int getLatestSequence(String userId) {
    final r = database.db.select(
      'SELECT COALESCE(MAX(sequence), 0) seq FROM sync_log WHERE user_id=?',
      [userId],
    );
    return (r.first['seq'] as num).toInt();
  }

  Future<int> getLatestSequenceAsync(String userId) async {
    if (database.isPostgres) {
      final r = await database.query(
        'SELECT COALESCE(MAX(sequence), 0) seq FROM sync_log WHERE user_id=?',
        [userId],
      );
      return (r.first['seq'] as num).toInt();
    }
    return getLatestSequence(userId);
  }

  void recordChange({
    required String userId,
    required String entityType,
    required String entityId,
    required String action,
    required int version,
    required Map<String, dynamic> payload,
    String? deviceId,
    Map<String, dynamic>? previousValues,
  }) {
    final now = DateTime.now().toIso8601String();
    if (database.isPostgres) {
      database.transaction((tx) async {
        await _recordSyncLogAsync(tx, userId, entityType, entityId, action, version, payload, now);
        await _recordAuditLogAsync(tx, userId, entityType, entityId, action, previousValues, payload, deviceId, now, now);
      });
      return;
    }
    _recordSyncLogSync(userId, entityType, entityId, action, version, payload, now);
    _recordAuditLogSync(userId, entityType, entityId, action, previousValues, payload, deviceId, now, now);
  }

  Future<void> recordChangeAsync({
    required String userId,
    required String entityType,
    required String entityId,
    required String action,
    required int version,
    required Map<String, dynamic> payload,
    String? deviceId,
    Map<String, dynamic>? previousValues,
  }) async {
    final now = DateTime.now().toIso8601String();
    if (database.isPostgres) {
      await database.transaction((tx) async {
        await _recordSyncLogAsync(tx, userId, entityType, entityId, action, version, payload, now);
        await _recordAuditLogAsync(tx, userId, entityType, entityId, action, previousValues, payload, deviceId, now, now);
      });
      return;
    }
    _recordSyncLogSync(userId, entityType, entityId, action, version, payload, now);
    _recordAuditLogSync(userId, entityType, entityId, action, previousValues, payload, deviceId, now, now);
  }

  void _recordSyncLogSync(
    String userId,
    String entityType,
    String entityId,
    String action,
    int version,
    Map<String, dynamic> payload,
    String timestamp,
  ) {
    database.db.execute(
      'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) '
      'VALUES(?,?,?,?,?,?,?)',
      [userId, entityType, entityId, action, version, jsonEncode(payload), timestamp],
    );
  }

  Future<void> _recordSyncLogAsync(
    DatabaseExecutor tx,
    String userId,
    String entityType,
    String entityId,
    String action,
    int version,
    Map<String, dynamic> payload,
    String timestamp,
  ) async {
    await tx.execute(
      'INSERT INTO sync_log(user_id, entity_type, entity_id, action, version, payload, created_at) '
      'VALUES(?,?,?,?,?,?,?)',
      [userId, entityType, entityId, action, version, jsonEncode(payload), timestamp],
    );
  }

  void _recordAuditLogSync(
    String userId,
    String entityType,
    String entityId,
    String action,
    Map<String, dynamic>? previousValues,
    Map<String, dynamic> newValues,
    String? deviceId,
    String clientTimestamp,
    String serverTimestamp,
  ) {
    final id = _uuid.v4();
    database.db.execute(
      'INSERT INTO audit_log(id, user_id, entity_type, entity_id, action, previous_values, new_values, device_id, client_timestamp, server_timestamp) '
      'VALUES(?,?,?,?,?,?,?,?,?,?)',
      [
        id,
        userId,
        entityType,
        entityId,
        action,
        previousValues != null ? jsonEncode(previousValues) : null,
        jsonEncode(newValues),
        deviceId,
        clientTimestamp,
        serverTimestamp,
      ],
    );
  }

  Future<void> _recordAuditLogAsync(
    DatabaseExecutor tx,
    String userId,
    String entityType,
    String entityId,
    String action,
    Map<String, dynamic>? previousValues,
    Map<String, dynamic> newValues,
    String? deviceId,
    String clientTimestamp,
    String serverTimestamp,
  ) async {
    final id = _uuid.v4();
    await tx.execute(
      'INSERT INTO audit_log(id, user_id, entity_type, entity_id, action, previous_values, new_values, device_id, client_timestamp, server_timestamp) '
      'VALUES(?,?,?,?,?,?,?,?,?,?)',
      [
        id,
        userId,
        entityType,
        entityId,
        action,
        previousValues != null ? jsonEncode(previousValues) : null,
        jsonEncode(newValues),
        deviceId,
        clientTimestamp,
        serverTimestamp,
      ],
    );
  }

  String? _tableNameFor(String entityType) {
    switch (entityType) {
      case 'transaction':
      case 'transactions':
        return 'transactions';
      case 'commitment':
      case 'commitments':
        return 'commitments';
      case 'goal':
      case 'goals':
        return 'goals';
      case 'decision':
      case 'decisions':
        return 'decisions';
      case 'review':
      case 'reviews':
        return 'reviews';
      case 'user':
      case 'users':
      case 'profile':
        return 'users';
      default:
        return null;
    }
  }

  void _insertEntitySync(
    String table,
    String id,
    String userId,
    Map<String, dynamic> payload, {
    required int version,
    required String now,
  }) {
    switch (table) {
      case 'transactions':
        database.db.execute(
          'INSERT INTO transactions(id, user_id, type, category, amount, description, date, recognized, version, updated_at, deleted_at) '
          'VALUES(?,?,?,?,?,?,?,?,?,?,NULL)',
          [
            id,
            userId,
            payload['type'] ?? 'expense',
            payload['category'] ?? 'Otros',
            (payload['amount'] as num?)?.toDouble() ?? 0.0,
            payload['description'] ?? '',
            payload['date'] ?? now,
            (payload['recognized'] ?? true) == true ? 1 : 0,
            version,
            now,
          ],
        );
        break;
      case 'commitments':
        database.db.execute(
          'INSERT INTO commitments(id, user_id, title, amount, due_date, status, version, updated_at, deleted_at) '
          'VALUES(?,?,?,?,?,?,?,?,NULL)',
          [
            id,
            userId,
            payload['title'] ?? 'Compromiso',
            (payload['amount'] as num?)?.toDouble() ?? 0.0,
            payload['dueDate'] ?? payload['due_date'] ?? now,
            payload['status'] ?? 'pending',
            version,
            now,
          ],
        );
        break;
      case 'goals':
        database.db.execute(
          'INSERT INTO goals(id, user_id, title, target_amount, saved_amount, version, updated_at, deleted_at) '
          'VALUES(?,?,?,?,?,?,?,NULL)',
          [
            id,
            userId,
            payload['title'] ?? 'Meta',
            (payload['targetAmount'] ?? payload['target_amount'] as num?)?.toDouble() ?? 0.0,
            (payload['savedAmount'] ?? payload['saved_amount'] as num?)?.toDouble() ?? 0.0,
            version,
            now,
          ],
        );
        break;
      case 'decisions':
        database.db.execute(
          'INSERT INTO decisions(id, user_id, action, note, created_at, version, updated_at, deleted_at) '
          'VALUES(?,?,?,?,?,?,?,NULL)',
          [
            id,
            userId,
            payload['action'] ?? '',
            payload['note'] ?? '',
            payload['created_at'] ?? now,
            version,
            now,
          ],
        );
        break;
      case 'reviews':
        database.db.execute(
          'INSERT INTO reviews(id, user_id, start_date, end_date, period_title, period_subtitle, transaction_ids, decision, decision_details, created_at, version, updated_at, deleted_at) '
          'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,NULL)',
          [
            id,
            userId,
            payload['start'] ?? now,
            payload['end'] ?? now,
            payload['periodTitle'] ?? '',
            payload['periodSubtitle'] ?? '',
            jsonEncode(payload['transactionIds'] ?? []),
            payload['decision'] ?? '',
            jsonEncode(payload['decisionDetails'] ?? {}),
            payload['createdAt'] ?? now,
            version,
            now,
          ],
        );
        break;
    }
  }

  Future<void> _insertEntityAsync(
    DatabaseExecutor tx,
    String table,
    String id,
    String userId,
    Map<String, dynamic> payload, {
    required int version,
    required String now,
  }) async {
    switch (table) {
      case 'transactions':
        await tx.execute(
          'INSERT INTO transactions(id, user_id, type, category, amount, description, date, recognized, version, updated_at, deleted_at) '
          'VALUES(?,?,?,?,?,?,?,?,?,?,NULL)',
          [
            id,
            userId,
            payload['type'] ?? 'expense',
            payload['category'] ?? 'Otros',
            (payload['amount'] as num?)?.toDouble() ?? 0.0,
            payload['description'] ?? '',
            payload['date'] ?? now,
            (payload['recognized'] ?? true) == true ? 1 : 0,
            version,
            now,
          ],
        );
        break;
      case 'commitments':
        await tx.execute(
          'INSERT INTO commitments(id, user_id, title, amount, due_date, status, version, updated_at, deleted_at) '
          'VALUES(?,?,?,?,?,?,?,?,NULL)',
          [
            id,
            userId,
            payload['title'] ?? 'Compromiso',
            (payload['amount'] as num?)?.toDouble() ?? 0.0,
            payload['dueDate'] ?? payload['due_date'] ?? now,
            payload['status'] ?? 'pending',
            version,
            now,
          ],
        );
        break;
      case 'goals':
        await tx.execute(
          'INSERT INTO goals(id, user_id, title, target_amount, saved_amount, version, updated_at, deleted_at) '
          'VALUES(?,?,?,?,?,?,?,NULL)',
          [
            id,
            userId,
            payload['title'] ?? 'Meta',
            (payload['targetAmount'] ?? payload['target_amount'] as num?)?.toDouble() ?? 0.0,
            (payload['savedAmount'] ?? payload['saved_amount'] as num?)?.toDouble() ?? 0.0,
            version,
            now,
          ],
        );
        break;
      case 'decisions':
        await tx.execute(
          'INSERT INTO decisions(id, user_id, action, note, created_at, version, updated_at, deleted_at) '
          'VALUES(?,?,?,?,?,?,?,NULL)',
          [
            id,
            userId,
            payload['action'] ?? '',
            payload['note'] ?? '',
            payload['created_at'] ?? now,
            version,
            now,
          ],
        );
        break;
      case 'reviews':
        await tx.execute(
          'INSERT INTO reviews(id, user_id, start_date, end_date, period_title, period_subtitle, transaction_ids, decision, decision_details, created_at, version, updated_at, deleted_at) '
          'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,NULL)',
          [
            id,
            userId,
            payload['start'] ?? now,
            payload['end'] ?? now,
            payload['periodTitle'] ?? '',
            payload['periodSubtitle'] ?? '',
            jsonEncode(payload['transactionIds'] ?? []),
            payload['decision'] ?? '',
            jsonEncode(payload['decisionDetails'] ?? {}),
            payload['createdAt'] ?? now,
            version,
            now,
          ],
        );
        break;
    }
  }

  void _updateEntitySync(
    String table,
    String id,
    String userId,
    Map<String, dynamic> payload, {
    required int version,
    required String now,
  }) {
    switch (table) {
      case 'transactions':
        database.db.execute(
          'UPDATE transactions SET type=?, category=?, amount=?, description=?, date=?, recognized=?, version=?, updated_at=? '
          'WHERE id=? AND user_id=?',
          [
            payload['type'] ?? 'expense',
            payload['category'] ?? 'Otros',
            (payload['amount'] as num?)?.toDouble() ?? 0.0,
            payload['description'] ?? '',
            payload['date'] ?? now,
            (payload['recognized'] ?? true) == true ? 1 : 0,
            version,
            now,
            id,
            userId,
          ],
        );
        break;
      case 'commitments':
        database.db.execute(
          'UPDATE commitments SET title=?, amount=?, due_date=?, status=?, version=?, updated_at=? '
          'WHERE id=? AND user_id=?',
          [
            payload['title'] ?? 'Compromiso',
            (payload['amount'] as num?)?.toDouble() ?? 0.0,
            payload['dueDate'] ?? payload['due_date'] ?? now,
            payload['status'] ?? 'pending',
            version,
            now,
            id,
            userId,
          ],
        );
        break;
      case 'goals':
        database.db.execute(
          'UPDATE goals SET title=?, target_amount=?, saved_amount=?, version=?, updated_at=? '
          'WHERE id=? AND user_id=?',
          [
            payload['title'] ?? 'Meta',
            (payload['targetAmount'] ?? payload['target_amount'] as num?)?.toDouble() ?? 0.0,
            (payload['savedAmount'] ?? payload['saved_amount'] as num?)?.toDouble() ?? 0.0,
            version,
            now,
            id,
            userId,
          ],
        );
        break;
      case 'decisions':
        database.db.execute(
          'UPDATE decisions SET action=?, note=?, version=?, updated_at=? WHERE id=? AND user_id=?',
          [
            payload['action'] ?? '',
            payload['note'] ?? '',
            version,
            now,
            id,
            userId,
          ],
        );
        break;
      case 'reviews':
        database.db.execute(
          'UPDATE reviews SET start_date=?, end_date=?, period_title=?, period_subtitle=?, transaction_ids=?, decision=?, decision_details=?, version=?, updated_at=? '
          'WHERE id=? AND user_id=?',
          [
            payload['start'] ?? now,
            payload['end'] ?? now,
            payload['periodTitle'] ?? '',
            payload['periodSubtitle'] ?? '',
            jsonEncode(payload['transactionIds'] ?? []),
            payload['decision'] ?? '',
            jsonEncode(payload['decisionDetails'] ?? {}),
            version,
            now,
            id,
            userId,
          ],
        );
        break;
      case 'users':
        database.db.execute(
          'UPDATE users SET name=?, updated_at=?, version=? WHERE id=?',
          [
            payload['name'] ?? '',
            now,
            version,
            id,
          ],
        );
        break;
    }
  }

  Future<void> _updateEntityAsync(
    DatabaseExecutor tx,
    String table,
    String id,
    String userId,
    Map<String, dynamic> payload, {
    required int version,
    required String now,
  }) async {
    switch (table) {
      case 'transactions':
        await tx.execute(
          'UPDATE transactions SET type=?, category=?, amount=?, description=?, date=?, recognized=?, version=?, updated_at=? '
          'WHERE id=? AND user_id=?',
          [
            payload['type'] ?? 'expense',
            payload['category'] ?? 'Otros',
            (payload['amount'] as num?)?.toDouble() ?? 0.0,
            payload['description'] ?? '',
            payload['date'] ?? now,
            (payload['recognized'] ?? true) == true ? 1 : 0,
            version,
            now,
            id,
            userId,
          ],
        );
        break;
      case 'commitments':
        await tx.execute(
          'UPDATE commitments SET title=?, amount=?, due_date=?, status=?, version=?, updated_at=? '
          'WHERE id=? AND user_id=?',
          [
            payload['title'] ?? 'Compromiso',
            (payload['amount'] as num?)?.toDouble() ?? 0.0,
            payload['dueDate'] ?? payload['due_date'] ?? now,
            payload['status'] ?? 'pending',
            version,
            now,
            id,
            userId,
          ],
        );
        break;
      case 'goals':
        await tx.execute(
          'UPDATE goals SET title=?, target_amount=?, saved_amount=?, version=?, updated_at=? '
          'WHERE id=? AND user_id=?',
          [
            payload['title'] ?? 'Meta',
            (payload['targetAmount'] ?? payload['target_amount'] as num?)?.toDouble() ?? 0.0,
            (payload['savedAmount'] ?? payload['saved_amount'] as num?)?.toDouble() ?? 0.0,
            version,
            now,
            id,
            userId,
          ],
        );
        break;
      case 'decisions':
        await tx.execute(
          'UPDATE decisions SET action=?, note=?, version=?, updated_at=? WHERE id=? AND user_id=?',
          [
            payload['action'] ?? '',
            payload['note'] ?? '',
            version,
            now,
            id,
            userId,
          ],
        );
        break;
      case 'reviews':
        await tx.execute(
          'UPDATE reviews SET start_date=?, end_date=?, period_title=?, period_subtitle=?, transaction_ids=?, decision=?, decision_details=?, version=?, updated_at=? '
          'WHERE id=? AND user_id=?',
          [
            payload['start'] ?? now,
            payload['end'] ?? now,
            payload['periodTitle'] ?? '',
            payload['periodSubtitle'] ?? '',
            jsonEncode(payload['transactionIds'] ?? []),
            payload['decision'] ?? '',
            jsonEncode(payload['decisionDetails'] ?? {}),
            version,
            now,
            id,
            userId,
          ],
        );
        break;
      case 'users':
        await tx.execute(
          'UPDATE users SET name=?, updated_at=?, version=? WHERE id=?',
          [
            payload['name'] ?? '',
            now,
            version,
            id,
          ],
        );
        break;
    }
  }
}

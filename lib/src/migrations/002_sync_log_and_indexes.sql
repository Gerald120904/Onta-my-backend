-- Migración 002: Tabla sync_log e índices de sincronización

-- La tabla sync_log utiliza sequence como clave incremental para cursores
-- En SQLite: INTEGER PRIMARY KEY AUTOINCREMENT
-- En PostgreSQL: BIGSERIAL PRIMARY KEY

CREATE TABLE IF NOT EXISTS sync_log (
  sequence {AUTO_INCREMENT_PK},
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

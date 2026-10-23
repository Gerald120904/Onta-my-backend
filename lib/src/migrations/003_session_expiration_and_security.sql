-- Migración 003: Blindaje de sesiones con expiración e índices de revocación rápida

CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at);

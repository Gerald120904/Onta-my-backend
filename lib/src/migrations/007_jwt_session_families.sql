-- Vincula access tokens a una sesión y conserva hashes de refresh consumidos
-- durante su vigencia para detectar la reutilización de tokens rotados.
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS sid TEXT;
ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS family_id TEXT;

CREATE TABLE IF NOT EXISTS used_refresh_tokens (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  family_id TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_used_refresh_family ON used_refresh_tokens(family_id);

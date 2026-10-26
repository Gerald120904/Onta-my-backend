-- Migración 004: Cuentas financieras con moneda inmutable
-- Permite múltiples cuentas por usuario (CRC, USD, EUR, etc.) con moneda fija para siempre.
-- Asocia transacciones, compromisos, metas, decisiones y revisiones a account_id.
-- Realiza backfill automático creando 'Cuenta Principal' (CRC) para usuarios existentes.

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

ALTER TABLE accounts ADD COLUMN IF NOT EXISTS initial_balance NUMERIC(18,2) NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS opening_balance NUMERIC(18,2) NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS color TEXT;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS icon TEXT;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS is_archived INTEGER NOT NULL DEFAULT 0;

ALTER TABLE transactions ADD COLUMN IF NOT EXISTS account_id TEXT;
ALTER TABLE commitments ADD COLUMN IF NOT EXISTS account_id TEXT;
ALTER TABLE goals ADD COLUMN IF NOT EXISTS account_id TEXT;
ALTER TABLE decisions ADD COLUMN IF NOT EXISTS account_id TEXT;
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS account_id TEXT;

CREATE INDEX IF NOT EXISTS idx_transactions_user_account ON transactions(user_id, account_id);
CREATE INDEX IF NOT EXISTS idx_commitments_user_account ON commitments(user_id, account_id);
CREATE INDEX IF NOT EXISTS idx_goals_user_account ON goals(user_id, account_id);

-- Backfill idempotente: crear cuenta inicial CRC para usuarios existentes sin cuentas
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

-- Vincular movimientos históricos sin cuenta asignada a la cuenta principal
UPDATE transactions 
SET account_id = 'acc_default_' || user_id
WHERE account_id IS NULL;

UPDATE commitments 
SET account_id = 'acc_default_' || user_id
WHERE account_id IS NULL;

UPDATE goals 
SET account_id = 'acc_default_' || user_id
WHERE account_id IS NULL;

UPDATE decisions 
SET account_id = 'acc_default_' || user_id
WHERE account_id IS NULL;

UPDATE reviews 
SET account_id = 'acc_default_' || user_id
WHERE account_id IS NULL;

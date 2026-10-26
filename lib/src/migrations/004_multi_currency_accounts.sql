-- Migración 004: Cuentas financieras con moneda inmutable
-- Permite múltiples cuentas por usuario (CRC, USD, EUR, etc.) con moneda fija para siempre.
-- Asocia transacciones, compromisos, metas, decisiones y revisiones a account_id.
-- Realiza backfill automático creando 'Cuenta Principal' (CRC) para usuarios existentes.
-- Aplica inmutabilidad estricta de divisa a nivel de base de datos (trigger).

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

-- Inmutabilidad estricta de divisa a nivel de base de datos (PostgreSQL)
CREATE OR REPLACE FUNCTION check_account_currency_immutable()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.currency IS DISTINCT FROM OLD.currency THEN
    RAISE EXCEPTION 'Currency is immutable and cannot be changed for an existing account';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_account_currency_immutable ON accounts;
CREATE TRIGGER trg_account_currency_immutable
BEFORE UPDATE ON accounts
FOR EACH ROW
EXECUTE FUNCTION check_account_currency_immutable();

-- Backfill idempotente: crear cuenta inicial CRC para usuarios existentes sin cuentas
INSERT INTO accounts (id, user_id, name, currency, initial_balance, opening_balance, color, icon, is_default, is_archived, created_at, version)
SELECT 
  'acc_default_' || id,
  id,
  'Cuenta Principal',
  'CRC',
  opening_balance,
  opening_balance,
  '#10B981',
  'wallet',
  1,
  0,
  created_at,
  1
FROM users
WHERE id NOT IN (SELECT user_id FROM accounts);

-- Sincronización de saldos iniciales
UPDATE accounts SET initial_balance = opening_balance WHERE (initial_balance IS NULL OR initial_balance = 0) AND opening_balance != 0;
UPDATE accounts SET opening_balance = initial_balance WHERE (opening_balance IS NULL OR opening_balance = 0) AND initial_balance != 0;

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

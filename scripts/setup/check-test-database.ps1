$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($env:NEON_DATABASE_URL)) {
  Write-Error 'NEON_DATABASE_URL faltante: usar una base Neon de prueba aislada.'
  exit 2
}
Push-Location (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
try {
  dart run bin/check_postgres.dart
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  dart test test/neon_integration_test.dart test/real_postgresql_validation_test.dart
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally { Pop-Location }

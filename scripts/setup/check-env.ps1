param([switch]$Production, [string]$EnvFile = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')) '.env.local'))
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $EnvFile) {
  foreach ($line in Get-Content -LiteralPath $EnvFile) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
  }
}
$required = @('JWT_SECRET', 'DATABASE_URL', 'ALLOWED_ORIGIN')
if ($Production) { $required += @('GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET', 'GOOGLE_REDIRECT_URI', 'GOOGLE_OAUTH_ADMIN_USER_ID', 'GOOGLE_TOKEN_ENCRYPTION_KEY', 'MAIL_FROM', 'PASSWORD_RESET_BASE_URL') }
$missing = @($required | Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_, 'Process')) })
if ($missing.Count -gt 0) {
  Write-Error ('Variables faltantes: ' + ($missing -join ', '))
  exit 1
}
if ($env:JWT_SECRET.Length -lt 32) { Write-Error 'JWT_SECRET debe tener al menos 32 caracteres.'; exit 1 }
if ($env:DATABASE_URL -notmatch '^postgres(ql)?://') { Write-Error 'DATABASE_URL debe ser PostgreSQL.'; exit 1 }
if ($Production -and $env:DATABASE_URL -match 'sslmode=disable') { Write-Error 'TLS no puede desactivarse en producción.'; exit 1 }
if ($Production -and $env:GOOGLE_REDIRECT_URI -notmatch '^https://.+/api/oauth/google/callback$') { Write-Error 'GOOGLE_REDIRECT_URI debe apuntar al callback HTTPS.'; exit 1 }
if ($Production) {
  try { $keyBytes = [Convert]::FromBase64String($env:GOOGLE_TOKEN_ENCRYPTION_KEY.Replace('-', '+').Replace('_', '/') + ('=' * ((4 - $env:GOOGLE_TOKEN_ENCRYPTION_KEY.Length % 4) % 4))) }
  catch { Write-Error 'GOOGLE_TOKEN_ENCRYPTION_KEY debe ser base64url válido.'; exit 1 }
  if ($keyBytes.Length -ne 32) { Write-Error 'GOOGLE_TOKEN_ENCRYPTION_KEY debe contener 32 bytes.'; exit 1 }
}
if ($Production -and $env:PASSWORD_RESET_BASE_URL -notmatch '^https://') { Write-Error 'El enlace de recuperación debe usar HTTPS.'; exit 1 }
Write-Output 'Configuración válida. No se mostraron secretos.'

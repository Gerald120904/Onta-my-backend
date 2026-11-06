param([switch]$Production, [string]$EnvFile = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')) '.env.local'))
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $EnvFile) {
  foreach ($line in Get-Content -LiteralPath $EnvFile) {
    $line = $line.TrimStart([char]0xFEFF).Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
    $separator = $line.IndexOf('=')
    if ($separator -lt 1) { continue }
    $name = $line.Substring(0, $separator).Trim()
    $value = $line.Substring($separator + 1).Trim()
    [Environment]::SetEnvironmentVariable($name, $value, 'Process')
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
if ($Production -and $env:DATABASE_URL -match 'sslmode=disable') { Write-Error 'TLS no puede desactivarse en producciÃ³n.'; exit 1 }
if ($Production -and $env:GOOGLE_REDIRECT_URI -cne 'https://onta-my-money-api.gerald.prod.page/api/oauth/google/callback') { Write-Error 'GOOGLE_REDIRECT_URI no coincide con el callback HTTPS registrado.'; exit 1 }
if ($Production) {
  try { $keyBytes = [Convert]::FromBase64String($env:GOOGLE_TOKEN_ENCRYPTION_KEY.Replace('-', '+').Replace('_', '/') + ('=' * ((4 - $env:GOOGLE_TOKEN_ENCRYPTION_KEY.Length % 4) % 4))) }
  catch { Write-Error 'GOOGLE_TOKEN_ENCRYPTION_KEY debe ser base64url vÃ¡lido.'; exit 1 }
  if ($keyBytes.Length -ne 32) { Write-Error 'GOOGLE_TOKEN_ENCRYPTION_KEY debe contener 32 bytes.'; exit 1 }
}
if ($Production -and $env:MAIL_FROM -cne 'receptor847@gmail.com') { Write-Error 'MAIL_FROM no coincide con el remitente autorizado.'; exit 1 }
if ($Production -and $env:ALLOWED_ORIGIN -cne 'https://onta-my-money.pages.dev') { Write-Error 'ALLOWED_ORIGIN no coincide con el frontend de producciÃ³n.'; exit 1 }
if ($Production -and $env:PASSWORD_RESET_BASE_URL -cne 'https://onta-my-money.pages.dev/') { Write-Error 'PASSWORD_RESET_BASE_URL no coincide con la URL HTTPS de producciÃ³n.'; exit 1 }
Write-Output 'ConfiguraciÃ³n vÃ¡lida. No se mostraron secretos.'

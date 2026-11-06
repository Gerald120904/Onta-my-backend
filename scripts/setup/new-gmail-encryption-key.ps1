param([string]$OutputPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')) '.env.local'))
$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $target) {
  $existing = Get-Content -LiteralPath $target -Raw
  if ($existing -match '(?m)^GOOGLE_TOKEN_ENCRYPTION_KEY=.+$') {
    Write-Output 'La clave de cifrado ya existe; no se modificó.'
    exit 0
  }
}
$bytes = [byte[]]::new(32)
$generator = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
$secret = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
Add-Content -LiteralPath $target -Value "GOOGLE_TOKEN_ENCRYPTION_KEY=$secret" -Encoding utf8
Write-Output "Clave generada en $target. El valor no se muestra en consola."

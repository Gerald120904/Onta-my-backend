param([string]$OutputPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')) '.env.local'))
$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $target) {
  $existing = Get-Content -LiteralPath $target -Raw
  if ($existing -match '(?m)^JWT_SECRET=.+$') {
    Write-Output 'JWT_SECRET ya existe en el archivo local; no se modificó.'
    exit 0
  }
}
$bytes = [byte[]]::new(48)
$generator = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
$secret = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
Add-Content -LiteralPath $target -Value "JWT_SECRET=$secret" -Encoding utf8
Write-Output "JWT_SECRET generado en $target. El valor no se muestra en consola."

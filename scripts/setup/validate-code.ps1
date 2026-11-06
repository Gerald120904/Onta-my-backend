param([string]$FrontendPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')) '../Frontend-Donde-Se-Fue-Mi-Plata'))
$ErrorActionPreference = 'Stop'
$backend = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Push-Location $backend
try {
  dart pub get
  if ($LASTEXITCODE -ne 0) { throw 'dart pub get falló' }
  dart analyze
  if ($LASTEXITCODE -ne 0) { throw 'dart analyze falló' }
  dart test
  if ($LASTEXITCODE -ne 0) { throw 'dart test falló' }
} finally { Pop-Location }
Push-Location $FrontendPath
try {
  flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'flutter pub get falló' }
  flutter analyze
  if ($LASTEXITCODE -ne 0) { throw 'flutter analyze falló' }
  flutter test
  if ($LASTEXITCODE -ne 0) { throw 'flutter test falló' }
  flutter build web --release --dart-define=API_URL=https://onta-my-money-api.gerald.prod.page
  if ($LASTEXITCODE -ne 0) { throw 'flutter build web falló' }
  if ($env:ANDROID_HOME -or $env:ANDROID_SDK_ROOT) {
    flutter build apk --release --dart-define=API_URL=https://onta-my-money-api.gerald.prod.page
    if ($LASTEXITCODE -ne 0) { throw 'flutter build apk falló' }
  } else { Write-Output 'APK pendiente: Android SDK no configurado.' }
} finally { Pop-Location }

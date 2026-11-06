param([string]$ApiBaseUrl = 'https://onta-my-money-api.gerald.prod.page')
$ErrorActionPreference = 'Stop'

$email = Read-Host 'Correo de tu cuenta administradora de Onta My Money'
$securePassword = Read-Host 'Contraseña de Onta My Money' -AsSecureString
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
$password = $null
$accessToken = $null
try {
  $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
  $login = Invoke-RestMethod -Method Post -Uri "$($ApiBaseUrl.TrimEnd('/'))/api/auth/login" `
    -ContentType 'application/json' `
    -Body (@{ email = $email; password = $password } | ConvertTo-Json -Compress)
  $accessToken = [string]$login.token
  if ([string]::IsNullOrWhiteSpace($accessToken)) { throw 'Login incompleto.' }
  $profile = Invoke-RestMethod -Method Get -Uri "$($ApiBaseUrl.TrimEnd('/'))/api/me" `
    -Headers @{ Authorization = "Bearer $accessToken" }
  if ([string]::IsNullOrWhiteSpace([string]$profile.id)) { throw 'La API no devolvió un ID.' }
  Write-Output ([string]$profile.id)
} catch {
  Write-Error 'No se pudo consultar el perfil. Revisá el acceso a la API y las credenciales; no se imprimió ningún token.'
  exit 1
} finally {
  if ($passwordPointer -ne [IntPtr]::Zero) {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
  }
  $password = $null
  $accessToken = $null
  $securePassword.Dispose()
}

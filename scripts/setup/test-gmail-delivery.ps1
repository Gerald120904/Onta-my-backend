param([string]$ApiBaseUrl = 'https://onta-my-money-api.gerald.prod.page')
$ErrorActionPreference = 'Stop'

$confirm = Read-Host 'Escribí ENVIAR para mandar un correo de prueba a receptor847@gmail.com'
if ($confirm -cne 'ENVIAR') { Write-Output 'Prueba cancelada.'; exit 0 }
$email = Read-Host 'Correo de tu cuenta administradora de Onta My Money'
$securePassword = Read-Host 'Contraseña de Onta My Money' -AsSecureString
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
$password = $null
$accessToken = $null
try {
  $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
  $base = $ApiBaseUrl.TrimEnd('/')
  $login = Invoke-RestMethod -Method Post -Uri "$base/api/auth/login" `
    -ContentType 'application/json' `
    -Body (@{ email = $email; password = $password } | ConvertTo-Json -Compress)
  $accessToken = [string]$login.token
  if ([string]::IsNullOrWhiteSpace($accessToken)) { throw 'Login incompleto.' }
  Invoke-RestMethod -Method Post -Uri "$base/api/oauth/google/test-send" `
    -Headers @{ Authorization = "Bearer $accessToken" } `
    -ContentType 'application/json' -Body '{}'
  Write-Output 'El backend aceptó la prueba. Revisá la bandeja de receptor847@gmail.com.'
} catch {
  Write-Error 'La prueba no se completó. Verificá la sesión administradora, la autorización Gmail y la conexión; no se imprimieron tokens.'
  exit 1
} finally {
  if ($passwordPointer -ne [IntPtr]::Zero) {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
  }
  $password = $null
  $accessToken = $null
  $securePassword.Dispose()
}

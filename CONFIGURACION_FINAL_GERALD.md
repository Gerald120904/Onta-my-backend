# Configuración final de Onta My Money

Esta guía contiene las acciones externas que debe realizar la persona administradora. No cambie los secretos OAuth que ya existen en Blitz. Los cambios de JWT y BFF de este repositorio todavía deben revisarse en los pull requests antes de cualquier despliegue.

## 1. Generar y configurar la clave de cifrado Gmail

En PowerShell, desde la carpeta del backend:

```powershell
.\scripts\setup\new-gmail-encryption-key.ps1
```

El comando genera 32 bytes aleatorios, guarda el valor únicamente en `.env.local` (archivo ignorado por Git) y no lo imprime. Abra ese archivo localmente y copie `GOOGLE_TOKEN_ENCRYPTION_KEY` al secreto del backend en Blitz. Guarde una copia en un gestor de contraseñas: perderla requerirá volver a autorizar Gmail.

## 2. Consultar y configurar el ID administrador OAuth

Después de integrar y desplegar el backend revisado, ejecute desde PowerShell:

```powershell
.\scripts\setup\get-oauth-admin-id.ps1
```

Ingrese el correo y la contraseña de Onta My Money cuando el script los solicite. El comando consulta `/api/me` con la sesión autenticada e imprime únicamente el ID interno. Guarde ese ID como `GOOGLE_OAUTH_ADMIN_USER_ID` en Blitz. No use el correo Gmail como ID.

## 3. Validar los secretos existentes de Blitz

En el panel de Blitz, confirme que existen `DATABASE_URL`, `JWT_SECRET`, `MAIL_FROM`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` y `GOOGLE_REDIRECT_URI`. No los vuelva a crear ni cambie su valor. Confirme sin copiar valores a logs:

- `MAIL_FROM` corresponde a `receptor847@gmail.com`.
- `GOOGLE_REDIRECT_URI` es exactamente `https://onta-my-money-api.gerald.prod.page/api/oauth/google/callback`.
- `PASSWORD_RESET_BASE_URL` es `https://onta-my-money.pages.dev/`.
- También están configurados los dos secretos de los pasos 1 y 2.

Para validar un archivo local sin mostrar secretos, ejecute `scripts/setup/check-env.ps1 -Production` desde el backend. El backend incluye las migraciones 005, 006 y 007; el despliegue debe aplicarlas sobre PostgreSQL persistente.

## 4. Revisar Google OAuth para producción

Abra [Google Auth Platform](https://console.cloud.google.com/auth/overview). Compruebe el proyecto existente, el cliente OAuth web y el URI de redirección anterior. No cree otro cliente.

El permiso `gmail.send` está clasificado como **sensible**. En estado **Testing**, los refresh tokens de una app externa normalmente vencen a los siete días. Cambie la audiencia a producción y presente el permiso para verificación si Google lo exige. Una excepción de uso personal puede existir para una app usada solo por el propietario o un grupo pequeño conocido, pero Google debe determinar si aplica a este servicio. No suponga que el cambio a producción elimina automáticamente la revisión. Google puede pedir dominio verificado, página de inicio y política de privacidad públicos, justificación del permiso y video de demostración. La política está preparada en `https://onta-my-money.pages.dev/privacy.html` y enlazada desde el inicio de sesión.

## 5. Integrar y desplegar backend y frontend de forma segura

Revise y cree los pull requests desde estos enlaces:

- Backend: [comparar codex/integral-stability con main](https://github.com/Gerald120904/Onta-my-backend/compare/main...codex/integral-stability?expand=1)
- Frontend: [comparar codex/integral-stability con main](https://github.com/Gerald120904/Onta-my-money/compare/main...codex/integral-stability?expand=1)

Integre primero el backend y luego el frontend; despliegue ambos solo después de revisar las verificaciones y aprobar los cambios. El backend mantiene sesiones opacas anteriores y la ruta same-origin de Cloudflare Pages guarda el refresh token web en cookie `HttpOnly`, `Secure`, `SameSite=Strict`. Android sigue usando la API directa con almacenamiento seguro del dispositivo. No borre Service Worker, IndexedDB ni datos locales. La publicación de Pages desde GitHub Actions requiere `CLOUDFLARE_API_TOKEN` como secreto y `CLOUDFLARE_ACCOUNT_ID` como variable del repositorio; sin ambos, el workflow solo compila y no publica.

## 6. Autorizar Gmail con la cuenta remitente

Después de desplegar y configurar las variables, inicie sesión como administrador. Abra `/api/oauth/google/start` con el token de esa sesión, visite el `authorization_url` devuelto y autorice con `receptor847@gmail.com`. Google volverá al callback registrado. Los usuarios normales de Onta My Money no realizan este paso.

## 7. Enviar un correo real de prueba

Desde el backend, ejecute:

```powershell
.\scripts\setup\test-gmail-delivery.ps1
```

Escriba `ENVIAR` para confirmar y luego ingrese las credenciales de la cuenta administradora de Onta My Money. El script solicita el envío y no imprime tokens. Confirme la llegada del mensaje a `receptor847@gmail.com`.

## 8. Verificar registro y recuperación de contraseña

Cree una cuenta de prueba con una dirección que controle, confirme el mensaje de verificación y pruebe iniciar sesión. Solicite recuperar la contraseña, use el enlace una sola vez y confirme que la contraseña anterior deja de funcionar. Repita con un correo que no exista y compruebe que la respuesta pública no revela si la cuenta está registrada.

## 9. Comprobar el APK Android

En el pull request del frontend, abra **Actions → Android validation**. Confirme que `Analyze`, `Test` y `Build production APK` terminan correctamente. Descargue el artefacto `onta-android-release-validation` desde esa ejecución para instalarlo en un dispositivo de prueba. El APK de CI no está firmado para publicar en una tienda.

## 10. Verificaciones finales de seguridad y sincronización

En un dispositivo de prueba, compruebe login, renovación, cierre de sesión, cambio y recuperación de contraseña. Cree movimientos sin conexión, cierre y vuelva a abrir la app; al recuperar conexión, confirme que se sincronizan una vez y que siguen presentes en el segundo dispositivo. Pruebe también un conflicto de edición y su resolución. No use Neon de producción para pruebas destructivas ni borre datos locales para resolver problemas de sesión.

Las pruebas automatizadas con SQLite y Gmail simulado no sustituyen una prueba con PostgreSQL aislado, una revisión visual en dispositivos físicos, la autorización de Google ni el correo real.

# Configuración final de Onta My Money

## PASO 1 — Secreto nuevo de cifrado

Generá una clave aleatoria de 32 bytes con `scripts/setup/new-gmail-encryption-key.ps1` en tu equipo. Copiá el valor de `GOOGLE_TOKEN_ENCRYPTION_KEY` desde `.env.local` a los secretos del backend en Blitz. Guardá una copia segura: perder esta clave impide descifrar el refresh token almacenado; cambiarla exige autorizar Gmail de nuevo. No la subás a Git.

## PASO 2 — Administrador OAuth

Configurá `GOOGLE_OAUTH_ADMIN_USER_ID` en Blitz con el ID de la cuenta administradora existente de Onta My Money. Esta ruta exige además una sesión autenticada de ese usuario. No usés el correo Gmail como identificador si no coincide con el ID de usuario de la aplicación.

## PASO 3 — Verificar configuración existente

Conservá sin mostrar ni modificar `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REDIRECT_URI`, `MAIL_FROM` y `JWT_SECRET` ya guardados en Blitz. Confirmá que el URI registrado en Google Cloud y `GOOGLE_REDIRECT_URI` sea exactamente `https://onta-my-money-api.gerald.prod.page/api/oauth/google/callback` y que `MAIL_FROM` sea `receptor847@gmail.com`. Configurá `PASSWORD_RESET_BASE_URL=https://onta-my-money.pages.dev/` si falta. El backend necesita su base PostgreSQL persistente (`DATABASE_URL`) y las migraciones 005 y 006 aplicadas al desplegar.

## PASO 4 — Autorizar Gmail una vez

Después de desplegar el backend, ingresá a Onta My Money con la cuenta administradora. Con su token de sesión llamá `GET /api/oauth/google/start` con `Authorization: Bearer <token>` y abrí `authorization_url` en un navegador. Aprobá con `receptor847@gmail.com`. El callback valida `state`, permiso y correo; persiste únicamente el refresh token cifrado. La URL de inicio no funciona sin sesión ni para otros usuarios. No compartás el URL ni el código de autorización.

## PASO 5 — Comprobación

Registrá una cuenta de prueba y verificá que llegue el correo, que el enlace active la cuenta y que recuperar contraseña entregue un enlace de un solo uso. Esto realiza envíos reales únicamente después de la autorización humana del paso 4. `dart analyze` y `dart test` comprueban el flujo con Gmail simulado, sin enviar correos.

El frontend conserva IndexedDB y la cola Offline-First. La migración marca verificadas las cuentas anteriores y exige verificación solo a las nuevas cuando Gmail está configurado.

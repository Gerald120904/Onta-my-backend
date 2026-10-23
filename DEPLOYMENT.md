# Guía de Despliegue en la Nube — Backend ¿Dónde se fue mi plata?

Esta guía detalla los pasos para desplegar el servidor en plataformas tipo Render, Fly.io o Railway con almacenamiento persistente para SQLite.

## 1. Variables de Entorno

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `PORT` | `8080` | Puerto en el que el servidor escucha peticiones HTTP. |
| `DATABASE_PATH` | `/app/data/plata.db` | Ruta absoluta al archivo SQLite persistente. |
| `ALLOWED_ORIGIN` | `*` | Orígenes CORS permitidos (e.g. `https://mi-dominio-web.com`). |

## 2. Configuración en Render / Fly.io

1. **Docker Service**: Configurar el servicio a partir del `Dockerfile` provisto.
2. **Volumen Persistente (Obligatorio para SQLite)**:
   - Punto de montaje: `/app/data`
   - Tamaño recomendado: 1 GB (ampliable según historial).
   - Instancia única: SQLite admite múltiples lectores concurrentes pero **un solo escritor**. Mantener 1 sola réplica en producción.
3. **Health Check**:
   - Path: `/api/health`
   - Status code esperado: `200`
4. **HTTPS**:
   - Provisto automáticamente por la infraestructura de Render o Fly.io con certificados TLS gratuitos.

## 3. Respaldo y Restauración de Base de Datos

### Respaldo en Caliente (Safe Hot Backup):
SQLite cuenta con la API de backup online. Puede ejecutarse en el contenedor:
```bash
sqlite3 /app/data/plata.db ".backup '/app/data/backup_$(date +%Y%m%d_%H%M%S).db'"
```

### Restauración:
```bash
cp /app/data/backup_archivo.db /app/data/plata.db
```

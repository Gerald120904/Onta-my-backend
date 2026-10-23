# Etapa 1: Build
FROM dart:stable AS build

WORKDIR /app
COPY pubspec.* ./
RUN dart pub get

COPY . .
RUN dart pub get --offline
RUN dart compile exe bin/server.dart -o bin/server

# Etapa 2: Runtime liviano
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    sqlite3 \
    libsqlite3-0 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/bin/server /app/bin/server

# Carpeta para base de datos persistente (montar volumen aquí)
RUN mkdir -p /app/data && chown -R 1000:1000 /app

ENV PORT=8080
ENV DATABASE_PATH=/app/data/plata.db
ENV ALLOWED_ORIGIN=*

EXPOSE 8080
USER 1000

CMD ["/app/bin/server"]

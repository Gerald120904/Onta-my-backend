import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../lib/src/api.dart';
import '../lib/src/database.dart';

Middleware corsMiddleware({required bool isProduction, String? allowedOriginOverride}) {
  final rawAllowedOrigin = allowedOriginOverride ?? Platform.environment['ALLOWED_ORIGIN'];
  final List<String> allowedOrigins = (rawAllowedOrigin != null && rawAllowedOrigin.trim().isNotEmpty)
      ? rawAllowedOrigin.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList()
      : <String>[];

  return (Handler innerHandler) {
    return (Request request) async {
      final originHeader = request.headers['origin'];
      String allowOrigin = '';

      if (isProduction) {
        // En producción NO se permite comodín '*'
        // Se valida estrictamente contra la lista blanca configurada en ALLOWED_ORIGIN (ej. Cloudflare Pages)
        if (originHeader != null && allowedOrigins.contains(originHeader) && originHeader != '*') {
          allowOrigin = originHeader;
        } else {
          allowOrigin = '';
        }
      } else {
        // En desarrollo / local se permite comodín o el origen entrante
        if (rawAllowedOrigin == null || rawAllowedOrigin == '*' || allowedOrigins.contains('*')) {
          allowOrigin = originHeader ?? '*';
        } else if (originHeader != null && allowedOrigins.contains(originHeader)) {
          allowOrigin = originHeader;
        } else {
          allowOrigin = allowedOrigins.isNotEmpty ? allowedOrigins.first : '*';
        }
      }

      final corsHeaders = <String, String>{
        if (allowOrigin.isNotEmpty) 'Access-Control-Allow-Origin': allowOrigin,
        'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept, Authorization, X-Device-Id',
        'Access-Control-Max-Age': '86400',
        if (isProduction && allowOrigin.isNotEmpty) 'Vary': 'Origin',
      };

      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: corsHeaders);
      }

      final response = await innerHandler(request);

      return response.change(
        headers: {
          ...response.headers,
          ...corsHeaders,
        },
      );
    };
  };
}

Future<void> main() async {
  final env = Platform.environment['ENVIRONMENT']?.toLowerCase() ??
      Platform.environment['APP_ENV']?.toLowerCase() ??
      Platform.environment['NODE_ENV']?.toLowerCase() ??
      'development';
  final isProduction = env == 'production' || env == 'prod';

  // Desactivación incondicional de la cuenta de demostración en producción
  final allowSeed = !isProduction && (Platform.environment['SEED_DEMO_USER']?.toLowerCase() != 'false');

  final databaseUrl = Platform.environment['DATABASE_URL'];
  final dbPath = Platform.environment['DATABASE_PATH'];

  final AppDatabase db;
  if (isProduction) {
    // 2. Cuando ENVIRONMENT=production, exige una DATABASE_URL PostgreSQL válida.
    // Si falta o es incorrecta, detén el arranque; nunca uses SQLite como alternativa en producción.
    if (!AppDatabase.isValidPostgresUrl(databaseUrl)) {
      stderr.writeln(
        'ERROR CRÍTICO: En entorno de producción (ENVIRONMENT=production), se exige una DATABASE_URL PostgreSQL válida.\n'
        'El arranque ha sido detenido porque falta o es incorrecta la URL.\n'
        'NUNCA se debe usar SQLite como alternativa en producción.\n'
        'DATABASE_URL configurada: ${databaseUrl == null ? "(no definida)" : "(formato no válido)"}',
      );
      exit(1);
    }

    try {
      print('Conectando a base de datos PostgreSQL en la nube (Producción con TLS obligatorio)...');
      db = await AppDatabase.openAsync(
        databaseUrl: databaseUrl,
        isProduction: true,
        environment: env,
      );
    } catch (e) {
      stderr.writeln('ERROR CRÍTICO: No se pudo conectar a PostgreSQL en producción: $e');
      exit(1);
    }
  } else {
    if (AppDatabase.isValidPostgresUrl(databaseUrl)) {
      print('Conectando a base de datos PostgreSQL...');
      db = await AppDatabase.openAsync(
        databaseUrl: databaseUrl,
        isProduction: false,
        environment: env,
      );
    } else {
      print('Iniciando base de datos SQLite local...');
      db = AppDatabase.open(customPath: dbPath);
    }
  }

  if (allowSeed) {
    await db.seed();
  }

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware(isProduction: isProduction))
      .addHandler(Api(db).router.call);

  final port = int.tryParse(Platform.environment['PORT'] ?? Platform.environment['API_PORT'] ?? '') ?? 8080;

  final server = await shelf_io.serve(
    handler,
    InternetAddress.anyIPv4,
    port,
  );

  print('');
  print('========================================');
  print(' API ¿Dónde se fue mi plata?');
  print(' Servidor escuchando en: http://${server.address.host}:${server.port}');
  print(' Motor de persistencia: ${db.isPostgres ? "PostgreSQL (Neon TLS)" : (dbPath ?? "SQLite data/plata.db")}');
  print(' Entorno: $env (Producción: $isProduction)');
  print(' Puerto activo: ${server.port}');
  print('========================================');
  print('');

  // Manejo de apagado ordenado
  ProcessSignal.sigint.watch().listen((_) async {
    print('\nCerrando servidor...');
    await server.close(force: true);
    await db.close();
    print('Servidor cerrado.');
    exit(0);
  });
}
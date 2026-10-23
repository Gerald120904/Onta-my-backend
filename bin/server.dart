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
        // Se valida estrictamente contra la lista blanca configurada en ALLOWED_ORIGIN
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

  // Desactivación obligatoria de la cuenta de demostración en producción
  final allowSeed = !isProduction && (Platform.environment['SEED_DEMO_USER']?.toLowerCase() != 'false');

  final dbPath = Platform.environment['DATABASE_PATH'];
  final db = AppDatabase.open(customPath: dbPath);
  if (allowSeed) {
    db.seed();
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
  print(' Base de datos: ${dbPath ?? "data/plata.db"}');
  print(' Puerto activo: ${server.port}');
  print('========================================');
  print('');

  // Handle graceful shutdown
  ProcessSignal.sigint.watch().listen((_) async {
    print('\nCerrando servidor...');
    await server.close(force: true);
    db.close();
    print('Servidor cerrado.');
    exit(0);
  });
}
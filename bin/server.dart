import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../lib/src/api.dart';
import '../lib/src/database.dart';

Middleware corsMiddleware() {
  final configuredOrigin = Platform.environment['ALLOWED_ORIGIN'] ?? '*';

  return (Handler innerHandler) {
    return (Request request) async {
      final originHeader = request.headers['origin'];
      final allowOrigin = (configuredOrigin == '*' || originHeader == null)
          ? configuredOrigin
          : (configuredOrigin.split(',').map((e) => e.trim()).contains(originHeader) ? originHeader : configuredOrigin);

      final corsHeaders = <String, String>{
        'Access-Control-Allow-Origin': allowOrigin,
        'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept, Authorization, X-Device-Id',
        'Access-Control-Max-Age': '86400',
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
  final dbPath = Platform.environment['DATABASE_PATH'];
  final db = AppDatabase.open(customPath: dbPath)..seed();

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware())
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
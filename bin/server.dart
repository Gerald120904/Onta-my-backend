import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../lib/src/api.dart';
import '../lib/src/database.dart';

Middleware corsMiddleware() {
  return (Handler innerHandler) {
    return (Request request) async {
      const corsHeaders = <String, String>{
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods':
            'GET, POST, PUT, PATCH, DELETE, OPTIONS',
        'Access-Control-Allow-Headers':
            'Origin, Content-Type, Accept, Authorization',
        'Access-Control-Max-Age': '86400',
      };

      // El navegador manda esta petición antes del POST real.
      if (request.method == 'OPTIONS') {
        return Response.ok(
          '',
          headers: corsHeaders,
        );
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
  final db = AppDatabase.open()..seed();

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware())
      .addHandler(Api(db).router.call);

  final port =
      int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  final server = await shelf_io.serve(
    handler,
    InternetAddress.anyIPv4,
    port,
  );

  print('');
  print('========================================');
  print(' API ¿Dónde se fue mi plata?');
  print(' http://localhost:${server.port}');
  print('========================================');
  print('');
}
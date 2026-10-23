import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../bin/server.dart';
import '../lib/src/database.dart';

void main() {
  group('Security Hardening: Demo User & Production Guardrails', () {
    test('seed() is completely inactive in production environment', () {
      final db = AppDatabase.inMemory();
      // Call seed in production mode
      db.seed(environment: 'production');
      // Check users
      final rows = db.db.select('SELECT * FROM users WHERE email=?', ['demo@plata.app']);
      expect(rows, isEmpty, reason: 'Demo user must NOT be seeded in production');
      db.close();
    });

    test('seed() with force: true is still strictly blocked in production environment', () {
      final db = AppDatabase.inMemory();
      // Call seed in production mode with force: true
      db.seed(force: true, environment: 'production');
      // Check users
      final rows = db.db.select('SELECT * FROM users WHERE email=?', ['demo@plata.app']);
      expect(rows, isEmpty, reason: 'Demo user must NOT be seeded in production even with force: true');
      db.close();
    });

    test('seed() works normally in development/local environment', () {
      final db = AppDatabase.inMemory();
      db.seed(environment: 'development');
      final rows = db.db.select('SELECT * FROM users WHERE email=?', ['demo@plata.app']);
      expect(rows, isNotEmpty, reason: 'Demo user should be seeded in local/development environment');
      db.close();
    });
  });

  group('Security Hardening: CORS Protection', () {
    test('Production rejects wildcard * and returns empty CORS origin for unauthorized origins', () async {
      final middleware = corsMiddleware(
        isProduction: true,
        allowedOriginOverride: 'https://plata.app,https://admin.plata.app',
      );
      final handler = middleware((Request req) async => Response.ok('OK'));

      // Request with unauthorized origin
      final reqUnauthorized = Request('GET', Uri.parse('http://localhost:8080/api/status'), headers: {
        'Origin': 'https://malicious-site.com',
      });
      final resUnauthorized = await handler(reqUnauthorized);
      expect(resUnauthorized.headers['Access-Control-Allow-Origin'], isNull);

      // Request with authorized origin
      final reqAuthorized = Request('GET', Uri.parse('http://localhost:8080/api/status'), headers: {
        'Origin': 'https://plata.app',
      });
      final resAuthorized = await handler(reqAuthorized);
      expect(resAuthorized.headers['Access-Control-Allow-Origin'], equals('https://plata.app'));
      expect(resAuthorized.headers['Vary'], equals('Origin'));
    });

    test('Production with unconfigured ALLOWED_ORIGIN emits no wildcard', () async {
      final middleware = corsMiddleware(
        isProduction: true,
        allowedOriginOverride: '',
      );
      final handler = middleware((Request req) async => Response.ok('OK'));

      final req = Request('GET', Uri.parse('http://localhost:8080/api/status'), headers: {
        'Origin': 'https://random-site.com',
      });
      final res = await handler(req);
      expect(res.headers['Access-Control-Allow-Origin'], isNull);
    });

    test('OPTIONS preflight returns correct CORS headers in production for authorized origin', () async {
      final middleware = corsMiddleware(
        isProduction: true,
        allowedOriginOverride: 'https://plata.app',
      );
      final handler = middleware((Request req) async => Response.ok('OK'));

      final reqOptions = Request('OPTIONS', Uri.parse('http://localhost:8080/api/status'), headers: {
        'Origin': 'https://plata.app',
      });
      final resOptions = await handler(reqOptions);
      expect(resOptions.statusCode, 200);
      expect(resOptions.headers['Access-Control-Allow-Origin'], equals('https://plata.app'));
      expect(resOptions.headers['Access-Control-Allow-Methods'], contains('POST'));
    });
  });
}

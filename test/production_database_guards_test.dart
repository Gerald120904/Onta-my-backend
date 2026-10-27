import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

import '../lib/src/database.dart';

void main() {
  group('PROTECCIONES DE PERSISTENCIA Y TLS EN PRODUCCIÓN', () {
    // =========================================================================
    // 1. CONDICIÓN 1: TLS OBLIGATORIO EN PRODUCCIÓN
    // =========================================================================
    group('1. Protección TLS (sslmode=disable prohibido en producción)', () {
      test('1.1 PostgresAppDatabase.connect rechaza sslmode=disable cuando isProduction es true', () async {
        const urlWithDisable = 'postgresql://postgres@127.0.0.1:5433/onta_test?sslmode=disable';

        expect(
          () async => await PostgresAppDatabase.connect(urlWithDisable, isProduction: true),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('sslmode=disable'),
            ),
          ),
          reason: 'En producción debe lanzar StateError si la URL solicita sslmode=disable',
        );
      });

      test('1.2 AppDatabase.openAsync rechaza sslmode=disable en producción sin recurrir a SQLite', () async {
        const urlWithDisable = 'postgres://postgres@127.0.0.1:5433/onta_test?sslmode=disable';

        expect(
          () async => await AppDatabase.openAsync(databaseUrl: urlWithDisable, isProduction: true),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('TLS es obligatorio'),
            ),
          ),
        );
      });

      test('1.3 En desarrollo (isProduction: false), sslmode=disable es permitido para pruebas locales', () async {
        const localTestUrl = 'postgresql://postgres@127.0.0.1:5433/onta_test?sslmode=disable';

        bool isAvailable = false;
        try {
          final s = await Socket.connect('127.0.0.1', 5433, timeout: const Duration(milliseconds: 300));
          s.destroy();
          isAvailable = true;
        } catch (_) {
          isAvailable = false;
        }

        if (!isAvailable) {
          expect(AppDatabase.isValidPostgresUrl(localTestUrl), isTrue);
          expect(
            () async => await PostgresAppDatabase.connect(localTestUrl, isProduction: true),
            throwsA(isA<StateError>()),
            reason: 'En producción debe seguir rechazándose sslmode=disable',
          );
          return;
        }

        final db = await PostgresAppDatabase.connect(localTestUrl, isProduction: false);
        try {
          expect(db.isPostgres, isTrue);
          final res = await db.query('SELECT 1 as connected');
          expect(res.first['connected'], equals(1));
        } finally {
          await db.close();
        }
      });
    });

    // =========================================================================
    // 2. CONDICIÓN 2: DATABASE_URL REQUERIDA Y PROHIBICIÓN DE SQLITE EN PRODUCCIÓN
    // =========================================================================
    group('2. Exigencia de DATABASE_URL PostgreSQL y Prohibición de SQLite en Producción', () {
      test('2.1 AppDatabase.isValidPostgresUrl valida esquemas y descarta URLs inválidas', () {
        expect(AppDatabase.isValidPostgresUrl('postgresql://user:pass@ep-cool.neon.tech/neondb?sslmode=require'), isTrue);
        expect(AppDatabase.isValidPostgresUrl('postgres://user:pass@localhost:5432/test'), isTrue);
        expect(AppDatabase.isValidPostgresUrl('postgres://127.0.0.1:5432/test'), isTrue);

        expect(AppDatabase.isValidPostgresUrl(null), isFalse);
        expect(AppDatabase.isValidPostgresUrl(''), isFalse);
        expect(AppDatabase.isValidPostgresUrl('   '), isFalse);
        expect(AppDatabase.isValidPostgresUrl('sqlite:///data/plata.db'), isFalse);
        expect(AppDatabase.isValidPostgresUrl('mysql://localhost:3306/db'), isFalse);
        expect(AppDatabase.isValidPostgresUrl('http://localhost:5432'), isFalse);
        expect(AppDatabase.isValidPostgresUrl('postgres://'), isFalse);
      });

      test('2.2 En producción, si DATABASE_URL falta o es null, detiene el arranque y NUNCA usa SQLite', () async {
        expect(
          () async => await AppDatabase.openAsync(databaseUrl: null, isProduction: true),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('se exige una DATABASE_URL PostgreSQL válida'),
                contains('No se permite SQLite como alternativa en producción'),
              ),
            ),
          ),
        );
      });

      test('2.3 En producción, si DATABASE_URL es cadena vacía, detiene el arranque', () async {
        expect(
          () async => await AppDatabase.openAsync(databaseUrl: '   ', isProduction: true),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('se exige una DATABASE_URL PostgreSQL válida'),
            ),
          ),
        );
      });

      test('2.4 En producción, si DATABASE_URL es incorrecta (no PostgreSQL), detiene el arranque con ArgumentError', () async {
        const invalidUrl = 'sqlite:///data/plata.db';

        expect(
          () async => await AppDatabase.openAsync(databaseUrl: invalidUrl, isProduction: true),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('DATABASE_URL no es una URL de PostgreSQL válida en producción'),
                contains('nunca se debe usar SQLite en producción'),
              ),
            ),
          ),
        );
      });

      test('2.5 En desarrollo (isProduction: false), la ausencia de DATABASE_URL conserva SQLite local', () async {
        final db = await AppDatabase.openAsync(
          databaseUrl: null,
          customPath: 'data/test_guards_dev.db',
          isProduction: false,
        );
        try {
          expect(db.isPostgres, isFalse);
          expect(db, isA<SqliteAppDatabase>());
        } finally {
          await db.close();
          final f = File('data/test_guards_dev.db');
          if (f.existsSync()) f.deleteSync();
        }
      });
    });

    // =========================================================================
    // 3. PRUEBAS DE PROCESO REAL (bin/server.dart)
    // =========================================================================
    group('3. Comprobación de Proceso server.dart ante Entorno de Producción', () {
      test('3.1 server.dart termina con código 1 y no arranca si falta DATABASE_URL en producción', () async {
        final result = await Process.run(
          'dart',
          ['bin/server.dart'],
          environment: {
            'ENVIRONMENT': 'production',
            'DATABASE_URL': '',
            'PORT': '8991',
          },
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );

        expect(result.exitCode, equals(1));
        final err = result.stderr.toString();
        expect(err, contains('se exige una DATABASE_URL PostgreSQL'));
        expect(err, contains('NUNCA se debe usar SQLite como alternativa en'));
      });

      test('3.2 server.dart termina con código 1 si DATABASE_URL tiene formato inválido en producción', () async {
        final result = await Process.run(
          'dart',
          ['bin/server.dart'],
          environment: {
            'ENVIRONMENT': 'production',
            'DATABASE_URL': 'sqlite:///data/plata.db',
            'PORT': '8992',
          },
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );

        expect(result.exitCode, equals(1));
        final err = result.stderr.toString();
        expect(err, contains('se exige una DATABASE_URL PostgreSQL'));
      });

      test('3.3 server.dart termina con código 1 si DATABASE_URL solicita sslmode=disable en producción', () async {
        final result = await Process.run(
          'dart',
          ['bin/server.dart'],
          environment: {
            'ENVIRONMENT': 'production',
            'DATABASE_URL': 'postgresql://postgres@127.0.0.1:5433/onta_test?sslmode=disable',
            'PORT': '8993',
          },
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );

        expect(result.exitCode, equals(1));
        final err = result.stderr.toString();
        expect(err, contains('sslmode=disable'));
      });
    });
  });
}

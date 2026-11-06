import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'database.dart';
import 'mail_templates.dart';

class GmailConfig {
  final String clientId;
  final String clientSecret;
  final String redirectUri;
  final String from;
  final String adminUserId;
  final List<int> encryptionKey;

  GmailConfig(
      {required this.clientId,
      required this.clientSecret,
      required this.redirectUri,
      required this.from,
      required this.adminUserId,
      required String encryptionKey})
      : encryptionKey = base64Url.decode(base64Url.normalize(encryptionKey)) {
    if (this.encryptionKey.length != 32) {
      throw StateError('GOOGLE_TOKEN_ENCRYPTION_KEY debe contener 32 bytes');
    }
    if (clientId.isEmpty ||
        clientSecret.isEmpty ||
        adminUserId.isEmpty ||
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(from) ||
        Uri.tryParse(redirectUri)?.path != '/api/oauth/google/callback') {
      throw StateError('Configuración de Gmail OAuth incompleta');
    }
  }

  static GmailConfig? fromEnvironment() {
    final env = Platform.environment;
    final values = [
      env['GOOGLE_CLIENT_ID'],
      env['GOOGLE_CLIENT_SECRET'],
      env['GOOGLE_REDIRECT_URI'],
      env['MAIL_FROM'],
      env['GOOGLE_OAUTH_ADMIN_USER_ID'],
      env['GOOGLE_TOKEN_ENCRYPTION_KEY']
    ];
    if (values.any((value) => value == null || value.isEmpty)) return null;
    final redirect = values[2]!;
    if (Uri.parse(redirect).scheme != 'https') {
      throw StateError('GOOGLE_REDIRECT_URI debe usar HTTPS');
    }
    return GmailConfig(
        clientId: values[0]!,
        clientSecret: values[1]!,
        redirectUri: redirect,
        from: values[3]!,
        adminUserId: values[4]!,
        encryptionKey: values[5]!);
  }
}

class GmailService {
  final AppDatabase database;
  final GmailConfig config;
  final http.Client client;
  final _cipher = AesGcm.with256bits();
  String? _accessToken;
  DateTime? _accessExpiresAt;
  Future<String>? _refreshInFlight;

  GmailService(this.database, this.config, {http.Client? client})
      : client = client ?? http.Client();

  static List<int> _randomBytes(int count) {
    final random = Random.secure();
    return List<int>.generate(count, (_) => random.nextInt(256));
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  Future<String> beginAuthorization(String adminUserId) async {
    if (adminUserId != config.adminUserId) {
      throw StateError('Administrador no autorizado');
    }
    final state = base64UrlEncode(_randomBytes(32)).replaceAll('=', '');
    final now = DateTime.now().toUtc();
    await database.transaction((tx) async {
      await tx.execute('DELETE FROM gmail_oauth_states WHERE admin_user_id=?',
          [adminUserId]);
      await tx.execute(
        'INSERT INTO gmail_oauth_states(state_hash,admin_user_id,expires_at) VALUES(?,?,?)',
        [
          _hash(state),
          adminUserId,
          now.add(const Duration(minutes: 10)).toIso8601String()
        ],
      );
    });
    return Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': config.clientId,
      'redirect_uri': config.redirectUri,
      'response_type': 'code',
      'scope': 'https://www.googleapis.com/auth/gmail.send openid email',
      'access_type': 'offline',
      'prompt': 'consent',
      'state': state,
    }).toString();
  }

  Future<void> completeAuthorization(String state, String code) async {
    if (state.isEmpty || code.isEmpty)
      throw StateError('Autorización inválida');
    final valid = await database.transaction((tx) async {
      final rows = await tx.query(
          'DELETE FROM gmail_oauth_states WHERE state_hash=? '
          'RETURNING admin_user_id, expires_at',
          [_hash(state)]);
      return rows.isNotEmpty &&
          rows.first['admin_user_id'] == config.adminUserId &&
          DateTime.tryParse(rows.first['expires_at'].toString())
                  ?.isAfter(DateTime.now().toUtc()) ==
              true;
    });
    if (!valid) throw StateError('Estado OAuth inválido o expirado');
    final data = await _tokenRequest({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': config.redirectUri,
    });
    final access = data['access_token'];
    final refresh = data['refresh_token'];
    final scope = (data['scope'] ?? '').toString();
    if (access is! String ||
        refresh is! String ||
        !scope
            .split(' ')
            .contains('https://www.googleapis.com/auth/gmail.send')) {
      throw StateError('Google no concedió acceso offline para enviar correo');
    }
    final email = await _authorizedEmail(access);
    if (email.toLowerCase() != config.from.toLowerCase()) {
      throw StateError('La cuenta autorizada no coincide con MAIL_FROM');
    }
    final encrypted = await encryptRefreshToken(refresh);
    await database.execute(
      'INSERT INTO gmail_oauth_tokens(id, encrypted_refresh_token, authorized_email, updated_at) '
      'VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET '
      'encrypted_refresh_token=excluded.encrypted_refresh_token, '
      'authorized_email=excluded.authorized_email, updated_at=excluded.updated_at',
      ['primary', encrypted, email, DateTime.now().toUtc().toIso8601String()],
    );
    _accessToken = access;
    _accessExpiresAt = DateTime.now().toUtc().add(Duration(
        seconds: ((data['expires_in'] as num?)?.toInt() ?? 3600) - 60));
  }

  Future<Map<String, dynamic>> _tokenRequest(Map<String, String> fields) async {
    final response = await client.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      body: {
        ...fields,
        'client_id': config.clientId,
        'client_secret': config.clientSecret,
      },
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Google rechazó la renovación OAuth');
    }
    final data = jsonDecode(response.body);
    if (data is! Map) throw StateError('Respuesta OAuth inválida');
    return Map<String, dynamic>.from(data);
  }

  Future<String> _authorizedEmail(String accessToken) async {
    final response = await client.get(
      Uri.parse('https://openidconnect.googleapis.com/v1/userinfo'),
      headers: {'authorization': 'Bearer $accessToken'},
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200)
      throw StateError('No se pudo verificar el remitente');
    final data = jsonDecode(response.body);
    if (data is! Map ||
        data['email_verified'] != true ||
        data['email'] is! String) {
      throw StateError('Cuenta remitente no verificada');
    }
    return data['email'] as String;
  }

  Future<String> encryptRefreshToken(String token) async {
    final box = await _cipher.encrypt(utf8.encode(token),
        secretKey: SecretKey(config.encryptionKey), nonce: _randomBytes(12));
    return jsonEncode({
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
  }

  Future<String> decryptRefreshToken(String stored) async {
    final data = jsonDecode(stored) as Map<String, dynamic>;
    final box = SecretBox(base64Decode(data['ciphertext'] as String),
        nonce: base64Decode(data['nonce'] as String),
        mac: Mac(base64Decode(data['mac'] as String)));
    return utf8.decode(
        await _cipher.decrypt(box, secretKey: SecretKey(config.encryptionKey)));
  }

  Future<String> _getAccessToken({bool force = false}) async {
    if (!force &&
        _accessToken != null &&
        _accessExpiresAt?.isAfter(DateTime.now().toUtc()) == true) {
      return _accessToken!;
    }
    if (_refreshInFlight != null) return _refreshInFlight!;
    final operation = _refreshAccessToken();
    _refreshInFlight = operation;
    try {
      return await operation;
    } finally {
      _refreshInFlight = null;
    }
  }

  Future<String> _refreshAccessToken() async {
    final rows = await database.query(
        'SELECT encrypted_refresh_token,authorized_email FROM gmail_oauth_tokens WHERE id=?',
        ['primary']);
    if (rows.isEmpty ||
        rows.first['authorized_email'].toString().toLowerCase() !=
            config.from.toLowerCase()) {
      throw StateError('Remitente Gmail no autorizado');
    }
    final refresh = await decryptRefreshToken(
        rows.first['encrypted_refresh_token'] as String);
    final data = await _tokenRequest({
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
    });
    if (data['access_token'] is! String)
      throw StateError('Token OAuth inválido');
    if (data['refresh_token'] is String) {
      await database.execute(
          'UPDATE gmail_oauth_tokens SET encrypted_refresh_token=?,updated_at=? WHERE id=?',
          [
            await encryptRefreshToken(data['refresh_token'] as String),
            DateTime.now().toUtc().toIso8601String(),
            'primary'
          ]);
    }
    _accessToken = data['access_token'] as String;
    _accessExpiresAt = DateTime.now().toUtc().add(Duration(
        seconds: ((data['expires_in'] as num?)?.toInt() ?? 3600) - 60));
    return _accessToken!;
  }

  Future<void> sendMail(String to, MailContent content) async {
    if (!RegExp(r'^[^\s@\r\n]+@[^\s@\r\n]+\.[^\s@\r\n]+$').hasMatch(to) ||
        content.subject.contains(RegExp(r'[\r\n]'))) {
      throw ArgumentError('Destinatario o asunto inválido');
    }
    final raw = _mime(to, content);
    var access = await _getAccessToken();
    var response = await _sendRaw(access, raw);
    if (response.statusCode == 401) {
      access = await _getAccessToken(force: true);
      response = await _sendRaw(access, raw);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Gmail rechazó el envío');
    }
  }

  Future<http.Response> _sendRaw(String access, String raw) => client
      .post(
        Uri.parse(
            'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'),
        headers: {
          'authorization': 'Bearer $access',
          'content-type': 'application/json'
        },
        body: jsonEncode({'raw': raw}),
      )
      .timeout(const Duration(seconds: 15));

  String _mime(String to, MailContent content) {
    final boundary =
        'onta-${base64UrlEncode(_randomBytes(12)).replaceAll('=', '')}';
    final subject = base64Encode(utf8.encode(content.subject));
    final text = base64Encode(utf8.encode(content.text));
    final html = base64Encode(utf8.encode(content.html));
    final message = 'From: ${config.from}\r\nTo: $to\r\n'
        'Subject: =?UTF-8?B?$subject?=\r\nMIME-Version: 1.0\r\n'
        'Content-Type: multipart/alternative; boundary="$boundary"\r\n\r\n'
        '--$boundary\r\nContent-Type: text/plain; charset=UTF-8\r\n'
        'Content-Transfer-Encoding: base64\r\n\r\n$text\r\n'
        '--$boundary\r\nContent-Type: text/html; charset=UTF-8\r\n'
        'Content-Transfer-Encoding: base64\r\n\r\n$html\r\n--$boundary--\r\n';
    return base64UrlEncode(utf8.encode(message)).replaceAll('=', '');
  }
}

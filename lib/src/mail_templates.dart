import 'dart:convert';

class MailContent {
  final String subject;
  final String text;
  final String html;
  const MailContent(this.subject, this.text, this.html);
}

class MailTemplates {
  static MailContent verification(String link) => _linkMail(
      'Verificá tu cuenta de Onta My Money',
      'Confirmá tu correo para activar tu cuenta.',
      link,
      'Verificar cuenta',
      'El enlace vence en 30 minutos.');

  static MailContent passwordReset(String link) => _linkMail(
      'Restablecer contraseña de Onta My Money',
      'Recibimos una solicitud para cambiar tu contraseña.',
      link,
      'Restablecer contraseña',
      'El enlace vence en 30 minutos.');

  static MailContent securityNotice(String detail) {
    final safe = const HtmlEscape().convert(detail);
    return MailContent(
      'Aviso de seguridad de Onta My Money',
      '$detail\nSi no reconocés esta actividad, restablecé tu contraseña.',
      _frame(
          '<p>$safe</p><p>Si no reconocés esta actividad, restablecé tu contraseña.</p>'),
    );
  }

  static MailContent _linkMail(
      String subject, String intro, String link, String action, String expiry) {
    final safeLink = const HtmlEscape().convert(link);
    return MailContent(
        subject,
        '$intro\n$link\n$expiry\nSi no lo solicitaste, ignorá este mensaje.',
        _frame('<p>${const HtmlEscape().convert(intro)}</p>'
            '<p><a href="$safeLink" style="display:inline-block;background:#0e9f6e;'
            'color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none">'
            '${const HtmlEscape().convert(action)}</a></p>'
            '<p>$expiry Si no lo solicitaste, ignorá este mensaje.</p>'));
  }

  static String _frame(String content) =>
      '<!doctype html><html lang="es"><body style="margin:0;background:#f3f7f5;'
      'font-family:Arial,sans-serif;color:#17332a">'
      '<div style="max-width:560px;margin:32px auto;background:#fff;padding:32px;'
      'border-radius:16px"><h1 style="color:#087f5b">Onta My Money</h1>'
      '$content<p style="font-size:12px;color:#66756f">'
      'Este es un mensaje automático de seguridad.</p></div></body></html>';
}

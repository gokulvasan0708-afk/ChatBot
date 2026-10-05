import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class AiApiException implements Exception {
  final String message;
  AiApiException(this.message);

  @override
  String toString() => message;
}

class AiApiService {
  // Release: flutter build <apk|web> --release --dart-define=AI_BASE_URL=https://api.yourdomain.com
  static const String _override = String.fromEnvironment('AI_BASE_URL');

  // Optional: hard-code your production URL here instead of --dart-define.
  static const String _prodUrl = '';

  /// null => not configured (only possible in release builds).
  static String? get baseUrl {
    final u = _override.isNotEmpty ? _override : _prodUrl;
    if (u.isNotEmpty) return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
    if (kReleaseMode) return null; // never fall back to localhost in release
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8000'; // Android emulator -> host PC
    }
    return 'http://127.0.0.1:8000';
  }

  final http.Client _client = http.Client();

  void dispose() => _client.close();

  Future<String> sendMessage(String message) async {
    final base = baseUrl;
    if (base == null) {
      throw AiApiException('AI service is not configured.');
    }
    try {
      final res = await _client
          .post(
            Uri.parse('$base/chat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'message': message}),
          )
          .timeout(const Duration(seconds: 70));

      final body = utf8.decode(res.bodyBytes);

      if (res.statusCode == 200) {
        final text = (jsonDecode(body) as Map)['response'];
        if (text is String && text.trim().isNotEmpty) return text;
        throw AiApiException('Empty response from server.');
      }
      throw AiApiException(_errorFor(res.statusCode, body));
    } on TimeoutException {
      throw AiApiException('Request timed out. Please try again.');
    } on http.ClientException {
      throw AiApiException('Cannot reach the server. Check your connection.');
    } on FormatException {
      throw AiApiException('Invalid response from server.');
    }
  }

  static String _errorFor(int code, String body) {
    if (code == 429) return 'Too many requests. Please wait a moment.';
    if (code == 401 || code == 403) return 'Not authorized to use the assistant.';
    try {
      final d = (jsonDecode(body) as Map)['detail'];
      if (d is String && d.isNotEmpty && d.length < 200) return d;
    } catch (_) {}
    if (code >= 500) return 'The AI service is busy. Please try again.';
    return 'Request failed ($code).';
  }
}

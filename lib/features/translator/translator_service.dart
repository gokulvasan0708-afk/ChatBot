import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../ai_assistant/ai_api_service.dart';

class TranslatorLanguage {
  final String code, name, native;
  const TranslatorLanguage(this.code, this.name, this.native);
}

class TranslatorException implements Exception {
  final String message;
  TranslatorException(this.message);
  @override
  String toString() => message;
}

class TranslatorPrefs {
  final String target; // preferred language code
  final String source; // 'auto' or a language code
  const TranslatorPrefs({this.target = 'en', this.source = 'auto'});
}

class TranslationResult {
  final String text;
  final String detected;
  const TranslationResult(this.text, this.detected);
}

/// Global translator logic (no UI). One instance of state for the whole app.
class TranslatorService {
  TranslatorService._();

  static const List<TranslatorLanguage> languages = [
    TranslatorLanguage('ta', 'Tamil', 'தமிழ்'),
    TranslatorLanguage('en', 'English', 'English'),
    TranslatorLanguage('ml', 'Malayalam', 'മലയാളം'),
    TranslatorLanguage('hi', 'Hindi', 'हिन्दी'),
    TranslatorLanguage('te', 'Telugu', 'తెలుగు'),
    TranslatorLanguage('kn', 'Kannada', 'ಕನ್ನಡ'),
  ];

  static String nameOf(String code) {
    if (code == 'auto') return 'Auto-detect';
    for (final l in languages) {
      if (l.code == code) return l.name;
    }
    return code;
  }

  /// Listen to this to react to preference changes.
  static final ValueNotifier<TranslatorPrefs> prefs =
      ValueNotifier(const TranslatorPrefs());

  static String? _loadedFor;
  static final Map<String, TranslationResult> _cache = {};

  static DocumentReference<Map<String, dynamic>>? get _userDoc {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    return FirebaseFirestore.instance.collection('users').doc(uid);
  }

  /// Loads saved preference once per signed-in account (safe to call often).
  static Future<void> loadPrefs() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _loadedFor == uid) return;
    _loadedFor = uid;
    _cache.clear();
    try {
      final d = (await _userDoc!.get()).data() ?? {};
      final t = (d['translatorTarget'] ?? 'en').toString();
      final s = (d['translatorSource'] ?? 'auto').toString();
      prefs.value = TranslatorPrefs(
        target: languages.any((l) => l.code == t) ? t : 'en',
        source: (s == 'auto' || languages.any((l) => l.code == s)) ? s : 'auto',
      );
    } catch (_) {
      _loadedFor = null; // retry next time; defaults stay in place
    }
  }

  /// Saves for future chats (updates UI immediately, persists in background).
  static Future<void> savePrefs(TranslatorPrefs p) async {
    prefs.value = p;
    try {
      await _userDoc?.set(
        {'translatorTarget': p.target, 'translatorSource': p.source},
        SetOptions(merge: true),
      );
    } catch (_) {
      throw TranslatorException('Could not save settings. Check your connection.');
    }
  }

  /// Translates up to 5 texts in one request. Order is preserved.
  /// Throws [TranslatorException] with a user-friendly message.
  /// Test hook: replaces the network call in unit tests.
  @visibleForTesting
  static Future<List<TranslationResult>> Function(List<String>)? translateOverride;

  static Future<List<TranslationResult>> translate(List<String> texts) async {
    if (texts.isEmpty) return const [];
    final override = translateOverride;
    if (override != null) return override(texts);
    final p = prefs.value;
    String k(String t) => '${p.source}|${p.target}|$t';

    final out = List<TranslationResult?>.filled(texts.length, null);
    final missing = <int>[];
    for (var i = 0; i < texts.length; i++) {
      final hit = _cache[k(texts[i])];
      if (hit != null) {
        out[i] = hit;
      } else {
        missing.add(i);
      }
    }

    if (missing.isNotEmpty) {
      final base = AiApiService.baseUrl;
      if (base == null) throw TranslatorException('Translator is not configured.');
      try {
        final res = await http
            .post(
              Uri.parse('$base/translate'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'texts': [for (final i in missing) texts[i]],
                'target': p.target,
                'source': p.source,
              }),
            )
            .timeout(const Duration(seconds: 40));
        if (res.statusCode == 429) {
          throw TranslatorException('Too many requests. Try again in a moment.');
        }
        if (res.statusCode != 200) {
          throw TranslatorException('Translation failed. Please try again.');
        }
        final list = (jsonDecode(res.body)['translations'] as List);
        if (list.length != missing.length) {
          throw TranslatorException('Translation failed. Please try again.');
        }
        for (var j = 0; j < missing.length; j++) {
          final m = list[j] as Map;
          final r = TranslationResult(
              (m['text'] ?? '').toString(), (m['source'] ?? '').toString());
          out[missing[j]] = r;
          _cache[k(texts[missing[j]])] = r;
        }
      } on TranslatorException {
        rethrow;
      } on TimeoutException {
        throw TranslatorException('Translation timed out. Please try again.');
      } catch (_) {
        throw TranslatorException('Cannot reach translator. Check your connection.');
      }
    }
    return [for (final r in out) r!];
  }
}

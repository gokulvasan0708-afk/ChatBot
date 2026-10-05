import 'package:flutter/foundation.dart';

import 'ai_api_service.dart';
import 'chat_message.dart';

/// Holds chat state outside the UI so history survives open/close and page changes.
class AiChatController extends ChangeNotifier {
  AiChatController._();
  static final AiChatController instance = AiChatController._();

  final _api = AiApiService();
  final List<ChatMessage> messages = [];
  bool loading = false;
  String? _lastPrompt;
  int _epoch = 0; // bumped on clear so late replies are dropped

  Future<void> send(String raw, {bool retry = false}) async {
    final text = (retry ? _lastPrompt : raw)?.trim() ?? '';
    if (text.isEmpty || loading) return;

    if (retry) {
      if (messages.isNotEmpty && messages.last.isError) messages.removeLast();
    } else {
      messages.add(ChatMessage(text: text, isUser: true));
    }
    _lastPrompt = text;
    loading = true;
    final epoch = _epoch;
    notifyListeners();

    ChatMessage result;
    try {
      result = ChatMessage(text: await _api.sendMessage(text), isUser: false);
    } on AiApiException catch (e) {
      result = ChatMessage(text: e.message, isUser: false, isError: true);
    } catch (_) {
      result = ChatMessage(
          text: 'Something went wrong.', isUser: false, isError: true);
    }
    if (epoch != _epoch) return; // chat was cleared (e.g. sign-out) meanwhile
    messages.add(result);
    loading = false;
    notifyListeners();
  }

  void retry() => send('', retry: true);

  /// [force] is used on sign-out: drops history even mid-request.
  void clear({bool force = false}) {
    if (loading && !force) return;
    _epoch++;
    messages.clear();
    _lastPrompt = null;
    loading = false;
    notifyListeners();
  }
}

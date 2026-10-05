class ChatMessage {
  final String text;
  final bool isUser;
  final bool isError;
  final DateTime time;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.isError = false,
    DateTime? time,
  }) : time = time ?? DateTime.now();
}

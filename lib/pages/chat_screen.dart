import '../features/translator/translator_popup.dart';
import '../features/ai_assistant/ai_launcher.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';

import 'cosmic_background.dart';
import 'private_chat_screen.dart';
import '../services/chat_settings_service.dart';
import '../services/voice_message_service.dart';
import '../services/call_service.dart';

import '../widgets/top_alert.dart';
import '../services/active_conversation.dart';
import '../widgets/incoming_message_alert.dart';

// ================================================================
// MARK A 1-TO-1 CHAT AS READ (clears the unread dot + Notify alert)
// ----------------------------------------------------------------
// Companion to markGroupRead() in pages/groupchat.dart. Read
// receipts themselves still live on the individual message docs
// ('readBy', used for the "Seen" tick), but the Nexus Notify
// "unseen messages" reminder (widgets/nexus_notify.dart) needs to
// know -- for MANY chats at once -- whether I've caught up, and
// reading every chat's newest message document just to answer that
// would cost one extra Firestore read per chat on every scan.
//
// So the same per-user marker pattern the groups use is mirrored
// onto the chat document itself:
//
//   chats/<chatId> { lastReadAt: { <uid>: <Timestamp> } }
//
// which lets the reminder scan answer "anything unseen?" for every
// chat from the single chats query it already has to run.
// ================================================================

Future<void> markChatRead(String chatId) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null || chatId.isEmpty) return;

  try {
    await FirebaseFirestore.instance.collection('chats').doc(chatId).set({
      'lastReadAt': {uid: FieldValue.serverTimestamp()},
    }, SetOptions(merge: true));
  } catch (e) {
    debugPrint('Mark chat read error: $e');
  }
}

// ================================================================
// SET NICKNAME DIALOGS
// ----------------------------------------------------------------
// Each dialog owns its own TextEditingController (created in initState,
// disposed in its own State.dispose()) instead of the caller creating a
// controller and disposing it manually right after showDialog's Future
// resolves. showDialog's Future completes the instant Navigator.pop()
// runs -- before the dialog route's exit transition has actually
// finished animating this content out of the tree -- so a manual
// dispose() right there can run while the TextField is still being
// rebuilt by that transition, throwing "A TextEditingController was
// used after being disposed." Owning the controller in the dialog's
// own State keeps controller disposal in sync with the TextField's
// real removal from the tree, no matter how long the exit transition
// takes. Two near-identical variants exist only because the two call
// sites (the open-chat top menu vs. the profile page's top menu) use
// slightly different visual styling that predates this fix.
// ================================================================

class _NicknameDialog extends StatefulWidget {
  final String initialValue;
  const _NicknameDialog({required this.initialValue});

  @override
  State<_NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends State<_NicknameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF18181F),
      title: const Text('Set Nickname', style: TextStyle(color: Colors.white)),
      content: TextField(
        controller: _controller,
        style: const TextStyle(color: Colors.white),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('SAVE'),
        ),
      ],
    );
  }
}

class _EditMessageDialog extends StatefulWidget {
  final String initialValue;
  const _EditMessageDialog({required this.initialValue});

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF18181F),
      title: const Text('Edit Message', style: TextStyle(color: Colors.white)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 5,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          hintText: 'Message',
          hintStyle: TextStyle(color: Colors.white38),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('SAVE', style: TextStyle(color: Color(0xFFA78BFA))),
        ),
      ],
    );
  }
}

class _ProfileNicknameDialog extends StatefulWidget {
  final String initialValue;
  const _ProfileNicknameDialog({required this.initialValue});

  @override
  State<_ProfileNicknameDialog> createState() => _ProfileNicknameDialogState();
}

class _ProfileNicknameDialogState extends State<_ProfileNicknameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF18181F),
      title: const Text('Set Nickname', style: TextStyle(color: Colors.white)),
      content: TextField(
        controller: _controller,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          hintText: 'Nickname',
          hintStyle: TextStyle(color: Colors.white38),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('SAVE', style: TextStyle(color: Color(0xFFA78BFA))),
        ),
      ],
    );
  }
}

// ================================================================
// TYPING INDICATOR
// ----------------------------------------------------------------
// "typing..." label plus three small dots that bounce up and down
// in sequence (each dot's animation is offset from the next), for
// a subtle sequential vertical animation. Purely presentational --
// visibility/backend wiring is owned entirely by the caller
// (`_buildTypingIndicatorBar` in chat_screen.dart), which only
// mounts this widget while the other user is actually typing.
// ================================================================

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();
  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _dot(int index) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // Each dot lags 1/3 of a cycle behind the previous one, so
        // they bounce up and back down one after another instead of
        // all moving together.
        final t = ((_controller.value - (index * (1 / 3))) % 1.0 + 1.0) % 1.0;
        final bounce = t < 0.5 ? (t * 2) : (2 - t * 2);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1.5),
          child: Transform.translate(
            offset: Offset(0, -3.0 * bounce),
            child: Container(
              width: 4,
              height: 4,
              decoration: const BoxDecoration(
                color: Color(0xFFA78BFA),
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text(
          'typing...',
          style: TextStyle(
            color: Color(0xFFA78BFA),
            fontSize: 11,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(width: 6),
        _dot(0),
        _dot(1),
        _dot(2),
      ],
    );
  }
}

// ================================================================
// PRESENCE STATUS DOT
// ----------------------------------------------------------------
// Small colored indicator that mirrors the presence status text
// exactly: a soft, continuously pulsing green glow while the status
// is "Active now", or a plain static red dot for any other/offline
// status ("Active just now", "Active 15 min ago", etc). Shared by
// both the Chats page list (chat_page.dart) and this Chat screen's
// header so there is exactly one presence-dot implementation --
// they read the same `isActive` boolean already derived from the
// existing Active Now / Last Seen calculation, so the dot can never
// drift out of sync with the status text next to it. The pulse
// animation only ever runs while `isActive` is true; it is stopped
// and reset the instant `isActive` flips to false, so no glow can
// linger after the user goes offline.
// ================================================================

class PresenceStatusDot extends StatefulWidget {
  final bool isActive;

  const PresenceStatusDot({super.key, required this.isActive});

  @override
  State<PresenceStatusDot> createState() => _PresenceStatusDotState();
}

class _PresenceStatusDotState extends State<PresenceStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant PresenceStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (widget.isActive) {
      _controller.repeat(reverse: true);
    } else {
      // Stop immediately and reset so no glow can linger once offline.
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) {
      return Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFEF4444),
        ),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) {
        final glow = _controller.value; // 0..1, pulses back and forth
        return Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Color.lerp(
              const Color(0xFF10B981),
              const Color(0xFF10B981),
              glow,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(
                  0xFF10B981,
                ).withValues(alpha: 0.25 + 0.35 * glow),
                blurRadius: 3 + 4 * glow,
                spreadRadius: 0.5 + 1 * glow,
              ),
            ],
          ),
        );
      },
    );
  }
}

ImageProvider? _profileImageProvider(String path) {
  final value = path.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://'))
    return NetworkImage(value);
  return AssetImage(value);
}

class ChatScreen extends StatefulWidget {
  final String otherUserUid;
  final String otherUserName;
  final String otherUserImage;
  final bool usePrivateProfile;

  // ==========================================================
  // NEW: optional callback for tapping the profile header.
  // If not provided, we fall back to a named route ('/profile')
  // passing otherUserUid as the argument. Wire up either one to
  // match however your app already navigates to a profile page.
  // ==========================================================
  final void Function(String otherUserUid)? onProfileTap;

  // ==========================================================
  // NEW: optional target message id (e.g. from Chat Search Mode
  // on the Chats page). When provided and the message exists in
  // this chat, the screen auto-scrolls to it on open and briefly
  // highlights it instead of jumping straight to the bottom.
  // ==========================================================
  final String? targetMessageId;

  const ChatScreen({
    super.key,
    required this.otherUserUid,
    required this.otherUserName,
    required this.otherUserImage,
    this.usePrivateProfile = false,
    this.onProfileTap,
    this.targetMessageId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with WidgetsBindingObserver, AiLauncherHide {
  final TextEditingController messageController = TextEditingController();
  late final TranslatorController _translator = TranslatorController(
    messageController,
  );

  // ==========================================================
  // ATTACHMENT MENU
  // ==========================================================

  Future<void> _showAttachmentMenu() async {
    if (_isSendingAttachment || _isSendingVoice || _isRecordingVoice) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF18181F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                _attachmentMenuTile(
                  context: sheetContext,
                  icon: Icons.photo_library_rounded,
                  title: 'Photos',
                  subtitle: 'Select one or multiple photos',
                  onTap: _pickPhotos,
                ),
                _attachmentMenuTile(
                  context: sheetContext,
                  icon: Icons.video_library_rounded,
                  title: 'Videos',
                  subtitle: 'Select one or multiple videos',
                  onTap: _pickVideos,
                ),
                _attachmentMenuTile(
                  context: sheetContext,
                  icon: Icons.audiotrack_rounded,
                  title: 'Audios',
                  subtitle: 'Select one or multiple audio files',
                  onTap: _pickAudios,
                ),
                _attachmentMenuTile(
                  context: sheetContext,
                  icon: Icons.insert_drive_file_rounded,
                  title: 'Files',
                  subtitle: 'Select one or multiple files/documents',
                  onTap: _pickFiles,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _attachmentMenuTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required Future<void> Function() onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: Container(
        width: 42,
        height: 42,
        decoration: const BoxDecoration(
          color: Color(0xFF20202A),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: const Color(0xFFA78BFA), size: 22),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: Colors.white54, fontSize: 11),
      ),
      onTap: () async {
        Navigator.pop(context);
        await onTap();
      },
    );
  }

  Future<void> _pickPhotos() async {
    try {
      final images = await _attachmentImagePicker.pickMultiImage(
        imageQuality: 90,
        maxWidth: 2000,
        maxHeight: 2000,
      );
      if (images.isEmpty) return;
      await _sendPickedAttachments(
        paths: images.map((x) => x.path).toList(),
        messageType: 'photo',
      );
    } catch (e) {
      _showAttachmentError('Unable to select photos.');
      debugPrint('Photo picker error: $e');
    }
  }

  Future<void> _pickVideos() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.video,
        allowMultiple: true,
        withData: false,
      );
      if (files.isEmpty) return;
      final paths = files
          .map((file) => file.path)
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          .toList();
      if (paths.isEmpty) {
        _showAttachmentError('Unable to access the selected videos.');
        return;
      }
      await _sendPickedAttachments(paths: paths, messageType: 'video');
    } catch (e) {
      _showAttachmentError('Unable to select videos.');
      debugPrint('Video picker error: $e');
    }
  }

  Future<void> _pickAudios() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
        withData: false,
      );
      if (files.isEmpty) return;
      final paths = files
          .map((file) => file.path)
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          .toList();
      if (paths.isEmpty) {
        _showAttachmentError('Unable to access the selected audio files.');
        return;
      }
      await _sendPickedAttachments(paths: paths, messageType: 'audio');
    } catch (e) {
      _showAttachmentError('Unable to select audio files.');
      debugPrint('Audio picker error: $e');
    }
  }

  Future<void> _pickFiles() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: true,
        withData: false,
      );
      if (files.isEmpty) return;
      final paths = files
          .map((file) => file.path)
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          .toList();
      if (paths.isEmpty) {
        _showAttachmentError('Unable to access the selected files.');
        return;
      }
      await _sendPickedAttachments(paths: paths, messageType: 'file');
    } catch (e) {
      _showAttachmentError('Unable to select files.');
      debugPrint('File picker error: $e');
    }
  }

  void _showAttachmentError(String message) {
    if (!mounted) return;
    showTopAlert(context, message);
  }

  String _attachmentFileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash >= 0 ? normalized.substring(slash + 1) : normalized;
  }

  String _attachmentExtension(String path) {
    final name = _attachmentFileName(path);
    final dot = name.lastIndexOf('.');
    return dot > 0 && dot < name.length - 1
        ? name.substring(dot + 1).toLowerCase()
        : '';
  }

  String _guessMimeType(String type, String path) {
    final ext = _attachmentExtension(path);
    const imageExt = {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'bmp',
      'heic',
      'heif',
    };
    const videoExt = {'mp4', 'mov', 'm4v', 'mkv', 'webm', 'avi', '3gp'};
    const audioExt = {'mp3', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'flac', 'amr'};

    if (type == 'photo' || imageExt.contains(ext))
      return 'image/$ext'.replaceFirst('image/jpg', 'image/jpeg');
    if (type == 'video' || videoExt.contains(ext)) return 'video/$ext';
    if (type == 'audio' || audioExt.contains(ext)) return 'audio/$ext';
    return 'application/octet-stream';
  }

  String _cloudinaryResourceTypeFor(String messageType) {
    if (messageType == 'photo') return 'image';
    if (messageType == 'video' || messageType == 'audio') return 'video';
    return 'raw';
  }

  Future<Map<String, dynamic>> _uploadAttachmentToCloudinary({
    required String path,
    required String messageType,
  }) async {
    final resourceType = _cloudinaryResourceTypeFor(messageType);
    final endpoint = Uri.parse(
      'https://api.cloudinary.com/v1_1/$_cloudinaryCloudName/$resourceType/upload',
    );

    final request = http.MultipartRequest('POST', endpoint);
    request.fields['upload_preset'] = _chatMediaUploadPreset;
    request.files.add(await http.MultipartFile.fromPath('file', path));

    final response = await request.send();
    final body = await response.stream.bytesToString();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      debugPrint('Cloudinary attachment upload failed: $body');
      throw Exception('Cloudinary upload failed (${response.statusCode})');
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map) throw Exception('Invalid Cloudinary response');

    final data = Map<String, dynamic>.from(decoded);
    final secureUrl = (data['secure_url'] ?? '').toString().trim();
    final publicId = (data['public_id'] ?? '').toString().trim();

    if (secureUrl.isEmpty || publicId.isEmpty) {
      throw Exception('Cloudinary did not return a usable file URL.');
    }

    return {
      'secureUrl': secureUrl,
      'publicId': publicId,
      'resourceType': (data['resource_type'] ?? resourceType).toString(),
    };
  }

  Future<void> _sendPickedAttachments({
    required List<String> paths,
    required String messageType,
  }) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null || paths.isEmpty) return;

    if (_otherSettings['blocked'] == true) {
      _showAttachmentError('This account has blocked you.');
      return;
    }

    if (_isSendingAttachment) return;

    setState(() => _isSendingAttachment = true);

    try {
      final selectedReply = replyMessage;
      bool sentAtLeastOne = false;

      for (final path in paths) {
        if (!mounted) return;

        final file = File(path);
        if (!await file.exists()) continue;
        final size = await file.length();
        if (size <= 0) continue;

        final fileName = _attachmentFileName(path);
        final upload = await _uploadAttachmentToCloudinary(
          path: path,
          messageType: messageType,
        );

        final now = FieldValue.serverTimestamp();
        final messageRef = messagesReference.doc();
        final chatType = (widget.usePrivateProfile || _isConnected)
            ? 'private'
            : 'public';

        await messageRef.set({
          'senderId': currentUser.uid,
          'receiverId': widget.otherUserUid,
          'text': '',
          'messageType': messageType,
          'fileUrl': upload['secureUrl'],
          'filePublicId': upload['publicId'],
          'cloudinaryResourceType': upload['resourceType'],
          'fileName': fileName,
          'fileSize': size,
          'mimeType': _guessMimeType(messageType, path),
          'sentAt': now,
          'expiresAt': chatType == 'public'
              ? Timestamp.fromDate(
                  DateTime.now().add(const Duration(hours: 24)),
                )
              : null,
          'chatTypeAtSend': chatType,
          'savedBy': <String>[],
          'hiddenFor': <String>[],
          'readBy': <String>[],
          'replyTo': selectedReply == null
              ? null
              : {
                  'messageId': selectedReply.id,
                  'senderId': (selectedReply.data()?['senderId'] ?? '')
                      .toString(),
                  'messageType':
                      (selectedReply.data()?['messageType'] ?? 'text')
                          .toString(),
                  'text':
                      (selectedReply.data()?['messageType'] ?? 'text')
                              .toString() ==
                          'voice'
                      ? '🎤 Voice message'
                      : (selectedReply.data()?['text'] ?? '').toString(),
                },
        });

        sentAtLeastOne = true;

        final lastMessageLabel = switch (messageType) {
          'photo' => '📷 Photo',
          'video' => '🎬 Video',
          'audio' => '🎵 Audio',
          _ => '📎 File',
        };

        await chatReference.set({
          'participants': [currentUser.uid, widget.otherUserUid],
          'lastMessage': lastMessageLabel,
          'lastMessageTime': now,
          'lastMessageSenderId': currentUser.uid,
          'otherUserUid': widget.otherUserUid,
          'hiddenFor': FieldValue.arrayRemove([currentUser.uid]),
          'updatedAt': now,
        }, SetOptions(merge: true));

        if (_otherSettings['muted'] != true) {
          try {
            final receiverDoc = await FirebaseFirestore.instance
                .collection('users')
                .doc(widget.otherUserUid)
                .get();
            final receiverToken = (receiverDoc.data()?['fcmToken'] ?? '')
                .toString()
                .trim();
            if (receiverToken.isNotEmpty) {
              await http.post(
                Uri.parse('https://chatbot-worker.gokulmi56cro.workers.dev'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'fcmToken': receiverToken,
                  'senderName': currentUser.displayName ?? 'New message',
                  'message': lastMessageLabel,
                  'senderUid': currentUser.uid,
                }),
              );
            }
          } catch (e) {
            debugPrint('Attachment notification error: $e');
          }
        }
      }

      if (sentAtLeastOne && mounted) {
        setState(() => replyMessage = null);
        await Future.delayed(const Duration(milliseconds: 120));
        if (mounted && scrollController.hasClients) {
          await scrollController.animateTo(
            scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      }
    } catch (e) {
      debugPrint('Send attachment error: $e');
      _showAttachmentError('Failed to send attachment. $e');
    } finally {
      if (mounted) setState(() => _isSendingAttachment = false);
    }
  }

  Future<void> _openAttachmentUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) _showAttachmentError('Unable to open this file.');
    } catch (e) {
      debugPrint('Open attachment error: $e');
      _showAttachmentError('Unable to open this file.');
    }
  }

  Widget _buildAttachmentMessageContent(
    DocumentSnapshot<Map<String, dynamic>> message,
    Map<String, dynamic> data,
    bool isMe,
  ) {
    final type = (data['messageType'] ?? 'file').toString();
    final url = (data['fileUrl'] ?? '').toString().trim();
    final name = (data['fileName'] ?? 'File').toString();
    final size = int.tryParse((data['fileSize'] ?? 0).toString()) ?? 0;

    if (url.isEmpty) {
      return const Text(
        'Attachment unavailable',
        style: TextStyle(color: Colors.white70),
      );
    }

    if (type == 'photo') {
      return GestureDetector(
        onTap: () => _openAttachmentUrl(url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240, maxHeight: 300),
            child: Image.network(
              url,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return const SizedBox(
                  width: 210,
                  height: 180,
                  child: Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white70,
                    ),
                  ),
                );
              },
              errorBuilder: (_, _, _) => const SizedBox(
                width: 210,
                height: 120,
                child: Center(
                  child: Icon(
                    Icons.broken_image_rounded,
                    color: Colors.white70,
                    size: 40,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final IconData icon = switch (type) {
      'video' => Icons.play_circle_fill_rounded,
      'audio' => Icons.audiotrack_rounded,
      _ => Icons.insert_drive_file_rounded,
    };

    final String label = switch (type) {
      'video' => 'Video',
      'audio' => 'Audio',
      _ => 'File',
    };

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openAttachmentUrl(url),
      child: Container(
        constraints: const BoxConstraints(minWidth: 205, maxWidth: 245),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (size > 0) ...[
                    const SizedBox(height: 3),
                    Text(
                      _formatFileSize(size),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 5),
            const Icon(
              Icons.open_in_new_rounded,
              color: Colors.white60,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  // ==========================================================
  // VOICE MESSAGE
  // ==========================================================
  final AudioRecorder _voiceRecorder = AudioRecorder();
  final AudioPlayer _voicePlayer = AudioPlayer();
  bool _isRecordingVoice = false;
  bool _isSendingVoice = false;
  int _voiceRecordingSeconds = 0;
  Timer? _voiceRecordingTimer;
  String? _playingVoiceMessageId;

  // ==========================================================
  // PHOTO / VIDEO / AUDIO / FILE ATTACHMENTS
  // ==========================================================
  final ImagePicker _attachmentImagePicker = ImagePicker();
  bool _isSendingAttachment = false;

  // Create an UNSIGNED Cloudinary upload preset with this exact name
  // (or change this value to your existing media preset).
  // The profile-image preset must not be reused if it only allows images.
  static const String _cloudinaryCloudName = 'hmae9acm';
  static const String _chatMediaUploadPreset = 'nexus_chat_media';

  final ScrollController scrollController = ScrollController();

  // ==========================================================
  // NEW: focus node for the expanding text field
  // ==========================================================
  final FocusNode messageFocusNode = FocusNode();

  // ==========================================================
  // REPLY MESSAGE
  // ==========================================================

  DocumentSnapshot<Map<String, dynamic>>? replyMessage;

  bool get isReplying => replyMessage != null;

  void _setReplyMessage(DocumentSnapshot<Map<String, dynamic>> message) {
    final data = message.data();

    if (data == null) return;

    setState(() {
      replyMessage = message;
    });
  }

  void _cancelReply() {
    setState(() {
      replyMessage = null;
    });
  }

  // ==========================================================
  // NEW: input focus / expanding text field
  // ==========================================================

  bool _inputFocused = false;

  void _handleFocusChange() {
    setState(() {
      _inputFocused = messageFocusNode.hasFocus;
    });
  }

  // ==========================================================
  // NEW: scroll-to-bottom button + unread dot state
  // ==========================================================

  bool _showScrollToBottomButton = false;
  bool _hasUnseenNewMessage = false;
  bool _initialScrollDone = false;

  // ==========================================================
  // NEW: track which message ids we already know about, so we
  // can detect brand-new arrivals and briefly highlight them.
  // ==========================================================

  final Set<String> _knownMessageIds = {};
  final Set<String> _highlightedMessageIds = {};
  bool _knownIdsInitialized = false;

  // ==========================================================
  // NEW: scroll-to-searched-message support (Chat Search Mode).
  // Each message bubble is given a GlobalKey (created lazily) so
  // we can ask the framework to scroll it fully into view once
  // it has actually been laid out, even though ListView.builder
  // only builds items near the viewport.
  // ==========================================================

  // Local build contexts are used instead of GlobalKey so opening/closing
  // chats cannot leave a GlobalKey attached to an inactive route.
  final Map<String, BuildContext> _messageBubbleContexts = {};

  void _rememberMessageContext(String messageId, BuildContext context) {
    _messageBubbleContexts[messageId] = context;
  }

  // ==========================================================
  // NEW: swipe-in-the-middle-of-the-chat to reveal timestamps
  // ==========================================================

  bool _revealOtherTimestamps = false;
  bool _revealMyTimestamps = false;
  double _globalDragAccumulator = 0;
  // Tracks vertical movement of the same pointer trace as
  // _globalDragAccumulator so the reveal below can tell a deliberate
  // horizontal swipe apart from an ordinary vertical scroll (see
  // _handleGlobalPointerMove).
  double _globalDragAccumulatorY = 0;
  Timer? _revealHideTimer;

  // FIX: true whenever a per-message swipe-to-reply drag (started by
  // touching an actual bubble) is in progress. While this is true the
  // background "swipe the empty space to reveal timestamps" gesture
  // below is ignored, so touching a bubble and swiping only ever does
  // swipe-to-reply, and never also reveals timestamps at the same time.
  bool _bubbleDragActive = false;

  void _setBubbleDragActive(bool active) {
    _bubbleDragActive = active;
    if (active) {
      // A bubble drag just claimed this pointer -- make sure it can't
      // also count toward (or have already started) a timestamp reveal.
      _globalDragAccumulator = 0;
      _globalDragAccumulatorY = 0;
      if (_revealOtherTimestamps || _revealMyTimestamps) {
        setState(() {
          _revealOtherTimestamps = false;
          _revealMyTimestamps = false;
        });
      }
    }
  }

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _otherUserSub;
  StreamSubscription<Map<String, dynamic>>? _mySettingsSub;
  StreamSubscription<Map<String, dynamic>>? _otherSettingsSub;
  Map<String, dynamic> _otherUserData = {};
  Map<String, dynamic> _mySettings = {};
  Map<String, dynamic> _otherSettings = {};
  Timer? _typingStopTimer;
  bool _isConnected = false;
  bool _otherTyping = false;

  // ==========================================================
  // NEW: real-time messages stream, created ONCE and reused.
  // ----------------------------------------------------------
  // `messagesReference` is a getter that builds a brand new
  // Query/Stream object every time it's evaluated. This screen's
  // build() (and therefore `_buildMessages()`) reruns on every
  // setState() in this State -- e.g. scrolling
  // (`_handleScrollPosition`), focusing the input
  // (`_handleFocusChange`), selecting/cancelling a reply, the
  // new-message highlight timer, etc. -- all of which happen
  // constantly during normal chat use. If the StreamBuilder below
  // were handed a freshly-constructed `.snapshots()` stream on
  // every one of those rebuilds, Flutter would treat it as a
  // different stream each time, tear down the previous Firestore
  // listener, and briefly reset to a loading state before
  // resubscribing -- which is what made incoming/outgoing messages
  // feel like they needed a manual refresh/re-open to show up
  // reliably. Building the stream once here and reusing the same
  // instance for the whole lifetime of this screen keeps a single,
  // continuously-open real-time listener, exactly like the rest of
  // this screen's presence/settings listeners already do.
  // ==========================================================

  late final Stream<QuerySnapshot<Map<String, dynamic>>> _messagesStream =
      messagesReference
          .orderBy('sentAt', descending: false)
          .snapshots(includeMetadataChanges: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // ==========================================================
    // IN-APP MESSAGE BAR SUPPRESSION
    // ----------------------------------------------------------
    // Tell the app that THIS conversation is the one on screen, so
    // the heads-up bar (widgets/incoming_message_alert.dart) stays
    // silent for messages arriving in this very chat -- they are
    // already visible in the thread. Messages from every OTHER chat
    // or group still pop their bar normally while this screen is up.
    // ==========================================================
    _activeConversationKey = ActiveConversation.chatKey(chatId);
    ActiveConversation.push(_activeConversationKey!);

    messageFocusNode.addListener(_handleFocusChange);
    scrollController.addListener(_handleScrollPosition);
    messageController.addListener(_handleTypingChanged);
    _voicePlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed) {
        setState(() => _playingVoiceMessageId = null);
      }
    });
    _listenChatSettings();

    // ==========================================================
    // NEW: SAVE ALERT FOR THE OTHER PARTICIPANT
    // Runs once, right after this chat screen finishes its first
    // frame (so the Overlay is ready), and shows a top bar if the
    // OTHER person saved a message since we last opened this chat.
    // ==========================================================
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkSaveNotification();
    });
  }

  // ==========================================================
  // NEW: SAVE ALERT FOR THE OTHER PARTICIPANT
  // Reads the chat doc's last "save" event. If it was the OTHER
  // participant who saved a message, and this user hasn't been
  // shown that alert yet, pop a top bar with a save icon reading
  // "<name> saved this message", then mark it seen so re-opening
  // the chat doesn't repeat it.
  // ==========================================================

  Future<void> _checkSaveNotification() async {
    try {
      final snap = await chatReference.get();
      final data = snap.data();
      if (data == null) return;

      final event = data['lastSaveEvent'] as Map<String, dynamic>?;
      if (event == null) return;

      final byUid = (event['byUid'] ?? '').toString();

      // Only notify the OTHER participant, never the saver themself.
      if (byUid.isEmpty || byUid == currentUid) return;

      final seenBy = List<String>.from(data['lastSaveEventSeenBy'] ?? []);
      if (seenBy.contains(currentUid)) return;

      if (!mounted) return;

      showTopAlert(
        context,
        '${widget.otherUserName} saved this message',
        icon: Icons.bookmark_rounded,
      );

      await chatReference.set({
        'lastSaveEventSeenBy': FieldValue.arrayUnion([currentUid]),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Save notification check error: $e');
    }
  }

  // ==========================================================
  // NEW: figure out whether we're near the bottom of the list
  // ==========================================================

  void _handleScrollPosition() {
    if (!scrollController.hasClients) return;

    final maxExtent = scrollController.position.maxScrollExtent;

    final current = scrollController.position.pixels;

    final bool atBottom = (maxExtent - current) < 80;

    final bool shouldShowButton = !atBottom;

    if (shouldShowButton != _showScrollToBottomButton ||
        (atBottom && _hasUnseenNewMessage)) {
      setState(() {
        _showScrollToBottomButton = shouldShowButton;

        if (atBottom) {
          _hasUnseenNewMessage = false;
        }
      });
    }
  }

  void _scrollToBottom({bool animate = true}) {
    if (!scrollController.hasClients) return;

    final target = scrollController.position.maxScrollExtent;

    if (animate) {
      scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      scrollController.jumpTo(target);
    }
  }

  // ==========================================================
  // NEW: scroll straight to a specific (searched-for) message
  // and make sure it's clearly visible once we land on it.
  // ==========================================================

  void _scrollToTargetMessage(
    String messageId,
    List<DocumentSnapshot<Map<String, dynamic>>> messages,
  ) {
    final int index = messages.indexWhere((m) => m.id == messageId);

    if (index == -1) {
      // Message no longer resolvable in this list (e.g. hidden for
      // the current user) — fall back to the normal open behavior.
      _scrollToBottom(animate: false);
      return;
    }

    unawaited(_attemptScrollToMessage(messageId, index, messages.length));
  }

  /// ListView.builder only lays out items near the viewport, so a
  /// message far from the bottom may not have a mounted context yet.
  /// We jump to a proportional estimate of its position, wait a
  /// frame, and check again — repeating a few times until the
  /// message's own GlobalKey is mounted, then use
  /// [Scrollable.ensureVisible] to land on it precisely.
  Future<void> _attemptScrollToMessage(
    String messageId,
    int index,
    int total, [
    int attempt = 0,
  ]) async {
    if (!mounted || !scrollController.hasClients) return;

    final BuildContext? targetContext = _messageBubbleContexts[messageId];

    if (targetContext != null) {
      await Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        alignment: 0.5,
      );

      if (mounted) _flashSearchHighlight(messageId);
      return;
    }

    if (attempt >= 8) {
      // Couldn't confirm the exact widget mounted; we're already
      // parked close to it from the estimate jumps below, so just
      // highlight it so it's still easy to spot.
      if (mounted) _flashSearchHighlight(messageId);
      return;
    }

    if (scrollController.position.maxScrollExtent > 0) {
      final double maxExtent = scrollController.position.maxScrollExtent;
      final double fraction = total > 1 ? index / (total - 1) : 0.0;
      final double estimate = (maxExtent * fraction).clamp(0.0, maxExtent);

      scrollController.jumpTo(estimate);
    }

    await Future.delayed(const Duration(milliseconds: 70));
    if (!mounted) return;

    await _attemptScrollToMessage(messageId, index, total, attempt + 1);
  }

  /// Briefly highlights the target message using the same visual
  /// treatment already used for newly-arrived messages, so it reads
  /// as clearly visible/found rather than as a new arrival.
  void _flashSearchHighlight(String messageId) {
    if (!mounted) return;

    setState(() {
      _highlightedMessageIds.add(messageId);
    });

    Timer(const Duration(seconds: 3), () {
      if (!mounted) return;

      setState(() {
        _highlightedMessageIds.remove(messageId);
      });
    });
  }

  Future<void> _listenChatSettings() async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;

    final settings = ChatSettingsService.instance;
    if (widget.usePrivateProfile) {
      await settings.setActiveInfo(widget.otherUserUid, true);
      await settings.setTypingInfo(widget.otherUserUid, true);
    }
    _mySettingsSub = settings
        .watchSettings(ownerUid: me.uid, otherUid: widget.otherUserUid)
        .listen((data) {
          if (!mounted) return;
          setState(() => _mySettings = data);
        });

    _otherSettingsSub = settings
        .watchSettings(ownerUid: widget.otherUserUid, otherUid: me.uid)
        .listen((data) {
          if (!mounted) return;
          setState(() {
            _otherSettings = data;
            _otherTyping =
                data['typingInfoEnabled'] == true &&
                _otherUserData['isTyping'] == true &&
                (_otherUserData['typingToUid'] ?? '') == me.uid;
          });
        });

    _otherUserSub = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.otherUserUid)
        .snapshots()
        .listen((doc) {
          if (!mounted) return;
          final data = doc.data() ?? <String, dynamic>{};
          setState(() {
            _otherUserData = data;
            _otherTyping =
                _otherSettings['typingInfoEnabled'] == true &&
                data['isTyping'] == true &&
                (data['typingToUid'] ?? '') == me.uid;
          });
        });

    final connectionUsers = [me.uid, widget.otherUserUid]..sort();
    final connectionId = connectionUsers.join('_');
    final connection = await FirebaseFirestore.instance
        .collection('connections')
        .doc(connectionId)
        .get();
    if (mounted) {
      setState(
        () =>
            _isConnected = (connection.data()?['status'] ?? '') == 'connected',
      );
    }
    await settings.updatePresence(active: true, typingToUid: null);
  }

  void _handleTypingChanged() {
    _typingStopTimer?.cancel();
    final text = messageController.text.trim();
    if (text.isEmpty) {
      unawaited(
        ChatSettingsService.instance.updatePresence(
          active: true,
          typingToUid: null,
        ),
      );
      return;
    }
    unawaited(
      ChatSettingsService.instance.updatePresence(
        active: true,
        typingToUid: widget.otherUserUid,
      ),
    );
    _typingStopTimer = Timer(const Duration(milliseconds: 1200), () {
      unawaited(
        ChatSettingsService.instance.updatePresence(
          active: true,
          typingToUid: null,
        ),
      );
    });
  }

  // ==========================================================
  // NEW: full emoji-keyboard reaction picker (emoji_picker_flutter
  // package) instead of a fixed 6-emoji row -- lets the user react
  // with ANY emoji, same as WhatsApp/Instagram.
  // Add this to pubspec.yaml under dependencies:
  //   emoji_picker_flutter: ^4.3.0
  // then run: flutter pub get
  // ==========================================================
  Future<void> _chooseReaction(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    final emoji = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF18181F),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) => SafeArea(
        child: SizedBox(
          height: 360,
          child: EmojiPicker(
            onEmojiSelected: (category, emoji) {
              Navigator.pop(context, emoji.emoji);
            },
            config: Config(
              height: 360,
              emojiViewConfig: EmojiViewConfig(
                backgroundColor: const Color(0xFF18181F),
                columns: 8,
                emojiSizeMax: 28,
              ),
              categoryViewConfig: const CategoryViewConfig(
                backgroundColor: Color(0xFF18181F),
                indicatorColor: Color(0xFFA78BFA),
                iconColorSelected: Color(0xFFA78BFA),
                iconColor: Colors.white54,
              ),
              bottomActionBarConfig: const BottomActionBarConfig(
                backgroundColor: Color(0xFF18181F),
                buttonColor: Color(0xFF18181F),
              ),
              searchViewConfig: const SearchViewConfig(
                backgroundColor: Color(0xFF18181F),
              ),
            ),
          ),
        ),
      ),
    );
    if (emoji == null) return;
    final uid = currentUid;
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final fresh = await tx.get(message.reference);
      final existing = fresh.data()?['reactions'];
      final reactions = existing is Map
          ? Map<String, dynamic>.from(existing)
          : <String, dynamic>{};
      reactions[uid] = emoji;
      tx.update(message.reference, {'reactions': reactions});
    });
  }

  // NEW: tapping the round reaction badge on a bubble removes YOUR
  // reaction from that message (WhatsApp/Instagram-style toggle-off).
  Future<void> _removeReaction(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    final uid = currentUid;
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final fresh = await tx.get(message.reference);
      final existing = fresh.data()?['reactions'];
      if (existing is! Map) return;
      final reactions = Map<String, dynamic>.from(existing);
      reactions.remove(uid);
      tx.update(message.reference, {'reactions': reactions});
    });
  }

  bool _canEditMessage(Map<String, dynamic> data) {
    final sentAt = data['sentAt'];
    return sentAt is Timestamp &&
        (data['senderId'] ?? '').toString() == currentUid &&
        DateTime.now().difference(sentAt.toDate()) <=
            const Duration(minutes: 2);
  }

  Future<void> _editMessage(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    final data = message.data() ?? {};
    final sentAt = data['sentAt'];
    if (sentAt is! Timestamp ||
        DateTime.now().difference(sentAt.toDate()) >
            const Duration(minutes: 2)) {
      return;
    }
    final edited = await showDialog<String>(
      context: context,
      builder: (context) =>
          _EditMessageDialog(initialValue: (data['text'] ?? '').toString()),
    );
    if (edited == null || edited.isEmpty) return;
    await message.reference.update({
      'text': edited,
      'editedAt': FieldValue.serverTimestamp(),
    });
  }

  // Guards the "Set Nickname" Save button against a second save being
  // fired (e.g. a fast double-tap) while the previous write is still
  // in flight.
  bool _savingNickname = false;

  // Connected accounts get voice/video calling ON automatically -- the
  // 'voiceCallEnabled'/'videoCallEnabled' field only ever gets written
  // once someone manually flips the corresponding menu toggle. So a
  // MISSING field is read as enabled for a connected relationship
  // (private chat, or a plain chat that has since become connected via
  // `_isConnected`) and as disabled for a public/non-connected one.
  // That means only an explicit `false` can turn it off for a
  // connected account, and only an explicit `true` can turn it on for
  // a non-connected one -- exactly mirroring the "Enable Voice/Video
  // Call ✓" checkboxes this same menu shows/writes below. [field] is
  // 'voiceCallEnabled' or 'videoCallEnabled' -- each call type has its
  // own independent permission.
  bool _isCallEnabled(Map<String, dynamic> settings, String field) {
    final bool isConnectedChat = widget.usePrivateProfile || _isConnected;
    return isConnectedChat ? settings[field] != false : settings[field] == true;
  }

  Future<void> _showChatSettingsMenu() async {
    final settings = ChatSettingsService.instance;
    final active = _mySettings['activeInfoEnabled'] == true;
    final typing = _mySettings['typingInfoEnabled'] == true;
    final muted = _mySettings['muted'] == true;
    final blocked = _mySettings['blocked'] == true;
    final voiceCall = _isCallEnabled(_mySettings, 'voiceCallEnabled');
    final videoCall = _isCallEnabled(_mySettings, 'videoCallEnabled');
    final nickname = (_mySettings['nickname'] ?? '').toString();

    // The "Set Nickname" row used to pop this bottom sheet and then,
    // in that same synchronous callback, immediately push the
    // AlertDialog with showDialog(). Popping a modal route and
    // pushing a new one back-to-back like that starts the sheet's
    // closing transition and the dialog's opening transition at the
    // same time on the same Navigator/Overlay, and Flutter tears down
    // the sheet's Element tree (and the InheritedWidget subscriptions
    // it still held) before that teardown had actually finished -- it
    // threw Flutter's own "'_dependents.isEmpty': is not true"
    // assertion instead of ever calling setNickname(), which is why
    // Save appeared to fail. The other rows below don't push a new
    // route after popping, so they never hit this.
    //
    // The fix is to only report *which* row was tapped here, and wait
    // for showModalBottomSheet's Future -- which only completes once
    // the sheet has fully finished closing -- before doing anything
    // that opens another route.
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF18181F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.edit_note_rounded,
                color: Color(0xFFA78BFA),
              ),
              title: const Text(
                'Set Nickname',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: nickname.isNotEmpty
                  ? Text(
                      nickname,
                      style: const TextStyle(color: Colors.white54),
                    )
                  : null,
              onTap: () => Navigator.pop(sheetContext, 'nickname'),
            ),
            if (!widget.usePrivateProfile && !_isConnected)
              ListTile(
                leading: Icon(
                  active
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                  color: const Color(0xFFA78BFA),
                ),
                title: Text(
                  'Enable Active Info${active ? ' ✓' : ''}',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await settings.setActiveInfo(widget.otherUserUid, !active);
                },
              ),
            if (!widget.usePrivateProfile && !_isConnected)
              ListTile(
                leading: Icon(
                  typing ? Icons.keyboard_rounded : Icons.keyboard_hide_rounded,
                  color: const Color(0xFFA78BFA),
                ),
                title: Text(
                  'Enable Typing Info${typing ? ' ✓' : ''}',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await settings.setTypingInfo(widget.otherUserUid, !typing);
                },
              ),
            ListTile(
              leading: Icon(
                muted
                    ? Icons.notifications_off_rounded
                    : Icons.notifications_active_rounded,
                color: const Color(0xFFA78BFA),
              ),
              title: Text(
                muted ? 'Unmute Message' : 'Mute Message',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () async {
                Navigator.pop(sheetContext);
                await settings.setMuted(widget.otherUserUid, !muted);
                IncomingMessageAlert.invalidateMute(widget.otherUserUid);
              },
            ),
            // Enabling this lets THIS chat's other member call ME -- it
            // does not grant me the ability to call them (see
            // ChatSettingsService.setVoiceCallEnabled). My own call button
            // above only shows once THEY enable this same toggle on their
            // side (gated on `_otherSettings['voiceCallEnabled']`).
            ListTile(
              leading: Icon(
                voiceCall ? Icons.call_rounded : Icons.call_end_rounded,
                color: const Color(0xFFA78BFA),
              ),
              title: Text(
                'Enable Voice Call${voiceCall ? ' ✓' : ''}',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () async {
                Navigator.pop(sheetContext);
                await settings.setVoiceCallEnabled(
                  widget.otherUserUid,
                  !voiceCall,
                );
              },
            ),
            // Same one-directional model as the voice call row above,
            // but its own independent field (videoCallEnabled) -- a
            // person can allow one without the other.
            ListTile(
              leading: Icon(
                videoCall ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                color: const Color(0xFFA78BFA),
              ),
              title: Text(
                'Enable Video Call${videoCall ? ' ✓' : ''}',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () async {
                Navigator.pop(sheetContext);
                await settings.setVideoCallEnabled(
                  widget.otherUserUid,
                  !videoCall,
                );
              },
            ),
            ListTile(
              leading: Icon(
                blocked ? Icons.lock_open_rounded : Icons.block_rounded,
                color: Colors.redAccent,
              ),
              title: Text(
                blocked ? 'Unblock Account' : 'Block Account',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () async {
                Navigator.pop(sheetContext);
                await settings.setBlocked(widget.otherUserUid, !blocked);
              },
            ),
          ],
        ),
      ),
    );

    if (!mounted || action != 'nickname') return;

    // The dialog content used to be an inline AlertDialog holding a
    // TextEditingController created right here, disposed on the very
    // next line after showDialog's Future resolved. showDialog's Future
    // completes the instant Navigator.pop() runs inside the dialog --
    // well before the dialog route's fade/scale exit transition has
    // actually finished animating this TextField out of the tree. That
    // transition keeps rebuilding the (still-mounted) TextField's
    // subtree for the rest of the animation, and disposing the
    // controller immediately after pop meant one of those rebuilds
    // tried to add a listener to an already-disposed ChangeNotifier --
    // "A TextEditingController was used after being disposed." -- which
    // is also what left the widget tree/build owner in the inconsistent
    // state behind the cascading "'_dependents.isEmpty': is not true"
    // and "Tried to build dirty widget in the wrong build scope" errors.
    //
    // _NicknameDialog below owns its own controller and disposes it in
    // its own State.dispose(), which Flutter only calls once this
    // widget's Element is actually unmounted -- i.e. once the exit
    // transition has fully finished -- so controller disposal and
    // TextField disposal can never race again, no matter how long that
    // transition takes.
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _NicknameDialog(initialValue: nickname),
    );
    if (value == null || _savingNickname) return;

    _savingNickname = true;
    try {
      await settings.setNickname(widget.otherUserUid, value);
    } catch (e) {
      if (mounted) {
        showTopAlert(
          context,
          'Failed to save nickname. Please try again.',
          isError: true,
        );
      }
    } finally {
      _savingNickname = false;
    }
  }

  // ==========================================================
  // CURRENT USER
  // ==========================================================

  /// Last 5 text messages received from the other user (oldest first),
  /// used by the global translator popup.
  Future<List<String>> _lastReceivedTexts() async {
    final snap = await messagesReference
        .orderBy('sentAt', descending: true)
        .limit(40)
        .get();
    final out = <String>[];
    for (final d in snap.docs) {
      final m = d.data();
      if ((m['senderId'] ?? '').toString() != widget.otherUserUid) continue;
      if ((m['messageType'] ?? 'text').toString() != 'text') continue;
      if (List<String>.from(m['hiddenFor'] ?? const []).contains(currentUid))
        continue;
      final t = (m['text'] ?? '').toString().trim();
      if (t.isEmpty) continue;
      out.add(t);
      if (out.length == 5) break;
    }
    return out.reversed.toList();
  }

  String get currentUid {
    return FirebaseAuth.instance.currentUser!.uid;
  }

  /// 'chat:<chatId>' for this screen, pushed on open and popped on
  /// close so the incoming-message bar knows to skip this chat.
  String? _activeConversationKey;

  // ==========================================================
  // CHAT ID
  // ==========================================================

  String get chatId {
    final ids = [currentUid, widget.otherUserUid];

    ids.sort();

    return ids.join('_');
  }

  // ==========================================================
  // CHAT DOCUMENT
  // ==========================================================

  DocumentReference<Map<String, dynamic>> get chatReference {
    return FirebaseFirestore.instance.collection('chats').doc(chatId);
  }

  // ==========================================================
  // MESSAGES
  // ==========================================================

  CollectionReference<Map<String, dynamic>> get messagesReference {
    return chatReference.collection('messages');
  }

  // ==========================================================
  // NEW: process each incoming snapshot to power the
  // auto-scroll-on-open, new-message-highlight, and
  // scroll-to-bottom/unread-dot behaviors.
  // ==========================================================

  void _processMessagesSnapshot(
    List<DocumentSnapshot<Map<String, dynamic>>> messages,
  ) {
    if (!_knownIdsInitialized) {
      _knownIdsInitialized = true;

      for (final m in messages) {
        _knownMessageIds.add(m.id);
      }

      if (!_initialScrollDone) {
        _initialScrollDone = true;

        final String? targetId = widget.targetMessageId;

        final bool hasTarget =
            targetId != null &&
            targetId.isNotEmpty &&
            messages.any((m) => m.id == targetId);

        if (hasTarget) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToTargetMessage(targetId, messages);
          });
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToBottom(animate: false);
          });
        }
      }

      return;
    }

    for (final m in messages) {
      if (_knownMessageIds.contains(m.id)) continue;

      _knownMessageIds.add(m.id);

      final data = m.data();
      final senderId = (data?['senderId'] ?? '').toString();

      // Briefly highlight every newly-arrived message.
      _highlightedMessageIds.add(m.id);

      Timer(const Duration(seconds: 3), () {
        if (!mounted) return;

        setState(() {
          _highlightedMessageIds.remove(m.id);
        });
      });

      // Only incoming messages affect the scroll-to-bottom /
      // unread-dot behavior (our own sends already scroll).
      if (senderId != currentUid) {
        if (scrollController.hasClients) {
          final maxExtent = scrollController.position.maxScrollExtent;

          final current = scrollController.position.pixels;

          final bool atBottom = (maxExtent - current) < 80;

          if (atBottom) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToBottom();
            });
          } else {
            _hasUnseenNewMessage = true;
          }
        }
      }
    }

    // Kick off a (best-effort, fire-and-forget) read receipt
    // update for the latest incoming message.
    _markLatestIncomingAsRead(messages);

    // Being on this screen with the messages in front of me also
    // counts as "caught up" for the Nexus Notify unseen-messages
    // reminder, so refresh my per-chat read marker too.
    unawaited(markChatRead(chatId));
  }

  // ==========================================================
  // NEW: READ RECEIPTS
  // Mark the most recent message from the other user as read
  // by us. The other user's own device does the same thing in
  // reverse, which is what lets us show "Seen" on our side.
  // ==========================================================

  Future<void> _markLatestIncomingAsRead(
    List<DocumentSnapshot<Map<String, dynamic>>> messages,
  ) async {
    for (int i = messages.length - 1; i >= 0; i--) {
      final data = messages[i].data();

      if (data == null) continue;

      final senderId = (data['senderId'] ?? '').toString();

      if (senderId != currentUid) {
        final readBy = List<String>.from(data['readBy'] ?? []);

        if (!readBy.contains(currentUid)) {
          try {
            await messages[i].reference.update({
              'readBy': FieldValue.arrayUnion([currentUid]),
            });
          } catch (e) {
            debugPrint('Mark as read error: $e');
          }
        }

        break;
      }
    }
  }

  // ==========================================================
  // SWIPE TO REPLY (now with a smoother spring-back animation)
  // ==========================================================

  Widget _buildSwipeableMessage(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) {
    final data = message.data();

    if (data == null) {
      return const SizedBox.shrink();
    }

    final senderId = (data['senderId'] ?? '').toString();

    final bool isMe = senderId == currentUid;

    return _SwipeableReply(
      key: ValueKey('swipe_${message.id}'),
      isMe: isMe,
      onReply: () => _setReplyMessage(message),
      onBubbleDragChanged: _setBubbleDragActive,
      child: _buildMessageBubble(message),
    );
  }

  // ==========================================================
  // REPLY PREVIEW ABOVE INPUT
  // NEW: animated in/out with AnimatedSize + AnimatedOpacity
  // ==========================================================

  // ==========================================================
  // TYPING INDICATOR BAR (bottom-left, above the input field)
  // ----------------------------------------------------------
  // Reuses the same `_otherTyping` flag the rest of the screen
  // already maintains via ChatSettingsService (Firestore
  // `isTyping` / `typingToUid` fields) -- no new backend/typing
  // mechanism is introduced here. Renders nothing at all (zero
  // height) when the other user isn't typing, so it disappears
  // completely as soon as they stop, and never disturbs the
  // message list / input layout while idle.
  // ==========================================================

  Widget _buildTypingIndicatorBar() {
    final bool typingAllowed =
        widget.usePrivateProfile ||
        _isConnected ||
        _otherSettings['typingInfoEnabled'] == true;

    if (!typingAllowed || !_otherTyping) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: const _TypingIndicator(),
      ),
    );
  }

  Widget _buildReplyPreview() {
    final data = replyMessage?.data();

    Widget content = const SizedBox.shrink();

    if (data != null) {
      final senderId = (data['senderId'] ?? '').toString();

      final text = (data['text'] ?? '').toString();

      final bool isMe = senderId == currentUid;

      content = Container(
        key: const ValueKey('reply_preview_visible'),

        margin: const EdgeInsets.fromLTRB(10, 5, 10, 0),

        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),

        decoration: BoxDecoration(
          color: const Color(0xFF18181F),

          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(15),
            topRight: Radius.circular(15),
          ),

          border: const Border(
            left: BorderSide(color: Color(0xFFA78BFA), width: 3),
          ),
        ),

        child: Row(
          children: [
            const Icon(Icons.reply_rounded, color: Color(0xFFA78BFA), size: 22),

            const SizedBox(width: 10),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,

                children: [
                  Text(
                    isMe
                        ? 'Replying to yourself'
                        : 'Replying to ${widget.otherUserName}',

                    maxLines: 1,

                    overflow: TextOverflow.ellipsis,

                    style: const TextStyle(
                      color: Color(0xFFA78BFA),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 3),

                  Text(
                    text,

                    maxLines: 1,

                    overflow: TextOverflow.ellipsis,

                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),

            IconButton(
              onPressed: _cancelReply,

              icon: const Icon(
                Icons.close_rounded,
                color: Colors.white60,
                size: 20,
              ),
            ),
          ],
        ),
      );
    } else {
      content = const SizedBox.shrink(key: ValueKey('reply_preview_hidden'));
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: Alignment.bottomCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: content,
      ),
    );
  }

  // ==========================================================
  // VOICE MESSAGE
  // ==========================================================

  String _formatVoiceDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remaining = seconds % 60;
    return '$minutes:${remaining.toString().padLeft(2, '0')}';
  }

  Future<void> _maybeDeleteCloudinaryAfterLocalSave(
    DocumentReference<Map<String, dynamic>> messageRef,
  ) async {
    try {
      final fresh = await messageRef.get();
      if (!fresh.exists) return;

      final data = fresh.data() ?? <String, dynamic>{};
      if ((data['messageType'] ?? 'text').toString() != 'voice') return;
      if (data['cloudinaryDeleted'] == true) return;

      final publicId = (data['cloudinaryPublicId'] ?? '').toString().trim();
      if (publicId.isEmpty) return;

      final savedBy = List<String>.from(data['localSavedBy'] ?? []);
      final participants = <String>{currentUid, widget.otherUserUid};

      // The sender saves a permanent local copy when sending. Once the
      // receiver also accesses the message, both devices have a local copy
      // and the temporary Cloudinary copy can be removed.
      if (!participants.every(savedBy.contains)) return;

      final deleted = await VoiceMessageService.instance.deleteCloudinaryAsset(
        chatId: chatId,
        messageId: messageRef.id,
        publicId: publicId,
      );

      if (deleted) {
        await messageRef.update({'cloudinaryDeleted': true});
      }
    } catch (e) {
      debugPrint('Cloudinary voice cleanup error: $e');
    }
  }

  Future<void> _playVoiceMessage(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    final data = message.data();
    if (data == null) return;
    if ((data['messageType'] ?? 'text').toString() != 'voice') return;

    final messageId = message.id;

    try {
      String path = await VoiceMessageService.instance.localPathFor(messageId);
      final localFile = File(path);

      if (!await localFile.exists() || await localFile.length() == 0) {
        final cloudinaryDeleted = data['cloudinaryDeleted'] == true;
        final audioUrl = (data['audioUrl'] ?? '').toString().trim();

        if (cloudinaryDeleted || audioUrl.isEmpty) {
          if (mounted) {
            showTopAlert(context, 'Audio is no longer available.');
          }
          return;
        }

        final downloaded = await VoiceMessageService.instance.downloadToLocal(
          messageId: messageId,
          audioUrl: audioUrl,
        );

        if (!downloaded) {
          if (mounted) {
            showTopAlert(context, 'Unable to save this audio locally.');
          }
          return;
        }

        path = await VoiceMessageService.instance.localPathFor(messageId);

        await message.reference.update({
          'localSavedBy': FieldValue.arrayUnion([currentUid]),
        });

        unawaited(_maybeDeleteCloudinaryAfterLocalSave(message.reference));
      }

      if (_playingVoiceMessageId == messageId && _voicePlayer.playing) {
        await _voicePlayer.pause();
        if (mounted) setState(() => _playingVoiceMessageId = null);
        return;
      }

      await _voicePlayer.stop();
      await _voicePlayer.setFilePath(path);

      if (mounted) setState(() => _playingVoiceMessageId = messageId);
      await _voicePlayer.play();
    } catch (e) {
      debugPrint('Voice playback error: $e');
      if (mounted) {
        setState(() => _playingVoiceMessageId = null);
        showTopAlert(context, 'Unable to play this voice message.');
      }
    }
  }

  Future<void> _startVoiceRecording() async {
    if (_isRecordingVoice || _isSendingVoice) return;

    if (_otherSettings['blocked'] == true) {
      if (mounted) {
        showTopAlert(context, 'This account has blocked you.');
      }
      return;
    }

    try {
      final permission = await _voiceRecorder.hasPermission();
      if (!permission) {
        if (mounted) {
          showTopAlert(
            context,
            'Microphone permission is required.',
            isError: true,
          );
        }
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final path =
          '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _voiceRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
        ),
        path: path,
      );

      if (!mounted) return;

      _voiceRecordingTimer?.cancel();
      setState(() {
        _isRecordingVoice = true;
        _voiceRecordingSeconds = 0;
      });

      _voiceRecordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || !_isRecordingVoice) return;
        setState(() => _voiceRecordingSeconds++);
      });
    } catch (e) {
      debugPrint('Voice recording start error: $e');
      if (mounted) {
        showTopAlert(context, 'Unable to start voice recording.');
      }
    }
  }

  Future<void> _cancelVoiceRecording() async {
    if (!_isRecordingVoice) return;

    _voiceRecordingTimer?.cancel();
    _voiceRecordingTimer = null;

    try {
      final path = await _voiceRecorder.stop();
      if (path != null) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    } catch (e) {
      debugPrint('Voice recording cancel error: $e');
    }

    if (!mounted) return;
    setState(() {
      _isRecordingVoice = false;
      _voiceRecordingSeconds = 0;
    });
  }

  Future<void> _stopAndSendVoiceRecording() async {
    if (!_isRecordingVoice || _isSendingVoice) return;

    _voiceRecordingTimer?.cancel();
    _voiceRecordingTimer = null;

    String? recordingPath;
    try {
      recordingPath = await _voiceRecorder.stop();
    } catch (e) {
      debugPrint('Voice recording stop error: $e');
    }

    final duration = _voiceRecordingSeconds;

    if (!mounted) return;
    setState(() {
      _isRecordingVoice = false;
      _isSendingVoice = true;
    });

    if (recordingPath == null) {
      if (mounted) setState(() => _isSendingVoice = false);
      return;
    }

    try {
      await _sendVoiceMessage(
        recordingPath: recordingPath,
        durationSeconds: duration,
      );
    } finally {
      try {
        final file = File(recordingPath);
        if (await file.exists()) await file.delete();
      } catch (_) {}

      if (mounted) {
        setState(() {
          _isSendingVoice = false;
          _voiceRecordingSeconds = 0;
        });
      }
    }
  }

  Future<void> _sendVoiceMessage({
    required String recordingPath,
    required int durationSeconds,
  }) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final recordingFile = File(recordingPath);
    if (!await recordingFile.exists() || await recordingFile.length() == 0)
      return;

    final messageRef = messagesReference.doc();

    try {
      // Save the sender's permanent local copy before the temporary recording
      // is removed. This lets the sender play it even after Cloudinary is gone.
      await VoiceMessageService.instance.copyRecordingToPermanent(
        recordingPath: recordingPath,
        messageId: messageRef.id,
      );

      final upload = await VoiceMessageService.instance.uploadToCloudinary(
        recordingPath,
      );
      final now = FieldValue.serverTimestamp();
      final selectedReply = replyMessage;
      final chatType = (widget.usePrivateProfile || _isConnected)
          ? 'private'
          : 'public';

      await messageRef.set({
        'senderId': currentUser.uid,
        'receiverId': widget.otherUserUid,
        'text': '',
        'messageType': 'voice',
        'audioUrl': upload.secureUrl,
        'cloudinaryPublicId': upload.publicId,
        'cloudinaryDeleted': false,
        'audioDuration': durationSeconds,
        'localSavedBy': [currentUser.uid],
        'sentAt': now,
        'expiresAt': chatType == 'public'
            ? Timestamp.fromDate(DateTime.now().add(const Duration(hours: 24)))
            : null,
        'chatTypeAtSend': chatType,
        'savedBy': <String>[],
        'hiddenFor': <String>[],
        'readBy': <String>[],
        'replyTo': selectedReply == null
            ? null
            : {
                'messageId': selectedReply.id,
                'senderId': (selectedReply.data()?['senderId'] ?? '')
                    .toString(),
                'messageType': (selectedReply.data()?['messageType'] ?? 'text')
                    .toString(),
                'text':
                    (selectedReply.data()?['messageType'] ?? 'text')
                            .toString() ==
                        'voice'
                    ? '🎤 Voice message'
                    : (selectedReply.data()?['text'] ?? '').toString(),
              },
      });

      if (mounted && replyMessage != null) {
        setState(() => replyMessage = null);
      }

      if (_otherSettings['muted'] != true) {
        try {
          final receiverDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(widget.otherUserUid)
              .get();
          final receiverData = receiverDoc.data() ?? {};
          final receiverToken = (receiverData['fcmToken'] ?? '')
              .toString()
              .trim();

          if (receiverToken.isNotEmpty) {
            await http.post(
              Uri.parse('https://chatbot-worker.gokulmi56cro.workers.dev'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'fcmToken': receiverToken,
                'senderName': currentUser.displayName ?? 'New message',
                'message': '🎤 Voice message',
                'senderUid': currentUser.uid,
              }),
            );
          }
        } catch (e) {
          debugPrint('Voice notification error: $e');
        }
      }

      await chatReference.set({
        'participants': [currentUser.uid, widget.otherUserUid],
        'lastMessage': '🎤 Voice message',
        'lastMessageTime': now,
        'lastMessageSenderId': currentUser.uid,
        'otherUserUid': widget.otherUserUid,
        'hiddenFor': FieldValue.arrayRemove([currentUser.uid]),
        'updatedAt': now,
      }, SetOptions(merge: true));

      if (mounted) {
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!mounted || !scrollController.hasClients) return;
          scrollController.animateTo(
            scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        });
      }
    } catch (e) {
      debugPrint('Send voice message error: $e');
      await VoiceMessageService.instance.deleteLocal(messageRef.id);
      if (mounted) {
        showTopAlert(
          context,
          'Failed to send voice message: $e',
          isError: true,
        );
      }
    }
  }

  Widget _buildVoiceMessageContent(
    DocumentSnapshot<Map<String, dynamic>> message,
    Map<String, dynamic> data,
    bool isMe,
  ) {
    final duration = int.tryParse((data['audioDuration'] ?? 0).toString()) ?? 0;
    final playing =
        _playingVoiceMessageId == message.id && _voicePlayer.playing;

    return SizedBox(
      width: 220,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () => _playVoiceMessage(message),
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 30,
            ),
          ),
          const SizedBox(width: 3),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Voice message',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    value: playing ? null : 0,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatVoiceDuration(duration),
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // SEND MESSAGE
  // ==========================================================

  Future<void> _sendMessage() async {
    if (_translator.busy) return;
    var text = messageController.text.trim();

    if (text.isEmpty) return;

    final currentUser = FirebaseAuth.instance.currentUser;

    if (currentUser == null) return;
    if (_otherSettings['blocked'] == true) {
      if (mounted) showTopAlert(context, 'This account has blocked you.');
      return;
    }

    String? originalText;
    try {
      final out = await _translator.beforeSend(text);
      text = out.text;
      originalText = out.original;
    } on TranslatorException catch (e) {
      if (mounted) showTopAlert(context, e.message, isError: true);
      return;
    } catch (_) {
      if (mounted)
        showTopAlert(
          context,
          'Translation failed. Message not sent.',
          isError: true,
        );
      return;
    }

    // Keep selected reply before clearing
    final selectedReply = replyMessage;

    messageController.clear();

    try {
      final now = FieldValue.serverTimestamp();

      await messagesReference.add({
        'senderId': currentUser.uid,

        'receiverId': widget.otherUserUid,

        'text': text,
        if (originalText != null) 'originalText': originalText,

        'sentAt': now,

        // ==================================================
        // SAVE SYSTEM
        // ==================================================
        'savedBy': <String>[],

        // ==================================================
        // 24 HOUR EXPIRY
        // ==================================================
        'expiresAt': (widget.usePrivateProfile || _isConnected)
            ? null
            : Timestamp.fromDate(DateTime.now().add(const Duration(hours: 24))),
        'chatTypeAtSend': (widget.usePrivateProfile || _isConnected)
            ? 'private'
            : 'public',

        // ==================================================
        // DELETE FOR YOU
        // ==================================================
        'hiddenFor': <String>[],

        // ==================================================
        // NEW: READ RECEIPTS
        // ==================================================
        'readBy': <String>[],

        // ==================================================
        // REPLY
        // ==================================================
        'replyTo': selectedReply == null
            ? null
            : {
                'messageId': selectedReply.id,

                'senderId': (selectedReply.data()?['senderId'] ?? '')
                    .toString(),

                'text': (selectedReply.data()?['text'] ?? '').toString(),
              },
      });

      // ==========================================================
      // SEND PUSH NOTIFICATION
      // ==========================================================

      if (_otherSettings['muted'] != true) {
        try {
          final receiverDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(widget.otherUserUid)
              .get();

          final receiverData = receiverDoc.data() ?? {};

          final receiverToken = (receiverData['fcmToken'] ?? '')
              .toString()
              .trim();

          debugPrint('RECEIVER UID: ${widget.otherUserUid}');
          debugPrint('RECEIVER FCM TOKEN: $receiverToken');

          if (receiverToken.isEmpty) {
            debugPrint('Receiver FCM token is empty.');
          } else {
            final response = await http.post(
              Uri.parse('https://chatbot-worker.gokulmi56cro.workers.dev'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'fcmToken': receiverToken,
                'senderName': currentUser.displayName ?? 'New message',
                'message': text,
                'senderUid': currentUser.uid,
              }),
            );

            debugPrint('Notification API status: ${response.statusCode}');

            debugPrint('Notification API response: ${response.body}');
          }
        } catch (e) {
          debugPrint('Notification send error: $e');
        }
      }

      // ==================================================
      // UPDATE CHAT
      // ==================================================

      await chatReference.set({
        'participants': [currentUser.uid, widget.otherUserUid],

        'lastMessage': text,

        'lastMessageTime': now,

        'lastMessageSenderId': currentUser.uid,

        'otherUserUid': widget.otherUserUid,

        'hiddenFor': FieldValue.arrayRemove([currentUser.uid]),

        'updatedAt': now,
      }, SetOptions(merge: true));

      // ==================================================
      // SCROLL TO BOTTOM
      // ==================================================

      Future.delayed(const Duration(milliseconds: 150), () {
        if (!scrollController.hasClients) {
          return;
        }

        scrollController.animateTo(
          scrollController.position.maxScrollExtent,

          duration: const Duration(milliseconds: 250),

          curve: Curves.easeOut,
        );
      });
    } catch (e) {
      debugPrint('Send message error: $e');

      if (!mounted) return;

      showTopAlert(context, 'Message failed to send', isError: true);
    }

    if (mounted) {
      setState(() {
        replyMessage = null;
      });
    }
  }

  // ==========================================================
  // NEW: FORWARD MESSAGE
  // Lets the user pick another person from the 'users'
  // collection and re-sends the same text into that chat.
  // ==========================================================

  Future<void> _forwardMessage(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    final data = message.data();
    if (data == null) return;
    final text = (data['text'] ?? '').toString();
    if (text.isEmpty) return;

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .limit(100)
          .get();
      final connectionSnap = await FirebaseFirestore.instance
          .collection('connections')
          .where('users', arrayContains: currentUid)
          .where('status', isEqualTo: 'connected')
          .get();
      final connectedUids = <String>{};
      for (final c in connectionSnap.docs) {
        for (final uid in List<String>.from(c.data()['users'] ?? const [])) {
          if (uid != currentUid) connectedUids.add(uid);
        }
      }
      final candidates = snapshot.docs
          .where((d) => d.id != currentUid)
          .toList();
      if (!mounted) return;
      final selected = <String>{};

      await showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF18181F),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        builder: (sheetContext) => StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(context).size.height * .72,
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    const Text(
                      'Forward message to...',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: ListView.builder(
                        itemCount: candidates.length,
                        itemBuilder: (context, index) {
                          final d = candidates[index];
                          final u = d.data();
                          final connected = connectedUids.contains(d.id);
                          final nickname = '';
                          final name = nickname.isNotEmpty
                              ? '$nickname [${(u['publicName'] ?? u['name'] ?? 'User').toString()}]'
                              : (connected &&
                                        (u['privateName'] ?? '')
                                            .toString()
                                            .trim()
                                            .isNotEmpty
                                    ? (u['privateName'] ?? '').toString()
                                    : (u['publicName'] ?? u['name'] ?? 'User')
                                          .toString());
                          final image =
                              connected &&
                                  (u['privateImage'] ?? '')
                                      .toString()
                                      .trim()
                                      .isNotEmpty
                              ? (u['privateImage'] ?? '').toString()
                              : (u['publicImage'] ?? u['profileImage'] ?? '')
                                    .toString();
                          final checked = selected.contains(d.id);
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFF20202A),
                              backgroundImage: _profileImageProvider(image),
                              child: image.isEmpty
                                  ? const Icon(
                                      Icons.person,
                                      color: Colors.white70,
                                    )
                                  : null,
                            ),
                            title: Text(
                              name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              connected ? 'Private' : 'Public',
                              style: const TextStyle(color: Colors.white54),
                            ),
                            trailing: Checkbox(
                              value: checked,
                              activeColor: const Color(0xFF7C3AED),
                              onChanged: (_) => setModalState(() {
                                if (checked) {
                                  selected.remove(d.id);
                                } else {
                                  selected.add(d.id);
                                }
                              }),
                            ),
                            onTap: () => setModalState(() {
                              if (checked) {
                                selected.remove(d.id);
                              } else {
                                selected.add(d.id);
                              }
                            }),
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: selected.isEmpty
                              ? null
                              : () async {
                                  Navigator.pop(sheetContext);
                                  for (final uid in selected) {
                                    await _sendForwardedMessage(
                                      targetUid: uid,
                                      text: text,
                                    );
                                  }
                                },
                          icon: const Icon(Icons.send_rounded),
                          label: Text(
                            'Forward${selected.isEmpty ? '' : ' (${selected.length})'}',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF7C3AED),
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    } catch (e) {
      debugPrint('Forward - load users error: $e');
    }
  }

  Future<void> _sendForwardedMessage({
    required String targetUid,
    required String text,
  }) async {
    final currentUser = FirebaseAuth.instance.currentUser;

    if (currentUser == null) return;

    final ids = [currentUser.uid, targetUid]..sort();
    final targetChatId = ids.join('_');

    final targetChatRef = FirebaseFirestore.instance
        .collection('chats')
        .doc(targetChatId);

    try {
      final now = FieldValue.serverTimestamp();
      final connection = await FirebaseFirestore.instance
          .collection('connections')
          .doc(targetChatId)
          .get();
      final isPrivate = (connection.data()?['status'] ?? '') == 'connected';

      await targetChatRef.collection('messages').add({
        'senderId': currentUser.uid,
        'receiverId': targetUid,
        'text': text,
        'sentAt': now,
        // ==================================================
        // FIX: this was always setting a 24-hour expiresAt, even
        // for private/connected chats. Match the same rule used
        // everywhere else in this file (text/voice/attachment
        // sends): private chat messages get expiresAt: null so
        // they never auto-clear.
        // ==================================================
        'expiresAt': isPrivate
            ? null
            : Timestamp.fromDate(DateTime.now().add(const Duration(hours: 24))),
        'chatTypeAtSend': isPrivate ? 'private' : 'public',
        'savedBy': <String>[],
        'hiddenFor': <String>[],
        'readBy': <String>[],
        'replyTo': null,
        'isForwarded': true,
      });

      await targetChatRef.set({
        'participants': [currentUser.uid, targetUid],
        'lastMessage': text,
        'lastMessageTime': now,
        'lastMessageSenderId': currentUser.uid,
        'otherUserUid': targetUid,
        'hiddenFor': FieldValue.arrayRemove([currentUser.uid]),
        'updatedAt': now,
      }, SetOptions(merge: true));

      if (!mounted) return;

      showTopAlert(context, 'Message forwarded');
    } catch (e) {
      debugPrint('Forward message error: $e');

      if (!mounted) return;

      showTopAlert(context, 'Failed to forward message', isError: true);
    }
  }

  // ==========================================================
  // SAVE MESSAGE FOR CURRENT USER ONLY
  // Saving exempts this message from the 24-hour expiry, but only
  // on the saving user's own chat screen (see _buildMessages filter).
  // ==========================================================

  Future<void> _saveMessage(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    final data = message.data();

    if (data == null) return;

    final hiddenFor = List<String>.from(data['hiddenFor'] ?? []);

    if (hiddenFor.contains(currentUid)) {
      return;
    }

    try {
      await message.reference.update({
        // ONLY THIS USER is saved
        'savedBy': FieldValue.arrayUnion([currentUid]),
      });

      // ==========================================================
      // NEW: record this save as an event on the CHAT doc (not the
      // message) so the OTHER participant can be alerted the next
      // time they open this chat. Resetting 'lastSaveEventSeenBy' to
      // just the saver makes the alert fresh for the other side again,
      // even if an older save event had already been seen by both.
      // ==========================================================
      await chatReference.set({
        'lastSaveEvent': {
          'byUid': currentUid,
          'messageId': message.id,
          'at': FieldValue.serverTimestamp(),
        },
        'lastSaveEventSeenBy': <String>[currentUid],
      }, SetOptions(merge: true));

      if (!mounted) return;

      showTopAlert(context, 'Message saved');
    } catch (e) {
      debugPrint('Save message error: $e');
    }
  }

  // ==========================================================
  // UNSAVE MESSAGE
  // After unsaving, message gets another 24 hours.
  // ==========================================================

  Future<void> _unsaveMessage(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    try {
      final data = message.data();
      final typeAtSend = (data?['chatTypeAtSend'] ?? 'public').toString();

      await message.reference.update({
        // Remove ONLY current user
        'savedBy': FieldValue.arrayRemove([currentUid]),

        // Give it a fresh 24-hour window from now, so it doesn't
        // vanish immediately if the original window already passed
        // while it was saved. Connected/private chats never expire.
        if (typeAtSend == 'public')
          'expiresAt': Timestamp.fromDate(
            DateTime.now().add(const Duration(hours: 24)),
          ),
      });

      if (!mounted) return;

      showTopAlert(context, 'Message will disappear after 24 hours');
    } catch (e) {
      debugPrint('Unsave message error: $e');
    }
  }

  // ==========================================================
  // DELETE FOR YOU
  // ==========================================================

  Future<void> _deleteForYou(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    try {
      final data = message.data() ?? <String, dynamic>{};
      if ((data['messageType'] ?? 'text').toString() == 'voice') {
        await VoiceMessageService.instance.deleteLocal(message.id);
      }

      await message.reference.update({
        'hiddenFor': FieldValue.arrayUnion([currentUid]),
      });

      if (!mounted) return;

      showTopAlert(context, 'Message deleted for you');
    } catch (e) {
      debugPrint('Delete for you error: $e');
    }
  }

  // ==========================================================
  // DELETE FOR EVERYONE
  // ONLY OWN MESSAGE
  // ==========================================================

  Future<void> _deleteForEveryone(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    final data = message.data();

    if (data == null) return;

    final senderId = (data['senderId'] ?? '').toString();

    if (senderId != currentUid) {
      return;
    }

    try {
      if ((data['messageType'] ?? 'text').toString() == 'voice') {
        await VoiceMessageService.instance.deleteLocal(message.id);
        final publicId = (data['cloudinaryPublicId'] ?? '').toString().trim();
        if (publicId.isNotEmpty && data['cloudinaryDeleted'] != true) {
          await VoiceMessageService.instance.deleteCloudinaryAsset(
            chatId: chatId,
            messageId: message.id,
            publicId: publicId,
          );
        }
      }

      await message.reference.delete();

      // ==================================================
      // FIND LATEST MESSAGE
      // ==================================================

      final remainingMessages = await messagesReference
          .orderBy('sentAt', descending: true)
          .limit(1)
          .get();

      // ==================================================
      // NO MESSAGES LEFT
      // ==================================================

      if (remainingMessages.docs.isEmpty) {
        await chatReference.set({
          'lastMessage': '',

          'lastMessageTime': null,

          'lastMessageSenderId': '',
        }, SetOptions(merge: true));

        return;
      }

      // ==================================================
      // UPDATE LAST MESSAGE
      // ==================================================

      final latestMessage = remainingMessages.docs.first;

      final latestData = latestMessage.data();

      await chatReference.set({
        'lastMessage':
            (latestData['messageType'] ?? 'text').toString() == 'voice'
            ? '🎤 Voice message'
            : (latestData['text'] ?? '').toString(),

        'lastMessageTime': latestData['sentAt'],

        'lastMessageSenderId': (latestData['senderId'] ?? '').toString(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Delete for everyone error: $e');
    }
  }

  // ==========================================================
  // LONG PRESS MESSAGE MENU
  // NEW: added a "Forward message" option
  // ==========================================================

  void _showMessageMenu(DocumentSnapshot<Map<String, dynamic>> message) {
    final data = message.data();

    if (data == null) return;

    final senderId = (data['senderId'] ?? '').toString();

    final bool isMe = senderId == currentUid;

    final List<String> savedBy = List<String>.from(data['savedBy'] ?? []);

    final bool isSaved = savedBy.contains(currentUid);

    showModalBottomSheet(
      context: context,

      backgroundColor: const Color(0xFF18181F),

      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),

      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,

            children: [
              const SizedBox(height: 10),

              if (isMe && _canEditMessage(data))
                ListTile(
                  leading: const Icon(
                    Icons.edit_rounded,
                    color: Color(0xFFA78BFA),
                  ),
                  title: const Text(
                    'Edit Message',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _editMessage(message);
                  },
                ),

              // ==================================================
              // SAVE / UNSAVE
              // Private/connected chats never expire messages, so
              // there's nothing to "save" from disappearing — hide
              // this option there and only show it in public chats.
              // ==================================================
              if (!(widget.usePrivateProfile || _isConnected))
                ListTile(
                  leading: Icon(
                    isSaved
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_add_rounded,

                    color: const Color(0xFFA78BFA),
                  ),

                  title: Text(
                    isSaved ? 'Unsave this message' : 'Save this message',

                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  onTap: () {
                    Navigator.pop(sheetContext);

                    if (isSaved) {
                      _unsaveMessage(message);
                    } else {
                      _saveMessage(message);
                    }
                  },
                ),

              // ==================================================
              // NEW: FORWARD MESSAGE
              // ==================================================
              ListTile(
                leading: const Icon(
                  Icons.send_rounded,
                  color: Color(0xFFA78BFA),
                ),

                title: const Text(
                  'Forward message',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                onTap: () {
                  Navigator.pop(sheetContext);
                  _forwardMessage(message);
                },
              ),

              // ==================================================
              // DELETE FOR YOU
              // ==================================================
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.orangeAccent,
                ),

                title: const Text(
                  'Delete for you',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                onTap: () {
                  Navigator.pop(sheetContext);

                  _deleteForYou(message);
                },
              ),

              // ==================================================
              // DELETE FOR EVERYONE
              // ONLY OWN MESSAGE
              // ==================================================
              if (isMe)
                ListTile(
                  leading: const Icon(
                    Icons.delete_forever_rounded,
                    color: Colors.redAccent,
                  ),

                  title: const Text(
                    'Delete for everyone',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  onTap: () {
                    Navigator.pop(sheetContext);

                    _deleteForEveryone(message);
                  },
                ),

              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  // ==========================================================
  // NEW: MESSAGE DATE/TIME FORMATTING FOR THE REVEAL GESTURE
  // Today -> time only, Yesterday -> "Yesterday",
  // Older -> full date.
  // ==========================================================

  String _formatRevealDate(Timestamp? timestamp) {
    if (timestamp == null) return '';

    final date = timestamp.toDate();
    final now = DateTime.now();

    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(date.year, date.month, date.day);

    final differenceInDays = today.difference(messageDay).inDays;

    if (differenceInDays == 0) {
      final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;

      final minute = date.minute.toString().padLeft(2, '0');

      final period = date.hour >= 12 ? 'PM' : 'AM';

      return '$hour:$minute $period';
    } else if (differenceInDays == 1) {
      return 'Yesterday';
    } else {
      final months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];

      return '${date.day} ${months[date.month - 1]} ${date.year}';
    }
  }

  // ==========================================================
  // MESSAGE BUBBLE
  // NEW: highlight-on-arrival, hidden timestamp (revealed via
  // swipe), "Sending..." for pending writes, and "Seen" +
  // subtle glow for the latest read outgoing message.
  // ==========================================================

  Widget _buildMessageBubble(
    DocumentSnapshot<Map<String, dynamic>> message, {
    bool isLatestOutgoingSeen = false,
  }) {
    final data = message.data();

    if (data == null) {
      return const SizedBox.shrink();
    }

    // ========================================================
    // HIDDEN FOR CURRENT USER
    // ========================================================

    final hiddenFor = List<String>.from(data['hiddenFor'] ?? []);

    if (hiddenFor.contains(currentUid)) {
      return const SizedBox.shrink();
    }

    // ========================================================
    // MESSAGE DATA
    // ========================================================

    final String senderId = (data['senderId'] ?? '').toString();

    final String text = (data['text'] ?? '').toString();

    final String messageType = (data['messageType'] ?? 'text').toString();

    final bool isMe = senderId == currentUid;

    final List<String> savedBy = List<String>.from(data['savedBy'] ?? []);

    final bool isSaved = savedBy.contains(currentUid);

    // ========================================================
    // REPLY DATA
    // ========================================================

    final Map<String, dynamic>? replyData = data['replyTo'] is Map
        ? Map<String, dynamic>.from(data['replyTo'] as Map)
        : null;

    // ========================================================
    // SENT TIME
    // ========================================================

    final Timestamp? sentAt = data['sentAt'] is Timestamp
        ? data['sentAt'] as Timestamp
        : null;

    // ========================================================
    // NEW: pending write ("Sending...") + reveal + highlight
    // ========================================================

    final bool isSending = message.metadata.hasPendingWrites;

    final bool isHighlighted = _highlightedMessageIds.contains(message.id);

    final bool showRevealedTimestamp = isMe
        ? _revealMyTimestamps
        : _revealOtherTimestamps;

    final Color baseColor = isMe
        ? const Color(0xFF7C3AED)
        : const Color(0xFF20202A);

    final Color highlightColor = isMe
        ? const Color(0xFFA78BFA)
        : const Color(0xFF2A2438);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,

      // NEW: Stack lets the reaction badge float in a small round
      // circle that overlaps the bottom corner of the bubble,
      // WhatsApp/Instagram-style, instead of sitting inline like a
      // pasted-in image.
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            onDoubleTap: () => _chooseReaction(message),
            onLongPress: () {
              _showMessageMenu(message);
            },

            child: AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOut,

              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),

              margin: const EdgeInsets.only(bottom: 8),

              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),

              decoration: BoxDecoration(
                color: isHighlighted ? highlightColor : baseColor,

                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),

                  topRight: const Radius.circular(18),

                  bottomLeft: Radius.circular(isMe ? 18 : 4),

                  bottomRight: Radius.circular(isMe ? 4 : 18),
                ),

                // NEW: subtle glow for the latest read outgoing msg
                boxShadow: isLatestOutgoingSeen
                    ? [
                        BoxShadow(
                          color: const Color(
                            0xFFA78BFA,
                          ).withValues(alpha: 0.45),
                          blurRadius: 12,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),

              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,

                children: [
                  // ==================================================
                  // REPLIED MESSAGE
                  // ==================================================

                  if (replyData != null) _buildRepliedMessagePreview(replyData),

                  // ==================================================
                  // CURRENT MESSAGE
                  // ==================================================
                  if (messageType == 'voice')
                    _buildVoiceMessageContent(message, data, isMe)
                  else if (messageType == 'photo' ||
                      messageType == 'video' ||
                      messageType == 'audio' ||
                      messageType == 'file')
                    _buildAttachmentMessageContent(message, data, isMe)
                  else
                    Row(
                      mainAxisSize: MainAxisSize.min,

                      crossAxisAlignment: CrossAxisAlignment.end,

                      children: [
                        Flexible(
                          child: Text(
                            text,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                        ),

                        if (isSaved) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.bookmark_rounded,
                            color: Colors.white70,
                            size: 15,
                          ),
                        ],
                      ],
                    ),

                  // ==================================================
                  // NEW: STATUS LINE
                  // Sending... > Seen > revealed timestamp > nothing
                  // FIX: wrapped in AnimatedSize so the bubble's own
                  // height eases in/out together with the fade below,
                  // instead of snapping to the new height instantly while
                  // only the text opacity was animated -- that mismatch
                  // (instant size jump + slow fade) is what made the
                  // timestamp look like it was popping in/out rather than
                  // smoothly appearing/disappearing.
                  // ==================================================
                  AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: isSending
                          ? const Padding(
                              key: ValueKey('sending'),
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                'Sending...',
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 10,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            )
                          : (isLatestOutgoingSeen
                                ? const Padding(
                                    key: ValueKey('seen'),
                                    padding: EdgeInsets.only(top: 4),
                                    child: Text(
                                      'Seen',
                                      style: TextStyle(
                                        color: Color(0xFFA78BFA),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  )
                                : (showRevealedTimestamp && sentAt != null
                                      ? Padding(
                                          key: const ValueKey('timestamp'),
                                          padding: const EdgeInsets.only(
                                            top: 4,
                                          ),
                                          child: Text(
                                            _formatRevealDate(sentAt),
                                            style: const TextStyle(
                                              color: Colors.white60,
                                              fontSize: 10,
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(
                                          key: ValueKey('none'),
                                        ))),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ==================================================
          // NEW: round reaction badge, WhatsApp/Instagram-style --
          // overlaps the bottom corner of the bubble. Tapping it
          // removes YOUR reaction; to react with a different emoji,
          // double-tap the message again to reopen the full picker.
          // ==================================================
          if (data['reactions'] is Map && (data['reactions'] as Map).isNotEmpty)
            Positioned(
              bottom: -10,
              left: isMe ? -6 : null,
              right: isMe ? null : -6,
              child: GestureDetector(
                onTap: () => _removeReaction(message),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF18181F),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF18181F),
                      width: 2,
                    ),
                  ),
                  child: Text(
                    (data['reactions'] as Map).values.last.toString(),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ==========================================================
  // REPLIED MESSAGE INSIDE BUBBLE
  // ==========================================================

  Widget _buildRepliedMessagePreview(Map<String, dynamic> replyData) {
    final String senderId = (replyData['senderId'] ?? '').toString();

    final String replyType = (replyData['messageType'] ?? 'text').toString();

    final String text = replyType == 'voice'
        ? '🎤 Voice message'
        : (replyData['text'] ?? '').toString();

    final bool isMe = senderId == currentUid;

    return Container(
      width: double.infinity,

      margin: const EdgeInsets.only(bottom: 8),

      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),

      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),

        borderRadius: BorderRadius.circular(10),
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Row(
            children: [
              const Icon(Icons.reply_rounded, color: Colors.white70, size: 15),

              const SizedBox(width: 5),

              Expanded(
                child: Text(
                  isMe ? 'You' : widget.otherUserName,

                  maxLines: 1,

                  overflow: TextOverflow.ellipsis,

                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 3),

          Text(
            text,

            maxLines: 2,

            overflow: TextOverflow.ellipsis,

            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // NEW: figure out which message is the "latest outgoing" one
  // so only that bubble can ever show the Seen indicator.
  // ==========================================================

  String? _latestOutgoingId(
    List<DocumentSnapshot<Map<String, dynamic>>> messages,
  ) {
    for (int i = messages.length - 1; i >= 0; i--) {
      final data = messages[i].data();

      if (data == null) continue;

      final senderId = (data['senderId'] ?? '').toString();

      if (senderId == currentUid) {
        return messages[i].id;
      }
    }

    return null;
  }

  bool _isLatestOutgoingSeen(
    List<DocumentSnapshot<Map<String, dynamic>>> messages,
    String? latestOutgoingId,
  ) {
    if (latestOutgoingId == null) return false;

    for (final m in messages) {
      if (m.id == latestOutgoingId) {
        final data = m.data();

        if (data == null) return false;

        final readBy = List<String>.from(data['readBy'] ?? []);

        return readBy.contains(widget.otherUserUid);
      }
    }

    return false;
  }

  // ==========================================================
  // NEW: reveal-timestamps gesture handling
  // Uses raw pointer events (via Listener) so it runs alongside
  // the per-message swipe-to-reply gesture without fighting it
  // for the gesture arena.
  // ==========================================================

  void _handleGlobalPointerMove(PointerMoveEvent event) {
    // FIX: this pointer is currently swiping an actual chat bubble
    // (swipe-to-reply) -- that gesture owns it exclusively, so don't
    // also treat it as an empty-space swipe that reveals timestamps.
    if (_bubbleDragActive) {
      _globalDragAccumulator = 0;
      _globalDragAccumulatorY = 0;
      return;
    }

    _globalDragAccumulator += event.delta.dx;
    _globalDragAccumulatorY += event.delta.dy;

    const threshold = 45.0;

    // Only reveal on a movement that is clearly more horizontal than
    // vertical, so an ordinary vertical scroll through the message list
    // (whose finger path is rarely perfectly straight) can never be
    // mistaken for the intentional horizontal swipe this reveal is for.
    final bool isHorizontalSwipe =
        _globalDragAccumulator.abs() > _globalDragAccumulatorY.abs();

    if (!isHorizontalSwipe) return;

    if (_globalDragAccumulator > threshold) {
      if (!_revealOtherTimestamps) {
        setState(() {
          _revealOtherTimestamps = true;
        });
      }
    } else if (_globalDragAccumulator < -threshold) {
      if (!_revealMyTimestamps) {
        setState(() {
          _revealMyTimestamps = true;
        });
      }
    }
  }

  void _handleGlobalPointerUp(PointerUpEvent event) {
    _globalDragAccumulator = 0;
    _globalDragAccumulatorY = 0;

    // A bubble-drag release is handled entirely by _SwipeableReply
    // (spring-back / reply). Nothing to reveal or schedule here.
    if (_bubbleDragActive) return;

    _revealHideTimer?.cancel();

    _revealHideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted) return;

      setState(() {
        _revealOtherTimestamps = false;
        _revealMyTimestamps = false;
      });
    });
  }

  // ==========================================================
  // CHAT MESSAGES
  // ==========================================================

  Widget _buildMessages() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _messagesStream,

      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Text(
              'Unable to load messages',

              style: TextStyle(color: Colors.white54),
            ),
          );
        }

        if (!snapshot.hasData) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFA78BFA)),
          );
        }

        final allMessages = snapshot.data!.docs;

        // ======================================================
        // FILTER HIDDEN MESSAGES
        // ======================================================

        final messages = allMessages.where((message) {
          final data = message.data();

          final hiddenFor = List<String>.from(data['hiddenFor'] ?? []);
          if (hiddenFor.contains(currentUid)) return false;
          final savedBy = List<String>.from(data['savedBy'] ?? []);
          final expiresAt = data['expiresAt'];
          final typeAtSend = (data['chatTypeAtSend'] ?? 'public').toString();
          if (typeAtSend == 'public' &&
              expiresAt is Timestamp &&
              expiresAt.toDate().isBefore(DateTime.now()) &&
              !savedBy.contains(currentUid)) {
            return false;
          }
          if (_mySettings['blocked'] == true ||
              _otherSettings['blocked'] == true)
            return false;
          return true;
        }).toList();

        // NEW: feed this snapshot into our tracking logic
        // (highlight-on-arrival, auto-scroll, read receipts).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _processMessagesSnapshot(messages);
        });

        // ======================================================
        // NO VISIBLE MESSAGES
        // ======================================================

        if (messages.isEmpty) {
          return const Center(
            child: Text(
              'Start chatting',

              style: TextStyle(color: Colors.white38, fontSize: 16),
            ),
          );
        }

        // NEW: compute the latest outgoing message + seen state
        // once per build instead of per-bubble.
        final latestOutgoingId = _latestOutgoingId(messages);

        final latestOutgoingSeen = _isLatestOutgoingSeen(
          messages,
          latestOutgoingId,
        );

        // ======================================================
        // MESSAGE LIST
        // ======================================================

        return Stack(
          children: [
            Listener(
              onPointerMove: _handleGlobalPointerMove,
              onPointerUp: _handleGlobalPointerUp,
              onPointerCancel: (_) {
                _globalDragAccumulator = 0;
                _globalDragAccumulatorY = 0;
              },
              child: ListView.builder(
                controller: scrollController,

                padding: const EdgeInsets.fromLTRB(15, 20, 15, 20),

                itemCount: messages.length,

                itemBuilder: (context, index) {
                  final message = messages[index];

                  final bool isLatestOutgoing =
                      latestOutgoingId != null &&
                      message.id == latestOutgoingId;

                  final data = message.data();

                  final senderId = (data['senderId'] ?? '').toString();

                  final bool isMe = senderId == currentUid;

                  return Builder(
                    builder: (messageContext) {
                      _rememberMessageContext(message.id, messageContext);
                      return _SwipeableReply(
                        key: ValueKey('swipe_${message.id}'),
                        isMe: isMe,
                        onReply: () => _setReplyMessage(message),
                        onBubbleDragChanged: _setBubbleDragActive,
                        child: _buildMessageBubble(
                          message,
                          isLatestOutgoingSeen:
                              isLatestOutgoing && latestOutgoingSeen,
                        ),
                      );
                    },
                  );
                },
              ),
            ),

            // ==================================================
            // NEW: SCROLL TO BOTTOM BUTTON + UNREAD DOT
            // ==================================================
            Positioned(
              right: 14,
              bottom: 14,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _showScrollToBottomButton ? 1 : 0,
                child: IgnorePointer(
                  ignoring: !_showScrollToBottomButton,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Material(
                        color: const Color(0xFF20202A),
                        shape: const CircleBorder(),
                        elevation: 4,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => _scrollToBottom(),
                          child: const Padding(
                            padding: EdgeInsets.all(10),
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: Color(0xFFA78BFA),
                              size: 26,
                            ),
                          ),
                        ),
                      ),

                      if (_hasUnseenNewMessage)
                        Positioned(
                          right: -1,
                          top: -1,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              color: Colors.redAccent,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // NEW: profile header tap
  // ==========================================================

  void _openUserProfile() {
    if (widget.onProfileTap != null) {
      widget.onProfileTap!(widget.otherUserUid);
      return;
    }

    // This screen is also used as the plain/public chat screen for
    // accounts that started out non-connected (chat list tap, chat
    // search-mode result tap, "Message" from the connection sheet).
    // If the account has since become connected, the header must open
    // the private/connected profile instead of the smaller public one
    // -- reusing the existing PrivateMemberProfilePage rather than a
    // second implementation. `widget.usePrivateProfile` covers the
    // PrivateChatScreen case (which already supplies its own
    // onProfileTap above and never reaches this branch), and
    // `_isConnected` covers a plain ChatScreen opened for a uid that
    // is connected.
    final bool openPrivateProfile = widget.usePrivateProfile || _isConnected;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => openPrivateProfile
            ? PrivateMemberProfilePage(uid: widget.otherUserUid)
            : PublicMemberProfilePage(uid: widget.otherUserUid),
      ),
    );
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: false,

      // ========================================================
      // APP BAR
      // ========================================================
      appBar: AppBar(
        backgroundColor: const Color(0xFF18181F),

        elevation: 0,

        iconTheme: const IconThemeData(color: Colors.white),

        titleSpacing: 0,

        title: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(widget.otherUserUid)
              .snapshots(),
          builder: (context, snapshot) {
            final data = snapshot.data?.data() ?? _otherUserData;
            final nick = (_mySettings['nickname'] ?? '').toString().trim();
            final baseName =
                (widget.usePrivateProfile
                        ? (data['privateName'] ?? widget.otherUserName)
                        : (data['publicName'] ?? widget.otherUserName))
                    .toString()
                    .trim();
            final name = nick.isNotEmpty
                ? nick
                : (baseName.isNotEmpty ? baseName : widget.otherUserName);
            final activeAllowed =
                widget.usePrivateProfile ||
                _isConnected ||
                _otherSettings['activeInfoEnabled'] == true;
            final status = activeAllowed
                ? ChatSettingsService.instance.activeLabel(data)
                : '';
            final image =
                (widget.usePrivateProfile
                        ? (data['privateImage'] ?? '')
                        : (data['publicImage'] ?? ''))
                    .toString()
                    .trim()
                    .isNotEmpty
                ? (widget.usePrivateProfile
                          ? (data['privateImage'] ?? '')
                          : (data['publicImage'] ?? ''))
                      .toString()
                : widget.otherUserImage;
            return InkWell(
              onTap: _openUserProfile,
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: const Color(0xFF20202A),
                    backgroundImage: _profileImageProvider(image),
                    child: image.isEmpty
                        ? const Icon(
                            Icons.person_rounded,
                            color: Colors.white70,
                          )
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        // NEW: the typing indicator no longer lives here -- it
                        // now shows above the input bar at the bottom of the
                        // screen instead of underneath the profile name (see
                        // the MESSAGE INPUT section below). This row only ever
                        // shows the active/last-seen status now.
                        if (status.isNotEmpty)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PresenceStatusDot(
                                isActive: status == 'Active now',
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),

        actions: [
          // Only show the call button once the OTHER member has enabled
          // "Enable Voice Call" for me from their own menu -- that
          // permission lives on THEIR settings doc for me
          // (`_otherSettings`), never on my own (`_mySettings`). This is
          // what makes the permission one-directional: my enabling it
          // shows the icon on THEIR screen so THEY can call ME, not the
          // other way around.
          if (_isCallEnabled(_otherSettings, 'voiceCallEnabled'))
            IconButton(
              icon: const Icon(Icons.call_rounded, color: Color(0xFF22D3EE)),
              onPressed: () {
                final image =
                    (widget.usePrivateProfile
                            ? (_otherUserData['privateImage'] ?? '')
                            : (_otherUserData['publicImage'] ?? ''))
                        .toString()
                        .trim()
                        .isNotEmpty
                    ? (widget.usePrivateProfile
                              ? _otherUserData['privateImage']
                              : _otherUserData['publicImage'])
                          .toString()
                    : widget.otherUserImage;

                CallService.instance.startCall(
                  context: context,
                  receiverId: widget.otherUserUid,
                  receiverName: widget.otherUserName,
                  receiverImage: image,
                );
              },
            ),
          // Video call icon sits centred between the voice call icon
          // and the 3-dot menu. It has its own independent permission
          // (`videoCallEnabled`) -- allowing voice does not imply
          // allowing video, and vice versa.
          if (_isCallEnabled(_otherSettings, 'videoCallEnabled'))
            IconButton(
              icon: const Icon(
                Icons.videocam_rounded,
                color: Color(0xFFA78BFA),
              ),
              onPressed: () {
                final image =
                    (widget.usePrivateProfile
                            ? (_otherUserData['privateImage'] ?? '')
                            : (_otherUserData['publicImage'] ?? ''))
                        .toString()
                        .trim()
                        .isNotEmpty
                    ? (widget.usePrivateProfile
                              ? _otherUserData['privateImage']
                              : _otherUserData['publicImage'])
                          .toString()
                    : widget.otherUserImage;

                CallService.instance.startCall(
                  context: context,
                  receiverId: widget.otherUserUid,
                  receiverName: widget.otherUserName,
                  receiverImage: image,
                  isVideo: true,
                );
              },
            ),
          IconButton(
            onPressed: _showChatSettingsMenu,
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
          ),
        ],
      ),

      // ========================================================
      // BODY
      // ========================================================

      // NEW: tapping anywhere outside the text field (message list,
      // empty background, etc.) now unfocuses/dismisses the keyboard.
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: CosmicBackground(
          fadeIn: false,
          child: Column(
            children: [
              Expanded(child: _buildMessages()),

              // ====================================================
              // TYPING INDICATOR
              // ----------------------------------------------------
              // Sits above the input bar, aligned bottom-left, and is
              // the ONLY place "typing..." is ever shown now (moved
              // out from underneath the profile name in the AppBar).
              // Driven by the same existing typing-status mechanism
              // used everywhere else in this screen (`_otherTyping`,
              // kept in sync by the ChatSettingsService listeners in
              // `_listenChatSettings`, which watch the other user's
              // `isTyping` / `typingToUid` fields in Firestore).
              // ====================================================
              _buildTypingIndicatorBar(),

              // ====================================================
              // MESSAGE INPUT
              // ====================================================
              SafeArea(
                top: false,

                child: Column(
                  mainAxisSize: MainAxisSize.min,

                  children: [
                    // ==================================================
                    // REPLY PREVIEW
                    // ==================================================

                    _buildReplyPreview(),

                    // ==================================================
                    // INPUT
                    // NEW: extra bottom spacing + expanding field
                    // ==================================================
                    TranslatorInputHost(
                      controller: _translator,
                      getReceivedTexts: _lastReceivedTexts,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),

                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,

                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: 1),
                              child: Container(
                                width: 38,
                                height: 38,
                                margin: const EdgeInsets.only(right: 7),
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(0xFF20202A),
                                ),
                                child: IconButton(
                                  tooltip: 'Attachments',
                                  padding: EdgeInsets.zero,
                                  onPressed:
                                      (_isSendingAttachment ||
                                          _isSendingVoice ||
                                          _isRecordingVoice)
                                      ? null
                                      : _showAttachmentMenu,
                                  icon: const Icon(
                                    Icons.add_rounded,
                                    color: Color(0xFFA78BFA),
                                    size: 25,
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: AnimatedSize(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOut,
                                alignment: Alignment.center,
                                child: TextField(
                                  controller: messageController,

                                  focusNode: messageFocusNode,

                                  minLines: 1,

                                  maxLines: _inputFocused ? 5 : 1,

                                  style: const TextStyle(color: Colors.white),

                                  textInputAction: TextInputAction.newline,

                                  decoration: InputDecoration(
                                    hintText: 'Type a message...',

                                    hintStyle: const TextStyle(
                                      color: Colors.white38,
                                    ),

                                    filled: true,

                                    fillColor: const Color(0xFF18181F),

                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: _inputFocused ? 14 : 12,
                                    ),

                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(25),

                                      borderSide: BorderSide(
                                        color: const Color(
                                          0xFFA78BFA,
                                        ).withValues(alpha: 0.35),
                                      ),
                                    ),

                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(25),

                                      borderSide: const BorderSide(
                                        color: Color(0xFFA78BFA),
                                      ),
                                    ),
                                  ),

                                  onSubmitted: (_) {
                                    _sendMessage();
                                  },
                                ),
                              ),
                            ),

                            const SizedBox(width: 8),

                            if (_isRecordingVoice)
                              Container(
                                height: 50,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF18181F),
                                  borderRadius: BorderRadius.circular(25),
                                  border: Border.all(
                                    color: const Color(
                                      0xFFA78BFA,
                                    ).withValues(alpha: 0.35),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.mic_rounded,
                                      color: Colors.redAccent,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      _formatVoiceDuration(
                                        _voiceRecordingSeconds,
                                      ),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(width: 3),
                                    IconButton(
                                      tooltip: 'Cancel recording',
                                      onPressed: _cancelVoiceRecording,
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        color: Colors.white70,
                                      ),
                                    ),
                                    Container(
                                      width: 42,
                                      height: 42,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Color(0xFF7C3AED),
                                      ),
                                      child: IconButton(
                                        onPressed: _isSendingVoice
                                            ? null
                                            : _stopAndSendVoiceRecording,
                                        icon: const Icon(
                                          Icons.send_rounded,
                                          color: Colors.white,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            else
                              ValueListenableBuilder<TextEditingValue>(
                                valueListenable: messageController,
                                builder: (context, value, _) {
                                  final hasText = value.text.trim().isNotEmpty;
                                  return Container(
                                    width: 50,
                                    height: 50,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Color(0xFF7C3AED),
                                    ),
                                    child: IconButton(
                                      onPressed: _isSendingVoice
                                          ? null
                                          : hasText
                                          ? _sendMessage
                                          : _startVoiceRecording,
                                      icon: Icon(
                                        hasText
                                            ? Icons.send_rounded
                                            : Icons.mic_rounded,
                                        color: Colors.white,
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(
        ChatSettingsService.instance.updatePresence(
          active: false,
          typingToUid: null,
        ),
      );
    } else if (state == AppLifecycleState.resumed) {
      unawaited(
        ChatSettingsService.instance.updatePresence(
          active: true,
          typingToUid: null,
        ),
      );
    }
  }

  // ==========================================================
  // DISPOSE
  // ==========================================================

  @override
  void dispose() {
    // This chat's screen is going away -- messages arriving here can
    // show their heads-up bar again.
    final activeKey = _activeConversationKey;
    if (activeKey != null) ActiveConversation.pop(activeKey);

    _typingStopTimer?.cancel();
    // NOTE: intentionally NOT passing `active: false` here. App-level
    // online/offline presence is owned by the app-level lifecycle observer
    // (see HomeShell/MePage), not by whether this individual chat screen is
    // open. Closing this screen should only clear the typing indicator --
    // it must never mark the account offline while the app itself is still
    // in the foreground (e.g. back on the Chats page).
    unawaited(ChatSettingsService.instance.updatePresence(typingToUid: null));
    _otherUserSub?.cancel();
    _mySettingsSub?.cancel();
    _otherSettingsSub?.cancel();
    messageController.removeListener(_handleTypingChanged);
    _translator.dispose();
    messageController.dispose();

    scrollController.removeListener(_handleScrollPosition);
    scrollController.dispose();

    messageFocusNode.removeListener(_handleFocusChange);
    messageFocusNode.dispose();

    _revealHideTimer?.cancel();
    _voiceRecordingTimer?.cancel();
    unawaited(_voiceRecorder.stop());
    unawaited(_voicePlayer.dispose());

    WidgetsBinding.instance.removeObserver(this);
    _messageBubbleContexts.clear();

    super.dispose();
  }
}

// ==============================================================
// NEW: private stateful widget powering the swipe-to-reply
// gesture with a smooth spring-back animation on release.
// ==============================================================

class _SwipeableReply extends StatefulWidget {
  final bool isMe;
  final VoidCallback onReply;
  final Widget child;
  // FIX: lets the parent screen know exactly when a drag that started
  // on this bubble begins/ends, so it can suppress the separate
  // "swipe empty space to reveal timestamps" gesture while a bubble
  // swipe is in progress (and only then -- see chat_screen's
  // _handleGlobalPointerMove).
  final ValueChanged<bool>? onBubbleDragChanged;

  const _SwipeableReply({
    super.key,
    required this.isMe,
    required this.onReply,
    required this.child,
    this.onBubbleDragChanged,
  });

  @override
  State<_SwipeableReply> createState() => _SwipeableReplyState();
}

class _SwipeableReplyState extends State<_SwipeableReply>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();

    _controller =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 320),
        )..addListener(() {
          setState(() {});
        });
  }

  // FIX: fires the instant this pointer goes down on the bubble --
  // before any movement, and before the drag is even accepted into
  // the gesture arena. Claiming the pointer this early (rather than in
  // onHorizontalDragStart) closes the timing gap during which the
  // background empty-space listener might otherwise start counting the
  // same movement toward a timestamp reveal.
  void _onDragDown(DragDownDetails details) {
    widget.onBubbleDragChanged?.call(true);
  }

  void _onDragStart(DragStartDetails details) {
    _controller.stop();
    _dragOffset = 0;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    setState(() {
      if (widget.isMe) {
        if (delta < 0) {
          // only accumulates on LEFT movement
          _dragOffset += delta;
          if (_dragOffset < -90) _dragOffset = -90;
        } else if (_dragOffset < 0) {
          // lets it spring back toward 0
          _dragOffset += delta;
          if (_dragOffset > 0) _dragOffset = 0;
        }
        // if delta > 0 (swipe right) and _dragOffset is already 0,
        // NEITHER branch runs -> _dragOffset stays exactly 0
      } else {
        if (delta > 0) {
          // only accumulates on RIGHT movement
          _dragOffset += delta;
          if (_dragOffset > 90) _dragOffset = 90;
        } else if (_dragOffset > 0) {
          _dragOffset += delta;
          if (_dragOffset < 0) _dragOffset = 0;
        }
      }
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final bool shouldReply = widget.isMe
        ? _dragOffset <=
              -55 // own message: only fires once swiped LEFT past -55
        : _dragOffset >=
              55; // other's message: only fires once swiped RIGHT past 55
    if (shouldReply) widget.onReply();
    _animateBack();
    widget.onBubbleDragChanged?.call(false);
  }

  void _onDragCancel() {
    _animateBack();
    widget.onBubbleDragChanged?.call(false);
  }

  void _animateBack() {
    final start = _dragOffset;

    final animation = Tween<double>(
      begin: start,
      end: 0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    void listener() {
      setState(() {
        _dragOffset = animation.value;
      });
    }

    animation.addListener(listener);

    _controller
      ..reset()
      ..forward().whenCompleteOrCancel(() {
        animation.removeListener(listener);
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isMe = widget.isMe;

    return GestureDetector(
      // FIX: was HitTestBehavior.translucent, which made this
      // GestureDetector claim every touch anywhere across the full
      // width of the chat row -- including the empty space beside the
      // bubble -- because a translucent hit-test box registers a hit
      // as soon as the touch falls inside its bounding box, regardless
      // of whether anything is actually painted there. That's what let
      // swiping the empty space next to a message trigger swipe-to-
      // reply. deferToChild (the default) only counts as a hit when
      // the touch lands on something this widget's child actually
      // paints -- i.e. the bubble itself -- so touches beside it fall
      // through untouched to the "swipe empty space to reveal
      // timestamps" gesture below.
      behavior: HitTestBehavior.deferToChild,
      onHorizontalDragDown: _onDragDown,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _onDragCancel,
      child: Stack(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        children: [
          Positioned(
            left: isMe ? null : 5,
            right: isMe ? 5 : null,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: (_dragOffset.abs() / 55).clamp(0.0, 1.0),
              child: AnimatedScale(
                duration: const Duration(milliseconds: 120),
                scale: 0.7 + (0.3 * (_dragOffset.abs() / 55).clamp(0.0, 1.0)),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF20202A),
                  ),
                  child: const Icon(
                    Icons.reply_rounded,
                    color: Color(0xFFA78BFA),
                    size: 21,
                  ),
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
// ================================================================
// PUBLIC MEMBER PROFILE
// ---------------------------------------------------------------
// Used by the Me -> Members flow and by the public chat header.
// It is deliberately a real page instead of a named route so the
// profile can never fail because '/profile' was not registered.
// ================================================================

class PublicMemberProfilePage extends StatefulWidget {
  final String uid;
  final Map<String, dynamic> initialData;

  const PublicMemberProfilePage({
    super.key,
    required this.uid,
    this.initialData = const {},
  });

  @override
  State<PublicMemberProfilePage> createState() =>
      _PublicMemberProfilePageState();
}

class _PublicMemberProfilePageState extends State<PublicMemberProfilePage> {
  Map<String, dynamic> _data = {};
  Map<String, dynamic> _mySettings = {};
  Map<String, dynamic> _otherSettings = {};
  bool _loadingConnection = true;
  String _connectionStatus = 'none';

  // Guards the "Set Nickname" Save button against a second save being
  // fired (e.g. a fast double-tap) while the previous write is still
  // in flight -- mirrors the same guard on _ChatScreenState.
  bool _savingNickname = false;

  @override
  void initState() {
    super.initState();
    _data = Map<String, dynamic>.from(widget.initialData);
    _load();
  }

  Future<void> _load() async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) {
      if (mounted) setState(() => _loadingConnection = false);
      return;
    }

    // Everything below runs TOGETHER and each part is guarded on its own:
    // one slow / denied read (e.g. the other person's chat settings) must
    // never keep the page on the loading spinner forever.
    final ids = [me.uid, widget.uid]..sort();
    final db = FirebaseFirestore.instance;
    const wait = Duration(seconds: 8);

    Future<T> safe<T>(Future<T> f, T fallback) async {
      try {
        return await f.timeout(wait);
      } catch (_) {
        return fallback;
      }
    }

    // 1) Connection status first -- it decides which buttons to show.
    final statusFuture = safe<String>(
      db
          .collection('connections')
          .doc(ids.join('_'))
          .get()
          .then((d) => (d.data()?['status'] ?? 'none').toString()),
      'none',
    );
    final userFuture = safe<Map<String, dynamic>?>(
      db.collection('users').doc(widget.uid).get().then((d) => d.data()),
      null,
    );

    final status = await statusFuture;
    final userData = await userFuture;
    if (!mounted) return;
    setState(() {
      if (userData != null) _data = userData;
      _connectionStatus = status;
      _loadingConnection = false;
    });

    // 2) Chat settings (nickname / mute ...) only fill in afterwards.
    final results = await Future.wait<Map<String, dynamic>>([
      safe<Map<String, dynamic>>(
        ChatSettingsService.instance.getSettings(
          ownerUid: me.uid,
          otherUid: widget.uid,
        ),
        _mySettings,
      ),
      safe<Map<String, dynamic>>(
        ChatSettingsService.instance.getSettings(
          ownerUid: widget.uid,
          otherUid: me.uid,
        ),
        _otherSettings,
      ),
    ]);
    if (!mounted) return;
    setState(() {
      _mySettings = results[0];
      _otherSettings = results[1];
    });
  }

  String get _publicName =>
      (_data['publicName'] ?? _data['name'] ?? 'User').toString().trim();
  String get _publicImage =>
      (_data['publicImage'] ?? _data['profileImage'] ?? '').toString().trim();

  ImageProvider? get _imageProvider {
    if (_publicImage.isEmpty) return null;
    if (_publicImage.startsWith('http://') ||
        _publicImage.startsWith('https://')) {
      return NetworkImage(_publicImage);
    }
    return AssetImage(_publicImage);
  }

  Future<void> _connect() async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null || me.uid == widget.uid) return;

    final ids = [me.uid, widget.uid]..sort();
    final ref = FirebaseFirestore.instance
        .collection('connections')
        .doc(ids.join('_'));
    await ref.set({
      'users': [me.uid, widget.uid],
      'senderUid': me.uid,
      'receiverUid': widget.uid,
      'senderName': (_data['publicName'] ?? 'User').toString(),
      'receiverName': _publicName,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
    if (!mounted) return;
    setState(() => _connectionStatus = 'pending');
  }

  /// "Message" button shown to the right of Connect / Request Pending
  /// for accounts that are not connected yet.
  Widget _messageButton() {
    return ElevatedButton(
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            otherUserUid: widget.uid,
            otherUserName: _publicName,
            otherUserImage: _publicImage,
          ),
        ),
      ),
      child: const Text('Message'),
    );
  }

  Future<void> _setNickname() async {
    // Same fix as _ChatScreenState._showChatSettingsMenu's nickname
    // dialog: own the controller inside the dialog's own StatefulWidget
    // (_ProfileNicknameDialog) instead of disposing it manually right
    // after showDialog's Future resolves, which races the dialog's exit
    // transition and can throw "A TextEditingController was used after
    // being disposed."
    final value = await showDialog<String>(
      context: context,
      builder: (dialog) => _ProfileNicknameDialog(
        initialValue: (_mySettings['nickname'] ?? '').toString(),
      ),
    );
    if (value == null || _savingNickname) return;

    _savingNickname = true;
    try {
      await ChatSettingsService.instance.setNickname(widget.uid, value);
      if (mounted)
        setState(() => _mySettings = {..._mySettings, 'nickname': value});
    } catch (e) {
      if (mounted) {
        showTopAlert(
          context,
          'Failed to save nickname. Please try again.',
          isError: true,
        );
      }
    } finally {
      _savingNickname = false;
    }
  }

  Future<void> _toggleSetting(String field, bool current) async {
    final service = ChatSettingsService.instance;
    if (field == 'activeInfoEnabled') {
      await service.setActiveInfo(widget.uid, !current);
    } else if (field == 'typingInfoEnabled') {
      await service.setTypingInfo(widget.uid, !current);
    } else if (field == 'muted') {
      await service.setMuted(widget.uid, !current);
      // Let the in-app heads-up bar re-read this chat's mute state.
      IncomingMessageAlert.invalidateMute(widget.uid);
    } else if (field == 'blocked') {
      await service.setBlocked(widget.uid, !current);
    }
    if (mounted) await _load();
  }

  Future<void> _showMenu() async {
    final active = _mySettings['activeInfoEnabled'] == true;
    final typing = _mySettings['typingInfoEnabled'] == true;
    final muted = _mySettings['muted'] == true;
    final blocked = _mySettings['blocked'] == true;

    // This "Set Nickname" row used to call Navigator.pop(sheet) and then,
    // in that same synchronous onTap callback, call _setNickname() --
    // which immediately opened a new AlertDialog via showDialog(). Popping
    // a modal bottom sheet route and pushing a new dialog route back-to-back
    // like that starts the sheet's closing transition and the dialog's
    // opening transition on the same Navigator/Overlay at the same time,
    // and Flutter tore down the sheet's Element tree (and the
    // InheritedWidget subscriptions/"_dependents" it still held) before
    // that teardown had actually finished -- throwing Flutter's own
    // "'_dependents.isEmpty': is not true" assertion instead of ever
    // reaching ChatSettingsService.setNickname(). The other rows below
    // never pushed a new route after popping, so they never hit this --
    // this is the same lifecycle bug that was already fixed for the main
    // chat screen's own top-menu (_ChatScreenState._showChatSettingsMenu),
    // but this separate "Profile" page's top-menu still had its own,
    // still-broken copy of the same Set Nickname flow.
    //
    // The fix: only report *which* row was tapped here, and wait for
    // showModalBottomSheet's own Future -- which only completes once the
    // sheet has fully finished closing -- before doing anything that opens
    // another route.
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF18181F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.edit_note_rounded,
                color: Color(0xFFA78BFA),
              ),
              title: const Text(
                'Set Nickname',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(sheet, 'nickname'),
            ),
            ListTile(
              leading: const Icon(
                Icons.visibility_rounded,
                color: Color(0xFFA78BFA),
              ),
              title: Text(
                'Enable Active Info${active ? ' ✓' : ''}',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(sheet, 'active'),
            ),
            ListTile(
              leading: const Icon(
                Icons.keyboard_rounded,
                color: Color(0xFFA78BFA),
              ),
              title: Text(
                'Enable Typing Info${typing ? ' ✓' : ''}',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(sheet, 'typing'),
            ),
            ListTile(
              leading: Icon(
                muted
                    ? Icons.notifications_off_rounded
                    : Icons.notifications_active_rounded,
                color: const Color(0xFFA78BFA),
              ),
              title: Text(
                muted ? 'Unmute Message' : 'Mute Message',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(sheet, 'muted'),
            ),
            ListTile(
              leading: Icon(
                blocked ? Icons.lock_open_rounded : Icons.block_rounded,
                color: Colors.redAccent,
              ),
              title: Text(
                blocked ? 'Unblock Account' : 'Block Account',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(sheet, 'blocked'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;
    switch (action) {
      case 'nickname':
        await _setNickname();
        break;
      case 'active':
        await _toggleSetting('activeInfoEnabled', active);
        break;
      case 'typing':
        await _toggleSetting('typingInfoEnabled', typing);
        break;
      case 'muted':
        await _toggleSetting('muted', muted);
        break;
      case 'blocked':
        await _toggleSetting('blocked', blocked);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final nickname = (_mySettings['nickname'] ?? '').toString().trim();
    final displayName = nickname.isNotEmpty
        ? '$nickname [$_publicName]'
        : _publicName;

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Profile',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            onPressed: _showMenu,
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(widget.uid)
            .snapshots(),
        builder: (context, snapshot) {
          final live = snapshot.data?.data();
          if (live != null) _data = live;

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 58,
                    backgroundColor: const Color(0xFF20202A),
                    backgroundImage: _imageProvider,
                    child: _publicImage.isEmpty
                        ? const Icon(
                            Icons.person_rounded,
                            size: 55,
                            color: Colors.white70,
                          )
                        : null,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    displayName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_loadingConnection)
                    const CircularProgressIndicator(color: Color(0xFFA78BFA))
                  else if (widget.uid ==
                      (FirebaseAuth.instance.currentUser?.uid ?? ''))
                    const SizedBox.shrink() // another profile of my own account
                  else if (_connectionStatus == 'connected')
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(
                                  otherUserUid: widget.uid,
                                  otherUserName: _publicName,
                                  otherUserImage: _publicImage,
                                ),
                              ),
                            ),
                            child: const Text('Message'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              final me = FirebaseAuth.instance.currentUser;
                              if (me == null) return;
                              final ids = [me.uid, widget.uid]..sort();
                              await FirebaseFirestore.instance
                                  .collection('connections')
                                  .doc(ids.join('_'))
                                  .delete();
                              if (mounted)
                                setState(() => _connectionStatus = 'none');
                            },
                            child: const Text('Connected'),
                          ),
                        ),
                      ],
                    )
                  else if (_connectionStatus == 'pending')
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: const Color(0xFF20202A),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: const Center(
                              child: Text(
                                'Request Pending',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: _messageButton()),
                      ],
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _connect,
                            child: const Text('Connect'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: _messageButton()),
                      ],
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

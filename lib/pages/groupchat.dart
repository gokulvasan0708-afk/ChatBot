import '../features/ai_assistant/ai_launcher.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

import 'groupstab.dart';
import '../services/chat_settings_service.dart';

import '../widgets/top_alert.dart';
import '../services/active_conversation.dart';
// ================================================================
// GROUP CHAT SCREEN
// ----------------------------------------------------------------
// Opened by tapping a group on the Hubs -> Groups tab
// (groupstab.dart's _GroupListTile.onTap). Visually/behaviourally
// modeled on the existing 1-to-1 ChatScreen (chat_screen.dart):
// same header layout (avatar + name, tap opens the profile page),
// same dark/tan bubble theme, same "call icons + 3-dot menu" app
// bar actions layout.
//
// Differences from the 1-to-1 chat screen, per spec:
//   - Tapping the header opens GroupProfilePage (groupstab.dart)
//     instead of a single member's profile.
//   - The 3-dot menu carries the existing "Mute Message" item,
//     then (admin only) "Sleep Mode", then the "Enable/Disable
//     Voice Call" and "Enable/Disable Video Call" rows, with
//     "Delete Group" for the admin / "Exit Group" for everyone
//     else placed LAST in the sheet -- all three of Sleep/Delete/
//     Exit reuse the exact dialogs/logic groupstab.dart already
//     has for the Group Profile page's own settings gear, so
//     behaviour stays identical wherever it's triggered from.
//   - Voice/Video call: same as the 1-to-1 chat screen, calling is
//     ON by default for everyone in the group. The "Disable Voice
//     Call" / "Disable Video Call" rows in this menu are how a
//     user manually turns their own header call icon off (and
//     back on again) for this group.
//
// Note: there's no group-calling signaling in this codebase yet
// (call_service.dart/call_signaling.dart are strictly 1-to-1), so
// the call icons here are wired up and toggle-able as asked, but
// tapping them currently just says so instead of placing a real
// group call -- that's a separate, bigger feature to build next.
// ================================================================

ImageProvider? _profileImageProvider(String path) {
  final value = path.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return NetworkImage(value);
  }
  return AssetImage(value);
}

// ================================================================
// EDIT MESSAGE DIALOG
// ----------------------------------------------------------------
// Same as the 1-to-1 chat screen's edit dialog (chat_screen.dart).
// ================================================================
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
      backgroundColor: const Color(0xFF1B120A),
      title: const Text(
        'Edit Message',
        style: TextStyle(color: Colors.white),
      ),
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
          child: const Text(
            'SAVE',
            style: TextStyle(color: Color(0xFFD2B48C)),
          ),
        ),
      ],
    );
  }
}

// ================================================================
// MARK A GROUP AS READ (clears the unread dot in the Groups tab)
// ----------------------------------------------------------------
// Writes the current user's "I have seen everything up to now"
// server timestamp into a per-user map on the GROUP document:
//
//   groups/<docId> { lastReadAt: { <uid>: <Timestamp> } }
//
// The Groups tab already streams the group documents themselves
// (see groupstab.dart's _groupsStream), so keeping the read marker
// on the group doc means the unread dot costs ZERO extra Firestore
// listeners/reads -- it's derived from data the tab is already
// receiving, by comparing `lastReadAt[uid]` against the group's
// existing `lastMessageAt`.
//
// Called when the group chat is opened, whenever a new message
// lands while it's open, and again when leaving it.
// ================================================================

Future<void> markGroupRead(String groupDocId) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null || groupDocId.isEmpty) return;

  try {
    await FirebaseFirestore.instance.collection('groups').doc(groupDocId).set(
      {
        'lastReadAt': {uid: FieldValue.serverTimestamp()},
      },
      SetOptions(merge: true),
    );
  } catch (e) {
    debugPrint('Mark group read error: $e');
  }
}

class GroupChatScreen extends StatefulWidget {
  final String groupDocId;

  const GroupChatScreen({super.key, required this.groupDocId});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> with AiLauncherHide {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _sending = false;

  // ==========================================================
  // TYPING INDICATOR
  // ----------------------------------------------------------
  // Same mechanism as the 1-to-1 chat screen (chat_screen.dart):
  // ChatSettingsService.updatePresence() writes `isTyping` +
  // `typingToUid` onto MY OWN user doc while I have text in the
  // box, and clears it 1.2s after I stop (or the instant I send/
  // clear the field). The only difference for a group is that
  // there's no single "otherUid" to target, so `typingToUid` is
  // set to a group-scoped marker ("group:<groupDocId>") instead
  // of a user uid -- every other member watches for that same
  // marker on each member's doc (see _GroupTypingIndicatorBar
  // below) to know who's typing in *this* group right now.
  // ==========================================================
  Timer? _typingStopTimer;

  String get _typingMarker => 'group:${widget.groupDocId}';

  void _handleTypingChanged() {
    _typingStopTimer?.cancel();
    final text = _textController.text.trim();
    if (text.isEmpty) {
      unawaited(ChatSettingsService.instance
          .updatePresence(active: true, typingToUid: null));
      return;
    }
    unawaited(ChatSettingsService.instance
        .updatePresence(active: true, typingToUid: _typingMarker));
    _typingStopTimer = Timer(const Duration(milliseconds: 1200), () {
      unawaited(ChatSettingsService.instance
          .updatePresence(active: true, typingToUid: null));
    });
  }

  // Newest message id we've already marked as read, so the
  // message StreamBuilder below only writes a read marker when
  // something genuinely NEW arrives (not on every rebuild).
  String? _lastReadMessageId;

  /// 'group:<groupDocId>' for this screen, pushed on open and popped
  /// on close so the in-app heads-up bar
  /// (widgets/incoming_message_alert.dart) stays silent for messages
  /// landing in THIS group -- they are already visible in the thread.
  /// Every other group and every 1-to-1 chat still alerts normally
  /// while this screen is up.
  late final String _activeConversationKey =
      ActiveConversation.groupKey(widget.groupDocId);

  @override
  void initState() {
    super.initState();
    _textController.addListener(_handleTypingChanged);
    ActiveConversation.push(_activeConversationKey);
    // Opening the group counts as reading it -- clears the dot on
    // the Groups tab straight away.
    unawaited(markGroupRead(widget.groupDocId));
  }

  // Called from the message stream whenever the newest message
  // changes while this screen is open, so messages that arrive
  // while the user is already reading never light the dot up.
  void _markReadIfNewMessage(String? newestMessageId) {
    if (newestMessageId == null || newestMessageId == _lastReadMessageId) {
      return;
    }
    _lastReadMessageId = newestMessageId;
    unawaited(markGroupRead(widget.groupDocId));
  }

  // Same "+" attachment flow as the 1-to-1 chat screen
  // (chat_screen.dart): Photos / Videos / Audios / Files, uploaded
  // to the same Cloudinary account, then written as a group message.
  final ImagePicker _attachmentImagePicker = ImagePicker();
  bool _isSendingAttachment = false;
  static const String _cloudinaryCloudName = 'hmae9acm';
  static const String _chatMediaUploadPreset = 'nexus_chat_media';

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // ==========================================================
  // REPLY MESSAGE
  // Same as the 1-to-1 chat screen (chat_screen.dart): swipe a
  // bubble to select it as the message being replied to.
  // ==========================================================

  DocumentSnapshot<Map<String, dynamic>>? replyMessage;

  bool get isReplying => replyMessage != null;

  void _setReplyMessage(DocumentSnapshot<Map<String, dynamic>> message) {
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
  // NEW: swipe-in-the-middle-of-the-chat to reveal timestamps
  // Same mechanism as the 1-to-1 chat screen (chat_screen.dart).
  // ==========================================================

  bool _revealOtherTimestamps = false;
  bool _revealMyTimestamps = false;
  double _globalDragAccumulator = 0;
  double _globalDragAccumulatorY = 0;
  Timer? _revealHideTimer;

  // True whenever a per-message swipe-to-reply drag (started by
  // touching an actual bubble) is in progress. While this is true the
  // background "swipe the empty space to reveal timestamps" gesture
  // below is ignored, so touching a bubble and swiping only ever does
  // swipe-to-reply, and never also reveals timestamps at the same time.
  bool _bubbleDragActive = false;

  void _setBubbleDragActive(bool active) {
    _bubbleDragActive = active;
    if (active) {
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

  void _handleGlobalPointerMove(PointerMoveEvent event) {
    if (_bubbleDragActive) {
      _globalDragAccumulator = 0;
      _globalDragAccumulatorY = 0;
      return;
    }

    _globalDragAccumulator += event.delta.dx;
    _globalDragAccumulatorY += event.delta.dy;

    const threshold = 45.0;

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

  @override
  void dispose() {
    // Leaving the group screen -- its messages can pop a bar again.
    ActiveConversation.pop(_activeConversationKey);
    _textController.removeListener(_handleTypingChanged);
    _textController.dispose();
    _scrollController.dispose();
    _revealHideTimer?.cancel();
    _typingStopTimer?.cancel();
    // Clear my typing flag so I don't linger as "typing" for the
    // rest of the group after leaving the screen.
    unawaited(ChatSettingsService.instance.updatePresence(typingToUid: null));
    // Final read marker on the way out, so anything that landed in
    // the last moments before leaving doesn't re-light the dot.
    unawaited(markGroupRead(widget.groupDocId));
    super.dispose();
  }

  Future<void> _send() async {
    final uid = _uid;
    final text = _textController.text.trim();
    if (uid == null || text.isEmpty || _sending) return;

    setState(() => _sending = true);
    _textController.clear();

    final groupRef =
        FirebaseFirestore.instance.collection('groups').doc(widget.groupDocId);
    final selectedReply = replyMessage;

    try {
      await groupRef.collection('messages').add({
        'senderUid': uid,
        'text': text,
        'sentAt': FieldValue.serverTimestamp(),
        'replyTo': selectedReply == null
            ? null
            : {
                'messageId': selectedReply.id,
                'senderUid': (selectedReply.data()?['senderUid'] ?? '').toString(),
                'messageType': (selectedReply.data()?['messageType'] ?? 'text').toString(),
                'text': (selectedReply.data()?['text'] ?? '').toString(),
              },
      });
      await groupRef.update({
        'lastMessage': text,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageSender': uid,
      });
      if (mounted && replyMessage != null) {
        setState(() => replyMessage = null);
      }
      if (mounted) {
        // Jump to the newest message (list is reversed, so 0 is
        // the bottom) once the new one lands.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } catch (e) {
      debugPrint('Send group message error: $e');
      if (mounted) {
        showTopAlert(context, 'Failed to send message.', isError: true);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ------------------------------------------------------------
  // "+" ATTACHMENT MENU
  // ------------------------------------------------------------
  // Mirrors chat_screen.dart's _showAttachmentMenu exactly: same
  // four options, same picker calls, same Cloudinary upload, so
  // group chat attachments behave identically to 1-to-1 ones.
  // ------------------------------------------------------------
  Future<void> _showAttachmentMenu() async {
    if (_isSendingAttachment) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B120A),
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
          color: Color(0xFF2A1B0E),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: const Color(0xFFD2B48C), size: 22),
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
      debugPrint('Group photo picker error: $e');
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
      debugPrint('Group video picker error: $e');
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
      debugPrint('Group audio picker error: $e');
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
      debugPrint('Group file picker error: $e');
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
    const imageExt = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif'};
    const videoExt = {'mp4', 'mov', 'm4v', 'mkv', 'webm', 'avi', '3gp'};
    const audioExt = {'mp3', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'flac', 'amr'};

    if (type == 'photo' || imageExt.contains(ext)) return 'image/$ext'.replaceFirst('image/jpg', 'image/jpeg');
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
      debugPrint('Cloudinary group attachment upload failed: $body');
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
    final uid = _uid;
    if (uid == null || paths.isEmpty || _isSendingAttachment) return;

    setState(() => _isSendingAttachment = true);

    final groupRef =
        FirebaseFirestore.instance.collection('groups').doc(widget.groupDocId);

    try {
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

        await groupRef.collection('messages').add({
          'senderUid': uid,
          'text': '',
          'messageType': messageType,
          'fileUrl': upload['secureUrl'],
          'filePublicId': upload['publicId'],
          'cloudinaryResourceType': upload['resourceType'],
          'fileName': fileName,
          'fileSize': size,
          'mimeType': _guessMimeType(messageType, path),
          'sentAt': now,
        });

        sentAtLeastOne = true;

        final lastMessageLabel = switch (messageType) {
          'photo' => '📷 Photo',
          'video' => '🎬 Video',
          'audio' => '🎵 Audio',
          _ => '📎 File',
        };

        await groupRef.update({
          'lastMessage': lastMessageLabel,
          'lastMessageAt': now,
          'lastMessageSender': uid,
        });
      }

      if (sentAtLeastOne && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } catch (e) {
      debugPrint('Send group attachment error: $e');
      _showAttachmentError('Failed to send attachment. $e');
    } finally {
      if (mounted) setState(() => _isSendingAttachment = false);
    }
  }

  Future<void> _openAttachmentUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) _showAttachmentError('Unable to open this file.');
    } catch (e) {
      debugPrint('Open group attachment error: $e');
      _showAttachmentError('Unable to open this file.');
    }
  }

  void _groupCallsComingSoon(String label) {
    showTopAlert(context, 'Group $label calling is coming soon.');
  }

  // ==========================================================
  // EDIT MESSAGE (own message, within 2 minutes of sending)
  // Same rule as the 1-to-1 chat screen (chat_screen.dart).
  // ==========================================================

  bool _canEditMessage(Map<String, dynamic> data) {
    final sentAt = data['sentAt'];
    final uid = _uid;
    return sentAt is Timestamp &&
        uid != null &&
        (data['senderUid'] ?? '').toString() == uid &&
        DateTime.now().difference(sentAt.toDate()) <= const Duration(minutes: 2);
  }

  Future<void> _editMessage(DocumentSnapshot<Map<String, dynamic>> message) async {
    final data = message.data() ?? {};
    final sentAt = data['sentAt'];
    if (sentAt is! Timestamp ||
        DateTime.now().difference(sentAt.toDate()) > const Duration(minutes: 2)) {
      return;
    }
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => _EditMessageDialog(
        initialValue: (data['text'] ?? '').toString(),
      ),
    );
    if (edited == null || edited.isEmpty) return;
    await message.reference.update({'text': edited, 'editedAt': FieldValue.serverTimestamp()});
  }

  // ==========================================================
  // FORWARD MESSAGE
  // Same as the 1-to-1 chat screen: pick a person from 'users'
  // and re-send the same text into that 1-to-1 chat.
  // ==========================================================

  Future<void> _forwardMessage(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    final data = message.data();
    if (data == null) return;
    final text = (data['text'] ?? '').toString();
    if (text.isEmpty) return;

    final uid = _uid;
    if (uid == null) return;

    try {
      final snapshot = await FirebaseFirestore.instance.collection('users').limit(100).get();
      final connectionSnap = await FirebaseFirestore.instance.collection('connections').where('users', arrayContains: uid).where('status', isEqualTo: 'connected').get();
      final connectedUids = <String>{};
      for (final c in connectionSnap.docs) { for (final u in List<String>.from(c.data()['users'] ?? const [])) { if (u != uid) connectedUids.add(u); } }
      final candidates = snapshot.docs.where((d) => d.id != uid).toList();
      if (!mounted) return;
      final selected = <String>{};

      await showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1B120A),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
        builder: (sheetContext) => StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(context).size.height * .72,
                child: Column(children: [
                  const SizedBox(height: 12),
                  const Text('Forward message to...', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
                  const SizedBox(height: 6),
                  Expanded(
                    child: ListView.builder(
                      itemCount: candidates.length,
                      itemBuilder: (context, index) {
                        final d = candidates[index];
                        final u = d.data();
                        final connected = connectedUids.contains(d.id);
                        final name = connected && (u['privateName'] ?? '').toString().trim().isNotEmpty ? (u['privateName'] ?? '').toString() : (u['publicName'] ?? u['name'] ?? 'User').toString();
                        final image = connected && (u['privateImage'] ?? '').toString().trim().isNotEmpty ? (u['privateImage'] ?? '').toString() : (u['publicImage'] ?? u['profileImage'] ?? '').toString();
                        final checked = selected.contains(d.id);
                        return ListTile(
                          leading: CircleAvatar(backgroundColor: const Color(0xFF2A1B0E), backgroundImage: _profileImageProvider(image), child: image.isEmpty ? const Icon(Icons.person, color: Colors.white70) : null),
                          title: Text(name, style: const TextStyle(color: Colors.white)),
                          subtitle: Text(connected ? 'Private' : 'Public', style: const TextStyle(color: Colors.white54)),
                          trailing: Checkbox(value: checked, activeColor: const Color(0xFF8B4513), onChanged: (_) => setModalState(() { if (checked) { selected.remove(d.id); } else { selected.add(d.id); } })),
                          onTap: () => setModalState(() { if (checked) { selected.remove(d.id); } else { selected.add(d.id); } }),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: SizedBox(width: double.infinity, child: ElevatedButton.icon(
                      onPressed: selected.isEmpty ? null : () async {
                        Navigator.pop(sheetContext);
                        for (final targetUid in selected) {
                          await _sendForwardedMessage(targetUid: targetUid, text: text);
                        }
                      },
                      icon: const Icon(Icons.send_rounded),
                      label: Text('Forward${selected.isEmpty ? '' : ' (${selected.length})'}'),
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B4513), foregroundColor: Colors.white),
                    )),
                  ),
                ]),
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

    final targetChatRef = FirebaseFirestore.instance.collection('chats').doc(targetChatId);

    try {
      final now = FieldValue.serverTimestamp();
      final connection = await FirebaseFirestore.instance.collection('connections').doc(targetChatId).get();
      final isPrivate = (connection.data()?['status'] ?? '') == 'connected';

      await targetChatRef.collection('messages').add({
        'senderId': currentUser.uid,
        'receiverId': targetUid,
        'text': text,
        'sentAt': now,
        'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(hours: 24))),
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
  // DELETE FOR YOU
  // ==========================================================

  Future<void> _deleteForYou(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await message.reference.update({
        'hiddenFor': FieldValue.arrayUnion([uid]),
      });

      if (!mounted) return;
      showTopAlert(context, 'Message deleted for you');
    } catch (e) {
      debugPrint('Delete for you error: $e');
    }
  }

  // ==========================================================
  // DELETE FOR EVERYONE (own message only)
  // ==========================================================

  Future<void> _deleteForEveryone(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    final data = message.data();
    if (data == null) return;

    final uid = _uid;
    final senderUid = (data['senderUid'] ?? '').toString();
    if (uid == null || senderUid != uid) return;

    final groupRef = FirebaseFirestore.instance.collection('groups').doc(widget.groupDocId);

    try {
      await message.reference.delete();

      final remainingMessages = await groupRef
          .collection('messages')
          .orderBy('sentAt', descending: true)
          .limit(1)
          .get();

      if (remainingMessages.docs.isEmpty) {
        await groupRef.set({
          'lastMessage': '',
          'lastMessageAt': null,
          'lastMessageSender': '',
        }, SetOptions(merge: true));
        return;
      }

      final latestMessage = remainingMessages.docs.first;
      final latestData = latestMessage.data();
      final latestType = (latestData['messageType'] ?? 'text').toString();
      final latestLabel = switch (latestType) {
        'photo' => '📷 Photo',
        'video' => '🎬 Video',
        'audio' => '🎵 Audio',
        'file' => '📎 File',
        _ => (latestData['text'] ?? '').toString(),
      };

      await groupRef.set({
        'lastMessage': latestLabel,
        'lastMessageAt': latestData['sentAt'],
        'lastMessageSender': (latestData['senderUid'] ?? '').toString(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Delete for everyone error: $e');
    }
  }

  // ==========================================================
  // DOUBLE-TAP EMOJI REACTION
  // Same as the 1-to-1 chat screen (chat_screen.dart): double-
  // tapping a bubble opens the full emoji-keyboard picker
  // (emoji_picker_flutter) and stores the pick in that message's
  // 'reactions' map, keyed by uid.
  // ==========================================================

  Future<void> _chooseReaction(DocumentSnapshot<Map<String, dynamic>> message) async {
    final emoji = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1B120A),
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
                backgroundColor: const Color(0xFF1B120A),
                columns: 8,
                emojiSizeMax: 28,
              ),
              categoryViewConfig: const CategoryViewConfig(
                backgroundColor: Color(0xFF1B120A),
                indicatorColor: Color(0xFFD2B48C),
                iconColorSelected: Color(0xFFD2B48C),
                iconColor: Colors.white54,
              ),
              bottomActionBarConfig: const BottomActionBarConfig(
                backgroundColor: Color(0xFF1B120A),
                buttonColor: Color(0xFF1B120A),
              ),
              searchViewConfig: const SearchViewConfig(
                backgroundColor: Color(0xFF1B120A),
              ),
            ),
          ),
        ),
      ),
    );
    if (emoji == null) return;
    final uid = _uid;
    if (uid == null) return;
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final fresh = await tx.get(message.reference);
      final existing = fresh.data()?['reactions'];
      final reactions = existing is Map ? Map<String, dynamic>.from(existing) : <String, dynamic>{};
      reactions[uid] = emoji;
      tx.update(message.reference, {'reactions': reactions});
    });
  }

  // Tapping the round reaction badge on a bubble removes YOUR
  // reaction from that message (WhatsApp/Instagram-style toggle-off).
  Future<void> _removeReaction(DocumentSnapshot<Map<String, dynamic>> message) async {
    final uid = _uid;
    if (uid == null) return;
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final fresh = await tx.get(message.reference);
      final existing = fresh.data()?['reactions'];
      if (existing is! Map) return;
      final reactions = Map<String, dynamic>.from(existing);
      reactions.remove(uid);
      tx.update(message.reference, {'reactions': reactions});
    });
  }

  // ==========================================================
  // LONG PRESS MESSAGE MENU
  // ==========================================================

  void _showMessageMenu(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) {
    final data = message.data();
    if (data == null) return;

    final uid = _uid;
    final senderUid = (data['senderUid'] ?? '').toString();
    final bool isMe = uid != null && senderUid == uid;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B120A),
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
                  leading: const Icon(Icons.edit_rounded, color: Color(0xFFD2B48C)),
                  title: const Text('Edit Message', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  onTap: () { Navigator.pop(sheetContext); _editMessage(message); },
                ),

              ListTile(
                leading: const Icon(Icons.send_rounded, color: Color(0xFFD2B48C)),
                title: const Text('Forward message', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                onTap: () { Navigator.pop(sheetContext); _forwardMessage(message); },
              ),

              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: Colors.orangeAccent),
                title: const Text('Delete for you', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                onTap: () { Navigator.pop(sheetContext); _deleteForYou(message); },
              ),

              if (isMe)
                ListTile(
                  leading: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent),
                  title: const Text('Delete for everyone', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  onTap: () { Navigator.pop(sheetContext); _deleteForEveryone(message); },
                ),

              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------
  // 3-DOT MENU
  // ------------------------------------------------------------
  // Reads the group doc fresh right before opening so the sheet
  // always reflects current admin/mute/sleep/call state, same
  // approach _GroupSettingsButton already uses in groupstab.dart.
  // ------------------------------------------------------------
  Future<void> _openMenu(Map<String, dynamic> groupData) async {
    final uid = _uid;
    if (uid == null) return;

    final String adminUid = (groupData['adminUid'] ?? '').toString();
    final bool isAdmin = adminUid.isNotEmpty && adminUid == uid;
    final String groupName = (groupData['groupName'] ?? 'this group').toString();

    final mutedBy = groupData['mutedBy'] is Map
        ? Map<String, dynamic>.from(groupData['mutedBy'] as Map)
        : <String, dynamic>{};
    final bool muted = mutedBy[uid] == true;

    // Voice/Video calling is ON by default for every member; a user's
    // own entry only needs to exist once they've explicitly disabled
    // it here, so "not present" reads as enabled, same as "true" does.
    final callsEnabledBy = groupData['callsEnabledBy'] is Map
        ? Map<String, dynamic>.from(groupData['callsEnabledBy'] as Map)
        : <String, dynamic>{};
    final bool voiceCall = callsEnabledBy['voice_$uid'] != false;
    final bool videoCall = callsEnabledBy['video_$uid'] != false;

    final DateTime? currentSleepUntil = groupData['sleepUntil'] is Timestamp
        ? (groupData['sleepUntil'] as Timestamp).toDate()
        : null;
    final String currentSleepType =
        (groupData['sleepType'] ?? 'timer').toString();
    final bool isSleeping =
        currentSleepUntil != null && currentSleepUntil.isAfter(DateTime.now());

    final groupRef =
        FirebaseFirestore.instance.collection('groups').doc(widget.groupDocId);

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1B120A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                muted ? Icons.notifications_off_rounded : Icons.notifications_active_rounded,
                color: const Color(0xFFD2B48C),
              ),
              title: Text(
                muted ? 'Unmute Message' : 'Mute Message',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(sheetContext, 'muted'),
            ),
            if (isAdmin)
              ListTile(
                leading: const Icon(Icons.bedtime_rounded, color: Color(0xFFD2B48C)),
                title: Text(
                  isSleeping ? 'Sleep Mode (active)' : 'Sleep Mode',
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: isSleeping
                    ? Text(
                        sleepLabel(currentSleepUntil, currentSleepType),
                        style: const TextStyle(color: Colors.white54),
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, 'sleep'),
              ),
            // Manual, per-user call permissions -- these are ON for
            // everyone by default (see the `!= false` reads above);
            // tapping here just lets a user switch their own header
            // call icon off, or back on again, for this group.
            ListTile(
              leading: Icon(voiceCall ? Icons.call_rounded : Icons.call_end_rounded, color: const Color(0xFFD2B48C)),
              title: Text(voiceCall ? 'Disable Voice Call' : 'Enable Voice Call', style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(sheetContext, 'voice'),
            ),
            ListTile(
              leading: Icon(videoCall ? Icons.videocam_rounded : Icons.videocam_off_rounded, color: const Color(0xFFD2B48C)),
              title: Text(videoCall ? 'Disable Video Call' : 'Enable Video Call', style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(sheetContext, 'video'),
            ),
            // Deliberately last in the sheet, per spec.
            if (isAdmin)
              ListTile(
                leading: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent),
                title: const Text('Delete Group', style: TextStyle(color: Colors.redAccent)),
                onTap: () => Navigator.pop(sheetContext, 'delete'),
              )
            else
              ListTile(
                leading: const Icon(Icons.logout_rounded, color: Colors.redAccent),
                title: const Text('Exit Group', style: TextStyle(color: Colors.redAccent)),
                onTap: () => Navigator.pop(sheetContext, 'exit'),
              ),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;

    switch (action) {
      case 'muted':
        await groupRef.update({'mutedBy.$uid': !muted});
        break;
      case 'voice':
        await groupRef.update({'callsEnabledBy.voice_$uid': !voiceCall});
        break;
      case 'video':
        await groupRef.update({'callsEnabledBy.video_$uid': !videoCall});
        break;
      case 'sleep':
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => SleepModeDialog(
            groupDocId: widget.groupDocId,
            currentSleepUntil: currentSleepUntil,
            currentSleepType: currentSleepType,
            isCurrentlySleeping: isSleeping,
          ),
        );
        break;
      case 'delete':
        confirmDeleteGroup(context, widget.groupDocId, groupName);
        break;
      case 'exit':
        confirmExitGroup(context, widget.groupDocId, groupName, uid);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    if (uid == null) return const SizedBox.shrink();

    final groupStream = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupDocId)
        .snapshots();

    return Scaffold(
      backgroundColor: const Color(0xFF120B06),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B120A),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        titleSpacing: 0,
        title: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: groupStream,
          builder: (context, snapshot) {
            final data = snapshot.data?.data() ?? {};
            final name = (data['groupName'] ?? 'Group').toString();
            final image = (data['groupProfileImage'] ?? '').toString();
            final members = data['members'] is List
                ? List<String>.from(data['members'] as List)
                : <String>[];
            final membersCount =
                (data['membersCount'] is int) ? data['membersCount'] as int : members.length;

            return InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GroupProfilePage(groupDocId: widget.groupDocId),
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: const Color(0xFF2A1B0E),
                    backgroundImage: _profileImageProvider(image),
                    child: image.isEmpty
                        ? const Icon(Icons.diversity_3_rounded, color: Colors.white70)
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
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        // Shows a live "N active" + green dot (same
                        // dot used for 1-to-1 chats in chat_screen.dart)
                        // whenever at least one member of this group is
                        // active right now; otherwise falls back to the
                        // member count, same as before.
                        GroupActiveMembersStatus(
                          members: members,
                          fallback: Text(
                            '$membersCount member${membersCount == 1 ? '' : 's'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white54, fontSize: 11),
                          ),
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
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: groupStream,
            builder: (context, snapshot) {
              final data = snapshot.data?.data() ?? {};
              final callsEnabledBy = data['callsEnabledBy'] is Map
                  ? Map<String, dynamic>.from(data['callsEnabledBy'] as Map)
                  : <String, dynamic>{};
              // Same default-on read as the menu above: only an
              // explicit `false` turns a user's own call icon off.
              final bool voiceCall = callsEnabledBy['voice_$uid'] != false;
              final bool videoCall = callsEnabledBy['video_$uid'] != false;

              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (voiceCall)
                    IconButton(
                      icon: const Icon(Icons.call_rounded),
                      onPressed: () => _groupCallsComingSoon('voice'),
                    ),
                  if (videoCall)
                    IconButton(
                      icon: const Icon(Icons.videocam_rounded),
                      onPressed: () => _groupCallsComingSoon('video'),
                    ),
                ],
              );
            },
          ),
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: groupStream,
            builder: (context, snapshot) {
              final data = snapshot.data?.data();
              return IconButton(
                icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
                onPressed: data == null ? null : () => _openMenu(data),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('groups')
                    .doc(widget.groupDocId)
                    .collection('messages')
                    .orderBy('sentAt', descending: true)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(
                      child: Text('Unable to load messages', style: TextStyle(color: Colors.white54)),
                    );
                  }
                  final allDocs = snapshot.data?.docs ?? const [];
                  // Hide messages this user chose "Delete for you" on.
                  final docs = allDocs.where((d) {
                    final hiddenFor = List<String>.from(d.data()['hiddenFor'] ?? []);
                    return !hiddenFor.contains(uid);
                  }).toList();

                  // The list is ordered newest-first, so docs.first is
                  // the latest message. Marking it read here keeps the
                  // Groups tab dot clear for anything that arrives
                  // while this screen is already open.
                  final newestId = docs.isNotEmpty ? docs.first.id : null;
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _markReadIfNewMessage(newestId),
                  );
                  if (snapshot.connectionState == ConnectionState.waiting && docs.isEmpty) {
                    return const Center(child: CircularProgressIndicator(color: Color(0xFFD2B48C)));
                  }
                  if (docs.isEmpty) {
                    return const Center(
                      child: Text('No messages yet. Say hello!', style: TextStyle(color: Colors.white38)),
                    );
                  }

                  return Listener(
                    onPointerMove: _handleGlobalPointerMove,
                    onPointerUp: _handleGlobalPointerUp,
                    onPointerCancel: (_) {
                      _globalDragAccumulator = 0;
                      _globalDragAccumulatorY = 0;
                    },
                    child: ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final doc = docs[index];
                      final data = doc.data();
                      final senderUid = (data['senderUid'] ?? '').toString();
                      final isMe = senderUid == uid;

                      // Only show the sender's name above a message
                      // when it's the first of a run from them
                      // (looking "down" the reversed list, i.e. the
                      // NEXT older message in time).
                      bool showSenderName = false;
                      // Instagram-style small avatar next to the LAST
                      // (most recent / bottom-most) message of a run
                      // from another member -- opposite corner from
                      // showSenderName, which marks the top of a run.
                      bool showAvatar = false;
                      if (!isMe) {
                        final olderData =
                            index + 1 < docs.length ? docs[index + 1].data() : null;
                        final olderSender = (olderData?['senderUid'] ?? '').toString();
                        showSenderName = olderSender != senderUid;

                        final newerData = index > 0 ? docs[index - 1].data() : null;
                        final newerSender = (newerData?['senderUid'] ?? '').toString();
                        showAvatar = index == 0 || newerSender != senderUid;
                      }

                      final Map<String, dynamic>? replyData =
                          data['replyTo'] is Map
                              ? Map<String, dynamic>.from(data['replyTo'] as Map)
                              : null;

                      final bool revealed =
                          isMe ? _revealMyTimestamps : _revealOtherTimestamps;

                      return _SwipeableReply(
                        key: ValueKey('swipe_${doc.id}'),
                        isMe: isMe,
                        onReply: () => _setReplyMessage(doc),
                        onBubbleDragChanged: _setBubbleDragActive,
                        child: GestureDetector(
                          onLongPress: () { _showMessageMenu(doc); },
                          onDoubleTap: () { _chooseReaction(doc); },
                          child: _GroupMessageBubble(
                            text: (data['text'] ?? '').toString(),
                            isMe: isMe,
                            senderUid: senderUid,
                            showSenderName: showSenderName,
                            showAvatar: showAvatar,
                            sentAt: data['sentAt'] is Timestamp ? (data['sentAt'] as Timestamp).toDate() : null,
                            messageType: (data['messageType'] ?? 'text').toString(),
                            fileUrl: (data['fileUrl'] ?? '').toString(),
                            fileName: (data['fileName'] ?? '').toString(),
                            onOpenAttachment: _openAttachmentUrl,
                            reactions: data['reactions'] is Map
                                ? Map<String, dynamic>.from(data['reactions'] as Map)
                                : const {},
                            onRemoveReaction: () { _removeReaction(doc); },
                            replyData: replyData,
                            revealTimestamp: revealed,
                            currentUid: uid,
                          ),
                        ),
                      );
                    },
                    ),
                  );
                },
              ),
            ),
            // Shows "<Name> is Typing..." (private/public name
            // resolved the same way the message bubbles and member
            // list already do) whenever another member is typing.
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: groupStream,
              builder: (context, snapshot) {
                final data = snapshot.data?.data() ?? {};
                final members = data['members'] is List
                    ? List<String>.from(data['members'] as List)
                    : <String>[];
                return _GroupTypingIndicatorBar(
                  groupDocId: widget.groupDocId,
                  members: members,
                );
              },
            ),
            _buildReplyPreview(),
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // REPLY PREVIEW ABOVE INPUT
  // Same layout as the 1-to-1 chat screen (chat_screen.dart).
  // ==========================================================

  Widget _buildReplyPreview() {
    final data = replyMessage?.data();

    Widget content = const SizedBox.shrink(key: ValueKey('reply_preview_hidden'));

    if (data != null) {
      final senderUid = (data['senderUid'] ?? '').toString();
      final text = (data['messageType'] ?? 'text').toString() == 'text'
          ? (data['text'] ?? '').toString()
          : '📎 Attachment';
      final bool isMe = senderUid == _uid;

      content = Container(
        key: const ValueKey('reply_preview_visible'),
        margin: const EdgeInsets.fromLTRB(10, 5, 10, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: const BoxDecoration(
          color: Color(0xFF1B120A),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(15),
            topRight: Radius.circular(15),
          ),
          border: Border(
            left: BorderSide(color: Color(0xFFD2B48C), width: 3),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.reply_rounded, color: Color(0xFFD2B48C), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Replying to ',
                        style: TextStyle(
                          color: Color(0xFFD2B48C),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (isMe)
                        const Text(
                          'yourself',
                          style: TextStyle(
                            color: Color(0xFFD2B48C),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      else
                        Flexible(child: _SenderNameLabel(uid: senderUid)),
                    ],
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
              icon: const Icon(Icons.close_rounded, color: Colors.white60, size: 20),
            ),
          ],
        ),
      );
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

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: const BoxDecoration(
        color: Color(0xFF1B120A),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: IconButton(
              onPressed: _isSendingAttachment ? null : _showAttachmentMenu,
              icon: const Icon(Icons.add_rounded, color: Color(0xFFD2B48C)),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _textController,
              style: const TextStyle(color: Colors.white),
              textCapitalization: TextCapitalization.sentences,
              minLines: 1,
              maxLines: 5,
              decoration: InputDecoration(
                hintText: 'Message',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF241609),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: const Color(0xFF8B4513),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _sending ? null : _send,
              child: const Padding(
                padding: EdgeInsets.all(11),
                child: Icon(Icons.send_rounded, color: Colors.white, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================
// GROUP TYPING INDICATOR BAR (bottom-left, above the input field)
// ----------------------------------------------------------------
// Watches every member's user doc (same `isTyping` / `typingToUid`
// fields ChatSettingsService.updatePresence() already writes for
// 1-to-1 chats in chat_screen.dart) and shows a bar whenever one or
// more OTHER members currently have `typingToUid` set to this
// group's marker. Renders nothing (zero height) while nobody else
// is typing, same as the 1-to-1 chat's typing bar.
// ================================================================

class _GroupTypingIndicatorBar extends StatelessWidget {
  final String groupDocId;
  final List<String> members;

  const _GroupTypingIndicatorBar({
    required this.groupDocId,
    required this.members,
  });

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return const SizedBox.shrink();

    // Never watch for my own typing marker -- this bar only ever
    // reports OTHER members typing.
    final uids = members.where((m) => m != me.uid).take(30).toList();
    if (uids.isEmpty) return const SizedBox.shrink();

    final typingMarker = 'group:$groupDocId';

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .where(FieldPath.documentId, whereIn: uids)
          .snapshots(),
      builder: (context, snapshot) {
        final typingDocs = (snapshot.data?.docs ?? const [])
            .where((d) =>
                d.data()['isTyping'] == true &&
                (d.data()['typingToUid'] ?? '') == typingMarker)
            .toList();

        if (typingDocs.isEmpty) return const SizedBox.shrink();

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          // Same connected-accounts lookup the message bubbles
          // (_SenderNameLabel) and the Group Profile member list
          // already use, so a typing member's PRIVATE name shows
          // only when connected, and their PUBLIC name otherwise.
          stream: FirebaseFirestore.instance
              .collection('connections')
              .where('users', arrayContains: me.uid)
              .where('status', isEqualTo: 'connected')
              .snapshots(),
          builder: (context, connSnapshot) {
            final connectedUids = <String>{};
            for (final doc in connSnapshot.data?.docs ?? const []) {
              final users = List<String>.from(doc.data()['users'] ?? []);
              final otherUid =
                  users.firstWhere((id) => id != me.uid, orElse: () => '');
              if (otherUid.isNotEmpty) connectedUids.add(otherUid);
            }

            final names = typingDocs.map((d) {
              final data = d.data();
              final publicName = (data['publicName'] ?? '').toString().trim();
              final privateName =
                  (data['privateName'] ?? '').toString().trim();
              final isConnected = connectedUids.contains(d.id);
              final name = (isConnected && privateName.isNotEmpty)
                  ? privateName
                  : publicName;
              return name.isEmpty ? 'Someone' : name;
            }).toList();

            final String label;
            if (names.length == 1) {
              label = names.first;
            } else if (names.length == 2) {
              label = '${names[0]} and ${names[1]}';
            } else {
              label = '${names[0]} and ${names.length - 1} others';
            }

            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: _GroupTypingIndicator(label: label),
              ),
            );
          },
        );
      },
    );
  }
}

// ================================================================
// GROUP TYPING INDICATOR (name + bouncing dots)
// ----------------------------------------------------------------
// Same look/animation as _TypingIndicator in chat_screen.dart --
// "typing..." text plus three dots that bounce in sequence -- but
// with the typing member's resolved name prefixed onto the label,
// since a group has more than one possible person typing.
// ================================================================

class _GroupTypingIndicator extends StatefulWidget {
  final String label;

  const _GroupTypingIndicator({required this.label});

  @override
  State<_GroupTypingIndicator> createState() => _GroupTypingIndicatorState();
}

class _GroupTypingIndicatorState extends State<_GroupTypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
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
                color: Color(0xFFD2B48C),
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
        Flexible(
          child: Text(
            '${widget.label} is Typing',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFD2B48C),
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
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
// GROUP MESSAGE BUBBLE
// ----------------------------------------------------------------
// Own messages: right-aligned, brown/tan bubble. Others: left-
// aligned, dark bubble with the sender's name shown above the
// first bubble of a consecutive run from them (connected/private
// name if connected, public name otherwise -- same rule the rest
// of the app uses).
// ================================================================

class _GroupMessageBubble extends StatelessWidget {
  final String text;
  final bool isMe;
  final String senderUid;
  final bool showSenderName;
  final bool showAvatar;
  final DateTime? sentAt;
  final String messageType;
  final String fileUrl;
  final String fileName;
  final void Function(String url)? onOpenAttachment;
  final Map<String, dynamic> reactions;
  final VoidCallback? onRemoveReaction;
  final Map<String, dynamic>? replyData;
  final bool revealTimestamp;
  final String? currentUid;

  const _GroupMessageBubble({
    required this.text,
    required this.isMe,
    required this.senderUid,
    required this.showSenderName,
    this.showAvatar = false,
    required this.sentAt,
    this.messageType = 'text',
    this.fileUrl = '',
    this.fileName = '',
    this.onOpenAttachment,
    this.reactions = const {},
    this.onRemoveReaction,
    this.replyData,
    this.revealTimestamp = false,
    this.currentUid,
  });

  IconData _attachmentIconFor(String type) {
    switch (type) {
      case 'video':
        return Icons.videocam_rounded;
      case 'audio':
        return Icons.audiotrack_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  // Photos render as an inline thumbnail (tap to open full-size);
  // videos/audio/files render as a compact icon + filename row that
  // opens the file externally -- same attachment types the 1-to-1
  // chat screen's "+" menu supports (chat_screen.dart).
  Widget _buildAttachmentContent() {
    if (messageType == 'photo' && fileUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: GestureDetector(
          onTap: () => onOpenAttachment?.call(fileUrl),
          child: Image.network(
            fileUrl,
            fit: BoxFit.cover,
            width: 200,
            height: 200,
            errorBuilder: (_, _, _) => Container(
              width: 200,
              height: 200,
              color: const Color(0xFF2A1B0E),
              child: const Icon(Icons.broken_image_rounded, color: Colors.white38),
            ),
          ),
        ),
      );
    }

    return InkWell(
      onTap: () => onOpenAttachment?.call(fileUrl),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_attachmentIconFor(messageType), color: const Color(0xFFD2B48C), size: 22),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                fileName.isEmpty ? 'Attachment' : fileName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Same send/receive date style as the 1-to-1 chat screen
  // (chat_screen.dart's _formatRevealDate): Today -> time only,
  // Yesterday -> "Yesterday", older -> full date.
  String _timeLabel(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(dt.year, dt.month, dt.day);
    final differenceInDays = today.difference(messageDay).inDays;

    if (differenceInDays == 0) {
      final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      final minute = dt.minute.toString().padLeft(2, '0');
      final period = dt.hour >= 12 ? 'PM' : 'AM';
      return '$hour:$minute $period';
    } else if (differenceInDays == 1) {
      return 'Yesterday';
    } else {
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
    }
  }

  // Replied-message preview shown inside the bubble, same layout as
  // the 1-to-1 chat screen (chat_screen.dart).
  Widget _buildRepliedMessagePreview(Map<String, dynamic> replyData) {
    final String senderId = (replyData['senderUid'] ?? '').toString();
    final String replyType = (replyData['messageType'] ?? 'text').toString();
    final String previewText =
        replyType == 'text' ? (replyData['text'] ?? '').toString() : '📎 Attachment';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
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
                child: senderId == currentUid
                    ? const Text(
                        'You',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      )
                    : _SenderNameLabel(uid: senderId),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            previewText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Stack lets the reaction badge float in a small round circle
    // that overlaps the bottom corner of the bubble, same as the
    // 1-to-1 chat screen (chat_screen.dart).
    final bubbleStack = Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72 - (isMe ? 0 : 32),
            ),
            child: Column(
              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (showSenderName)
                  Padding(
                    padding: const EdgeInsets.only(left: 10, bottom: 2),
                    child: _SenderNameLabel(uid: senderUid),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: isMe ? const Color(0xFF8B4513) : const Color(0xFF1B120A),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isMe ? 16 : 4),
                      bottomRight: Radius.circular(isMe ? 4 : 16),
                    ),
                    border: isMe ? null : Border.all(color: const Color(0xFFD2B48C).withValues(alpha: .18)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (replyData != null)
                        _buildRepliedMessagePreview(replyData!),
                      if (messageType != 'text')
                        _buildAttachmentContent()
                      else
                        Text(text, style: const TextStyle(color: Colors.white, fontSize: 15)),
                      if (sentAt != null) ...[
                        const SizedBox(height: 3),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          alignment: Alignment.topCenter,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            child: revealTimestamp
                                ? Text(
                                    _timeLabel(sentAt!),
                                    key: const ValueKey('timestamp'),
                                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                                  )
                                : const SizedBox.shrink(key: ValueKey('none')),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Round reaction badge, WhatsApp/Instagram-style -- overlaps
          // the bottom corner of the bubble. Tapping it removes YOUR
          // reaction; to react with a different emoji, double-tap the
          // message again to reopen the full picker.
          if (reactions.isNotEmpty)
            Positioned(
              bottom: 2,
              left: isMe ? -6 : null,
              right: isMe ? null : -6,
              child: GestureDetector(
                onTap: onRemoveReaction,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B120A),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF120B06),
                      width: 2,
                    ),
                  ),
                  child: Text(
                    reactions.values.last.toString(),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ),
        ],
      );

    if (isMe) {
      return Align(alignment: Alignment.centerRight, child: bubbleStack);
    }

    // Other members' messages: small circular avatar (Instagram-
    // style) at the bottom-left of the last bubble in a consecutive
    // run from that sender; otherwise a same-width blank spacer so
    // later bubbles in the run still line up under it.
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: showAvatar ? _SenderAvatar(uid: senderUid) : null,
          ),
          const SizedBox(width: 6),
          Flexible(child: bubbleStack),
        ],
      ),
    );
  }
}

// ================================================================
// SWIPE TO REPLY
// Same widget as the 1-to-1 chat screen (chat_screen.dart): swiping
// a bubble (left for your own messages, right for others') past a
// threshold selects it as the message being replied to, with a
// smooth spring-back animation.
// ================================================================

class _SwipeableReply extends StatefulWidget {
  final bool isMe;
  final VoidCallback onReply;
  final Widget child;
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
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    )..addListener(() {
        setState(() {});
      });
  }

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
          _dragOffset += delta;
          if (_dragOffset < -90) _dragOffset = -90;
        } else if (_dragOffset < 0) {
          _dragOffset += delta;
          if (_dragOffset > 0) _dragOffset = 0;
        }
      } else {
        if (delta > 0) {
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
        ? _dragOffset <= -55
        : _dragOffset >= 55;
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
    final animation = Tween<double>(begin: start, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

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
                    color: Color(0xFF2A1B0E),
                  ),
                  child: const Icon(
                    Icons.reply_rounded,
                    color: Color(0xFFD2B48C),
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

// Small circular avatar shown next to another member's messages,
// Instagram/WhatsApp-group-style. Mirrors _SenderNameLabel's
// connected -> private image / not connected -> public image logic.
class _SenderAvatar extends StatelessWidget {
  final String uid;

  const _SenderAvatar({required this.uid});

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        if (data == null || me == null) {
          return const CircleAvatar(
            radius: 13,
            backgroundColor: Color(0xFF2A1B0E),
            child: Icon(Icons.person, color: Colors.white70, size: 14),
          );
        }

        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: FirebaseFirestore.instance
              .collection('connections')
              .doc(([me.uid, uid]..sort()).join('_'))
              .get(),
          builder: (context, connSnapshot) {
            final isConnected =
                (connSnapshot.data?.data()?['status'] ?? '') == 'connected';
            final privateImage = (data['privateImage'] ?? '').toString().trim();
            final publicImage =
                (data['publicImage'] ?? data['profileImage'] ?? '').toString().trim();
            final image = (isConnected && privateImage.isNotEmpty) ? privateImage : publicImage;

            return CircleAvatar(
              radius: 13,
              backgroundColor: const Color(0xFF2A1B0E),
              backgroundImage: _profileImageProvider(image),
              child: image.isEmpty
                  ? const Icon(Icons.person, color: Colors.white70, size: 14)
                  : null,
            );
          },
        );
      },
    );
  }
}

class _SenderNameLabel extends StatelessWidget {
  final String uid;

  const _SenderNameLabel({required this.uid});

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        if (data == null || me == null) return const SizedBox.shrink();

        final publicName = (data['publicName'] ?? '').toString().trim();
        final privateName = (data['privateName'] ?? '').toString().trim();

        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: FirebaseFirestore.instance
              .collection('connections')
              .doc(([me.uid, uid]..sort()).join('_'))
              .get(),
          builder: (context, connSnapshot) {
            final isConnected =
                (connSnapshot.data?.data()?['status'] ?? '') == 'connected';
            final name = (isConnected && privateName.isNotEmpty) ? privateName : publicName;
            return Text(
              name.isEmpty ? 'Unnamed' : name,
              style: const TextStyle(color: Color(0xFFD2B48C), fontSize: 12, fontWeight: FontWeight.w600),
            );
          },
        );
      },
    );
  }
}
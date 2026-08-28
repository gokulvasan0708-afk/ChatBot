import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class ChatScreen extends StatefulWidget {
  final String otherUserUid;
  final String otherUserName;
  final String otherUserImage;

  // ==========================================================
  // NEW: optional callback for tapping the profile header.
  // If not provided, we fall back to a named route ('/profile')
  // passing otherUserUid as the argument. Wire up either one to
  // match however your app already navigates to a profile page.
  // ==========================================================
  final void Function(String otherUserUid)? onProfileTap;

  const ChatScreen({
    super.key,
    required this.otherUserUid,
    required this.otherUserName,
    required this.otherUserImage,
    this.onProfileTap,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController messageController =
      TextEditingController();

  final ScrollController scrollController =
      ScrollController();

  // ==========================================================
  // NEW: focus node for the expanding text field
  // ==========================================================
  final FocusNode messageFocusNode = FocusNode();

  // ==========================================================
  // REPLY MESSAGE
  // ==========================================================

  DocumentSnapshot<Map<String, dynamic>>? replyMessage;

  bool get isReplying => replyMessage != null;

  void _setReplyMessage(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) {
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
  // NEW: swipe-in-the-middle-of-the-chat to reveal timestamps
  // ==========================================================

  bool _revealOtherTimestamps = false;
  bool _revealMyTimestamps = false;
  double _globalDragAccumulator = 0;
  Timer? _revealHideTimer;

  @override
  void initState() {
    super.initState();

    messageFocusNode.addListener(_handleFocusChange);
    scrollController.addListener(_handleScrollPosition);
  }

  // ==========================================================
  // NEW: figure out whether we're near the bottom of the list
  // ==========================================================

  void _handleScrollPosition() {
    if (!scrollController.hasClients) return;

    final maxExtent =
        scrollController.position.maxScrollExtent;

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

    final target =
        scrollController.position.maxScrollExtent;

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
  // CURRENT USER
  // ==========================================================

  String get currentUid {
    return FirebaseAuth.instance.currentUser!.uid;
  }

  // ==========================================================
  // CHAT ID
  // ==========================================================

  String get chatId {
    final ids = [
      currentUid,
      widget.otherUserUid,
    ];

    ids.sort();

    return ids.join('_');
  }

  // ==========================================================
  // CHAT DOCUMENT
  // ==========================================================

  DocumentReference<Map<String, dynamic>> get chatReference {
    return FirebaseFirestore.instance
        .collection('chats')
        .doc(chatId);
  }

  // ==========================================================
  // MESSAGES
  // ==========================================================

  CollectionReference<Map<String, dynamic>>
      get messagesReference {
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

        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom(animate: false);
        });
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
          final maxExtent =
              scrollController.position.maxScrollExtent;

          final current =
              scrollController.position.pixels;

          final bool atBottom =
              (maxExtent - current) < 80;

          if (atBottom) {
            WidgetsBinding.instance
                .addPostFrameCallback((_) {
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
        final readBy =
            List<String>.from(data['readBy'] ?? []);

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

    final senderId =
        (data['senderId'] ?? '').toString();

    final bool isMe =
        senderId == currentUid;

    return _SwipeableReply(
      key: ValueKey('swipe_${message.id}'),
      isMe: isMe,
      onReply: () => _setReplyMessage(message),
      child: _buildMessageBubble(message),
    );
  }

  // ==========================================================
  // REPLY PREVIEW ABOVE INPUT
  // NEW: animated in/out with AnimatedSize + AnimatedOpacity
  // ==========================================================

  Widget _buildReplyPreview() {
    final data = replyMessage?.data();

    Widget content = const SizedBox.shrink();

    if (data != null) {
      final senderId =
          (data['senderId'] ?? '').toString();

      final text =
          (data['text'] ?? '').toString();

      final bool isMe =
          senderId == currentUid;

      content = Container(
        key: const ValueKey('reply_preview_visible'),

        margin: const EdgeInsets.fromLTRB(
          10,
          5,
          10,
          0,
        ),

        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),

        decoration: BoxDecoration(
          color: const Color(0xFF0B1D32),

          borderRadius:
              const BorderRadius.only(
            topLeft: Radius.circular(15),
            topRight: Radius.circular(15),
          ),

          border: const Border(
            left: BorderSide(
              color: Colors.lightBlueAccent,
              width: 3,
            ),
          ),
        ),

        child: Row(
          children: [
            const Icon(
              Icons.reply_rounded,
              color: Colors.lightBlueAccent,
              size: 22,
            ),

            const SizedBox(width: 10),

            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,

                children: [
                  Text(
                    isMe
                        ? 'Replying to yourself'
                        : 'Replying to ${widget.otherUserName}',

                    maxLines: 1,

                    overflow:
                        TextOverflow.ellipsis,

                    style: const TextStyle(
                      color: Colors.lightBlueAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 3),

                  Text(
                    text,

                    maxLines: 1,

                    overflow:
                        TextOverflow.ellipsis,

                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
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
      content = const SizedBox.shrink(
        key: ValueKey('reply_preview_hidden'),
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

  // ==========================================================
  // SEND MESSAGE
  // ==========================================================

  Future<void> _sendMessage() async {
    final text =
        messageController.text.trim();

    if (text.isEmpty) return;

    final currentUser =
        FirebaseAuth.instance.currentUser;

    if (currentUser == null) return;

    // Keep selected reply before clearing
    final selectedReply =
        replyMessage;

    messageController.clear();

    try {
      final now =
          FieldValue.serverTimestamp();

      await messagesReference.add({
        'senderId':
            currentUser.uid,

        'receiverId':
            widget.otherUserUid,

        'text':
            text,

        'sentAt':
            now,

        // ==================================================
        // SAVE SYSTEM
        // ==================================================

        'savedBy':
            <String>[],

        // ==================================================
        // DELETE FOR YOU
        // ==================================================

        'hiddenFor':
            <String>[],

        // ==================================================
        // NEW: READ RECEIPTS
        // ==================================================

        'readBy':
            <String>[],

        // ==================================================
        // REPLY
        // ==================================================

        'replyTo':
            selectedReply == null
                ? null
                : {
                    'messageId':
                        selectedReply.id,

                    'senderId':
                        (selectedReply.data()?[
                                    'senderId'] ??
                                '')
                            .toString(),

                    'text':
                        (selectedReply.data()?[
                                    'text'] ??
                                '')
                            .toString(),
                  },
      });

// ==========================================================
// SEND PUSH NOTIFICATION
// ==========================================================

try {
  final receiverDoc = await FirebaseFirestore.instance
      .collection('users')
      .doc(widget.otherUserUid)
      .get();

  final receiverData = receiverDoc.data();

  final receiverToken =
      receiverData?['fcmToken']?.toString();

  if (receiverToken != null && receiverToken.isNotEmpty) {
    final response = await http.post(
      Uri.parse(
        'https://chatbot-worker.gokulmi56cro.workers.dev',
      ),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'fcmToken': receiverToken,
        'senderName':
            currentUser.displayName ?? 'New message',
        'message': text,
        'senderUid': currentUser.uid,
      }),
    );

    debugPrint(
      'Notification API status: ${response.statusCode}',
    );

    debugPrint(
      'Notification API response: ${response.body}',
    );
  } else {
    debugPrint(
      'Receiver FCM token not found.',
    );
  }
} catch (e) {
  debugPrint(
    'Notification send error: $e',
  );
}

      // ==================================================
      // UPDATE CHAT
      // ==================================================

      await chatReference.set({
        'participants': [
          currentUser.uid,
          widget.otherUserUid,
        ],

        'lastMessage':
            text,

        'lastMessageTime':
            now,

        'lastMessageSenderId':
            currentUser.uid,

        'otherUserUid':
            widget.otherUserUid,

        'hiddenFor':
            FieldValue.arrayRemove([
          currentUser.uid,
        ]),

        'updatedAt':
            now,
      }, SetOptions(merge: true));

      // ==================================================
      // SCROLL TO BOTTOM
      // ==================================================

      Future.delayed(
        const Duration(milliseconds: 150),
        () {
          if (!scrollController.hasClients) {
            return;
          }

          scrollController.animateTo(
            scrollController.position.maxScrollExtent,

            duration:
                const Duration(milliseconds: 250),

            curve:
                Curves.easeOut,
          );
        },
      );
    } catch (e) {
      debugPrint(
        'Send message error: $e',
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content:
              Text('Message failed to send'),
        ),
      );
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

    List<QueryDocumentSnapshot<Map<String, dynamic>>>
        candidates = [];

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .limit(50)
          .get();

      candidates = snapshot.docs
          .where((doc) => doc.id != currentUid)
          .toList();
    } catch (e) {
      debugPrint('Forward - load users error: $e');
    }

    if (!mounted) return;

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No users available to forward to'),
        ),
      );
      return;
    }

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0B1D32),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(22),
        ),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 16,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Forward message to...',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: 320,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  itemBuilder: (context, index) {
                    final userDoc = candidates[index];
                    final userData = userDoc.data();

                    final name =
                        (userData['name'] ??
                                userData['username'] ??
                                'Unknown user')
                            .toString();

                    final image =
                        (userData['profileImage'] ??
                                userData['photoUrl'] ??
                                '')
                            .toString();

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            const Color(0xFF132B45),
                        backgroundImage: image.isNotEmpty
                            ? AssetImage(image)
                            : null,
                        child: image.isEmpty
                            ? const Icon(
                                Icons.person_rounded,
                                color: Colors.white70,
                              )
                            : null,
                      ),
                      title: Text(
                        name,
                        style: const TextStyle(
                          color: Colors.white,
                        ),
                      ),
                      onTap: () async {
                        Navigator.pop(sheetContext);
                        await _sendForwardedMessage(
                          targetUid: userDoc.id,
                          text: text,
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
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

      await targetChatRef.collection('messages').add({
        'senderId': currentUser.uid,
        'receiverId': targetUid,
        'text': text,
        'sentAt': now,
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

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Message forwarded')),
      );
    } catch (e) {
      debugPrint('Forward message error: $e');

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to forward message'),
        ),
      );
    }
  }

  // ==========================================================
  // SAVE MESSAGE FOR CURRENT USER ONLY
  // ==========================================================

  Future<void> _saveMessage(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    final data = message.data();

    if (data == null) return;

    final hiddenFor =
        List<String>.from(
      data['hiddenFor'] ?? [],
    );

    if (hiddenFor.contains(currentUid)) {
      return;
    }

    try {
      await message.reference.update({
        'savedBy':
            FieldValue.arrayUnion([
          currentUid,
        ]),
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content:
              Text('Message saved'),
        ),
      );
    } catch (e) {
      debugPrint(
        'Save message error: $e',
      );
    }
  }

  // ==========================================================
  // REMOVE SAVE FOR CURRENT USER
  // ==========================================================

  Future<void> _unsaveMessage(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    try {
      await message.reference.update({
        'savedBy':
            FieldValue.arrayRemove([
          currentUid,
        ]),
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content:
              Text('Message removed from saved'),
        ),
      );
    } catch (e) {
      debugPrint(
        'Unsave message error: $e',
      );
    }
  }

  // ==========================================================
  // DELETE FOR YOU
  // ==========================================================

  Future<void> _deleteForYou(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) async {
    try {
      await message.reference.update({
        'hiddenFor':
            FieldValue.arrayUnion([
          currentUid,
        ]),
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content:
              Text('Message deleted for you'),
        ),
      );
    } catch (e) {
      debugPrint(
        'Delete for you error: $e',
      );
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

    final senderId =
        (data['senderId'] ?? '').toString();

    if (senderId != currentUid) {
      return;
    }

    try {
      await message.reference.delete();

      // ==================================================
      // FIND LATEST MESSAGE
      // ==================================================

      final remainingMessages =
          await messagesReference
              .orderBy(
                'sentAt',
                descending: true,
              )
              .limit(1)
              .get();

      // ==================================================
      // NO MESSAGES LEFT
      // ==================================================

      if (remainingMessages.docs.isEmpty) {
        await chatReference.set({
          'lastMessage':
              '',

          'lastMessageTime':
              null,

          'lastMessageSenderId':
              '',
        }, SetOptions(merge: true));

        return;
      }

      // ==================================================
      // UPDATE LAST MESSAGE
      // ==================================================

      final latestMessage =
          remainingMessages.docs.first;

      final latestData =
          latestMessage.data();

      await chatReference.set({
        'lastMessage':
            (latestData['text'] ?? '')
                .toString(),

        'lastMessageTime':
            latestData['sentAt'],

        'lastMessageSenderId':
            (latestData['senderId'] ?? '')
                .toString(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint(
        'Delete for everyone error: $e',
      );
    }
  }

  // ==========================================================
  // LONG PRESS MESSAGE MENU
  // NEW: added a "Forward message" option
  // ==========================================================

  void _showMessageMenu(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) {
    final data = message.data();

    if (data == null) return;

    final senderId =
        (data['senderId'] ?? '').toString();

    final bool isMe =
        senderId == currentUid;

    final List<String> savedBy =
        List<String>.from(
      data['savedBy'] ?? [],
    );

    final bool isSaved =
        savedBy.contains(currentUid);

    showModalBottomSheet(
      context: context,

      backgroundColor:
          const Color(0xFF0B1D32),

      shape:
          const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(
          top: Radius.circular(22),
        ),
      ),

      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize:
                MainAxisSize.min,

            children: [
              const SizedBox(height: 10),

              // ==================================================
              // SAVE / UNSAVE
              // ==================================================

              ListTile(
                leading: Icon(
                  isSaved
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_add_rounded,

                  color:
                      Colors.lightBlueAccent,
                ),

                title: Text(
                  isSaved
                      ? 'Remove from saved'
                      : 'Save this message',

                  style:
                      const TextStyle(
                    color: Colors.white,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                onTap: () {
                  Navigator.pop(
                    sheetContext,
                  );

                  if (isSaved) {
                    _unsaveMessage(
                      message,
                    );
                  } else {
                    _saveMessage(
                      message,
                    );
                  }
                },
              ),

              // ==================================================
              // NEW: FORWARD MESSAGE
              // ==================================================

              ListTile(
                leading: const Icon(
                  Icons.forward_rounded,
                  color: Colors.lightBlueAccent,
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
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                onTap: () {
                  Navigator.pop(
                    sheetContext,
                  );

                  _deleteForYou(
                    message,
                  );
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
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                  onTap: () {
                    Navigator.pop(
                      sheetContext,
                    );

                    _deleteForEveryone(
                      message,
                    );
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
    final messageDay =
        DateTime(date.year, date.month, date.day);

    final differenceInDays =
        today.difference(messageDay).inDays;

    if (differenceInDays == 0) {
      final hour =
          date.hour % 12 == 0 ? 12 : date.hour % 12;

      final minute =
          date.minute.toString().padLeft(2, '0');

      final period = date.hour >= 12 ? 'PM' : 'AM';

      return '$hour:$minute $period';
    } else if (differenceInDays == 1) {
      return 'Yesterday';
    } else {
      final months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
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
    final data =
        message.data();

    if (data == null) {
      return const SizedBox.shrink();
    }

    // ========================================================
    // HIDDEN FOR CURRENT USER
    // ========================================================

    final hiddenFor =
        List<String>.from(
      data['hiddenFor'] ?? [],
    );

    if (hiddenFor.contains(currentUid)) {
      return const SizedBox.shrink();
    }

    // ========================================================
    // MESSAGE DATA
    // ========================================================

    final String senderId =
        (data['senderId'] ?? '')
            .toString();

    final String text =
        (data['text'] ?? '')
            .toString();

    final bool isMe =
        senderId == currentUid;

    final List<String> savedBy =
        List<String>.from(
      data['savedBy'] ?? [],
    );

    final bool isSaved =
        savedBy.contains(currentUid);

    // ========================================================
    // REPLY DATA
    // ========================================================

    final Map<String, dynamic>? replyData =
        data['replyTo'] is Map
            ? Map<String, dynamic>.from(
                data['replyTo'] as Map,
              )
            : null;

    // ========================================================
    // SENT TIME
    // ========================================================

    final Timestamp? sentAt =
        data['sentAt'] is Timestamp
            ? data['sentAt'] as Timestamp
            : null;

    // ========================================================
    // NEW: pending write ("Sending...") + reveal + highlight
    // ========================================================

    final bool isSending = message.metadata.hasPendingWrites;

    final bool isHighlighted =
        _highlightedMessageIds.contains(message.id);

    final bool showRevealedTimestamp = isMe
        ? _revealMyTimestamps
        : _revealOtherTimestamps;

    final Color baseColor =
        isMe ? Colors.blue : const Color(0xFF132B45);

    final Color highlightColor = isMe
        ? const Color(0xFF5B9BFF)
        : const Color(0xFF1F4A73);

    return Align(
      alignment:
          isMe
              ? Alignment.centerRight
              : Alignment.centerLeft,

      child: GestureDetector(
        onLongPress: () {
          _showMessageMenu(
            message,
          );
        },

        child: AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOut,

          constraints:
              BoxConstraints(
            maxWidth:
                MediaQuery.of(context)
                        .size
                        .width *
                    0.75,
          ),

          margin:
              const EdgeInsets.only(
            bottom: 8,
          ),

          padding:
              const EdgeInsets.symmetric(
            horizontal: 15,
            vertical: 10,
          ),

          decoration:
              BoxDecoration(
            color:
                isHighlighted ? highlightColor : baseColor,

            borderRadius:
                BorderRadius.only(
              topLeft:
                  const Radius.circular(
                18,
              ),

              topRight:
                  const Radius.circular(
                18,
              ),

              bottomLeft:
                  Radius.circular(
                isMe ? 18 : 4,
              ),

              bottomRight:
                  Radius.circular(
                isMe ? 4 : 18,
              ),
            ),

            // NEW: subtle glow for the latest read outgoing msg
            boxShadow: isLatestOutgoingSeen
                ? [
                    BoxShadow(
                      color: Colors.lightBlueAccent
                          .withValues(alpha: 0.45),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),

          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.end,

            children: [
              // ==================================================
              // REPLIED MESSAGE
              // ==================================================

              if (replyData != null)
                _buildRepliedMessagePreview(
                  replyData,
                ),

              // ==================================================
              // CURRENT MESSAGE
              // ==================================================

              Row(
                mainAxisSize:
                    MainAxisSize.min,

                crossAxisAlignment:
                    CrossAxisAlignment.end,

                children: [
                  Flexible(
                    child: Text(
                      text,

                      style:
                          const TextStyle(
                        color:
                            Colors.white,
                        fontSize: 16,
                      ),
                    ),
                  ),

                  // ==================================================
                  // SAVED ICON
                  // ONLY FOR THE USER WHO SAVED IT
                  // ==================================================

                  if (isSaved) ...[
                    const SizedBox(
                      width: 6,
                    ),

                    const Icon(
                      Icons.bookmark_rounded,
                      color:
                          Colors.white70,
                      size: 15,
                    ),
                  ],
                ],
              ),

              // ==================================================
              // NEW: STATUS LINE
              // Sending... > Seen > revealed timestamp > nothing
              // ==================================================

              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
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
                                color: Colors.lightBlueAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : (showRevealedTimestamp && sentAt != null
                            ? Padding(
                                key: const ValueKey('timestamp'),
                                padding:
                                    const EdgeInsets.only(top: 4),
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
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================================
  // REPLIED MESSAGE INSIDE BUBBLE
  // ==========================================================

  Widget _buildRepliedMessagePreview(
    Map<String, dynamic> replyData,
  ) {
    final String senderId =
        (replyData['senderId'] ?? '')
            .toString();

    final String text =
        (replyData['text'] ?? '')
            .toString();

    final bool isMe =
        senderId == currentUid;

    return Container(
      width:
          double.infinity,

      margin:
          const EdgeInsets.only(
        bottom: 8,
      ),

      padding:
          const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 7,
      ),

      decoration:
          BoxDecoration(
        color:
            Colors.black.withValues(
          alpha: 0.18,
        ),

        borderRadius:
            BorderRadius.circular(
          10,
        ),
      ),

      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,

        children: [
          Row(
            children: [
              const Icon(
                Icons.reply_rounded,
                color:
                    Colors.white70,
                size: 15,
              ),

              const SizedBox(
                width: 5,
              ),

              Expanded(
                child: Text(
                  isMe
                      ? 'You'
                      : widget.otherUserName,

                  maxLines: 1,

                  overflow:
                      TextOverflow.ellipsis,

                  style:
                      const TextStyle(
                    color:
                        Colors.white,
                    fontSize: 11,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(
            height: 3,
          ),

          Text(
            text,

            maxLines: 2,

            overflow:
                TextOverflow.ellipsis,

            style:
                const TextStyle(
              color:
                  Colors.white60,
              fontSize: 12,
            ),
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
    _globalDragAccumulator += event.delta.dx;

    const threshold = 45.0;

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

    _revealHideTimer?.cancel();

    _revealHideTimer = Timer(
      const Duration(milliseconds: 2500),
      () {
        if (!mounted) return;

        setState(() {
          _revealOtherTimestamps = false;
          _revealMyTimestamps = false;
        });
      },
    );
  }

  // ==========================================================
  // CHAT MESSAGES
  // ==========================================================

  Widget _buildMessages() {
    return StreamBuilder<
        QuerySnapshot<Map<String, dynamic>>>(
      stream:
          messagesReference
              .orderBy(
                'sentAt',
                descending: false,
              )
              .snapshots(includeMetadataChanges: true),

      builder:
          (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Text(
              'Unable to load messages',

              style:
                  TextStyle(
                color:
                    Colors.white54,
              ),
            ),
          );
        }

        if (!snapshot.hasData) {
          return const Center(
            child:
                CircularProgressIndicator(
              color:
                  Colors.lightBlueAccent,
            ),
          );
        }

        final allMessages =
            snapshot.data!.docs;

        // ======================================================
        // FILTER HIDDEN MESSAGES
        // ======================================================

        final messages =
            allMessages.where(
          (message) {
            final data =
                message.data();

            final hiddenFor =
                List<String>.from(
              data['hiddenFor'] ?? [],
            );

            return !hiddenFor
                .contains(
              currentUid,
            );
          },
        ).toList();

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

              style:
                  TextStyle(
                color:
                    Colors.white38,
                fontSize: 16,
              ),
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
              },
              child: ListView.builder(
                controller:
                    scrollController,

                padding:
                    const EdgeInsets.fromLTRB(
                  15,
                  20,
                  15,
                  20,
                ),

                itemCount:
                    messages.length,

                itemBuilder:
                    (context, index) {
                  final message = messages[index];

                  final bool isLatestOutgoing =
                      latestOutgoingId != null &&
                          message.id == latestOutgoingId;

                  final data = message.data();

                  final senderId =
                      (data['senderId'] ?? '').toString();

                  final bool isMe = senderId == currentUid;

                  return _SwipeableReply(
                    key: ValueKey('swipe_${message.id}'),
                    isMe: isMe,
                    onReply: () => _setReplyMessage(message),
                    child: _buildMessageBubble(
                      message,
                      isLatestOutgoingSeen:
                          isLatestOutgoing && latestOutgoingSeen,
                    ),
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
                        color: const Color(0xFF132B45),
                        shape: const CircleBorder(),
                        elevation: 4,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => _scrollToBottom(),
                          child: const Padding(
                            padding: EdgeInsets.all(10),
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: Colors.lightBlueAccent,
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

    Navigator.pushNamed(
      context,
      '/profile',
      arguments: widget.otherUserUid,
    );
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      backgroundColor:
          const Color(0xFF020B18),

      // ========================================================
      // APP BAR
      // ========================================================

      appBar: AppBar(
        backgroundColor:
            const Color(0xFF0B1D32),

        elevation: 0,

        iconTheme:
            const IconThemeData(
          color: Colors.white,
        ),

        titleSpacing: 0,

        title: InkWell(
          onTap: _openUserProfile,
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,

                backgroundColor:
                    const Color(0xFF132B45),

                backgroundImage:
                    widget.otherUserImage
                            .isNotEmpty
                        ? AssetImage(
                            widget
                                .otherUserImage,
                          )
                        : null,

                child:
                    widget.otherUserImage
                            .isEmpty
                        ? const Icon(
                            Icons
                                .person_rounded,
                            color:
                                Colors.white70,
                          )
                        : null,
              ),

              const SizedBox(
                width: 10,
              ),

              Expanded(
                child: Text(
                  widget.otherUserName,

                  maxLines: 1,

                  overflow:
                      TextOverflow.ellipsis,

                  style:
                      const TextStyle(
                    color:
                        Colors.white,
                    fontSize: 18,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),

      // ========================================================
      // BODY
      // ========================================================

      body: Column(
        children: [
          Expanded(
            child:
                _buildMessages(),
          ),

          // ====================================================
          // MESSAGE INPUT
          // ====================================================

          SafeArea(
            top: false,

            child: Column(
              mainAxisSize:
                  MainAxisSize.min,

              children: [
                // ==================================================
                // REPLY PREVIEW
                // ==================================================

                _buildReplyPreview(),

                // ==================================================
                // INPUT
                // NEW: extra bottom spacing + expanding field
                // ==================================================

                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(
                    10,
                    8,
                    10,
                    16,
                  ),

                  child: Row(
                    crossAxisAlignment:
                        CrossAxisAlignment.end,

                    children: [
                      Expanded(
                        child: AnimatedSize(
                          duration:
                              const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                          alignment: Alignment.center,
                          child: TextField(
                            controller:
                                messageController,

                            focusNode: messageFocusNode,

                            minLines: 1,

                            maxLines:
                                _inputFocused ? 5 : 1,

                            style:
                                const TextStyle(
                              color:
                                  Colors.white,
                            ),

                            textInputAction:
                                TextInputAction
                                    .newline,

                            decoration:
                                InputDecoration(
                              hintText:
                                  'Type a message...',

                              hintStyle:
                                  const TextStyle(
                                color:
                                    Colors.white38,
                              ),

                              filled: true,

                              fillColor:
                                  const Color(
                                0xFF0B1D32,
                              ),

                              contentPadding:
                                  EdgeInsets
                                      .symmetric(
                                horizontal:
                                    16,
                                vertical:
                                    _inputFocused ? 14 : 12,
                              ),

                              enabledBorder:
                                  OutlineInputBorder(
                                borderRadius:
                                    BorderRadius
                                        .circular(
                                  25,
                                ),

                                borderSide:
                                    BorderSide(
                                  color:
                                      Colors
                                          .lightBlueAccent
                                          .withValues(
                                    alpha:
                                        0.35,
                                  ),
                                ),
                              ),

                              focusedBorder:
                                  OutlineInputBorder(
                                borderRadius:
                                    BorderRadius
                                        .circular(
                                  25,
                                ),

                                borderSide:
                                    const BorderSide(
                                  color:
                                      Colors
                                          .lightBlueAccent,
                                ),
                              ),
                            ),

                            onSubmitted:
                                (_) {
                              _sendMessage();
                            },
                          ),
                        ),
                      ),

                      const SizedBox(
                        width: 8,
                      ),

                      Container(
                        width: 50,
                        height: 50,

                        decoration:
                            const BoxDecoration(
                          shape:
                              BoxShape.circle,

                          color:
                              Colors.blue,
                        ),

                        child:
                            IconButton(
                          onPressed:
                              _sendMessage,

                          icon:
                              const Icon(
                            Icons
                                .send_rounded,

                            color:
                                Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // DISPOSE
  // ==========================================================

  @override
  void dispose() {
    messageController.dispose();

    scrollController.removeListener(_handleScrollPosition);
    scrollController.dispose();

    messageFocusNode.removeListener(_handleFocusChange);
    messageFocusNode.dispose();

    _revealHideTimer?.cancel();

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

  const _SwipeableReply({
    super.key,
    required this.isMe,
    required this.onReply,
    required this.child,
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

    if (shouldReply) {
      widget.onReply();
    }

    _animateBack();
  }

  void _onDragCancel() {
    _animateBack();
  }

  void _animateBack() {
    final start = _dragOffset;

    final animation = Tween<double>(
      begin: start,
      end: 0,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutCubic,
      ),
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
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _onDragCancel,
      child: Stack(
        alignment:
            isMe ? Alignment.centerRight : Alignment.centerLeft,
        children: [
          Positioned(
            left: isMe ? null : 5,
            right: isMe ? 5 : null,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: (_dragOffset.abs() / 55).clamp(0.0, 1.0),
              child: AnimatedScale(
                duration: const Duration(milliseconds: 120),
                scale: 0.7 +
                    (0.3 * (_dragOffset.abs() / 55).clamp(0.0, 1.0)),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF132B45),
                  ),
                  child: const Icon(
                    Icons.reply_rounded,
                    color: Colors.lightBlueAccent,
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

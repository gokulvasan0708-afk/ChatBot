import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class ChatScreen extends StatefulWidget {
  final String otherUserUid;
  final String otherUserName;
  final String otherUserImage;

  const ChatScreen({
    super.key,
    required this.otherUserUid,
    required this.otherUserName,
    required this.otherUserImage,
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
  // SWIPE TO REPLY
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

    double swipeOffset = 0;

    return StatefulBuilder(
      builder: (context, setSwipeState) {
        return GestureDetector(
          behavior: HitTestBehavior.translucent,

          // ====================================================
          // SWIPE START
          // ====================================================

          onHorizontalDragStart: (_) {
            setSwipeState(() {
              swipeOffset = 0;
            });
          },

          // ====================================================
          // SWIPE MOVING
          // ====================================================

          onHorizontalDragUpdate: (details) {
            final delta =
                details.primaryDelta ?? 0;

            // --------------------------------------------------
            // MY MESSAGE
            // RIGHT -> LEFT
            // --------------------------------------------------

            if (isMe) {
              if (delta < 0) {
                swipeOffset += delta;

                if (swipeOffset < -90) {
                  swipeOffset = -90;
                }
              }
            }

            // --------------------------------------------------
            // OTHER USER MESSAGE
            // LEFT -> RIGHT
            // --------------------------------------------------

            else {
              if (delta > 0) {
                swipeOffset += delta;

                if (swipeOffset > 90) {
                  swipeOffset = 90;
                }
              }
            }

            setSwipeState(() {});
          },

          // ====================================================
          // SWIPE RELEASE
          // ====================================================

          onHorizontalDragEnd: (_) {
            final bool shouldReply =
                isMe
                    ? swipeOffset <= -55
                    : swipeOffset >= 55;

            if (shouldReply) {
              _setReplyMessage(message);
            }

            // Snap back
            setSwipeState(() {
              swipeOffset = 0;
            });
          },

          // ====================================================
          // SWIPE CANCEL
          // ====================================================

          onHorizontalDragCancel: () {
            setSwipeState(() {
              swipeOffset = 0;
            });
          },

          // ====================================================
          // MESSAGE + REPLY ICON
          // ====================================================

          child: Stack(
            alignment: isMe
                ? Alignment.centerRight
                : Alignment.centerLeft,

            children: [
              // ==================================================
              // REPLY ICON
              // ==================================================

              Positioned(
                left: isMe ? null : 5,
                right: isMe ? 5 : null,

                child: Opacity(
                  opacity: (swipeOffset.abs() / 55)
                      .clamp(0.0, 1.0),

                  child: Container(
                    width: 36,
                    height: 36,

                    decoration:
                        const BoxDecoration(
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

              // ==================================================
              // MOVING MESSAGE
              // ==================================================

              Transform.translate(
                offset: Offset(
                  swipeOffset,
                  0,
                ),
                child:
                    _buildMessageBubble(message),
              ),
            ],
          ),
        );
      },
    );
  }

  // ==========================================================
  // REPLY PREVIEW ABOVE INPUT
  // ==========================================================

  Widget _buildReplyPreview() {
    if (replyMessage == null) {
      return const SizedBox.shrink();
    }

    final data = replyMessage!.data();

    if (data == null) {
      return const SizedBox.shrink();
    }

    final senderId =
        (data['senderId'] ?? '').toString();

    final text =
        (data['text'] ?? '').toString();

    final bool isMe =
        senderId == currentUid;

    return Container(
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
  final currentUser =
      FirebaseAuth.instance.currentUser;

  if (currentUser != null) {
    final response = await http.post(
      Uri.parse(
        'http://10.87.83.40:3000/api/send-notification',
      ),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'receiverUid': widget.otherUserUid,
        'senderUid': currentUser.uid,
        'senderName':
            currentUser.displayName ?? 'New message',
        'message': text,
      }),
    );

    debugPrint(
      'Notification API status: ${response.statusCode}',
    );

    debugPrint(
      'Notification API response: ${response.body}',
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
  // MESSAGE TIME
  // ==========================================================

  String _formatTime(
    Timestamp? timestamp,
  ) {
    if (timestamp == null) {
      return '';
    }

    final date =
        timestamp.toDate();

    final hour =
        date.hour % 12 == 0
            ? 12
            : date.hour % 12;

    final minute =
        date.minute
            .toString()
            .padLeft(2, '0');

    final period =
        date.hour >= 12
            ? 'PM'
            : 'AM';

    return '$hour:$minute $period';
  }

  // ==========================================================
  // MESSAGE BUBBLE
  // ==========================================================

  Widget _buildMessageBubble(
    DocumentSnapshot<Map<String, dynamic>> message,
  ) {
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

        child: Container(
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
                isMe
                    ? Colors.blue
                    : const Color(
                        0xFF132B45,
                      ),

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
              // TIME
              // ==================================================

              if (sentAt != null) ...[
                const SizedBox(
                  height: 4,
                ),

                Text(
                  _formatTime(
                    sentAt,
                  ),

                  style:
                      const TextStyle(
                    color:
                        Colors.white60,
                    fontSize: 10,
                  ),
                ),
              ],
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
              .snapshots(),

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

        // ======================================================
        // MESSAGE LIST
        // ======================================================

        return ListView.builder(
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
            return _buildSwipeableMessage(
              messages[index],
            );
          },
        );
      },
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

        title: Row(
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

                if (replyMessage != null)
                  _buildReplyPreview(),

                // ==================================================
                // INPUT
                // ==================================================

                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(
                    10,
                    8,
                    10,
                    10,
                  ),

                  child: Row(
                    crossAxisAlignment:
                        CrossAxisAlignment.end,

                    children: [
                      Expanded(
                        child: TextField(
                          controller:
                              messageController,

                          minLines: 1,

                          maxLines: 5,

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
                                const EdgeInsets
                                    .symmetric(
                              horizontal:
                                  16,
                              vertical:
                                  12,
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

    scrollController.dispose();

    super.dispose();
  }
}
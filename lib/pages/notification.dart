import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/notification_service.dart';
import 'cosmic_background.dart';

import '../widgets/top_alert.dart';
// ==========================================================
// NOTIFICATION PAGE
// ==========================================================

class NotificationPage extends StatelessWidget {
  const NotificationPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user =
        FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Scaffold(
        backgroundColor:
            Color(0xFF0F0F14),
        body: Center(
          child: Text(
            'Please login again.',
            style: TextStyle(
              color: Colors.white,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,

      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,

        title: const Text(
          'Notifications',
          style: TextStyle(
            color: Colors.white,
            fontSize: 23,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),

      body: CosmicBackground(
        fadeIn: false,
        child: StreamBuilder<
          QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('connections')
            .where('receiverUid', isEqualTo: user.uid)
            .where('status', isEqualTo: 'pending')
            .snapshots(),

        builder: (context, snapshot) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return const Center(
              child:
                  CircularProgressIndicator(
                color:
                    Color(0xFFA78BFA),
              ),
            );
          }

          if (snapshot.hasError) {
            debugPrint(
              'Notification stream error: '
              '${snapshot.error}',
            );

            return const Center(
              child: Text(
                'Failed to load notifications.',
                style: TextStyle(
                  color: Colors.white70,
                ),
              ),
            );
          }

          final requests = snapshot.data?.docs ?? [];

          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            // ==================================================
            // GROUP REQUESTS
            // Same live/persistent pattern as the connection
            // requests above, written by groupstab.dart's
            // _CreateGroupDialogState._create() to the
            // 'groupRequests' collection whenever "Add Member" is
            // used -- see _GroupRequestCard below.
            // ==================================================
            stream: FirebaseFirestore.instance
                .collection('groupRequests')
                .where('receiverUid', isEqualTo: user.uid)
                .where('status', isEqualTo: 'pending')
                .snapshots(),
            builder: (context, groupSnapshot) {
              final groupRequests = groupSnapshot.data?.docs ?? [];

              return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('notifications')
                    .where('receiverUid', isEqualTo: user.uid)
                    .snapshots(),
                builder: (context, storedSnapshot) {
                  final storedDocs = storedSnapshot.data?.docs ?? [];
                  final now = DateTime.now();

                  // 7-day retention: anything past expiresAt is removed
                  // from Firestore (and hidden right away).
                  _purgeExpired(storedDocs, now);

                  // Request notifications that are still pending are shown
                  // by their live (actionable) card, so skip the saved copy
                  // to avoid duplicates. Once the request is answered the
                  // live card disappears and the saved copy stays for 7 days.
                  final liveIds = <String>{
                    ...requests.map((d) => d.id),
                    ...groupRequests.map((d) => d.id),
                  };
                  final seenRequestIds = <String>{};
                  final stored = storedDocs.where((d) {
                    final data = d.data();
                    final e = data['expiresAt'];
                    if (e is Timestamp && !e.toDate().isAfter(now)) return false;
                    final rid = (data['requestId'] ?? '').toString();
                    if (rid.isNotEmpty && liveIds.contains(rid)) return false;
                    return true;
                  }).toList()
                    ..sort((a, b) {
                      final ta = a.data()['createdAt'];
                      final tb = b.data()['createdAt'];
                      final da = ta is Timestamp ? ta.toDate() : now;
                      final db = tb is Timestamp ? tb.toDate() : now;
                      return db.compareTo(da);
                    });
                  stored.removeWhere((d) {
                    final rid = (d.data()['requestId'] ?? '').toString();
                    if (rid.isEmpty) return false;
                    return !seenRequestIds.add(rid);
                  });
                  if (requests.isEmpty && groupRequests.isEmpty && stored.isEmpty) {
                    return const Center(child: Text('No notifications', style: TextStyle(color: Colors.white54, fontSize: 16)));
                  }
                  final total = requests.length + groupRequests.length + stored.length;
                  return ListView.separated(
                    padding: const EdgeInsets.all(20),
                    itemCount: total,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      if (index < requests.length) {
                        final doc = requests[index];
                        final data = doc.data();
                        return _ConnectionRequestCard(
                          requestId: doc.id,
                          senderUid: (data['senderUid'] ?? '').toString().trim(),
                        );
                      }
                      if (index < requests.length + groupRequests.length) {
                        final doc = groupRequests[index - requests.length];
                        return _GroupRequestCard(
                          requestId: doc.id,
                          data: doc.data(),
                        );
                      }
                      final doc = stored[index - requests.length - groupRequests.length];
                      return _StoredNotificationCard(data: doc.data());
                    },
                  );
                },
              );
            },
          );

        },
        ),
      ),
    );
  }
}

// ==========================================================
// 7-DAY CLEANUP
// Deletes this user's saved notifications once expiresAt has passed.
// Uses the already-loaded snapshot (no extra query / index needed).
// ==========================================================
void _purgeExpired(
  List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  DateTime now,
) {
  for (final d in docs) {
    final e = d.data()['expiresAt'];
    if (e is Timestamp && !e.toDate().isAfter(now)) {
      d.reference.delete().catchError((Object err) {
        debugPrint('Expired notification delete failed: $err');
      });
    }
  }
}

// ==========================================================
// STORED RESULT NOTIFICATION
// ==========================================================
class _StoredNotificationCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _StoredNotificationCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final type = (data['type'] ?? '').toString();
    final senderName = (data['senderName'] ?? 'User').toString();
    final message = (data['message'] ?? '').toString();
    final title = type == 'connection_request'
        ? 'Connection Request'
        : type == 'group_request'
            ? 'Group Request'
            : type == 'connection_accepted'
        ? 'Connection Accepted'
        : type == 'connection_declined'
            ? 'Connection Declined'
            : type == 'group_request_accepted'
                ? 'Group Request Accepted'
                : type == 'group_request_declined'
                    ? 'Group Request Declined'
                    : 'Notification';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFA78BFA).withValues(alpha: .35)),
      ),
      child: Row(children: [
        const Icon(Icons.notifications_active_rounded, color: Color(0xFFA78BFA)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(senderName, style: const TextStyle(color: Color(0xFFA78BFA), fontWeight: FontWeight.w600)),
          if (message.isNotEmpty) Text(message, style: const TextStyle(color: Colors.white70)),
        ])),
      ]),
    );
  }
}

// ==========================================================
// CONNECTION REQUEST CARD
// ==========================================================

class _ConnectionRequestCard
    extends StatefulWidget {
  final String requestId;

  final String senderUid;

  const _ConnectionRequestCard({
    required this.requestId,
    required this.senderUid,
  });

  @override
  State<_ConnectionRequestCard>
      createState() =>
          _ConnectionRequestCardState();
}

// ==========================================================
// CARD STATE
// ==========================================================

class _ConnectionRequestCardState
    extends State<_ConnectionRequestCard> {
  bool _processing = false;

  // ========================================================
  // GET USER DATA
  // ========================================================

  Future<Map<String, dynamic>>
      _getUserData(
    String uid,
  ) async {
    final cleanUid =
        uid.trim();

    if (cleanUid.isEmpty) {
      return {};
    }

    try {
      final doc =
          await FirebaseFirestore
              .instance
              .collection('users')
              .doc(cleanUid)
              .get();

      if (!doc.exists) {
        debugPrint(
          'User document not found: '
          '$cleanUid',
        );

        return {};
      }

      return doc.data() ?? {};
    } catch (e) {
      debugPrint(
        'Get user data error: $e',
      );

      return {};
    }
  }

  // ========================================================
  // SEND RESPONSE NOTIFICATION
  // ========================================================

  Future<bool>
      _sendResponseNotification({
    required String targetUid,
    required String senderUid,
    required String senderName,
    required String message,
    required String type,
  }) async {
    try {
      final cleanTargetUid =
          targetUid.trim();

      final cleanSenderUid =
          senderUid.trim();

      if (cleanTargetUid.isEmpty) {
        debugPrint(
          'Target UID is empty.',
        );

        return false;
      }

      if (cleanSenderUid.isEmpty) {
        debugPrint(
          'Sender UID is empty.',
        );

        return false;
      }

      // ----------------------------------------------------
      // USE NOTIFICATION SERVICE
      // ----------------------------------------------------

      final result =
          await NotificationService.instance
              .sendToUser(
        receiverUid:
            cleanTargetUid,

        senderName:
            senderName,

        message:
            message,

        type:
            type,

        senderUid:
            cleanSenderUid,
      );

      debugPrint(
        'Response notification result: '
        '$result',
      );

      return result;
    } catch (e) {
      debugPrint(
        'Response notification error: $e',
      );

      return false;
    }
  }

  // ========================================================
  // ACCEPT REQUEST
  // ========================================================

  Future<void>
      _acceptRequest(
    BuildContext context,
  ) async {
    if (_processing) {
      return;
    }

    setState(() {
      _processing = true;
    });

    try {
      // ----------------------------------------------------
      // CURRENT USER
      // ----------------------------------------------------

      final currentUser =
          FirebaseAuth.instance
              .currentUser;

      if (currentUser == null) {
        debugPrint(
          'Current user is null.',
        );

        return;
      }

      final currentUid =
          currentUser.uid.trim();

      if (currentUid.isEmpty) {
        debugPrint(
          'Current UID is empty.',
        );

        return;
      }

      // ----------------------------------------------------
      // CURRENT USER DATA
      // ----------------------------------------------------

      final currentUserData =
          await _getUserData(
        currentUid,
      );

      final currentUserName =
          (currentUserData[
                    'publicName'] ??
                '')
              .toString()
              .trim();

      final displayName =
          currentUserName.isEmpty
              ? 'User'
              : currentUserName;

      // ----------------------------------------------------
      // GET REQUEST
      // ----------------------------------------------------

      final requestDoc =
          await FirebaseFirestore
              .instance
              .collection('connections')
              .doc(widget.requestId)
              .get();

      if (!requestDoc.exists) {
        debugPrint(
          'Connection request not found.',
        );

        return;
      }

      final requestData =
          requestDoc.data() ?? {};

      // ----------------------------------------------------
      // ORIGINAL SENDER
      // ----------------------------------------------------

      final originalSenderUid =
          (requestData[
                    'senderUid'] ??
                '')
              .toString()
              .trim();

      if (originalSenderUid.isEmpty) {
        debugPrint(
          'Original sender UID is empty.',
        );

        return;
      }

      // ----------------------------------------------------
      // SAFETY CHECK
      // ----------------------------------------------------

      final receiverUid =
          (requestData[
                    'receiverUid'] ??
                '')
              .toString()
              .trim();

      if (receiverUid.isNotEmpty &&
          receiverUid !=
              currentUid) {
        debugPrint(
          'Request does not belong '
          'to current user.',
        );

        return;
      }

      // ----------------------------------------------------
      // SEND NOTIFICATION TO ORIGINAL SENDER
      // (Done BEFORE mutating the connection document so the
      // lookup for the original sender's data/token happens
      // against the same, still-pending record that the
      // original "connection request" notification used.)
      // ----------------------------------------------------

      final acceptedPrivateName = (currentUserData['privateName'] ?? '').toString().trim();
      await FirebaseFirestore.instance.collection('notifications').add({
        'receiverUid': originalSenderUid,
        'senderUid': currentUid,
        'senderName': acceptedPrivateName.isNotEmpty ? acceptedPrivateName : displayName,
        'message': '${acceptedPrivateName.isNotEmpty ? acceptedPrivateName : displayName} accepted your connection request',
        'type': 'connection_accepted',
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(days: 7))),
      });

      final notificationSent =
          await _sendResponseNotification(
        targetUid:
            originalSenderUid,

        senderUid:
            currentUid,

        senderName:
            displayName,

        message:
            '$displayName accepted your connection request',

        type:
            'connection_accepted',
      );

      // ----------------------------------------------------
      // UPDATE CONNECTION
      // ----------------------------------------------------

      await FirebaseFirestore
          .instance
          .collection('connections')
          .doc(widget.requestId)
          .update({
        'status': 'connected',

        'acceptedAt':
            FieldValue.serverTimestamp(),
      });

      debugPrint(
        'Connection accepted.',
      );

      // ----------------------------------------------------
      // RESULT
      // ----------------------------------------------------

      if (!context.mounted) {
        return;
      }

      showTopAlert(context, notificationSent
                ? 'Connection accepted.'
                : 'Connection accepted, but notification was not sent.');
    } catch (e) {
      debugPrint(
        'Accept request error: $e',
      );

      if (!context.mounted) {
        return;
      }

      showTopAlert(context, 'Failed to accept request.', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
        });
      }
    }
  }

  // ========================================================
  // DECLINE REQUEST
  // ========================================================

  Future<void>
      _rejectRequest(
    BuildContext context,
  ) async {
    if (_processing) {
      return;
    }

    setState(() {
      _processing = true;
    });

    try {
      // ----------------------------------------------------
      // CURRENT USER
      // ----------------------------------------------------

      final currentUser =
          FirebaseAuth.instance
              .currentUser;

      if (currentUser == null) {
        debugPrint(
          'Current user is null.',
        );

        return;
      }

      final currentUid =
          currentUser.uid.trim();

      if (currentUid.isEmpty) {
        debugPrint(
          'Current UID is empty.',
        );

        return;
      }

      // ----------------------------------------------------
      // CURRENT USER DATA
      // ----------------------------------------------------

      final currentUserData =
          await _getUserData(
        currentUid,
      );

      final currentUserName =
          (currentUserData[
                    'publicName'] ??
                '')
              .toString()
              .trim();

      final displayName =
          currentUserName.isEmpty
              ? 'User'
              : currentUserName;

      // ----------------------------------------------------
      // GET REQUEST BEFORE DELETE
      // ----------------------------------------------------

      final requestDoc =
          await FirebaseFirestore
              .instance
              .collection('connections')
              .doc(widget.requestId)
              .get();

      if (!requestDoc.exists) {
        debugPrint(
          'Connection request not found.',
        );

        return;
      }

      final requestData =
          requestDoc.data() ?? {};

      // ----------------------------------------------------
      // ORIGINAL SENDER
      // ----------------------------------------------------

      final originalSenderUid =
          (requestData[
                    'senderUid'] ??
                '')
              .toString()
              .trim();

      if (originalSenderUid.isEmpty) {
        debugPrint(
          'Original sender UID is empty.',
        );

        return;
      }

      // ----------------------------------------------------
      // SAFETY CHECK
      // ----------------------------------------------------

      final receiverUid =
          (requestData[
                    'receiverUid'] ??
                '')
              .toString()
              .trim();

      if (receiverUid.isNotEmpty &&
          receiverUid !=
              currentUid) {
        debugPrint(
          'Request does not belong '
          'to current user.',
        );

        return;
      }

      // ----------------------------------------------------
      // SEND DECLINE NOTIFICATION
      // (Done BEFORE deleting the connection document. Once
      // the document is deleted there is nothing left to
      // reference the original request state, so the
      // notification must be sent first, then the document
      // can be safely removed.)
      // ----------------------------------------------------

      await FirebaseFirestore.instance.collection('notifications').add({
        'receiverUid': originalSenderUid,
        'senderUid': currentUid,
        'senderName': displayName,
        'message': '$displayName declined your connection request',
        'type': 'connection_declined',
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(days: 7))),
      });

      final notificationSent =
          await _sendResponseNotification(
        targetUid:
            originalSenderUid,

        senderUid:
            currentUid,

        senderName:
            displayName,

        message:
            '$displayName declined your connection request',

        type:
            'connection_declined',
      );

      // ----------------------------------------------------
      // DELETE REQUEST
      // ----------------------------------------------------

      await FirebaseFirestore
          .instance
          .collection('connections')
          .doc(widget.requestId)
          .delete();

      debugPrint(
        'Connection request deleted.',
      );

      // ----------------------------------------------------
      // RESULT
      // ----------------------------------------------------

      if (!context.mounted) {
        return;
      }

      showTopAlert(context, notificationSent
                ? 'Connection request declined.'
                : 'Request declined, but notification was not sent.');
    } catch (e) {
      debugPrint(
        'Decline request error: $e',
      );

      if (!context.mounted) {
        return;
      }

      showTopAlert(context, 'Failed to decline request.', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
        });
      }
    }
  }

  // ========================================================
  // UI
  // ========================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    return FutureBuilder<
        Map<String, dynamic>>(
      future:
          _getUserData(
        widget.senderUid,
      ),

      builder: (
        context,
        snapshot,
      ) {
        // --------------------------------------------------
        // LOADING
        // --------------------------------------------------

        if (snapshot.connectionState ==
            ConnectionState.waiting) {
          return Container(
            height: 100,

            decoration:
                BoxDecoration(
              color:
                  const Color(
                0xFF18181F,
              ),

              borderRadius:
                  BorderRadius.circular(
                18,
              ),
            ),

            child: const Center(
              child:
                  CircularProgressIndicator(
                color:
                    Color(0xFFA78BFA),
              ),
            ),
          );
        }

        // --------------------------------------------------
        // USER DATA
        // --------------------------------------------------

        final data =
            snapshot.data ?? {};

        final String name =
            (data['publicName'] ??
                    'User')
                .toString()
                .trim();

        final String image =
            (data['publicImage'] ??
                    '')
                .toString()
                .trim();

        // --------------------------------------------------
        // CARD
        // --------------------------------------------------

        return Container(
          padding:
              const EdgeInsets.all(
            14,
          ),

          decoration:
              BoxDecoration(
            color:
                const Color(
              0xFF18181F,
            ),

            borderRadius:
                BorderRadius.circular(
              18,
            ),

            border:
                Border.all(
              color:
                  const Color(0xFFA78BFA)
                      .withValues(
                alpha: 0.30,
              ),
            ),
          ),

          child: Row(
            crossAxisAlignment:
                CrossAxisAlignment.start,

            children: [
              // ============================================
              // PROFILE IMAGE
              // ============================================

              Container(
                width: 55,
                height: 55,

                decoration:
                    BoxDecoration(
                  shape:
                      BoxShape.circle,

                  border:
                      Border.all(
                    color:
                        const Color(0xFFA78BFA),
                  ),
                ),

                child: ClipOval(
                  child:
                      image.isNotEmpty
                          ? Image.asset(
                              image,
                              fit:
                                  BoxFit.cover,

                              errorBuilder:
                                  (
                                context,
                                error,
                                stackTrace,
                              ) {
                                return const Icon(
                                  Icons
                                      .person_rounded,
                                  color:
                                      Colors.white70,
                                  size: 30,
                                );
                              },
                            )
                          : const Icon(
                              Icons
                                  .person_rounded,
                              color:
                                  Colors.white70,
                              size: 30,
                            ),
                ),
              ),

              const SizedBox(
                width: 13,
              ),

              // ============================================
              // CONTENT
              // ============================================

              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,

                  children: [
                    Text(
                      name.isEmpty
                          ? 'User'
                          : name,

                      style:
                          const TextStyle(
                        color:
                            Colors.white,

                        fontSize: 16,

                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),

                    const SizedBox(
                      height: 5,
                    ),

                    const Text(
                      'sent you a connection request.',

                      style:
                          TextStyle(
                        color:
                            Colors.white54,

                        fontSize: 13,
                      ),
                    ),

                    const SizedBox(
                      height: 10,
                    ),

                    Row(
                      children: [
                        // ==================================
                        // ACCEPT
                        // ==================================

                        Expanded(
                          child:
                              ElevatedButton(
                            onPressed:
                                _processing
                                    ? null
                                    : () {
                                        _acceptRequest(
                                          context,
                                        );
                                      },

                            style:
                                ElevatedButton
                                    .styleFrom(
                              backgroundColor:
                                  const Color(0xFF7C3AED),

                              foregroundColor:
                                  Colors.white,

                              disabledBackgroundColor:
                                  const Color(0xFF7C3AED)
                                      .withValues(
                                alpha: 0.4,
                              ),

                              elevation: 0,

                              padding:
                                  const EdgeInsets
                                      .symmetric(
                                vertical: 10,
                              ),
                            ),

                            child:
                                _processing
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child:
                                            CircularProgressIndicator(
                                          strokeWidth:
                                              2,
                                          color:
                                              Colors.white,
                                        ),
                                      )
                                    : const Text(
                                        'Accept',
                                      ),
                          ),
                        ),

                        const SizedBox(
                          width: 8,
                        ),

                        // ==================================
                        // DECLINE
                        // ==================================

                        Expanded(
                          child:
                              OutlinedButton(
                            onPressed:
                                _processing
                                    ? null
                                    : () {
                                        _rejectRequest(
                                          context,
                                        );
                                      },

                            style:
                                OutlinedButton
                                    .styleFrom(
                              foregroundColor:
                                  Colors.white70,

                              disabledForegroundColor:
                                  Colors.white24,

                              side:
                                  const BorderSide(
                                color:
                                    Colors.white24,
                              ),

                              padding:
                                  const EdgeInsets
                                      .symmetric(
                                vertical: 10,
                              ),
                            ),

                            child:
                                const Text(
                              'Decline',
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
    );
  }
}

// ==========================================================
// GROUP PROFILE IMAGE PROVIDER
// ----------------------------------------------------------
// Group profile images are Cloudinary https:// URLs (see
// groupstab.dart's _pickGroupImage), not bundled assets, so this
// needs the same http-vs-asset check groupstab.dart's own
// _profileImageProvider uses.
// ==========================================================

ImageProvider? _groupImageProvider(String path) {
  final value = path.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return NetworkImage(value);
  }
  return AssetImage(value);
}

// ==========================================================
// FORMAT REQUEST DATE/TIME
// ==========================================================

String _formatRequestTimestamp(dynamic value) {
  if (value is! Timestamp) {
    return '';
  }

  final date = value.toDate();

  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  final hour24 = date.hour;
  final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  final ampm = hour24 >= 12 ? 'PM' : 'AM';
  final minute = date.minute.toString().padLeft(2, '0');

  return '${date.day} ${months[date.month - 1]}, $hour12:$minute $ampm';
}

// ==========================================================
// GROUP REQUEST CARD
// ----------------------------------------------------------
// Same architecture as _ConnectionRequestCard above: the pending
// request doc (from 'groupRequests', written by groupstab.dart's
// _CreateGroupDialogState._create() whenever "Add Member" is
// used) drives Accept/Decline, and the request-holder's own live
// profile (here: the group admin/creator) is fetched separately
// via FutureBuilder. The group's own display fields (image, name,
// Group ID) are read directly off the request doc -- they were
// captured at request time, exactly like senderName is captured
// on the 'connections' doc. No password/passwordHash/passwordSalt
// field is ever read or shown here.
// ==========================================================

class _GroupRequestCard extends StatefulWidget {
  final String requestId;

  final Map<String, dynamic> data;

  const _GroupRequestCard({
    required this.requestId,
    required this.data,
  });

  @override
  State<_GroupRequestCard> createState() => _GroupRequestCardState();
}

class _GroupRequestCardState extends State<_GroupRequestCard> {
  bool _processing = false;

  // ========================================================
  // GET USER DATA
  // ========================================================

  Future<Map<String, dynamic>> _getUserData(String uid) async {
    final cleanUid = uid.trim();

    if (cleanUid.isEmpty) {
      return {};
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(cleanUid)
          .get();

      if (!doc.exists) {
        debugPrint('User document not found: $cleanUid');
        return {};
      }

      return doc.data() ?? {};
    } catch (e) {
      debugPrint('Get user data error: $e');
      return {};
    }
  }

  // ========================================================
  // SEND RESPONSE NOTIFICATION
  // ========================================================

  Future<bool> _sendResponseNotification({
    required String targetUid,
    required String senderUid,
    required String senderName,
    required String message,
    required String type,
  }) async {
    try {
      final cleanTargetUid = targetUid.trim();
      final cleanSenderUid = senderUid.trim();

      if (cleanTargetUid.isEmpty || cleanSenderUid.isEmpty) {
        debugPrint('Target/sender UID is empty.');
        return false;
      }

      final result = await NotificationService.instance.sendToUser(
        receiverUid: cleanTargetUid,
        senderName: senderName,
        message: message,
        type: type,
        senderUid: cleanSenderUid,
      );

      debugPrint('Group response notification result: $result');

      return result;
    } catch (e) {
      debugPrint('Group response notification error: $e');
      return false;
    }
  }

  // ========================================================
  // ACCEPT REQUEST
  // ========================================================

  Future<void> _acceptRequest(BuildContext context) async {
    if (_processing) {
      return;
    }

    setState(() {
      _processing = true;
    });

    try {
      final currentUser = FirebaseAuth.instance.currentUser;

      if (currentUser == null) {
        debugPrint('Current user is null.');
        return;
      }

      final currentUid = currentUser.uid.trim();

      if (currentUid.isEmpty) {
        debugPrint('Current UID is empty.');
        return;
      }

      // ----------------------------------------------------
      // SAFETY CHECK
      // ----------------------------------------------------

      final receiverUid =
          (widget.data['receiverUid'] ?? '').toString().trim();

      if (receiverUid.isNotEmpty && receiverUid != currentUid) {
        debugPrint('Request does not belong to current user.');
        return;
      }

      final groupDocId = (widget.data['groupDocId'] ?? '').toString().trim();
      final groupName = (widget.data['groupName'] ?? 'Group').toString().trim();
      final senderUid = (widget.data['senderUid'] ??
              widget.data['adminUid'] ??
              '')
          .toString()
          .trim();

      if (groupDocId.isEmpty) {
        debugPrint('Group doc id is empty.');
        return;
      }

      if (senderUid.isEmpty) {
        debugPrint('Group request sender UID is empty.');
        return;
      }

      // ----------------------------------------------------
      // CURRENT USER DATA
      // ----------------------------------------------------

      final currentUserData = await _getUserData(currentUid);

      final currentUserName =
          (currentUserData['publicName'] ?? '').toString().trim();

      final displayName = currentUserName.isEmpty ? 'User' : currentUserName;

      // ----------------------------------------------------
      // ADD TO GROUP MEMBERS
      // ----------------------------------------------------

      await FirebaseFirestore.instance
          .collection('groups')
          .doc(groupDocId)
          .update({
        'members': FieldValue.arrayUnion([currentUid]),
        'pendingMembers': FieldValue.arrayRemove([currentUid]),
        'membersCount': FieldValue.increment(1),
      });

      // ----------------------------------------------------
      // SEND NOTIFICATION TO GROUP ADMIN / SENDER
      // (Done the same way the connection Accept flow does: a
      // persisted 'notifications' doc plus a push, before the
      // request doc below is updated.)
      // ----------------------------------------------------

      final message =
          '$displayName accepted your group request for "$groupName"';

      await FirebaseFirestore.instance.collection('notifications').add({
        'receiverUid': senderUid,
        'senderUid': currentUid,
        'senderName': displayName,
        'message': message,
        'type': 'group_request_accepted',
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt':
            Timestamp.fromDate(DateTime.now().add(const Duration(days: 7))),
      });

      final notificationSent = await _sendResponseNotification(
        targetUid: senderUid,
        senderUid: currentUid,
        senderName: displayName,
        message: message,
        type: 'group_request_accepted',
      );

      // ----------------------------------------------------
      // UPDATE REQUEST
      // ----------------------------------------------------

      await FirebaseFirestore.instance
          .collection('groupRequests')
          .doc(widget.requestId)
          .update({
        'status': 'accepted',
        'acceptedAt': FieldValue.serverTimestamp(),
      });

      debugPrint('Group request accepted.');

      if (!context.mounted) {
        return;
      }

      showTopAlert(context, notificationSent
                ? 'You joined "$groupName".'
                : 'You joined "$groupName", but notification was not sent.');
    } catch (e) {
      debugPrint('Accept group request error: $e');

      if (!context.mounted) {
        return;
      }

      showTopAlert(context, 'Failed to accept group request.', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
        });
      }
    }
  }

  // ========================================================
  // DECLINE REQUEST
  // ========================================================

  Future<void> _rejectRequest(BuildContext context) async {
    if (_processing) {
      return;
    }

    setState(() {
      _processing = true;
    });

    try {
      final currentUser = FirebaseAuth.instance.currentUser;

      if (currentUser == null) {
        debugPrint('Current user is null.');
        return;
      }

      final currentUid = currentUser.uid.trim();

      if (currentUid.isEmpty) {
        debugPrint('Current UID is empty.');
        return;
      }

      // ----------------------------------------------------
      // SAFETY CHECK
      // ----------------------------------------------------

      final receiverUid =
          (widget.data['receiverUid'] ?? '').toString().trim();

      if (receiverUid.isNotEmpty && receiverUid != currentUid) {
        debugPrint('Request does not belong to current user.');
        return;
      }

      final groupDocId = (widget.data['groupDocId'] ?? '').toString().trim();
      final groupName = (widget.data['groupName'] ?? 'Group').toString().trim();
      final senderUid = (widget.data['senderUid'] ??
              widget.data['adminUid'] ??
              '')
          .toString()
          .trim();

      if (groupDocId.isEmpty) {
        debugPrint('Group doc id is empty.');
        return;
      }

      if (senderUid.isEmpty) {
        debugPrint('Group request sender UID is empty.');
        return;
      }

      // ----------------------------------------------------
      // CURRENT USER DATA
      // ----------------------------------------------------

      final currentUserData = await _getUserData(currentUid);

      final currentUserName =
          (currentUserData['publicName'] ?? '').toString().trim();

      final displayName = currentUserName.isEmpty ? 'User' : currentUserName;

      // ----------------------------------------------------
      // REMOVE FROM PENDING MEMBERS
      // User must NOT become a member on decline.
      // ----------------------------------------------------

      await FirebaseFirestore.instance
          .collection('groups')
          .doc(groupDocId)
          .update({
        'pendingMembers': FieldValue.arrayRemove([currentUid]),
      });

      // ----------------------------------------------------
      // SEND DECLINE NOTIFICATION
      // (Done BEFORE deleting the request document, same as the
      // connection Decline flow -- once the doc is deleted there
      // is nothing left to reference the original request state.)
      // ----------------------------------------------------

      final message =
          '$displayName declined your group request for "$groupName"';

      await FirebaseFirestore.instance.collection('notifications').add({
        'receiverUid': senderUid,
        'senderUid': currentUid,
        'senderName': displayName,
        'message': message,
        'type': 'group_request_declined',
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt':
            Timestamp.fromDate(DateTime.now().add(const Duration(days: 7))),
      });

      final notificationSent = await _sendResponseNotification(
        targetUid: senderUid,
        senderUid: currentUid,
        senderName: displayName,
        message: message,
        type: 'group_request_declined',
      );

      // ----------------------------------------------------
      // DELETE REQUEST
      // ----------------------------------------------------

      await FirebaseFirestore.instance
          .collection('groupRequests')
          .doc(widget.requestId)
          .delete();

      debugPrint('Group request declined.');

      if (!context.mounted) {
        return;
      }

      showTopAlert(context, notificationSent
                ? 'Group request declined.'
                : 'Request declined, but notification was not sent.');
    } catch (e) {
      debugPrint('Decline group request error: $e');

      if (!context.mounted) {
        return;
      }

      showTopAlert(context, 'Failed to decline group request.', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
        });
      }
    }
  }

  // ========================================================
  // UI
  // ========================================================

  @override
  Widget build(BuildContext context) {
    final String groupName = (widget.data['groupName'] ?? 'Group').toString().trim();
    final String groupId = (widget.data['groupId'] ?? '').toString().trim();
    final String groupImage =
        (widget.data['groupProfileImage'] ?? '').toString().trim();
    final String adminUid = (widget.data['adminUid'] ??
            widget.data['senderUid'] ??
            '')
        .toString()
        .trim();
    final String requestedAt =
        _formatRequestTimestamp(widget.data['createdAt']);

    return FutureBuilder<Map<String, dynamic>>(
      future: _getUserData(adminUid),
      builder: (context, snapshot) {
        final adminData = snapshot.data ?? {};

        final String adminName =
            (adminData['publicName'] ?? '').toString().trim();

        return Container(
          padding: const EdgeInsets.all(14),

          decoration: BoxDecoration(
            color: const Color(0xFF18181F),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: const Color(0xFFA78BFA).withValues(alpha: 0.30),
            ),
          ),

          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ============================================
              // GROUP PROFILE IMAGE
              // ============================================

              Container(
                width: 55,
                height: 55,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFA78BFA)),
                ),
                child: ClipOval(
                  child: groupImage.isNotEmpty
                      ? Image(
                          image: _groupImageProvider(groupImage)!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return const Icon(
                              Icons.diversity_3_rounded,
                              color: Colors.white70,
                              size: 30,
                            );
                          },
                        )
                      : const Icon(
                          Icons.diversity_3_rounded,
                          color: Colors.white70,
                          size: 30,
                        ),
                ),
              ),

              const SizedBox(width: 13),

              // ============================================
              // CONTENT
              // ============================================

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      groupName.isEmpty ? 'Group' : groupName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    if (groupId.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        groupId,
                        style: const TextStyle(
                          color: Color(0xFFA78BFA),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],

                    const SizedBox(height: 5),

                    Text(
                      'Invited by ${adminName.isEmpty ? 'User' : adminName}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),

                    if (requestedAt.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        requestedAt,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11.5,
                        ),
                      ),
                    ],

                    const SizedBox(height: 10),

                    Row(
                      children: [
                        // ==================================
                        // ACCEPT
                        // ==================================

                        Expanded(
                          child: ElevatedButton(
                            onPressed: _processing
                                ? null
                                : () {
                                    _acceptRequest(context);
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF7C3AED),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor:
                                  const Color(0xFF7C3AED)
                                      .withValues(alpha: 0.4),
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                            ),
                            child: _processing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text('Accept'),
                          ),
                        ),

                        const SizedBox(width: 8),

                        // ==================================
                        // DECLINE
                        // ==================================

                        Expanded(
                          child: OutlinedButton(
                            onPressed: _processing
                                ? null
                                : () {
                                    _rejectRequest(context);
                                  },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white70,
                              disabledForegroundColor: Colors.white24,
                              side: const BorderSide(color: Colors.white24),
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                            ),
                            child: const Text('Decline'),
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
    );
  }
}
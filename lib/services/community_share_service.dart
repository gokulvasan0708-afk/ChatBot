import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_feed_service.dart';

// ================================================================
// COMMUNITY SHARE SERVICE  (Community spec -- "Share within Nexus")
// ----------------------------------------------------------------
// Shares a feed post into an existing Nexus chat by writing an
// ordinary text message with the EXACT same shape the chat screens
// already write:
//   - group chats:   groups/{id}/messages   (senderUid/text/sentAt)
//   - private chats: chats/{a_b}/messages   (senderId/receiverId/...)
// so the shared post shows up in the existing chat UI with zero
// changes to it. An extra 'sharedPost' map rides along on the
// message document (ignored by the current chat widgets) so a later
// version can render a rich tap-to-open card.
//
// Only destinations the user legitimately has are offered: groups
// they are a member of and users they are connected with.
// ================================================================

class CommunityShareTarget {
  /// 'group' or 'user'
  final String kind;

  /// groupDocId for groups, uid for users
  final String id;
  final String name;
  final String imageUrl;

  const CommunityShareTarget({
    required this.kind,
    required this.id,
    required this.name,
    required this.imageUrl,
  });
}

class CommunityShareService {
  CommunityShareService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ==========================================================
  // TARGETS
  // ==========================================================

  static Future<List<CommunityShareTarget>> loadTargets(String uid) async {
    final targets = <CommunityShareTarget>[];

    final groupSnap = await _firestore
        .collection('groups')
        .where('members', arrayContains: uid)
        .get();
    for (final d in groupSnap.docs) {
      final data = d.data();
      targets.add(CommunityShareTarget(
        kind: 'group',
        id: d.id,
        name: (data['groupName'] ?? 'Group').toString(),
        imageUrl: (data['groupProfileImage'] ?? '').toString(),
      ));
    }

    final connectionSnap = await _firestore
        .collection('connections')
        .where('users', arrayContains: uid)
        .where('status', isEqualTo: 'connected')
        .get();

    final otherUids = <String>{};
    for (final c in connectionSnap.docs) {
      final users = c.data()['users'];
      if (users is List) {
        for (final u in users) {
          if (u.toString() != uid) otherUids.add(u.toString());
        }
      }
    }

    final userDocs = await Future.wait(
      otherUids.map((u) => _firestore.collection('users').doc(u).get()),
    );
    for (final doc in userDocs) {
      final data = doc.data();
      if (data == null) continue;
      targets.add(CommunityShareTarget(
        kind: 'user',
        id: doc.id,
        name: (data['privateName'] ?? data['publicName'] ?? 'User').toString(),
        imageUrl: (data['privateImage'] ?? data['publicImage'] ?? '').toString(),
      ));
    }

    targets.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return targets;
  }

  // ==========================================================
  // MESSAGE TEXT
  // ==========================================================

  static String buildShareText({
    required String communityName,
    required Map<String, dynamic> post,
  }) {
    final type = (post['type'] ?? 'text').toString();
    final title = (post['title'] ?? '').toString().trim();
    final text = (post['text'] ?? '').toString().trim();
    final author = (post['authorName'] ?? 'A member').toString();

    final label = CommunityFeedService.typeLabels[type] ?? 'Post';
    var body = title.isNotEmpty ? title : text;
    if (title.isNotEmpty && text.isNotEmpty) body = '$title — $text';
    if (body.isEmpty) body = '($label)';
    if (body.length > 220) body = '${body.substring(0, 217)}…';

    final where = communityName.trim().isEmpty ? 'Community' : communityName.trim();
    return '📌 $label from $where\n$author: $body';
  }

  static Map<String, dynamic> _sharedPostMeta(Map<String, dynamic> post) => {
        'postId': (post['id'] ?? '').toString(),
        'communityDocId': (post['communityDocId'] ?? '').toString(),
        'type': (post['type'] ?? 'text').toString(),
      };

  // ==========================================================
  // SEND
  // ==========================================================

  static Future<void> sendToGroup({
    required String groupDocId,
    required String senderUid,
    required String text,
    required Map<String, dynamic> post,
  }) async {
    final groupRef = _firestore.collection('groups').doc(groupDocId);
    final groupSnap = await groupRef.get();
    final members = groupSnap.data()?['members'];
    if (members is! List || !members.contains(senderUid)) {
      throw Exception('You are no longer a member of this group.');
    }

    await groupRef.collection('messages').add({
      'senderUid': senderUid,
      'text': text,
      'sentAt': FieldValue.serverTimestamp(),
      'replyTo': null,
      'sharedPost': _sharedPostMeta(post),
    });
    await groupRef.update({
      'lastMessage': text,
      'lastMessageAt': FieldValue.serverTimestamp(),
      'lastMessageSender': senderUid,
    });
  }

  static Future<void> sendToUser({
    required String targetUid,
    required String senderUid,
    required String text,
    required Map<String, dynamic> post,
  }) async {
    final ids = [senderUid, targetUid]..sort();
    final chatId = ids.join('_');

    // Re-verify the connection at send time.
    final connection = await _firestore.collection('connections').doc(chatId).get();
    if ((connection.data()?['status'] ?? '') != 'connected') {
      throw Exception('You are no longer connected with this user.');
    }

    final chatRef = _firestore.collection('chats').doc(chatId);
    final now = FieldValue.serverTimestamp();

    await chatRef.collection('messages').add({
      'senderId': senderUid,
      'receiverId': targetUid,
      'text': text,
      'sentAt': now,
      'expiresAt': null,
      'chatTypeAtSend': 'private',
      'savedBy': <String>[],
      'hiddenFor': <String>[],
      'readBy': <String>[],
      'replyTo': null,
      'isForwarded': true,
      'sharedPost': _sharedPostMeta(post),
    });

    await chatRef.set({
      'participants': [senderUid, targetUid],
      'lastMessage': text,
      'lastMessageTime': now,
      'lastMessageSenderId': senderUid,
      'otherUserUid': targetUid,
      'hiddenFor': FieldValue.arrayRemove([senderUid]),
      'updatedAt': now,
    }, SetOptions(merge: true));
  }
}

import 'package:cloud_firestore/cloud_firestore.dart';

import '../club_paths.dart';

class ClubDiscussionService {
  ClubDiscussionService._();
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> _posts(String clubId) =>
      ClubPaths.club(clubId).collection('posts');

  static CollectionReference<Map<String, dynamic>> _comments(
          String clubId, String postId) =>
      _posts(clubId).doc(postId).collection('comments');

  static Stream<List<Map<String, dynamic>>> watchPosts(String clubId) {
    return _posts(clubId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((s) => s.docs.map((d) => {...d.data(), 'id': d.id}).toList());
  }

  static Future<String> createPost({
    required String clubId,
    required String uid,
    required String authorName,
    required String authorAvatar,
    required String text,
    required bool spoiler,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) throw Exception('Write something first.');
    if (clean.length > 3000) throw Exception('Post is too long.');
    final ref = _posts(clubId).doc();
    await ref.set({
      'authorUid': uid,
      'authorName': authorName,
      'authorAvatar': authorAvatar,
      'text': clean,
      'isSpoiler': spoiler,
      'likes': <String>[],
      'commentCount': 0,
      'isPinned': false,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  static Future<void> toggleLike({
    required String clubId,
    required String postId,
    required String uid,
    required bool liked,
  }) async {
    await _posts(clubId).doc(postId).update({
      'likes': liked
          ? FieldValue.arrayRemove([uid])
          : FieldValue.arrayUnion([uid]),
    });
  }

  static Future<void> togglePin({
    required String clubId,
    required String postId,
    required bool pinned,
  }) async {
    await _posts(clubId).doc(postId).update({
      'isPinned': !pinned,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> deletePost({
    required String clubId,
    required String postId,
  }) async {
    await _posts(clubId).doc(postId).delete();
  }

  static Future<void> reportPost({
    required String clubId,
    required String postId,
    required String reporterUid,
    required String reason,
    String targetUid = '',
  }) async {
    await ClubPaths.reports(clubId).add({
      'clubId': clubId,
      'postId': postId,
      'targetUid': targetUid,
      'targetType': 'post',
      'reporterUid': reporterUid,
      'reason': reason.trim().isEmpty ? 'Other' : reason.trim(),
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static Stream<List<Map<String, dynamic>>> watchComments(
      String clubId, String postId) {
    return _comments(clubId, postId)
        .orderBy('createdAt')
        .snapshots()
        .map((s) => s.docs.map((d) => {...d.data(), 'id': d.id}).toList());
  }

  static Future<void> addComment({
    required String clubId,
    required String postId,
    required String uid,
    required String authorName,
    required String authorAvatar,
    required String text,
    String parentId = '',
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    final batch = _db.batch();
    final ref = _comments(clubId, postId).doc();
    batch.set(ref, {
      'authorUid': uid,
      'authorName': authorName,
      'authorAvatar': authorAvatar,
      'text': clean,
      'parentId': parentId,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(_posts(clubId).doc(postId), {
      'commentCount': FieldValue.increment(1),
    });
    await batch.commit();
  }

  static Future<void> deleteComment({
    required String clubId,
    required String postId,
    required String commentId,
  }) async {
    final batch = _db.batch();
    batch.delete(_comments(clubId, postId).doc(commentId));
    batch.update(_posts(clubId).doc(postId), {
      'commentCount': FieldValue.increment(-1),
    });
    await batch.commit();
  }
}

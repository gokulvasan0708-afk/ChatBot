import 'package:cloud_firestore/cloud_firestore.dart';

import '../club_paths.dart';

class ClubWatchlistService {

  static CollectionReference<Map<String, dynamic>> _items(String clubId, String uid) =>
      ClubPaths.club(clubId).collection('watchlists').doc(uid).collection('items');

  static Stream<QuerySnapshot<Map<String, dynamic>>> watch(String clubId, String uid) =>
      _items(clubId, uid).orderBy('updatedAt', descending: true).snapshots();

  static Future<void> save({
    required String clubId,
    required String uid,
    required String contentId,
    required String title,
    String thumbnailUrl = '',
    String progress = '',
    String status = 'Saved',
  }) async {
    await _items(clubId, uid).doc(contentId).set({
      'contentId': contentId,
      'title': title,
      'thumbnailUrl': thumbnailUrl,
      'progress': progress,
      'status': status,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> update({required String clubId, required String uid, required String itemId, String? progress, String? status}) async {
    final data = <String, dynamic>{'updatedAt': FieldValue.serverTimestamp()};
    if (progress != null) data['progress'] = progress;
    if (status != null) data['status'] = status;
    await _items(clubId, uid).doc(itemId).update(data);
  }

  static Future<void> remove({required String clubId, required String uid, required String itemId}) =>
      _items(clubId, uid).doc(itemId).delete();
}

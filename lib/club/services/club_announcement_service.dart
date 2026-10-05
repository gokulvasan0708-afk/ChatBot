import 'package:cloud_firestore/cloud_firestore.dart';

import '../club_paths.dart';

class ClubAnnouncementService {

  static CollectionReference<Map<String, dynamic>> _ref(String clubId) =>
      ClubPaths.club(clubId).collection('announcements');

  static Stream<QuerySnapshot<Map<String, dynamic>>> watch(String clubId) =>
      _ref(clubId).orderBy('createdAt', descending: true).snapshots();

  static Future<void> create({
    required String clubId,
    required String authorUid,
    required String authorName,
    required String authorAvatar,
    required String title,
    required String description,
  }) async {
    if (title.trim().isEmpty || description.trim().isEmpty) {
      throw Exception('Title and description are required.');
    }
    await _ref(clubId).add({
      'authorUid': authorUid,
      'authorName': authorName,
      'authorAvatar': authorAvatar,
      'title': title.trim(),
      'description': description.trim(),
      'isPinned': false,
      'readBy': <String>[],
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> setPinned({
    required String clubId,
    required String announcementId,
    required bool pinned,
  }) => _ref(clubId).doc(announcementId).update({'isPinned': pinned});

  static Future<void> markRead({
    required String clubId,
    required String announcementId,
    required String uid,
  }) => _ref(clubId).doc(announcementId).update({
        'readBy': FieldValue.arrayUnion([uid]),
      });

  static Future<void> delete({
    required String clubId,
    required String announcementId,
  }) => _ref(clubId).doc(announcementId).delete();
}

import 'package:cloud_firestore/cloud_firestore.dart';

class ClubNotificationService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> _ref(String uid) =>
      _db.collection('users').doc(uid).collection('clubNotifications');

  static Stream<QuerySnapshot<Map<String, dynamic>>> watch(String uid) =>
      _ref(uid).orderBy('createdAt', descending: true).snapshots();

  static Future<void> create({required String uid, required String clubId, required String title, required String body, String type = 'club'}) async {
    await _ref(uid).add({
      'clubId': clubId,
      'title': title,
      'body': body,
      'type': type,
      'isRead': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> markRead(String uid, String id) => _ref(uid).doc(id).update({'isRead': true});

  static Future<void> markAllRead(String uid) async {
    final snap = await _ref(uid).where('isRead', isEqualTo: false).get();
    final batch = _db.batch();
    for (final doc in snap.docs) {
      batch.update(doc.reference, {'isRead': true});
    }
    await batch.commit();
  }

  static Future<void> delete(String uid, String id) => _ref(uid).doc(id).delete();
}

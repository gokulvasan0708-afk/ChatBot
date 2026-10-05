import 'package:cloud_firestore/cloud_firestore.dart';

import '../club_paths.dart';

class ClubActivityService {
  ClubActivityService._();
  static CollectionReference<Map<String,dynamic>> _ref(String clubId) => ClubPaths.club(clubId).collection('activities');

  static Stream<QuerySnapshot<Map<String,dynamic>>> watchActivities(String clubId) => _ref(clubId).orderBy('date', descending: false).snapshots();

  static Future<String> createActivity({required String clubId, required String uid, required String title, required String description, required DateTime date}) async {
    if (title.trim().isEmpty) throw Exception('Enter an activity title.');
    final ref = _ref(clubId).doc();
    await ref.set({'title': title.trim(), 'description': description.trim(), 'date': Timestamp.fromDate(date), 'participants': <String>[], 'createdBy': uid, 'createdAt': FieldValue.serverTimestamp()});
    return ref.id;
  }

  static Future<void> join({required String clubId, required String activityId, required String uid}) => _ref(clubId).doc(activityId).update({'participants': FieldValue.arrayUnion([uid])});
  static Future<void> leave({required String clubId, required String activityId, required String uid}) => _ref(clubId).doc(activityId).update({'participants': FieldValue.arrayRemove([uid])});
}

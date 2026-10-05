import 'package:cloud_firestore/cloud_firestore.dart';

import '../club_paths.dart';

class ClubModerationService {
  ClubModerationService._();

  static CollectionReference<Map<String, dynamic>> _reports(String clubId) =>
      ClubPaths.reports(clubId);

  static CollectionReference<Map<String, dynamic>> _moderation(String clubId) =>
      ClubPaths.club(clubId).collection('moderation');

  static Stream<List<Map<String, dynamic>>> watchReports(String clubId) {
    return _reports(clubId)
        .where('clubId', isEqualTo: clubId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map((d) => {...d.data(), 'id': d.id}).toList());
  }

  static Future<void> setReportStatus({
    required String reportId,
    required String status,
    required String moderatorUid,
    String clubId = '',
  }) async {
    await _reports(clubId).doc(reportId).update({
      'status': status,
      'reviewedBy': moderatorUid,
      'reviewedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> warnUser({
    required String clubId,
    required String targetUid,
    required String moderatorUid,
    required String reason,
  }) async {
    final ref = _moderation(clubId).doc(targetUid);
    await ref.set({
      'uid': targetUid,
      'warningCount': FieldValue.increment(1),
      'lastWarningReason': reason.trim().isEmpty ? 'Club rule violation' : reason.trim(),
      'lastWarnedBy': moderatorUid,
      'lastWarnedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> muteUser({
    required String clubId,
    required String targetUid,
    required String moderatorUid,
    required Duration duration,
    required String reason,
  }) async {
    final until = Timestamp.fromDate(DateTime.now().add(duration));
    await _moderation(clubId).doc(targetUid).set({
      'uid': targetUid,
      'mutedUntil': until,
      'muteReason': reason.trim().isEmpty ? 'Club rule violation' : reason.trim(),
      'mutedBy': moderatorUid,
      'mutedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> unmuteUser({
    required String clubId,
    required String targetUid,
  }) async {
    await _moderation(clubId).doc(targetUid).set({
      'mutedUntil': null,
    }, SetOptions(merge: true));
  }

  static Future<void> removeMember({
    required String clubId,
    required String targetUid,
  }) async {
    await ClubPaths.club(clubId).update({
      'members': FieldValue.arrayRemove([targetUid]),
      'moderators': FieldValue.arrayRemove([targetUid]),
      'leaders': FieldValue.arrayRemove([targetUid]),
      'membersCount': FieldValue.increment(-1),
    });
  }
}

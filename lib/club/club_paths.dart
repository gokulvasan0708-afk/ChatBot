import 'package:cloud_firestore/cloud_firestore.dart';

// ================================================================
// CLUB PATHS
// ----------------------------------------------------------------
// One place that decides WHERE a club lives in Firestore, so every
// page / service in the Club module works for both kinds of club
// without being copied:
//
//   Hubs club       docId = Firestore auto id        -> 'clubs'
//   Community club  docId = 'cc_' + auto id          -> 'communityClubs'
//
// The two kinds use completely separate collections (club docs,
// Club-ID reservations, applications and reports), so a Community
// club can never show up on the Hubs > Clubs page and a Hubs club
// can never show up inside a Community. Firestore auto ids never
// contain '_', so the 'cc_' prefix can never clash with a Hubs id.
// ================================================================
class ClubPaths {
  ClubPaths._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Prefix of every Community club doc id.
  static const String communityPrefix = 'cc_';

  // Hubs (standalone) clubs
  static const String hubClubs = 'clubs';
  static const String hubClubIds = 'clubIds';
  static const String hubApplications = 'clubApplications';
  static const String hubReports = 'clubReports';

  // Community clubs
  static const String communityClubs = 'communityClubs';
  static const String communityClubIds = 'communityClubIds';
  static const String communityApplications = 'communityClubApplications';
  static const String communityReports = 'communityClubReports';

  static bool isCommunityClub(String clubDocId) =>
      clubDocId.startsWith(communityPrefix);

  /// The collection the club [clubDocId] lives in.
  static CollectionReference<Map<String, dynamic>> clubs(String clubDocId) =>
      _db.collection(isCommunityClub(clubDocId) ? communityClubs : hubClubs);

  /// The club document itself.
  static DocumentReference<Map<String, dynamic>> club(String clubDocId) =>
      clubs(clubDocId).doc(clubDocId);

  /// Recruitment applications of that club.
  static CollectionReference<Map<String, dynamic>> applications(
          String clubDocId) =>
      _db.collection(isCommunityClub(clubDocId)
          ? communityApplications
          : hubApplications);

  /// Reports filed inside that club. An empty id means a Hubs club.
  static CollectionReference<Map<String, dynamic>> reports(String clubDocId) =>
      _db.collection(
          isCommunityClub(clubDocId) ? communityReports : hubReports);

  /// A fresh doc id for a new Community club.
  static String newCommunityClubDocId() =>
      '$communityPrefix${_db.collection(communityClubs).doc().id}';
}

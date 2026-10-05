import 'package:cloud_firestore/cloud_firestore.dart';

/// Phase 1 Firestore model for a Club.
///
/// Collection: `clubs/{clubId}`
///
/// The fields introduced here are intentionally additive so existing clubs
/// created by the previous Club feature continue to work.
class ClubModel {
  final String id;
  final String clubId; // public ID, e.g. "@Coding Club-A1B2"
  final String name;
  final String category;
  final String description;
  final String about;
  final String rules;
  final String avatarUrl;
  final String bannerUrl;
  final String ownerUid;
  final List<String> moderatorUids;
  final List<String> memberUids;
  final int membersCount;
  final String joinMode;
  final DateTime? createdAt;

  const ClubModel({
    required this.id,
    required this.clubId,
    required this.name,
    required this.category,
    required this.description,
    required this.about,
    required this.rules,
    required this.avatarUrl,
    required this.bannerUrl,
    required this.ownerUid,
    required this.moderatorUids,
    required this.memberUids,
    required this.membersCount,
    required this.joinMode,
    required this.createdAt,
  });

  bool isMember(String uid) => uid.isNotEmpty && memberUids.contains(uid);
  bool isModerator(String uid) =>
      uid.isNotEmpty && moderatorUids.contains(uid);
  bool isOwner(String uid) => uid.isNotEmpty && ownerUid == uid;

  factory ClubModel.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    final data = snapshot.data() ?? <String, dynamic>{};
    return ClubModel.fromMap(snapshot.id, data);
  }

  factory ClubModel.fromMap(String id, Map<String, dynamic> data) {
    final leaders = _strings(data['leaders']);
    final moderators = _strings(data['moderators']);
    final owner = (data['ownerUid'] ?? data['createdBy'] ?? '').toString();

    return ClubModel(
      id: id,
      clubId: (data['clubId'] ?? '').toString(),
      name: (data['name'] ?? 'Unnamed Club').toString(),
      category: (data['category'] ?? '').toString(),
      description: (data['description'] ?? '').toString(),
      about: (data['about'] ?? data['description'] ?? '').toString(),
      rules: (data['rules'] ?? '').toString(),
      avatarUrl: (data['avatarUrl'] ?? data['logoUrl'] ?? '').toString(),
      bannerUrl: (data['bannerUrl'] ?? '').toString(),
      ownerUid: owner,
      moderatorUids: moderators.isNotEmpty
          ? moderators
          : leaders.where((uid) => uid != owner).toList(),
      memberUids: _strings(data['members']),
      membersCount: _int(data['membersCount'], _strings(data['members']).length),
      joinMode: (data['joinMode'] ?? 'open').toString(),
      createdAt: _date(data['createdAt']),
    );
  }

  Map<String, dynamic> toMap() => {
        'clubId': clubId,
        'name': name,
        'category': category,
        'description': description,
        'about': about,
        'rules': rules,
        'avatarUrl': avatarUrl,
        'logoUrl': avatarUrl,
        'bannerUrl': bannerUrl,
        'ownerUid': ownerUid,
        'createdBy': ownerUid,
        'moderators': moderatorUids,
        'members': memberUids,
        'membersCount': membersCount,
        'joinMode': joinMode,
        'createdAt': createdAt == null
            ? FieldValue.serverTimestamp()
            : Timestamp.fromDate(createdAt!),
      };

  static List<String> _strings(dynamic value) {
    if (value is! List) return <String>[];
    return value.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
  }

  static int _int(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return fallback;
  }

  static DateTime? _date(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }
}

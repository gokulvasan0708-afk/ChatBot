import 'community_member_profile_service.dart';

// ================================================================
// COMMUNITY CHAT IDENTITY SERVICE
// ----------------------------------------------------------------
// The Community Chat (the auto-created group opened from
// Community Home -> "Community Chat") must show each person as
// their COMMUNITY PROFILE -- the profile's own name and image --
// and not the account's normal public / private chat name + photo.
//
// A message in the Community Chat is tagged with
//   senderUid         the login account (already existed)
//   senderProfileId   the Community Profile that sent it (new)
//
// Showing a message resolves, in order:
//   1. the profile named by senderProfileId (so an account that
//      holds two profiles -- e.g. Controller + Student -- shows
//      the right one on each message), else
//   2. the sender's currently active profile in that community
//      (old messages that were sent before senderProfileId
//      existed).
// When neither exists the caller falls back to the old account
// name / image, so nothing breaks for people without a profile.
// ================================================================

class CommunityChatIdentity {
  final String profileId;
  final String name;
  final String image;
  final String role;

  const CommunityChatIdentity({
    required this.profileId,
    required this.name,
    required this.image,
    required this.role,
  });
}

class CommunityChatIdentityService {
  CommunityChatIdentityService._();

  static CommunityChatIdentity? _fromProfile(Map<String, dynamic>? p) {
    if (p == null) return null;

    final role = (p['role'] ?? '').toString().trim();
    final name = CommunityMemberProfileService.displayName(
      (p['name'] ?? '').toString(),
      role.isEmpty ? CommunityMemberProfileService.roleMember : role,
    );

    return CommunityChatIdentity(
      profileId: (p['id'] ?? p['profileId'] ?? '').toString(),
      name: name,
      image: (p['image'] ?? '').toString().trim(),
      role: role,
    );
  }

  /// Live Community Profile identity for one chat sender.
  ///
  /// [profileId] is the message's `senderProfileId` ('' for older
  /// messages). Emits null when the community has no matching
  /// profile, so the caller can fall back to the account's name.
  static Stream<CommunityChatIdentity?> watch({
    required String communityDocId,
    required String uid,
    String profileId = '',
  }) {
    if (communityDocId.isEmpty) return Stream.value(null);

    if (profileId.isNotEmpty) {
      return CommunityMemberProfileService.watchProfile(
        communityDocId,
        profileId,
      ).map(_fromProfile);
    }

    if (uid.isEmpty) return Stream.value(null);

    return CommunityMemberProfileService.watchActiveProfile(
      communityDocId,
      uid,
    ).map(_fromProfile);
  }

  /// The Profile ID the signed-in account is chatting as in this
  /// community right now ('' when it can't be worked out).
  static Future<String> currentProfileId(String communityDocId) {
    return CommunityMemberProfileService.currentProfileId(communityDocId);
  }

  /// Name to show for a typing account, picked from the community's
  /// active profiles. [pointer] is the account's chosen profile id
  /// (users/{uid}.activeCommunityProfiles[communityId]).
  static String typingNameFor({
    required String uid,
    required String pointer,
    required List<Map<String, dynamic>> profiles,
  }) {
    final mine = [
      for (final p in profiles)
        if ((p['uid'] ?? '').toString() == uid) p,
    ];
    if (mine.isEmpty) return '';

    final id = CommunityMemberProfileService.pickActiveId(mine, pointer);
    for (final p in mine) {
      if ((p['id'] ?? '').toString() == id) {
        return _fromProfile(p)?.name ?? '';
      }
    }
    return '';
  }
}

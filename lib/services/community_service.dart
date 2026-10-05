import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_member_profile_service.dart';

// ================================================================
// COMMUNITY SERVICE
// ----------------------------------------------------------------
// Mirrors the existing Group data pattern (see groupstab.dart /
// api_service.dart) as closely as possible:
//   - Community documents live in their own top-level 'communities'
//     collection, same shape/spirit as 'groups'.
//   - A Community's own live Community ID is generated the same way
//     a Group's ID is (a live preview while typing the name, unique-
//     checked against Firestore) -- except per spec the suffix here
//     is a random 4-digit number rather than a slice of the
//     creator's Account ID, and the format has no leading '@':
//       "<CommunityName>-<4 digits>"   e.g. "CodingClub-4821"
//
// Unlike Group creation, Community creation does NOT go through the
// backend Worker (api_service.dart / server.js): group creation needs
// the backend because the group password has to be hashed server-side.
// Communities carry no password, so there is nothing that needs the
// Admin SDK -- every operation here is a direct, client-side Firestore
// write, exactly like the rest of the app's non-password flows
// (connections, chats, groupRequests, etc.).
//
// MEMBERSHIP = MEMBER PROFILES (Profile IDs), NOT UIDs
// ----------------------------------------------------------------
// Joining a community creates a member profile
// (communities/{id}/memberProfiles/{profileId}). One account may hold
// several profiles in the same community (one per role / identity);
// each is a separate member with its own Profile ID, name, password
// and details. `membersCount` counts ACTIVE profiles. The `members`
// array of uids is only an account ACCESS list (chat / feed / rules):
// an account stays in it while it has at least one active profile.
// See community_member_profile_service.dart for the full layout.
//
// COMMUNITY CHAT
// ----------------------------------------------------------------
// Every Community automatically gets one general chat, and that chat
// is created as an ordinary document in the SAME 'groups' collection
// GroupChatScreen (groupchat.dart) already reads from -- so the
// Community's chat is, byte-for-byte, a real group: same message
// bubbles, same reactions/replies/edit/delete, same typing indicator,
// same call-icon toggles, same mute/sleep settings, same admin
// controls. Nothing in groupchat.dart had to change for this to work.
// The only extra fields on that 'groups' doc are 'communityId'
// (linking back to the owning community) and 'isCommunityChat: true',
// which every existing group-reading widget already ignores safely.
// ================================================================
class CommunityService {
  CommunityService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _communities =>
      _firestore.collection('communities');

  static CollectionReference<Map<String, dynamic>> get _groups =>
      _firestore.collection('groups');

  // ==========================================================
  // COMMUNITY ID
  // "<CommunityName>-<4 random digits>", unique-checked the same
  // way UserProfileService._generateUniqueUserId() checks 'userId'.
  // ==========================================================

  static final Random _random = Random();

  static String _slugifyName(String name) {
    final cleaned = name.trim().replaceAll(RegExp(r'\s+'), '');
    return cleaned.isEmpty ? 'Community' : cleaned;
  }

  static String _randomFourDigits() {
    return (_random.nextInt(9000) + 1000).toString();
  }

  static Future<String> generateUniqueCommunityId(String name) async {
    final base = _slugifyName(name);

    while (true) {
      final candidate = '$base-${_randomFourDigits()}';

      final existing = await _communities
          .where('communityId', isEqualTo: candidate)
          .limit(1)
          .get();

      if (existing.docs.isEmpty) return candidate;
    }
  }

  /// Live preview only (no uniqueness check -- that happens once, at
  /// create time, exactly like the group ID preview vs. the real ID
  /// the backend hands back on create).
  static String previewCommunityId(String name, String previewSuffix) {
    final base = _slugifyName(name);
    return name.trim().isEmpty ? '' : '$base-$previewSuffix';
  }

  // ==========================================================
  // CREATE COMMUNITY
  // ==========================================================

  static Future<Map<String, String>> createCommunity({
    required String name,
    required String type, // 'normal' | 'college'
    required String collegeName,
    required String description,
    required String logoUrl,
    required String ownerUid,
    required String ownerAccountId,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw Exception('Community name is required');
    }

    final communityId = await generateUniqueCommunityId(trimmedName);

    final communityRef = _communities.doc();
    final groupRef = _groups.doc();
    // The creator joins as the community's first member profile (Controller).
    final ownerProfileRef = communityRef.collection('memberProfiles').doc();

    final batch = _firestore.batch();

    batch.set(communityRef, {
      'communityId': communityId,
      'name': trimmedName,
      'type': type,
      'collegeName': type == 'college' ? collegeName.trim() : '',
      'description': description.trim(),
      'logoUrl': logoUrl,
      'ownerUid': ownerUid,
      'ownerAccountId': ownerAccountId,
      'admins': <String>[],
      'moderators': <String>[],
      'members': [ownerUid],
      'membersCount': 1,
      'profileIndex': {
        ownerProfileRef.id: {
          'uid': ownerUid,
          'role': CommunityMemberProfileService.roleController,
        },
      },
      'groupDocId': groupRef.id,
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
    });

    batch.set(ownerProfileRef, {
      'profileId': ownerProfileRef.id,
      'uid': ownerUid,
      'role': CommunityMemberProfileService.roleController,
      // No automatic name: the member sets it on their profile; until
      // then the role is shown (grey).
      'name': '',
      'identityKey': 'owner',
      'identityName': '',
      'registerNumber': '',
      'department': '',
      'year': '',
      'image': '',
      'active': true,
      'createdAt': FieldValue.serverTimestamp(),
      'joinedAt': FieldValue.serverTimestamp(),
    });

    // The Community's general chat -- a real 'groups' doc, so it
    // renders in GroupChatScreen with zero changes to that screen.
    batch.set(groupRef, {
      'groupId': communityId,
      'groupName': trimmedName,
      'groupProfileImage': logoUrl,
      'adminUid': ownerUid,
      'coAdminUids': <String>[],
      'members': [ownerUid],
      'membersCount': 1,
      'mutedBy': <String, dynamic>{},
      'callsEnabledBy': <String, dynamic>{},
      'pendingMembers': <String>[],
      'communityId': communityRef.id,
      'isCommunityChat': true,
      'createdAt': FieldValue.serverTimestamp(),
    });

    await batch.commit();

    await CommunityMemberProfileService.setActiveProfile(
        communityRef.id, ownerUid, ownerProfileRef.id);

    return {
      'communityDocId': communityRef.id,
      'communityId': communityId,
      'groupDocId': groupRef.id,
      'profileId': ownerProfileRef.id,
    };
  }

  // ==========================================================
  // READ
  // ==========================================================

  /// Every community the given uid currently belongs to.
  static Stream<QuerySnapshot<Map<String, dynamic>>> myCommunities(
    String uid,
  ) {
    return _communities
        .where('members', arrayContains: uid)
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  static Stream<DocumentSnapshot<Map<String, dynamic>>> watchCommunity(
    String communityDocId,
  ) {
    return _communities.doc(communityDocId).snapshots();
  }

  static Future<Map<String, dynamic>?> findByCommunityId(
    String communityId,
  ) async {
    final query = await _communities
        .where('communityId', isEqualTo: communityId.trim())
        .limit(1)
        .get();

    if (query.docs.isEmpty) return null;

    final doc = query.docs.first;
    return {...doc.data(), 'docId': doc.id};
  }

  // ==========================================================
  // JOIN  (creates / re-activates a MEMBER PROFILE)
  // ==========================================================

  static CollectionReference<Map<String, dynamic>> _profiles(String cid) =>
      _communities.doc(cid).collection('memberProfiles');

  static List<String> _strings(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : <String>[];

  /// Joins the community with ONE member profile.
  ///
  ///  * The profile is identified by (account, [role], [identityKey]).
  ///  * It already exists AND is active -> nothing is created and the
  ///    member count does NOT change (`alreadyMember: true`).
  ///  * It exists but the member had left -> the SAME profile (same
  ///    Profile ID, name, password, details) is re-activated and the
  ///    count goes up by one.
  ///  * Otherwise a NEW profile with a NEW Profile ID is created and the
  ///    count goes up by one -- even when the same account already has
  ///    profiles with other roles here.
  ///
  /// Returns {success, alreadyMember, profileId, created, groupDocId}.
  static Future<Map<String, dynamic>> joinWithProfile({
    required String communityDocId,
    required String uid,
    required String role,
    String identityKey = '',
    String identityName = '',
    String name = '',
    String department = '',
    String year = '',
    String registerNumber = '',
    String image = '',
  }) async {
    final communityRef = _communities.doc(communityDocId);
    final snap = await communityRef.get();
    if (!snap.exists) {
      return {'success': false, 'message': 'Community not found'};
    }

    final data = snap.data()!;
    final groupDocId = (data['groupDocId'] ?? '').toString();
    final ownerUid = (data['ownerUid'] ?? '').toString();
    final accountList = _strings(data['members']);

    // Member of the old (uid-based) data: give them their first profile
    // before a second one is added, so nothing is lost or counted twice.
    if (accountList.contains(uid)) {
      await CommunityMemberProfileService.ensureMyProfile(communityDocId, data);
    }

    // Same account + same role + same identity already has a profile?
    final mine = await _profiles(communityDocId)
        .where('uid', isEqualTo: uid)
        .get();
    QueryDocumentSnapshot<Map<String, dynamic>>? existing;
    for (final d in mine.docs) {
      final p = d.data();
      final sameRole = (p['role'] ?? '').toString() == role;
      final key = (p['identityKey'] ?? '').toString();
      final sameIdentity = key == identityKey ||
          (uid == ownerUid &&
              role == CommunityMemberProfileService.roleController &&
              key == 'owner');
      if (!sameRole || !sameIdentity) continue;
      if (existing == null || p['active'] != false) existing = d;
    }

    if (existing != null && existing.data()['active'] != false) {
      await CommunityMemberProfileService.setActiveProfile(
          communityDocId, uid, existing.id);
      return {
        'success': true,
        'alreadyMember': true,
        'created': false,
        'profileId': existing.id,
        'groupDocId': groupDocId,
      };
    }

    final profileRef = existing?.reference ?? _profiles(communityDocId).doc();
    final batch = _firestore.batch();

    if (existing == null) {
      // Never filled in automatically (not from the public name either).
      final shownName = name.trim();
      batch.set(profileRef, {
        'profileId': profileRef.id,
        'uid': uid,
        'role': role,
        'name': shownName,
        'identityKey': identityKey,
        'identityName': identityName,
        'registerNumber': registerNumber,
        'department': department,
        'year': year,
        'image': image,
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
        'joinedAt': FieldValue.serverTimestamp(),
      });
    } else {
      batch.update(profileRef, {
        'active': true,
        'removed': false,
        'joinedAt': FieldValue.serverTimestamp(),
        'leftAt': FieldValue.delete(),
        if (department.isNotEmpty) 'department': department,
        if (year.isNotEmpty) 'year': year,
      });
    }

    batch.update(communityRef, {
      'profileIndex.${profileRef.id}': {'uid': uid, 'role': role},
      'members': FieldValue.arrayUnion([uid]),
      'membersCount': FieldValue.increment(1),
    });

    // The community chat only needs the ACCOUNT once.
    if (groupDocId.isNotEmpty && !accountList.contains(uid)) {
      batch.update(_groups.doc(groupDocId), {
        'members': FieldValue.arrayUnion([uid]),
        'membersCount': FieldValue.increment(1),
      });
    }

    await batch.commit();
    await CommunityMemberProfileService.setActiveProfile(
        communityDocId, uid, profileRef.id);

    return {
      'success': true,
      'alreadyMember': false,
      'created': existing == null,
      'profileId': profileRef.id,
      'groupDocId': groupDocId,
    };
  }

  /// Plain join for communities without any role / class requirements:
  /// a "Member" profile.
  static Future<Map<String, dynamic>> joinCommunity({
    required String communityDocId,
    required String uid,
  }) {
    return joinWithProfile(
      communityDocId: communityDocId,
      uid: uid,
      role: CommunityMemberProfileService.roleMember,
      identityKey: 'member',
    );
  }

  // ==========================================================
  // LEAVE / REMOVE  (one PROFILE at a time)
  // ==========================================================

  /// A member leaves with ONE profile. Their other profiles in the same
  /// community stay members. The profile itself is kept (inactive) so its
  /// data and password stay separate if that role is joined again.
  static Future<void> leaveProfile({
    required String communityDocId,
    required String profileId,
    required String uid,
  }) async {
    final p = await _profiles(communityDocId).doc(profileId).get();
    if (!p.exists) return;
    if ((p.data()?['uid'] ?? '').toString() != uid) {
      throw Exception('You can only leave with your own profile.');
    }
    await deactivateProfile(
      communityDocId: communityDocId,
      profileId: profileId,
    );
  }

  /// Marks one profile as no longer a member: the count goes down by one,
  /// the profile leaves every role list, and the ACCOUNT leaves the
  /// access list / community chat only when it has no other active
  /// profile left.
  static Future<void> deactivateProfile({
    required String communityDocId,
    required String profileId,
    bool removed = false,
  }) async {
    final communityRef = _communities.doc(communityDocId);
    final results = await Future.wait([
      communityRef.get(),
      _profiles(communityDocId).doc(profileId).get(),
    ]);
    final communitySnap = results[0];
    final profileSnap = results[1];
    if (!communitySnap.exists || !profileSnap.exists) return;

    final profile = profileSnap.data() ?? <String, dynamic>{};
    if (profile['active'] == false) return;
    final uid = (profile['uid'] ?? '').toString();
    final groupDocId =
        (communitySnap.data()?['groupDocId'] ?? '').toString();

    var otherActive = false;
    if (uid.isNotEmpty) {
      final siblings =
          await _profiles(communityDocId).where('uid', isEqualTo: uid).get();
      otherActive = siblings.docs
          .any((d) => d.id != profileId && d.data()['active'] != false);
    }

    final batch = _firestore.batch();

    batch.update(_profiles(communityDocId).doc(profileId), {
      'active': false,
      'removed': removed,
      'leftAt': FieldValue.serverTimestamp(),
    });

    batch.update(communityRef, {
      'profileIndex.$profileId': FieldValue.delete(),
      'admins': FieldValue.arrayRemove([profileId, if (!otherActive) uid]),
      'moderators': FieldValue.arrayRemove([profileId, if (!otherActive) uid]),
      'membersCount': FieldValue.increment(-1),
      if (!otherActive && uid.isNotEmpty)
        'members': FieldValue.arrayRemove([uid]),
    });

    if (!otherActive && uid.isNotEmpty && groupDocId.isNotEmpty) {
      batch.update(_groups.doc(groupDocId), {
        'members': FieldValue.arrayRemove([uid]),
        'membersCount': FieldValue.increment(-1),
      });
    }

    await batch.commit();
  }

  // ==========================================================
  // DELETE (Controller / Principal)
  // ==========================================================

  /// The owner (the Controller who created it) and anyone using a
  /// Controller or Principal profile may delete the community.
  static Future<bool> _canManageCommunity(
    Map<String, dynamic> data,
    String uid,
  ) async {
    if (uid.isEmpty) return false;
    if ((data['ownerUid'] ?? '').toString() == uid) return true;

    const allowed = {'Controller', 'Principal'};

    final idx = data['profileIndex'];
    if (idx is Map) {
      for (final entry in idx.values) {
        if (entry is Map &&
            (entry['uid'] ?? '').toString() == uid &&
            allowed.contains((entry['role'] ?? '').toString())) {
          return true;
        }
      }
      return false;
    }

    // Communities created before Profile IDs.
    final chosen = data['memberRoles'];
    return chosen is Map && allowed.contains((chosen[uid] ?? '').toString());
  }

  static Future<void> updateCommunity({
    required String communityDocId,
    required String requesterUid,
    required String name,
    required String type,
    required String collegeName,
    required String description,
    required String logoUrl,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw Exception('Community name is required');
    }
    if (type != 'normal' && type != 'college') {
      throw Exception('Invalid community type');
    }
    if (type == 'college' && collegeName.trim().isEmpty) {
      throw Exception('College / institution name is required');
    }

    final communityRef = _communities.doc(communityDocId);
    final snap = await communityRef.get();
    if (!snap.exists) {
      throw Exception('Community not found.');
    }

    final data = snap.data()!;
    if (!await _canManageCommunity(data, requesterUid)) {
      throw Exception(
        'Only the Controller or Principal can edit this community.',
      );
    }

    final groupDocId = (data['groupDocId'] ?? '').toString();
    final groupRef = groupDocId.isEmpty ? null : _groups.doc(groupDocId);
    final groupSnap = groupRef == null ? null : await groupRef.get();
    final batch = _firestore.batch();

    batch.update(communityRef, {
      'name': trimmedName,
      'type': type,
      'collegeName': type == 'college' ? collegeName.trim() : '',
      'description': description.trim(),
      'logoUrl': logoUrl,
    });
    if (groupRef != null && groupSnap?.exists == true) {
      batch.update(groupRef, {
        'groupName': trimmedName,
        'groupProfileImage': logoUrl,
      });
    }

    await batch.commit();
  }

  static Future<void> deleteCommunity({
    required String communityDocId,
    required String requesterUid,
  }) async {
    final communityRef = _communities.doc(communityDocId);
    final snap = await communityRef.get();
    if (!snap.exists) return;

    final data = snap.data()!;
    if (!await _canManageCommunity(data, requesterUid)) {
      throw Exception(
        'Only the Controller or Principal can delete this community.',
      );
    }

    final groupDocId = (data['groupDocId'] ?? '').toString();
    final batch = _firestore.batch();

    batch.delete(communityRef);
    if (groupDocId.isNotEmpty) {
      batch.delete(_groups.doc(groupDocId));
    }

    await batch.commit();
  }

  // ==========================================================
  // ROLES (Rep = Community Admin / Moderator -- Section 12)
  // These lists hold PROFILE IDs, never uids.
  // ==========================================================

  static Future<void> setAdmin({
    required String communityDocId,
    required String profileId,
    required bool isAdmin,
  }) async {
    await _communities.doc(communityDocId).update({
      'admins': isAdmin
          ? FieldValue.arrayUnion([profileId])
          : FieldValue.arrayRemove([profileId]),
    });
  }

  static Future<void> setModerator({
    required String communityDocId,
    required String profileId,
    required bool isModerator,
  }) async {
    await _communities.doc(communityDocId).update({
      'moderators': isModerator
          ? FieldValue.arrayUnion([profileId])
          : FieldValue.arrayRemove([profileId]),
    });
  }

  /// Removes ONE member profile (another profile of the same account, if
  /// any, stays a member).
  static Future<void> removeMember({
    required String communityDocId,
    required String profileId,
  }) async {
    final communityRef = _communities.doc(communityDocId);
    final results = await Future.wait([
      communityRef.get(),
      _profiles(communityDocId).doc(profileId).get(),
    ]);
    if (!results[0].exists || !results[1].exists) return;
    final community = results[0].data() ?? <String, dynamic>{};
    final profile = results[1].data() ?? <String, dynamic>{};

    // The Controller profile of the person who created the community
    // can't be removed.
    if ((profile['uid'] ?? '').toString() ==
            (community['ownerUid'] ?? '').toString() &&
        (profile['role'] ?? '').toString() ==
            CommunityMemberProfileService.roleController) {
      throw Exception('The community owner can\'t be removed.');
    }

    await deactivateProfile(
      communityDocId: communityDocId,
      profileId: profileId,
      removed: true,
    );
  }

  /// Removes a member of the OLD uid-based data (no member profile yet --
  /// listed with the id `legacy_<uid>`). Nothing to deactivate: the
  /// account just leaves the access list, role lists and community chat.
  static Future<void> removeLegacyMember({
    required String communityDocId,
    required String uid,
  }) async {
    if (uid.isEmpty) return;
    final communityRef = _communities.doc(communityDocId);
    final snap = await communityRef.get();
    if (!snap.exists) return;
    final community = snap.data() ?? <String, dynamic>{};

    if ((community['ownerUid'] ?? '').toString() == uid) {
      throw Exception('The community owner can\'t be removed.');
    }
    final members = _strings(community['members']);
    if (!members.contains(uid)) return;

    final groupDocId = (community['groupDocId'] ?? '').toString();
    final batch = _firestore.batch();
    batch.update(communityRef, {
      'members': FieldValue.arrayRemove([uid]),
      'admins': FieldValue.arrayRemove([uid]),
      'moderators': FieldValue.arrayRemove([uid]),
      'memberRoles.$uid': FieldValue.delete(),
      'membersCount': FieldValue.increment(-1),
    });
    if (groupDocId.isNotEmpty) {
      batch.update(_groups.doc(groupDocId), {
        'members': FieldValue.arrayRemove([uid]),
        'membersCount': FieldValue.increment(-1),
      });
    }
    await batch.commit();
  }

  /// true for owner, admin or moderator -- the "authorized" bar used
  /// throughout the Community spec (pin announcement, manage members,
  /// remove content, etc.). Admin / moderator are PROFILE ids: an
  /// account is privileged when one of its active profiles is in them.
  static bool isPrivileged(Map<String, dynamic> community, String uid) {
    if (uid.isEmpty) return false;
    if ((community['ownerUid'] ?? '').toString() == uid) return true;

    final admins = _strings(community['admins']);
    final moderators = _strings(community['moderators']);
    // Communities created before Profile IDs stored uids here.
    if (admins.contains(uid) || moderators.contains(uid)) return true;

    final idx = community['profileIndex'];
    if (idx is Map) {
      for (final e in idx.entries) {
        final entry = e.value;
        if (entry is Map &&
            (entry['uid'] ?? '').toString() == uid &&
            (admins.contains(e.key.toString()) ||
                moderators.contains(e.key.toString()))) {
          return true;
        }
      }
    }
    return false;
  }
}
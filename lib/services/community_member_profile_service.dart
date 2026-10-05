import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'user_profile_service.dart';

// ================================================================
// COMMUNITY MEMBER PROFILE SERVICE  (Profile-ID based)
// ----------------------------------------------------------------
// A community member is a MEMBER PROFILE, not a login account (UID).
// One account can hold several profiles in the same community --
// e.g. "Controller - Gokulvasan" and "Student - Gokulvasan" -- and
// every profile has its own Profile ID, name, password, role and
// role-specific details. They never share data.
//
//   communities/{cid}/memberProfiles/{profileId}
//     profileId      same as the doc id
//     uid            the login account that owns the profile (NOT the
//                    member identity -- only used for ownership/access)
//     role           Controller | Principal | HOD | Faculty |
//                    Student | Member
//     name           the name shown for this profile (own per profile)
//     identityKey    what makes the profile unique inside the role:
//                      'owner' | 'name:<Role>:<name key>' |
//                      'reg:<register number>' | 'student' | 'member'
//     identityName   staff: the exact name matched when joining
//     registerNumber / department / year   (students)
//     image
//     active         true while the profile is a member. Leaving keeps
//                    the profile (so its data + password stay separate)
//                    and only flips this to false.
//     createdAt / joinedAt / leftAt / removed
//
//   communities/{cid}
//     profileIndex   { <profileId>: { uid, role } }  active profiles
//                    only -- lets screens read roles without extra reads
//     admins / moderators   [profileId]  (Rep = a Student profile that
//                    is in one of these lists)
//     membersCount   number of ACTIVE member profiles
//     members        [uid]  account ACCESS list only (chat / feed /
//                    Firestore rules). An account is in it while it has
//                    at least one active profile.
//
//   users/{uid}.activeCommunityProfiles { <cid>: <profileId> }
//                    which of the account's profiles it is using now
// ================================================================
class CommunityMemberProfileService {
  CommunityMemberProfileService._();

  static final FirebaseFirestore _fs = FirebaseFirestore.instance;

  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  static CollectionReference<Map<String, dynamic>> profilesRef(String cid) =>
      _fs.collection('communities').doc(cid).collection('memberProfiles');

  // ==============================================================
  // ROLES
  // ==============================================================

  static const String roleController = 'Controller';
  static const String roleRep = 'Rep';
  static const String roleStudent = 'Student';
  static const String roleMember = 'Member';
  static const String rolePrincipal = 'Principal';
  static const String roleHod = 'HOD';
  static const String roleFaculty = 'Faculty';

  /// Roles a person picks (and is verified for) when joining as staff.
  static const List<String> staffRoles = [
    rolePrincipal,
    roleHod,
    roleFaculty,
    roleController,
  ];

  static int roleRank(String role) {
    switch (role) {
      case rolePrincipal:
        return 0;
      case roleController:
        return 1;
      case roleHod:
        return 2;
      case roleFaculty:
        return 3;
      case roleRep:
        return 4;
      case roleStudent:
        return 5;
      default:
        return 6;
    }
  }

  static List<String> _list(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : <String>[];

  static bool isActive(Map<String, dynamic> profile) =>
      profile['active'] != false;

  /// Role shown for a profile: its stored role, or Rep when a Student /
  /// Member profile was made a representative.
  static String effectiveRole(
    Map<String, dynamic> profile,
    Map<String, dynamic> community,
  ) {
    final role = (profile['role'] ?? '').toString().trim();
    final id = (profile['id'] ?? profile['profileId'] ?? '').toString();
    final base = role.isEmpty ? roleMember : role;
    if ((base == roleStudent || base == roleMember) && id.isNotEmpty) {
      if (_list(community['admins']).contains(id) ||
          _list(community['moderators']).contains(id)) {
        return roleRep;
      }
    }
    return base;
  }

  /// Role of one profile, read from the community doc's profileIndex.
  static String roleOfProfile(
      String profileId, Map<String, dynamic> community) {
    final idx = community['profileIndex'];
    final entry = idx is Map ? idx[profileId] : null;
    final role = entry is Map ? (entry['role'] ?? '').toString() : '';
    return effectiveRole({'id': profileId, 'role': role}, community);
  }

  /// Best role among the account's ACTIVE profiles, worked out from the
  /// community doc alone (used by screens that only know a uid).
  static String quickRole(String uid, Map<String, dynamic> community) {
    final idx = community['profileIndex'];
    if (uid.isNotEmpty && idx is Map) {
      String? best;
      idx.forEach((pid, entry) {
        if (entry is! Map) return;
        if ((entry['uid'] ?? '').toString() != uid) return;
        final role = effectiveRole(
            {'id': pid.toString(), 'role': (entry['role'] ?? '').toString()},
            community);
        if (best == null || roleRank(role) < roleRank(best!)) best = role;
      });
      if (best != null) return best!;
    }

    // Communities created before Profile IDs: old uid-based fields.
    if (uid.isNotEmpty && idx is! Map) {
      final chosen = community['memberRoles'];
      final ownerUid = (community['ownerUid'] ?? '').toString();
      final picked = chosen is Map ? (chosen[uid] ?? '').toString().trim() : '';
      if (uid == ownerUid) {
        return (staffRoles.contains(picked) || picked == roleStudent)
            ? picked
            : roleController;
      }
      if (staffRoles.contains(picked)) return picked;
      if (_list(community['admins']).contains(uid) ||
          _list(community['moderators']).contains(uid)) {
        return roleRep;
      }
    }
    return roleMember;
  }

  /// The name to show: the profile's name, or its role when the name is
  /// empty (e.g. "Principal", "Student").
  static String displayName(String name, String role) =>
      name.trim().isEmpty ? role : name.trim();

  /// Controller / Principal / HOD / Faculty profiles show no Skills or
  /// Contributions.
  static bool hidesExtras(String role) =>
      role == roleController ||
      role == rolePrincipal ||
      role == roleHod ||
      role == roleFaculty;

  // ==============================================================
  // READING PROFILES
  // ==============================================================

  static Map<String, dynamic> _withId(
          DocumentSnapshot<Map<String, dynamic>> d) =>
      {...?d.data(), 'id': d.id, 'profileId': d.id};

  static int _byRoleThenName(Map<String, dynamic> a, Map<String, dynamic> b,
      Map<String, dynamic> community) {
    final r = roleRank(effectiveRole(a, community))
        .compareTo(roleRank(effectiveRole(b, community)));
    if (r != 0) return r;
    return (a['name'] ?? '')
        .toString()
        .toLowerCase()
        .compareTo((b['name'] ?? '').toString().toLowerCase());
  }

  /// Every ACTIVE member profile of the community (live).
  static Stream<List<Map<String, dynamic>>> watchProfiles(String cid) {
    return profilesRef(cid).snapshots().map((s) => [
          for (final d in s.docs)
            if (isActive(d.data())) _withId(d),
        ]);
  }

  /// Every profile doc (active AND inactive) -- used to tell members of
  /// the old uid-based data (no profile yet) from people who left.
  static Stream<List<Map<String, dynamic>>> watchAllProfiles(String cid) {
    return profilesRef(cid)
        .snapshots()
        .map((s) => [for (final d in s.docs) _withId(d)]);
  }

  static Future<Map<String, dynamic>?> getProfile(
      String cid, String profileId) async {
    if (profileId.isEmpty) return null;
    final d = await profilesRef(cid).doc(profileId).get();
    return d.exists ? _withId(d) : null;
  }

  static Stream<Map<String, dynamic>?> watchProfile(
      String cid, String profileId) {
    return profilesRef(cid)
        .doc(profileId)
        .snapshots()
        .map((d) => d.exists ? _withId(d) : null);
  }

  /// The account's ACTIVE profiles in this community.
  static Future<List<Map<String, dynamic>>> loadMyProfiles(
      String cid, String uid) async {
    if (uid.isEmpty) return [];
    final q = await profilesRef(cid).where('uid', isEqualTo: uid).get();
    return [
      for (final d in q.docs)
        if (isActive(d.data())) _withId(d),
    ];
  }

  static Stream<List<Map<String, dynamic>>> watchMyProfiles(
      String cid, String uid) {
    return profilesRef(cid)
        .where('uid', isEqualTo: uid)
        .snapshots()
        .map((s) => [
              for (final d in s.docs)
                if (isActive(d.data())) _withId(d),
            ]);
  }

  static Future<String> _pointer(String cid, String uid) async {
    try {
      final u = await _fs.collection('users').doc(uid).get();
      final all = u.data()?['activeCommunityProfiles'];
      return all is Map ? (all[cid] ?? '').toString() : '';
    } catch (_) {
      return '';
    }
  }

  static Map<String, dynamic> _pickActive(
      List<Map<String, dynamic>> mine, String pointer) {
    for (final p in mine) {
      if (p['id'] == pointer) return p;
    }
    final copy = [...mine]..sort((a, b) =>
        roleRank((a['role'] ?? '').toString())
            .compareTo(roleRank((b['role'] ?? '').toString())));
    return copy.first;
  }

  /// The profile this account is using in the community right now:
  /// the one it chose last, else its highest-ranked active profile.
  /// null when the account has no active profile here.
  static Future<Map<String, dynamic>?> loadActiveProfile(
      String cid, String uid) async {
    final mine = await loadMyProfiles(cid, uid);
    if (mine.isEmpty) return null;
    return _pickActive(mine, await _pointer(cid, uid));
  }

  static Future<String> activeProfileId(String cid, String uid) async =>
      ((await loadActiveProfile(cid, uid))?['id'] ?? '').toString();

  /// Profile ID the signed-in account is acting as in [cid] right now,
  /// or '' when it can't be worked out. Never throws -- used to tag
  /// new posts / comments / uploads / check-ins with the profile that
  /// made them, so Contributions stay separate per Profile ID.
  static Future<String> currentProfileId(String cid) async {
    final uid = _uid;
    if (uid == null || uid.isEmpty || cid.isEmpty) return '';
    try {
      return await activeProfileId(cid, uid);
    } catch (_) {
      return '';
    }
  }

  /// Live pointer: the Profile ID the account chose as active in [cid]
  /// ('' when none was chosen yet).
  static Stream<String> watchActivePointer(String cid, String uid) {
    if (uid.isEmpty) return Stream.value('');
    return _fs.collection('users').doc(uid).snapshots().map((s) {
      final all = s.data()?['activeCommunityProfiles'];
      return all is Map ? (all[cid] ?? '').toString() : '';
    }).distinct();
  }

  /// Which of [mine] (the account's active profiles) is the active one,
  /// given the stored [pointer]. '' when [mine] is empty.
  static String pickActiveId(List<Map<String, dynamic>> mine, String pointer) {
    if (mine.isEmpty) return '';
    return (_pickActive(mine, pointer)['id'] ?? '').toString();
  }

  /// Live version of [loadActiveProfile] (re-runs when any of the
  /// account's profiles change).
  static Stream<Map<String, dynamic>?> watchActiveProfile(
      String cid, String uid) {
    return profilesRef(cid)
        .where('uid', isEqualTo: uid)
        .snapshots()
        .asyncMap((s) async {
      final mine = [
        for (final d in s.docs)
          if (isActive(d.data())) _withId(d),
      ];
      if (mine.isEmpty) return null;
      return _pickActive(mine, await _pointer(cid, uid));
    });
  }

  static Future<void> setActiveProfile(
      String cid, String uid, String profileId) async {
    if (uid.isEmpty || profileId.isEmpty) return;
    try {
      await _fs.collection('users').doc(uid).set({
        'activeCommunityProfiles': {cid: profileId},
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  /// Sorted copy for lists (role order, then name).
  static List<Map<String, dynamic>> sorted(
    List<Map<String, dynamic>> profiles,
    Map<String, dynamic> community,
  ) =>
      [...profiles]..sort((a, b) => _byRoleThenName(a, b, community));

  // ==============================================================
  // WRITING A PROFILE
  // ==============================================================

  /// Changes the name of ONE profile. Other profiles of the same
  /// account keep their own names. An empty name is allowed: the
  /// profile then shows its role (Student, Principal, ...) again.
  static Future<void> saveName(
      String communityDocId, String profileId, String name) async {
    final uid = _uid;
    if (uid == null) throw Exception('Please sign in again.');
    final clean = name.trim();

    final ref = profilesRef(communityDocId).doc(profileId);
    final snap = await ref.get();
    if (!snap.exists) throw Exception('This profile no longer exists.');
    if ((snap.data()?['uid'] ?? '').toString() != uid) {
      throw Exception('You can only edit your own profile.');
    }
    await ref.update({'name': clean});
  }

  // ==============================================================
  // SKILLS  (own list per Profile ID)
  // --------------------------------------------------------------
  // Stored on the profile doc (memberProfiles/{profileId}.skills), NOT on
  // the login account, so "Student 711225205015" and "Student
  // 711225205016" of the same account never share skills.
  // ==============================================================

  /// Skills stored on this profile, or null when it never had any saved.
  static List<String>? skillsOf(Map<String, dynamic> profile) {
    final raw = profile['skills'];
    if (raw is! List) return null;
    return UserProfileService.normalizeSkills(raw.map((e) => e.toString()));
  }

  /// Skills of one profile. Old data kept the skills on the account
  /// (users/{uid}.publicSkills); that list is only used while the
  /// account has a SINGLE profile (so it is unambiguous) and the profile
  /// has no list of its own yet.
  static Future<List<String>> resolveSkills(
      String cid, Map<String, dynamic> profile) async {
    final own = skillsOf(profile);
    if (own != null) return own;

    final uid = (profile['uid'] ?? '').toString();
    if (uid.isEmpty) return <String>[];
    try {
      final mine =
          await profilesRef(cid).where('uid', isEqualTo: uid).limit(2).get();
      if (mine.docs.length > 1) return <String>[];
      final u = await _fs.collection('users').doc(uid).get();
      final raw = u.data()?['publicSkills'];
      return raw is List
          ? UserProfileService.normalizeSkills(raw.map((e) => e.toString()))
          : <String>[];
    } catch (_) {
      return <String>[];
    }
  }

  static Future<List<String>> loadSkills(String cid, String profileId) async {
    final p = await getProfile(cid, profileId);
    if (p == null) return <String>[];
    return resolveSkills(cid, p);
  }

  static Future<List<String>> saveSkills(
      String cid, String profileId, List<String> skills) async {
    final uid = _uid;
    if (uid == null) throw Exception('Please sign in again.');
    final ref = profilesRef(cid).doc(profileId);
    final snap = await ref.get();
    if (!snap.exists) throw Exception('This profile no longer exists.');
    if ((snap.data()?['uid'] ?? '').toString() != uid) {
      throw Exception('You can only edit your own profile.');
    }
    final clean = UserProfileService.normalizeSkills(skills);
    await ref.update({'skills': clean});
    return clean;
  }

  /// One-time, best-effort: an account with exactly ONE profile moves its
  /// old account-level skills onto that profile, so nothing is lost.
  static Future<void> adoptLegacySkills(String cid, String uid) async {
    if (uid.isEmpty) return;
    try {
      final mine =
          await profilesRef(cid).where('uid', isEqualTo: uid).limit(2).get();
      if (mine.docs.length != 1) return;
      final doc = mine.docs.first;
      if (doc.data()['skills'] is List) return;
      final u = await _fs.collection('users').doc(uid).get();
      final raw = u.data()?['publicSkills'];
      if (raw is! List || raw.isEmpty) return;
      await doc.reference.update({
        'skills':
            UserProfileService.normalizeSkills(raw.map((e) => e.toString())),
      });
    } catch (_) {}
  }

  // ==============================================================
  // COMMUNITIES CREATED / JOINED BEFORE PROFILE IDs
  // ==============================================================

  /// One-time, best-effort: an account that is already a member through
  /// the old uid-based data gets its member profile created from that
  /// data (role, name, class details), so nothing is lost.
  static Future<void> ensureMyProfile(
      String communityDocId, Map<String, dynamic> community) async {
    final uid = _uid;
    if (uid == null || uid.isEmpty) return;
    if (!_list(community['members']).contains(uid)) return;
    // Communities already on Profile IDs only need this when the account
    // truly has no profile (checked below).

    try {
      final mine = await profilesRef(communityDocId)
          .where('uid', isEqualTo: uid)
          .limit(1)
          .get();
      if (mine.docs.isNotEmpty) return;

      final ref = _fs.collection('communities').doc(communityDocId);
      var role = quickRole(uid, community);
      if (role == roleRep) role = roleStudent;

      var name = '';
      var department = '';
      var year = '';
      var register = '';
      var identityName = '';

      try {
        final u = await _fs.collection('users').doc(uid).get();
        final all = u.data()?['communityProfiles'];
        final old = all is Map ? all[communityDocId] : null;
        if (old is Map) name = (old['name'] ?? '').toString().trim();
      } catch (_) {}

      try {
        final s = await ref.collection('students').doc(uid).get();
        if (s.exists) {
          final d = s.data() ?? {};
          department = (d['department'] ?? '').toString();
          year = (d['year'] ?? '').toString();
          register = (d['registerNumber'] ?? '').toString();
          if (role == roleMember) role = roleStudent;
        }
      } catch (_) {}

      try {
        final st = await ref
            .collection('staff')
            .where('uid', isEqualTo: uid)
            .limit(1)
            .get();
        if (st.docs.isNotEmpty) {
          final d = st.docs.first.data();
          final r = (d['role'] ?? '').toString();
          if (staffRoles.contains(r)) role = r;
          identityName = (d['name'] ?? '').toString();
        }
      } catch (_) {}

      final ownerUid = (community['ownerUid'] ?? '').toString();
      final String identityKey;
      if (uid == ownerUid && role == roleController) {
        identityKey = 'owner';
      } else if (staffRoles.contains(role) && identityName.isNotEmpty) {
        final key =
            identityName.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        identityKey = 'name:$role:$key';
      } else if (role == roleStudent && register.isNotEmpty) {
        identityKey = 'reg:$register';
      } else {
        identityKey = role == roleStudent ? 'student' : 'member';
      }

      final profileRef = profilesRef(communityDocId).doc();
      final oldMod = _list(community['moderators']).contains(uid);
      final oldAdmin = _list(community['admins']).contains(uid);

      final batch = _fs.batch();
      batch.set(profileRef, {
        'profileId': profileRef.id,
        'uid': uid,
        'role': role,
        'name': name,
        'identityKey': identityKey,
        'identityName': identityName,
        'registerNumber': register,
        'department': department,
        'year': year,
        'image': '',
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
        'joinedAt': FieldValue.serverTimestamp(),
      });
      batch.update(ref, {
        'profileIndex.${profileRef.id}': {'uid': uid, 'role': role},
        // Old Rep assignments were stored by uid -> move them to the profile.
        if (oldMod) 'moderators': FieldValue.arrayRemove([uid]),
        if (oldAdmin) 'admins': FieldValue.arrayRemove([uid]),
      });
      await batch.commit();

      // arrayRemove + arrayUnion on one field can't share a write.
      if (oldMod || oldAdmin) {
        await ref.update({
          if (oldMod) 'moderators': FieldValue.arrayUnion([profileRef.id]),
          if (oldAdmin) 'admins': FieldValue.arrayUnion([profileRef.id]),
        });
      }

      await setActiveProfile(communityDocId, uid, profileRef.id);
    } catch (_) {}
  }
}
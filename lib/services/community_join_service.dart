import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/community_join_password_service.dart';
import '../services/community_member_profile_service.dart';
import '../services/community_service.dart';

// ================================================================
// COMMUNITY JOIN REQUIREMENTS -- DATA MODEL + SERVICE (Phase 2)
// ----------------------------------------------------------------
// Firestore layout (all under the existing communities/{id} doc):
//
//   communities/{id}
//     departments: [ 'CSE', 'IT', ... ]          (optional, owner-set)
//     roleNames: { Principal: [..], HOD: [..],    (optional, owner-set) the
//                  Faculty: [..], Controller: [..] }  name(s) a person must
//                                                 enter when joining with
//                                                 that role. Kept on the
//                                                 community doc so it is
//                                                 readable by joiners with
//                                                 no extra Firestore rules.
//
//   communities/{id}/memberProfiles/{profileId}   (written on join)
//     One MEMBER PROFILE per role / identity -- joining never uses the
//     login account (UID) as the member identity. The same account can
//     join with Controller, then Student, ... and each gets its own
//     profile (Profile ID, name, password, class details).
//     uid, role, name, identityKey, identityName, registerNumber,
//     department, year, image, active, joinedAt
//     (see community_member_profile_service.dart)
//
//   communities/{id}/joinRequirements/{dept}__{year}
//     department, year
//     requiredField        'registerNumber'
//     rangeStart/rangeEnd  String digits, or '' when no range is set
//     disabledNumbers      [String]  never allowed to join
//     extraAllowedNumbers  [String]  allowed even if outside the range
//     updatedAt, updatedBy
//
// Only the community owner may change any of this. The rules below
// are enforced here in the service; add matching Firestore security
// rules too if the project locks writes down server-side.
// ================================================================

/// Result of checking one register number against a year's rules.
enum JoinCheckStatus {
  allowed,
  empty,
  notNumeric,
  disabled,
  outOfRange,

  /// The owner has not set any allowed numbers (range / extra allowed)
  /// for this class, so nobody can join it yet.
  notConfigured,
}

class JoinCheckResult {
  final JoinCheckStatus status;

  const JoinCheckResult(this.status);

  bool get allowed => status == JoinCheckStatus.allowed;

  /// Message safe to show directly to the student.
  String get message {
    switch (status) {
      case JoinCheckStatus.allowed:
        return 'Register number accepted.';
      case JoinCheckStatus.empty:
        return 'Please enter your register number.';
      case JoinCheckStatus.notNumeric:
        return 'Register number must contain numbers only.';
      case JoinCheckStatus.disabled:
        return 'This register number is not allowed to join.';
      case JoinCheckStatus.outOfRange:
        return 'This register number is not permitted for this class.';
      case JoinCheckStatus.notConfigured:
        return 'Join requirements are not set for this class yet. '
            'Please contact the community owner.';
    }
  }
}

class JoinRequirements {
  final String department;
  final String year;
  final String requiredField;
  final String rangeStart;
  final String rangeEnd;
  final List<String> disabledNumbers;
  final List<String> extraAllowedNumbers;

  const JoinRequirements({
    required this.department,
    required this.year,
    this.requiredField = 'registerNumber',
    this.rangeStart = '',
    this.rangeEnd = '',
    this.disabledNumbers = const [],
    this.extraAllowedNumbers = const [],
  });

  bool get hasRange => rangeStart.isNotEmpty && rangeEnd.isNotEmpty;

  factory JoinRequirements.empty(String department, String year) =>
      JoinRequirements(department: department, year: year);

  factory JoinRequirements.fromMap(
    Map<String, dynamic>? data, {
    required String department,
    required String year,
  }) {
    if (data == null) return JoinRequirements.empty(department, year);

    List<String> strings(dynamic v) => v is List
        ? v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    return JoinRequirements(
      department: department,
      year: year,
      requiredField: (data['requiredField'] ?? 'registerNumber').toString(),
      rangeStart: (data['rangeStart'] ?? '').toString(),
      rangeEnd: (data['rangeEnd'] ?? '').toString(),
      disabledNumbers: strings(data['disabledNumbers']),
      extraAllowedNumbers: strings(data['extraAllowedNumbers']),
    );
  }

  /// Checks a register number against these rules.
  /// Priority: empty/non-numeric -> disabled (always wins) -> extra
  /// allowed -> range. A register number is accepted ONLY when it is in
  /// the range or in the extra-allowed list. If the owner has set
  /// neither for this class, nobody can join it (join requirements
  /// must be satisfied -- they are never skipped).
  JoinCheckResult check(String input) {
    final number = input.trim();
    if (number.isEmpty) return const JoinCheckResult(JoinCheckStatus.empty);
    if (!CommunityJoinService.isDigitsOnly(number)) {
      return const JoinCheckResult(JoinCheckStatus.notNumeric);
    }
    if (disabledNumbers.contains(number)) {
      return const JoinCheckResult(JoinCheckStatus.disabled);
    }
    if (extraAllowedNumbers.contains(number)) {
      return const JoinCheckResult(JoinCheckStatus.allowed);
    }
    if (hasRange) {
      final n = BigInt.tryParse(number);
      final lo = BigInt.tryParse(rangeStart);
      final hi = BigInt.tryParse(rangeEnd);
      if (n == null || lo == null || hi == null) {
        return const JoinCheckResult(JoinCheckStatus.outOfRange);
      }
      final inRange = n >= lo && n <= hi && number.length == rangeStart.length;
      if (!inRange) return const JoinCheckResult(JoinCheckStatus.outOfRange);
      return const JoinCheckResult(JoinCheckStatus.allowed);
    }
    // No range and not in the extra-allowed list.
    if (extraAllowedNumbers.isEmpty) {
      return const JoinCheckResult(JoinCheckStatus.notConfigured);
    }
    return const JoinCheckResult(JoinCheckStatus.outOfRange);
  }
}

/// Roles (other than Student) a person can join with.
const List<String> kStaffRoles = ['Principal', 'HOD', 'Faculty', 'Controller'];

/// What a person can choose when joining a community.
class JoinOptions {
  /// The owner has set join requirements for at least one class.
  final bool hasStudentRules;

  /// Staff roles that have at least one name set by the owner.
  final List<String> roles;

  const JoinOptions({required this.hasStudentRules, required this.roles});

  bool get isEmpty => !hasStudentRules && roles.isEmpty;
}

class CommunityJoinService {
  CommunityJoinService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  static DocumentReference<Map<String, dynamic>> _community(String id) =>
      _firestore.collection('communities').doc(id);

  static bool isDigitsOnly(String value) =>
      value.isNotEmpty && RegExp(r'^[0-9]+$').hasMatch(value);

  /// Stable doc id for one department + year, e.g. "CSE__1st_Year".
  static String requirementDocId(String department, String year) {
    String clean(String s) =>
        s.trim().replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    return '${clean(department)}__${clean(year)}';
  }

  static DocumentReference<Map<String, dynamic>> _requirementRef(
    String communityDocId,
    String department,
    String year,
  ) =>
      _community(communityDocId)
          .collection('joinRequirements')
          .doc(requirementDocId(department, year));

  /// True when the signed-in user owns this community.
  static Future<bool> isOwner(String communityDocId) async {
    final snap = await _community(communityDocId).get();
    return (snap.data()?['ownerUid'] ?? '').toString() == _uid && _uid.isNotEmpty;
  }

  static Future<void> _requireOwner(String communityDocId) async {
    if (!await isOwner(communityDocId)) {
      throw Exception('Only the community owner can change join requirements.');
    }
  }

  // ---------------- reading ----------------

  static Stream<JoinRequirements> watchRequirements(
    String communityDocId,
    String department,
    String year,
  ) {
    return _requirementRef(communityDocId, department, year)
        .snapshots()
        .map((s) => JoinRequirements.fromMap(
              s.data(),
              department: department,
              year: year,
            ));
  }

  static Future<JoinRequirements> getRequirements(
    String communityDocId,
    String department,
    String year,
  ) async {
    final snap =
        await _requirementRef(communityDocId, department, year).get();
    return JoinRequirements.fromMap(
      snap.data(),
      department: department,
      year: year,
    );
  }

  // ---------------- writing (owner only) ----------------

  /// Creates the requirement doc if missing and sets the required field.
  static Future<void> setRequiredField(
    String communityDocId,
    String department,
    String year,
    String field,
  ) async {
    await _requireOwner(communityDocId);
    await _requirementRef(communityDocId, department, year).set({
      'department': department,
      'year': year,
      'requiredField': field,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': _uid,
    }, SetOptions(merge: true));
  }

  /// Sets the allowed register-number range. Both ends must be digits
  /// of the same length and start <= end. Pass empty strings to clear.
  static Future<void> setRange(
    String communityDocId,
    String department,
    String year, {
    required String start,
    required String end,
  }) async {
    await _requireOwner(communityDocId);
    final s = start.trim();
    final e = end.trim();

    if (s.isNotEmpty || e.isNotEmpty) {
      if (!isDigitsOnly(s) || !isDigitsOnly(e)) {
        throw Exception('Range values must contain numbers only.');
      }
      if (s.length != e.length) {
        throw Exception('Range start and end must have the same length.');
      }
      if (BigInt.parse(s) > BigInt.parse(e)) {
        throw Exception('Range start must not be greater than range end.');
      }
    }

    await _requirementRef(communityDocId, department, year).set({
      'department': department,
      'year': year,
      'rangeStart': s,
      'rangeEnd': e,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': _uid,
    }, SetOptions(merge: true));
  }

  static Future<void> addDisabledNumber(
    String communityDocId,
    String department,
    String year,
    String number,
  ) =>
      _changeList(communityDocId, department, year,
          field: 'disabledNumbers', number: number, add: true);

  static Future<void> removeDisabledNumber(
    String communityDocId,
    String department,
    String year,
    String number,
  ) =>
      _changeList(communityDocId, department, year,
          field: 'disabledNumbers', number: number, add: false);

  static Future<void> addExtraAllowedNumber(
    String communityDocId,
    String department,
    String year,
    String number,
  ) =>
      _changeList(communityDocId, department, year,
          field: 'extraAllowedNumbers', number: number, add: true);

  static Future<void> removeExtraAllowedNumber(
    String communityDocId,
    String department,
    String year,
    String number,
  ) =>
      _changeList(communityDocId, department, year,
          field: 'extraAllowedNumbers', number: number, add: false);

  static Future<void> _changeList(
    String communityDocId,
    String department,
    String year, {
    required String field,
    required String number,
    required bool add,
  }) async {
    await _requireOwner(communityDocId);
    final n = number.trim();
    if (!isDigitsOnly(n)) {
      throw Exception('Register number must contain numbers only.');
    }

    // A number cannot be both disabled and extra-allowed.
    final other =
        field == 'disabledNumbers' ? 'extraAllowedNumbers' : 'disabledNumbers';

    await _requirementRef(communityDocId, department, year).set({
      'department': department,
      'year': year,
      field: add ? FieldValue.arrayUnion([n]) : FieldValue.arrayRemove([n]),
      if (add) other: FieldValue.arrayRemove([n]),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': _uid,
    }, SetOptions(merge: true));
  }

  // ---------------- joining (students) ----------------

  /// True when the join sheet must ask something before joining: the
  /// owner set a class's join requirements (department, year, register
  /// number) and/or a name for a staff role. Communities with no
  /// requirements are joined straight away.
  static Future<bool> requiresRegistration(
    String communityDocId,
    Map<String, dynamic> community,
  ) async {
    final options = await joinOptions(communityDocId);
    return !options.isEmpty;
  }

  /// What the join sheet should offer: whether classes have join
  /// requirements, and which staff roles have a name set.
  static Future<JoinOptions> joinOptions(String communityDocId) async {
    final classes = await _community(communityDocId)
        .collection('joinRequirements')
        .limit(1)
        .get();

    final community = await _community(communityDocId).get();
    final withNames = <String>{
      for (final r in kStaffRoles)
        if (_namesFrom(community.data(), r).isNotEmpty) r,
    };

    return JoinOptions(
      hasStudentRules: classes.docs.isNotEmpty,
      roles: [for (final r in kStaffRoles) if (withNames.contains(r)) r],
    );
  }

  // ---------------- role names (Principal / HOD / Faculty / Controller) ----

  /// Lower-cased, trimmed, single-spaced -- how names are compared.
  static String nameKey(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Names set for [role] on the community doc (`roleNames.<role>`).
  static List<String> _namesFrom(Map<String, dynamic>? community, String role) {
    final all = community?['roleNames'];
    final raw = all is Map ? all[role] : null;
    return raw is List
        ? raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
        : <String>[];
  }

  static Stream<List<String>> watchRoleNames(
    String communityDocId,
    String role,
  ) =>
      _community(communityDocId)
          .snapshots()
          .map((s) => _namesFrom(s.data(), role));

  static Future<List<String>> getRoleNames(
    String communityDocId,
    String role,
  ) async {
    final snap = await _community(communityDocId).get();
    return _namesFrom(snap.data(), role);
  }

  /// Owner only: allows [name] to join with [role].
  static Future<void> addRoleName(
    String communityDocId,
    String role,
    String name,
  ) async {
    await _requireOwner(communityDocId);
    if (!kStaffRoles.contains(role)) throw Exception('Unknown role.');
    final clean = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty) throw Exception('Please enter a name.');

    final existing = await getRoleNames(communityDocId, role);
    if (existing.any((n) => nameKey(n) == nameKey(clean))) {
      throw Exception('This name is already added.');
    }

    await _community(communityDocId).update({
      'roleNames.$role': FieldValue.arrayUnion([clean]),
    });
  }

  /// Owner only: removes a name set with [addRoleName].
  static Future<void> removeRoleName(
    String communityDocId,
    String role,
    String name,
  ) async {
    await _requireOwner(communityDocId);
    await _community(communityDocId).update({
      'roleNames.$role': FieldValue.arrayRemove([name]),
    });
  }

  // ---------------- join password (set on the member profile) ----------------

  /// Does this ACCOUNT already have an ACTIVE profile with this exact
  /// role + identity? Then it is the same member -> never asked for the
  /// password again.
  static Future<bool> _hasActiveIdentity(
    String communityDocId,
    String uid,
    String role,
    String identityKey,
  ) async {
    try {
      final q = await CommunityMemberProfileService.profilesRef(communityDocId)
          .where('uid', isEqualTo: uid)
          .get();
      return q.docs.any((d) {
        final p = d.data();
        return p['active'] != false &&
            (p['role'] ?? '').toString() == role &&
            (p['identityKey'] ?? '').toString() == identityKey;
      });
    } catch (_) {
      return false;
    }
  }

  /// ACTIVE profiles of OTHER accounts that already use this identity.
  static Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _takenBy(
    String communityDocId,
    String uid,
    String role,
    String identityKey,
  ) async {
    try {
      final q = await CommunityMemberProfileService.profilesRef(communityDocId)
          .where('identityKey', isEqualTo: identityKey)
          .get();
      return q.docs.where((d) {
        final p = d.data();
        return p['active'] != false &&
            (p['role'] ?? '').toString() == role &&
            (p['uid'] ?? '').toString() != uid;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// null = no password needed (or the right one was given: [verified]
  /// is set). Otherwise the failed-join result that makes the join
  /// sheet ask for the password.
  static Future<Map<String, dynamic>?> _passwordGate({
    required String communityDocId,
    required String uid,
    required String role,
    required String identityKey,
    required String lockKey,
    required String password,
    required String what, // 'register number' / 'name'
    required void Function() onVerified,
  }) async {
    if (await _hasActiveIdentity(communityDocId, uid, role, identityKey)) {
      return null;
    }
    final status =
        await CommunityJoinPasswordService.statusFor(communityDocId, lockKey);
    if (status == JoinLockStatus.none) return null;

    if (password.isEmpty) {
      return {
        'success': false,
        'needsPassword': true,
        'message': 'This $what is protected with a password.',
      };
    }
    final ok = await CommunityJoinPasswordService.verify(
        communityDocId, lockKey, password);
    if (!ok) {
      return {
        'success': false,
        'needsPassword': true,
        'wrongPassword': true,
        'message': 'Wrong password.',
      };
    }
    onVerified();
    return null;
  }

  /// After a join made with the password: the older record of this
  /// register number / name (another account, or an earlier profile) is
  /// replaced, and the NEW profile owns the password.
  static Future<void> _takeOver({
    required String communityDocId,
    required String lockKey,
    required String profileId,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> others,
  }) async {
    for (final d in others) {
      if (d.id == profileId) continue;
      try {
        await CommunityService.deactivateProfile(
          communityDocId: communityDocId,
          profileId: d.id,
          removed: true,
        );
      } catch (_) {}
    }
    await CommunityJoinPasswordService.claim(
        communityDocId, lockKey, profileId);
  }

  /// Joins with a staff role. The typed [name] must match a name the
  /// owner set for [role]. Creates (or re-activates) the member profile
  /// for this role. Returns the same shape as
  /// CommunityService.joinWithProfile: {success, message?, profileId, ...}.
  static Future<Map<String, dynamic>> joinAsRole({
    required String communityDocId,
    required String role,
    required String name,
    String password = '',
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return {'success': false, 'message': 'Please sign in first.'};
    }
    if (!kStaffRoles.contains(role)) {
      return {'success': false, 'message': 'Please select a valid role.'};
    }

    final entered = name.trim();
    if (entered.isEmpty) {
      return {'success': false, 'message': 'Please enter your name.'};
    }

    final names = await getRoleNames(communityDocId, role);
    if (names.isEmpty) {
      return {
        'success': false,
        'message': 'No name has been set for $role in this community.',
      };
    }

    final key = nameKey(entered);
    String? matched;
    for (final n in names) {
      if (nameKey(n) == key) matched = n;
    }
    if (matched == null) {
      return {
        'success': false,
        'message': 'This name is not permitted for $role.',
      };
    }

    final identityKey = 'name:$role:$key';

    // A password set on this name (from the profile) is asked first --
    // for the same person rejoining and for anybody else typing it.
    final lockKey = CommunityJoinPasswordService.nameKey(role, entered);
    var verified = false;
    final gate = await _passwordGate(
      communityDocId: communityDocId,
      uid: user.uid,
      role: role,
      identityKey: identityKey,
      lockKey: lockKey,
      password: password,
      what: 'name',
      onVerified: () => verified = true,
    );
    if (gate != null) return gate;

    // One name can belong to only one member profile.
    final others =
        await _takenBy(communityDocId, user.uid, role, identityKey);
    if (others.isNotEmpty && !verified) {
      return {
        'success': false,
        'message': 'This name has already been used to join.',
      };
    }

    final joined = await CommunityService.joinWithProfile(
      communityDocId: communityDocId,
      uid: user.uid,
      role: role,
      identityKey: identityKey,
      identityName: matched,
      // name stays empty: the member sets it on their profile (until then
      // the role is shown in grey).
    );
    if (joined['success'] != true) return joined;

    if (verified) {
      await _takeOver(
        communityDocId: communityDocId,
        lockKey: lockKey,
        profileId: (joined['profileId'] ?? '').toString(),
        others: others,
      );
    }

    return joined;
  }

  /// Student in a community that only set staff names (no class rules):
  /// joins straight away with a Student profile, so the tag is "Student"
  /// rather than "Member".
  static Future<Map<String, dynamic>> joinAsPlainStudent({
    required String communityDocId,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return {'success': false, 'message': 'Please sign in first.'};
    }

    // Plain join is ONLY for communities with no class join
    // requirements. If the owner set any, the student must enter a
    // register number that satisfies them (joinAsStudent).
    final rules = await _community(communityDocId)
        .collection('joinRequirements')
        .limit(1)
        .get();
    if (rules.docs.isNotEmpty) {
      return {
        'success': false,
        'message': 'This community has join requirements. '
            'Select your department and year and enter your register number.',
      };
    }

    // A Student profile of its own -- never merged with this account's
    // Controller / staff profiles in the same community.
    return CommunityService.joinWithProfile(
      communityDocId: communityDocId,
      uid: user.uid,
      role: CommunityMemberProfileService.roleStudent,
      identityKey: 'student',
    );
  }

  /// Validates the register number against the class's rules, then
  /// creates (or re-activates) the Student member profile. Returns the
  /// same shape as CommunityService.joinWithProfile:
  /// {success, message?, alreadyMember?, profileId?, groupDocId?}.
  static Future<Map<String, dynamic>> joinAsStudent({
    required String communityDocId,
    required String department,
    required String year,
    required String registerNumber,
    String password = '',
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return {'success': false, 'message': 'Please sign in first.'};
    }

    final number = registerNumber.trim();
    final requirements =
        await getRequirements(communityDocId, department, year);

    final result = requirements.check(number);
    if (!result.allowed) {
      return {'success': false, 'message': result.message};
    }

    const role = CommunityMemberProfileService.roleStudent;
    final identityKey = 'reg:$number';

    // A password set on this register number (from the profile) is asked
    // first -- for the same person rejoining and for anybody else.
    final lockKey = CommunityJoinPasswordService.regKey(number);
    var verified = false;
    final gate = await _passwordGate(
      communityDocId: communityDocId,
      uid: user.uid,
      role: role,
      identityKey: identityKey,
      lockKey: lockKey,
      password: password,
      what: 'register number',
      onVerified: () => verified = true,
    );
    if (gate != null) return gate;

    // One register number can belong to only one member profile.
    final others =
        await _takenBy(communityDocId, user.uid, role, identityKey);
    if (others.isNotEmpty && !verified) {
      return {
        'success': false,
        'message': 'This register number has already been used to join.',
      };
    }

    final joined = await CommunityService.joinWithProfile(
      communityDocId: communityDocId,
      uid: user.uid,
      role: role,
      identityKey: identityKey,
      registerNumber: number,
      department: department,
      year: year,
    );
    if (joined['success'] != true) return joined;

    if (verified) {
      await _takeOver(
        communityDocId: communityDocId,
        lockKey: lockKey,
        profileId: (joined['profileId'] ?? '').toString(),
        others: others,
      );
    }

    return joined;
  }

  // ---------------- departments + staff (owner only) ----------------

  static Future<void> setDepartments(
    String communityDocId,
    List<String> departments,
  ) async {
    await _requireOwner(communityDocId);
    final cleaned = departments
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    await _community(communityDocId).update({'departments': cleaned});
  }
}
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/community_service.dart';

// ================================================================
// COMMUNITY JOIN REQUIREMENTS -- DATA MODEL + SERVICE (Phase 2)
// ----------------------------------------------------------------
// Firestore layout (all under the existing communities/{id} doc):
//
//   communities/{id}
//     departments: [ 'CSE', 'IT', ... ]          (optional, owner-set)
//
//   communities/{id}/staff/{autoId}
//     name, role (Principal | HOD | Faculty), department, image
//
//   communities/{id}/students/{uid}               (written on join, Phase 5)
//     uid, name, registerNumber, department, year, image, joinedAt
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
  /// allowed -> range (if one is set). With no range set, any valid
  /// numeric register number is accepted.
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
    }
    return const JoinCheckResult(JoinCheckStatus.allowed);
  }
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

  /// True when a student must give department, year and register number
  /// to join: any community whose owner has set up at least one class's
  /// join requirements (Normal or College). Communities with no
  /// requirements are joined straight away.
  static Future<bool> requiresRegistration(
    String communityDocId,
    Map<String, dynamic> community,
  ) async {
    final snap = await _community(communityDocId)
        .collection('joinRequirements')
        .limit(1)
        .get();
    return snap.docs.isNotEmpty;
  }

  /// Validates the register number against the class's rules, then
  /// joins the community and records the student. Returns the same
  /// shape as CommunityService.joinCommunity:
  /// {success, message?, alreadyMember?, groupDocId?}.
  static Future<Map<String, dynamic>> joinAsStudent({
    required String communityDocId,
    required String department,
    required String year,
    required String registerNumber,
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

    // One register number can belong to only one account.
    final duplicate = await _community(communityDocId)
        .collection('students')
        .where('registerNumber', isEqualTo: number)
        .limit(1)
        .get();
    if (duplicate.docs.isNotEmpty && duplicate.docs.first.id != user.uid) {
      return {
        'success': false,
        'message': 'This register number has already been used to join.',
      };
    }

    final joined = await CommunityService.joinCommunity(
      communityDocId: communityDocId,
      uid: user.uid,
    );
    if (joined['success'] != true) return joined;

    final profile = await _firestore.collection('users').doc(user.uid).get();
    final data = profile.data() ?? {};

    await _community(communityDocId)
        .collection('students')
        .doc(user.uid)
        .set({
      'uid': user.uid,
      'name': (data['publicName'] ?? '').toString(),
      'image': (data['publicImage'] ?? '').toString(),
      'registerNumber': number,
      'department': department,
      'year': year,
      'joinedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

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

  static Future<void> addStaff(
    String communityDocId, {
    required String name,
    required String role, // Principal | HOD | Faculty
    String department = '',
    String image = '',
  }) async {
    await _requireOwner(communityDocId);
    if (name.trim().isEmpty) throw Exception('Name is required.');
    await _community(communityDocId).collection('staff').add({
      'name': name.trim(),
      'role': role,
      'department': department.trim(),
      'image': image,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> removeStaff(
    String communityDocId,
    String staffDocId,
  ) async {
    await _requireOwner(communityDocId);
    await _community(communityDocId)
        .collection('staff')
        .doc(staffDocId)
        .delete();
  }
}
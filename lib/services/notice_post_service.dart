import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_member_profile_service.dart';
import 'community_service.dart';

// ================================================================
// NOTICE POST SERVICE
// ----------------------------------------------------------------
// Posts made straight onto the Community Notice Board (the "post"
// icon next to the eye icon). One Firestore doc per post in the
// top-level 'noticePosts' collection:
//
//   communityDocId, authorUid, authorName, authorAvatarUrl
//   type        'text' | 'text_image' | 'image' | 'video' | 'video_text'
//   title, text
//   mediaUrl    hosted image / video URL ('' for text-only)
//   mediaType   'image' | 'video' | ''
//   audiences   [ NoticeAudience.* ]   (multi-select)
//   departments [ 'CSE', 'IT', ... ]   (used by the department audiences)
//   years       [ '1st Year', ... ]    (used by the year audiences)
//   endAt       Timestamp  -> after this time the post is no longer shown
//   createdAt   server timestamp
// ================================================================

class NoticePostType {
  NoticePostType._();

  static const String text = 'text';
  static const String textImage = 'text_image';
  static const String image = 'image';
  static const String video = 'video';
  static const String videoText = 'video_text';

  static const List<String> all = [text, textImage, image, video, videoText];

  static String label(String t) {
    switch (t) {
      case text:
        return 'Text only';
      case textImage:
        return 'Text with image';
      case image:
        return 'Image only';
      case video:
        return 'Video only';
      case videoText:
        return 'Video with text';
      default:
        return t;
    }
  }

  static bool hasText(String t) =>
      t == text || t == textImage || t == videoText;
  static bool hasImage(String t) => t == textImage || t == image;
  static bool hasVideo(String t) => t == video || t == videoText;
}

class NoticeAudience {
  NoticeAudience._();

  static const String community = 'community';
  static const String specificDepartment = 'specific_department';
  static const String entireDepartment = 'entire_department';
  static const String specificYear = 'specific_year';
  static const String departmentYear = 'department_year';
  static const String faculty = 'faculty';
  static const String students = 'students';
  static const String hod = 'hod';

  static const List<String> all = [
    community,
    specificDepartment,
    entireDepartment,
    specificYear,
    departmentYear,
    faculty,
    students,
    hod,
  ];

  static String label(String k) {
    switch (k) {
      case community:
        return 'Entire Community';
      case specificDepartment:
        return 'Specific Department';
      case entireDepartment:
        return 'Entire Department';
      case specificYear:
        return 'Specific Year';
      case departmentYear:
        return 'Specific Department with Year';
      case faculty:
        return 'Faculty only';
      case students:
        return 'Students only';
      case hod:
        return 'HOD only';
      default:
        return k;
    }
  }

  static bool needsDepartments(Iterable<String> kinds) => kinds.any(
      (k) => k == specificDepartment || k == entireDepartment || k == departmentYear);

  static bool needsYears(Iterable<String> kinds) =>
      kinds.any((k) => k == specificYear || k == departmentYear);
}

/// Who the signed-in member is inside one community (for audience checks).
class NoticeViewer {
  final String role; // Student / Faculty / HOD / Principal / Controller / Rep / Member
  final String department;
  final String year;

  const NoticeViewer({
    this.role = CommunityMemberProfileService.roleMember,
    this.department = '',
    this.year = '',
  });

  static const NoticeViewer unknown = NoticeViewer();
}

class NoticePostService {
  NoticePostService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _posts =>
      _firestore.collection('noticePosts');

  // ==========================================================
  // WHO CAN POST
  // ==========================================================

  /// Community owner / admins / moderators and members who joined as
  /// Principal, HOD, Faculty or Controller.
  static bool canPost(Map<String, dynamic> community, String uid) {
    if (uid.isEmpty) return false;
    if (CommunityService.isPrivileged(community, uid)) return true;
    final role = CommunityMemberProfileService.quickRole(uid, community);
    return CommunityMemberProfileService.staffRoles.contains(role);
  }

  // ==========================================================
  // CREATE / DELETE
  // ==========================================================

  static Future<String> createPost({
    required String communityDocId,
    required String authorUid,
    required String authorName,
    required String authorAvatarUrl,
    required String type,
    required String title,
    required String text,
    required String mediaUrl,
    required List<String> audiences,
    required List<String> departments,
    required List<String> years,
    required DateTime endAt,
  }) async {
    if (!NoticePostType.all.contains(type)) {
      throw Exception('Unknown post type.');
    }
    if (!endAt.isAfter(DateTime.now())) {
      throw Exception('The end time must be in the future.');
    }
    final kinds = audiences.where(NoticeAudience.all.contains).toList();
    if (kinds.isEmpty) throw Exception('Choose who the post is for.');

    final mediaType = NoticePostType.hasImage(type)
        ? 'image'
        : NoticePostType.hasVideo(type)
            ? 'video'
            : '';

    final ref = _posts.doc();
    await ref.set({
      'communityDocId': communityDocId,
      'authorUid': authorUid,
      'authorName': authorName,
      'authorAvatarUrl': authorAvatarUrl,
      'type': type,
      'title': title.trim(),
      'text': text.trim(),
      'mediaUrl': mediaUrl,
      'mediaType': mediaType,
      'audiences': kinds,
      'departments': NoticeAudience.needsDepartments(kinds) ? departments : <String>[],
      'years': NoticeAudience.needsYears(kinds) ? years : <String>[],
      'endAt': Timestamp.fromDate(endAt),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  /// Only the member who made the post can edit it.
  static Future<void> updatePost({
    required String id,
    required String requesterUid,
    required String type,
    required String title,
    required String text,
    required String mediaUrl,
    required List<String> audiences,
    required List<String> departments,
    required List<String> years,
    required DateTime endAt,
  }) async {
    if (!endAt.isAfter(DateTime.now())) {
      throw Exception('The end time must be in the future.');
    }
    final kinds = audiences.where(NoticeAudience.all.contains).toList();
    if (kinds.isEmpty) throw Exception('Choose who the post is for.');

    final doc = await _posts.doc(id).get();
    if (!doc.exists) throw Exception('This post no longer exists.');
    if ((doc.data()?['authorUid'] ?? '').toString() != requesterUid) {
      throw Exception('Only the person who posted this can edit it.');
    }

    final mediaType = NoticePostType.hasImage(type)
        ? 'image'
        : NoticePostType.hasVideo(type)
            ? 'video'
            : '';

    await _posts.doc(id).update({
      'title': title.trim(),
      'text': text.trim(),
      'mediaUrl': mediaUrl,
      'mediaType': mediaType,
      'audiences': kinds,
      'departments': NoticeAudience.needsDepartments(kinds) ? departments : <String>[],
      'years': NoticeAudience.needsYears(kinds) ? years : <String>[],
      'endAt': Timestamp.fromDate(endAt),
      'editedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Only the member who made the post can delete it.
  static Future<void> deletePost({
    required String id,
    required String requesterUid,
  }) async {
    final doc = await _posts.doc(id).get();
    if (!doc.exists) return;
    if ((doc.data()?['authorUid'] ?? '').toString() != requesterUid) {
      throw Exception('Only the person who posted this can delete it.');
    }
    await _posts.doc(id).delete();
  }

  // ==========================================================
  // READ
  // ==========================================================

  static Stream<List<Map<String, dynamic>>> watchPosts(String communityDocId) {
    return _posts
        .where('communityDocId', isEqualTo: communityDocId)
        .snapshots()
        .map((snap) => snap.docs.map((d) => {...d.data(), 'id': d.id}).toList());
  }

  /// Role + department + year of [uid] in this community: read from the
  /// member PROFILE the account is using right now (Profile ID based).
  static Future<NoticeViewer> loadViewer(
    String communityDocId,
    Map<String, dynamic> community,
    String uid,
  ) async {
    if (uid.isEmpty) return NoticeViewer.unknown;
    var role = CommunityMemberProfileService.quickRole(uid, community);
    var dept = '';
    var year = '';

    try {
      final profile = await CommunityMemberProfileService.loadActiveProfile(
          communityDocId, uid);
      if (profile != null) {
        role = CommunityMemberProfileService.effectiveRole(profile, community);
        dept = (profile['department'] ?? '').toString().trim();
        year = (profile['year'] ?? '').toString().trim();
      }
    } catch (_) {}

    return NoticeViewer(role: role, department: dept, year: year);
  }

  // ==========================================================
  // HELPERS
  // ==========================================================

  static DateTime? endOf(Map<String, dynamic> post) {
    final v = post['endAt'];
    return v is Timestamp ? v.toDate() : null;
  }

  /// A post stops being shown once its end time is reached.
  static bool isActive(Map<String, dynamic> post, DateTime now) {
    final end = endOf(post);
    if (end == null) return false;
    return now.isBefore(end);
  }

  static List<String> _list(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : <String>[];

  static String _n(String s) => s.trim().toLowerCase();

  /// Whether [viewer] is in the post's audience. Multiple audience
  /// options are OR-ed: matching any one of them is enough.
  ///   Specific Department  -> students of the chosen departments
  ///   Entire Department    -> everyone (students + staff) in them
  ///   Specific Year        -> students of the chosen years
  ///   Dept with Year       -> students in a chosen department AND year
  static bool isVisibleTo(Map<String, dynamic> post, NoticeViewer viewer) {
    final kinds = _list(post['audiences']);
    if (kinds.isEmpty || kinds.contains(NoticeAudience.community)) return true;

    final depts = _list(post['departments']).map(_n).toSet();
    final years = _list(post['years']).map(_n).toSet();
    final vDept = _n(viewer.department);
    final vYear = _n(viewer.year);
    final isStudent = viewer.role == CommunityMemberProfileService.roleStudent;

    for (final k in kinds) {
      switch (k) {
        case NoticeAudience.specificDepartment:
          if (isStudent && vDept.isNotEmpty && depts.contains(vDept)) return true;
          break;
        case NoticeAudience.entireDepartment:
          if (vDept.isNotEmpty && depts.contains(vDept)) return true;
          break;
        case NoticeAudience.specificYear:
          if (vYear.isNotEmpty && years.contains(vYear)) return true;
          break;
        case NoticeAudience.departmentYear:
          if (vDept.isNotEmpty &&
              vYear.isNotEmpty &&
              depts.contains(vDept) &&
              years.contains(vYear)) {
            return true;
          }
          break;
        case NoticeAudience.faculty:
          if (viewer.role == CommunityMemberProfileService.roleFaculty) return true;
          break;
        case NoticeAudience.students:
          if (isStudent) return true;
          break;
        case NoticeAudience.hod:
          if (viewer.role == CommunityMemberProfileService.roleHod) return true;
          break;
      }
    }
    return false;
  }

  /// e.g. "Specific Year (2nd Year, 3rd Year) · Faculty only"
  static String audienceSummary(Map<String, dynamic> post) {
    final kinds = _list(post['audiences']);
    if (kinds.isEmpty) return NoticeAudience.label(NoticeAudience.community);
    final depts = _list(post['departments']);
    final years = _list(post['years']);
    return kinds.map((k) {
      final label = NoticeAudience.label(k);
      final extra = <String>[
        if (NoticeAudience.needsDepartments([k])) ...depts,
        if (NoticeAudience.needsYears([k])) ...years,
      ];
      return extra.isEmpty ? label : '$label (${extra.join(', ')})';
    }).join(' · ');
  }
}
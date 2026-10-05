import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_media_service.dart';
import 'community_member_profile_service.dart';
import 'community_service.dart';

// ================================================================
// COMMUNITY RESOURCE SERVICE  (Community spec -- Section 8)
// ----------------------------------------------------------------
// Same pattern as CommunityFeedService / AnnouncementService:
// a top-level Firestore collection ('communityResources') scoped by
// 'communityDocId', direct client-side writes, and
// CommunityService.isPrivileged() as the single "authorized" check
// (delete other people's resources).
//
// Files are uploaded through CommunityMediaService (the same
// Cloudinary account/preset chat attachments already use) -- no
// Firebase Storage, no new upload code.
//
// One 'communityResources' document = one library entry:
//   communityDocId, uploaderUid, uploaderName, uploaderAvatarUrl,
//   title, description, category, tags[], fileUrl, fileName,
//   fileExt, fileSize, downloadCount, reportedBy[], createdAt
//
// Subcollection:
//   communityResources/{id}/reports/{uid}   (reason per reporter)
//
// Needs ONE composite index: communityResources
//   communityDocId ASC, createdAt DESC
// (same shape as communityPosts). Search / category / tag / sort
// are applied client-side by [applyFilter] so that single index
// serves every view (the same approach the Feed uses).
//
// [matchScore] is intentionally public: the unified Community
// Search (Section 11) and the Nexus AI assistant (Section 19) will
// call it instead of re-implementing resource matching.
// ================================================================

class CommunityResourceSnapshot {
  final List<Map<String, dynamic>> resources;
  final bool fromCache;

  const CommunityResourceSnapshot({
    required this.resources,
    required this.fromCache,
  });
}

class CommunityResourceService {
  CommunityResourceService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get resources =>
      _firestore.collection('communityResources');

  // ==========================================================
  // CONSTANTS
  // ==========================================================

  static const List<String> categories = [
    'notes',
    'pyq',
    'lab',
    'study',
    'placement',
    'project',
    'programming',
    'documents',
    'events',
  ];

  static const Map<String, String> categoryLabels = {
    'notes': 'Notes',
    'pyq': 'Previous Year Questions',
    'lab': 'Lab Manuals',
    'study': 'Study Materials',
    'placement': 'Placement Materials',
    'project': 'Project Resources',
    'programming': 'Programming Resources',
    'documents': 'Important Documents',
    'events': 'Event Documents',
  };

  /// Short labels for the filter chips.
  static const Map<String, String> categoryShortLabels = {
    'notes': 'Notes',
    'pyq': 'Previous Questions',
    'lab': 'Lab Manuals',
    'study': 'Study Materials',
    'placement': 'Placement',
    'project': 'Projects',
    'programming': 'Programming',
    'documents': 'Documents',
    'events': 'Event Docs',
  };

  static const List<String> sorts = ['newest', 'popular'];

  static const Map<String, String> sortLabels = {
    'newest': 'Newest first',
    'popular': 'Most downloaded',
  };

  static const List<String> reportReasons = [
    'Spam',
    'Inappropriate content',
    'Copyright / not allowed to share',
    'Wrong or misleading',
    'Other',
  ];

  /// File types that are never accepted into the library.
  static const Set<String> blockedExtensions = {
    'apk',
    'exe',
    'msi',
    'bat',
    'cmd',
    'com',
    'scr',
    'sh',
    'jar',
    'dmg',
    'vbs',
    'ps1',
  };

  static const int maxTitleLength = 100;
  static const int maxDescriptionLength = 500;
  static const int maxTags = 8;
  static const int maxTagLength = 30;

  /// Cloudinary can serve a file with a "download" disposition when
  /// 'fl_attachment' is added to the delivery URL. If the Cloudinary
  /// account has "strict transformations" turned on this flag is
  /// rejected; set this to false and Download simply opens the same
  /// URL as View (the system browser then handles the download).
  static const bool useAttachmentFlag = true;

  // ==========================================================
  // HELPERS
  // ==========================================================

  static List<String> _asStringList(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : <String>[];

  static DateTime? _dateOf(dynamic v) =>
      v is Timestamp ? v.toDate() : (v is DateTime ? v : null);

  static DateTime createdAtOf(Map<String, dynamic> r) =>
      _dateOf(r['createdAt']) ?? DateTime.now();

  static int downloadCountOf(Map<String, dynamic> r) =>
      r['downloadCount'] is int ? r['downloadCount'] as int : 0;

  static int sizeOf(Map<String, dynamic> r) =>
      r['fileSize'] is int ? r['fileSize'] as int : 0;

  static List<String> tagsOf(Map<String, dynamic> r) => _asStringList(r['tags']);

  static bool isUploader(Map<String, dynamic> r, String uid) =>
      (r['uploaderUid'] ?? '').toString() == uid;

  static bool isReportedBy(Map<String, dynamic> r, String uid) =>
      _asStringList(r['reportedBy']).contains(uid);

  static int reportCount(Map<String, dynamic> r) =>
      _asStringList(r['reportedBy']).length;

  static bool canDelete(
          Map<String, dynamic> r, Map<String, dynamic> community, String uid) =>
      isUploader(r, uid) || CommunityService.isPrivileged(community, uid);

  static String categoryLabel(String key) => categoryLabels[key] ?? 'Other';

  /// "1.4 MB", "230 KB", "12 B".
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }

  /// Tags typed as "dsa, 2nd year, #exam" -> ['dsa', '2nd year', 'exam'].
  /// Lower-cased, de-duplicated, length and count limited.
  static List<String> parseTags(String raw) {
    final out = <String>[];
    for (final part in raw.split(RegExp(r'[,\n]'))) {
      var t = part.trim().replaceAll('#', '').toLowerCase();
      t = t.replaceAll(RegExp(r'\s+'), ' ');
      if (t.isEmpty) continue;
      if (t.length > maxTagLength) t = t.substring(0, maxTagLength);
      if (!out.contains(t)) out.add(t);
      if (out.length >= maxTags) break;
    }
    return out;
  }

  /// URL that makes the browser download instead of preview.
  static String downloadUrl(String fileUrl) {
    if (!useAttachmentFlag) return fileUrl;
    const marker = '/upload/';
    final i = fileUrl.indexOf(marker);
    if (i < 0 || !fileUrl.contains('res.cloudinary.com')) return fileUrl;
    if (fileUrl.contains('/fl_attachment')) return fileUrl;
    return '${fileUrl.substring(0, i + marker.length)}fl_attachment/'
        '${fileUrl.substring(i + marker.length)}';
  }

  // ==========================================================
  // CREATE
  // ==========================================================

  static Future<void> _requireMember(
      String communityDocId, String uid) async {
    final snap = await _firestore
        .collection('communities')
        .doc(communityDocId)
        .get();
    final data = snap.data();
    if (data == null) throw Exception('This community no longer exists.');
    final members = _asStringList(data['members']);
    if (!members.contains(uid)) {
      throw Exception('Only Community members can upload resources.');
    }
  }

  /// Validates everything that can be checked BEFORE the (slow) file
  /// upload, so the user learns about a problem immediately.
  static Future<void> validateBeforeUpload({
    required String communityDocId,
    required String uploaderUid,
    required String title,
    required String description,
    required String category,
    required String filePath,
  }) async {
    if (title.trim().isEmpty) throw Exception('Please enter a title.');
    if (title.trim().length > maxTitleLength) {
      throw Exception('Title is too long (max $maxTitleLength characters).');
    }
    if (description.trim().length > maxDescriptionLength) {
      throw Exception(
          'Description is too long (max $maxDescriptionLength characters).');
    }
    if (!categories.contains(category)) {
      throw Exception('Please choose a category.');
    }
    if (filePath.isEmpty) throw Exception('Please choose a file to upload.');

    final ext = CommunityMediaService.extensionOf(filePath);
    if (blockedExtensions.contains(ext)) {
      throw Exception('.$ext files can\'t be uploaded to the library.');
    }

    await _requireMember(communityDocId, uploaderUid);
  }

  /// Uploads the file (Cloudinary) and writes the library entry.
  /// [onStatus] receives short progress labels for the UI.
  static Future<String> uploadResource({
    required String communityDocId,
    required String uploaderUid,
    required String uploaderName,
    required String uploaderAvatarUrl,
    required String title,
    required String description,
    required String category,
    required List<String> tags,
    required String filePath,
    void Function(String status)? onStatus,
  }) async {
    await validateBeforeUpload(
      communityDocId: communityDocId,
      uploaderUid: uploaderUid,
      title: title,
      description: description,
      category: category,
      filePath: filePath,
    );

    onStatus?.call('Uploading file…');
    final uploaded = await CommunityMediaService.upload(
      path: filePath,
      kind: CommunityMediaService.kindFile,
    );

    onStatus?.call('Saving…');
    final uploaderProfileId =
        await CommunityMemberProfileService.currentProfileId(communityDocId);
    final ref = resources.doc();
    await ref.set({
      'communityDocId': communityDocId,
      'uploaderUid': uploaderUid,
      // Profile ID that shared it (Contributions are per profile).
      'uploaderProfileId': uploaderProfileId,
      'uploaderName': uploaderName,
      'uploaderAvatarUrl': uploaderAvatarUrl,
      'title': title.trim(),
      'description': description.trim(),
      'category': category,
      'tags': tags,
      'fileUrl': uploaded.url,
      'fileName': uploaded.fileName,
      'fileExt': CommunityMediaService.extensionOf(uploaded.fileName),
      'fileSize': uploaded.sizeBytes,
      'downloadCount': 0,
      'reportedBy': <String>[],
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  // ==========================================================
  // READ
  // ==========================================================

  /// Newest 300 resources of a community (server-ordered).
  static Stream<CommunityResourceSnapshot> watchResources(
      String communityDocId) {
    return resources
        .where('communityDocId', isEqualTo: communityDocId)
        .snapshots()
        .map((snap) {
      final list = snap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
      int ms(dynamic v) => v is Timestamp ? v.millisecondsSinceEpoch : 0;
      list.sort((a, b) => ms(b['createdAt']).compareTo(ms(a['createdAt'])));
      return CommunityResourceSnapshot(
        resources: list.take(300).toList(),
        fromCache: snap.metadata.isFromCache,
      );
    });
  }

  // ==========================================================
  // SEARCH / FILTER / SORT
  // ==========================================================

  /// 0 = no match. Higher = better. Title beats tag beats
  /// description / file name / uploader. Every whitespace separated
  /// word of [query] must match somewhere.
  static int matchScore(Map<String, dynamic> r, String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return 1;

    final title = (r['title'] ?? '').toString().toLowerCase();
    final desc = (r['description'] ?? '').toString().toLowerCase();
    final file = (r['fileName'] ?? '').toString().toLowerCase();
    final uploader = (r['uploaderName'] ?? '').toString().toLowerCase();
    final category = categoryLabel((r['category'] ?? '').toString()).toLowerCase();
    final tags = tagsOf(r);

    var total = 0;
    for (final w in words) {
      var s = 0;
      if (title.contains(w)) s += title.startsWith(w) ? 10 : 8;
      if (tags.any((t) => t == w)) {
        s += 7;
      } else if (tags.any((t) => t.contains(w))) {
        s += 4;
      }
      if (category.contains(w)) s += 3;
      if (desc.contains(w)) s += 2;
      if (file.contains(w)) s += 2;
      if (uploader.contains(w)) s += 1;
      if (s == 0) return 0; // every word must match somewhere
      total += s;
    }
    return total;
  }

  /// Applies category / tag / search / sort. Resources the user has
  /// reported are hidden for that user.
  static List<Map<String, dynamic>> applyFilter(
    List<Map<String, dynamic>> all, {
    required String uid,
    String category = '',
    String tag = '',
    String query = '',
    String sort = 'newest',
  }) {
    var list = all.where((r) => !isReportedBy(r, uid)).toList();

    if (category.isNotEmpty) {
      list = list.where((r) => (r['category'] ?? '') == category).toList();
    }
    if (tag.isNotEmpty) {
      final t = tag.toLowerCase();
      list = list.where((r) => tagsOf(r).contains(t)).toList();
    }

    final q = query.trim();
    if (q.isNotEmpty) {
      final scored = <MapEntry<Map<String, dynamic>, int>>[];
      for (final r in list) {
        final s = matchScore(r, q);
        if (s > 0) scored.add(MapEntry(r, s));
      }
      scored.sort((a, b) {
        final byScore = b.value.compareTo(a.value);
        if (byScore != 0) return byScore;
        return createdAtOf(b.key).compareTo(createdAtOf(a.key));
      });
      return scored.map((e) => e.key).toList();
    }

    if (sort == 'popular') {
      list.sort((a, b) {
        final byCount = downloadCountOf(b).compareTo(downloadCountOf(a));
        if (byCount != 0) return byCount;
        return createdAtOf(b).compareTo(createdAtOf(a));
      });
    } else {
      list.sort((a, b) => createdAtOf(b).compareTo(createdAtOf(a)));
    }
    return list;
  }

  /// Resource count per category key (reported-by-me excluded).
  static Map<String, int> categoryCounts(
      List<Map<String, dynamic>> all, String uid) {
    final counts = <String, int>{};
    for (final r in all) {
      if (isReportedBy(r, uid)) continue;
      final c = (r['category'] ?? '').toString();
      counts[c] = (counts[c] ?? 0) + 1;
    }
    return counts;
  }

  /// Most-used tags (for the quick tag row).
  static List<String> topTags(List<Map<String, dynamic>> all, String uid,
      {int limit = 10}) {
    final counts = <String, int>{};
    for (final r in all) {
      if (isReportedBy(r, uid)) continue;
      for (final t in tagsOf(r)) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).map((e) => e.key).toList();
  }

  // ==========================================================
  // DOWNLOAD COUNT / REPORT / DELETE
  // ==========================================================

  /// Best-effort counter -- a failure here must never block the
  /// user from opening the file, so it is swallowed.
  static Future<void> recordDownload(String resourceId) async {
    try {
      await resources
          .doc(resourceId)
          .update({'downloadCount': FieldValue.increment(1)});
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> _load(String resourceId) async {
    final snap = await resources.doc(resourceId).get();
    final data = snap.data();
    if (data == null) throw Exception('This resource no longer exists.');
    return data;
  }

  static Future<void> reportResource({
    required String resourceId,
    required String uid,
    required String reason,
  }) async {
    final r = await _load(resourceId);
    if (isUploader(r, uid)) {
      throw Exception('You can\'t report your own resource.');
    }

    final batch = _firestore.batch();
    batch.update(resources.doc(resourceId), {
      'reportedBy': FieldValue.arrayUnion([uid]),
    });
    batch.set(resources.doc(resourceId).collection('reports').doc(uid), {
      'reporterUid': uid,
      'reason': reason,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  /// Uploader, or Community owner/admin/moderator.
  static Future<void> deleteResource({
    required String resourceId,
    required String requesterUid,
    required Map<String, dynamic> community,
  }) async {
    final r = await _load(resourceId);
    if (!isUploader(r, requesterUid) &&
        !CommunityService.isPrivileged(community, requesterUid)) {
      throw Exception('You don\'t have permission to delete this resource.');
    }

    // Reports live in a subcollection, which Firestore does not
    // cascade -- remove them so nothing is orphaned.
    final reportsRef = resources.doc(resourceId).collection('reports');
    while (true) {
      final chunk = await reportsRef.limit(400).get();
      if (chunk.docs.isEmpty) break;
      final batch = _firestore.batch();
      for (final d in chunk.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
      if (chunk.docs.length < 400) break;
    }

    await resources.doc(resourceId).delete();
  }
}
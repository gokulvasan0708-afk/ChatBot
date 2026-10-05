import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/community_resource_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// COMMUNITY RESOURCE CARD  (Community spec -- Section 8)
// ----------------------------------------------------------------
// One library entry: file-type icon, title, category, description,
// tappable tags, uploaded by / date / size / downloads, View +
// Download buttons and a menu (Copy link, Report, Delete).
// Used by the Resources page AND the Feed's "Resources" tab so the
// two always look and behave the same.
// ================================================================
class CommunityResourceCard extends StatelessWidget {
  final Map<String, dynamic> resource;
  final Map<String, dynamic> community;
  final void Function(String tag)? onTagTap;
  final void Function(String category)? onCategoryTap;

  const CommunityResourceCard({
    super.key,
    required this.resource,
    required this.community,
    this.onTagTap,
    this.onCategoryTap,
  });

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';
  String get _id => (resource['id'] ?? '').toString();
  String get _fileUrl => (resource['fileUrl'] ?? '').toString();

  static String _clean(Object e) =>
      e.toString().replaceFirst('Exception: ', '');

  // ------------------------------------------------------------
  // File-type look
  // ------------------------------------------------------------

  static IconData iconForExt(String ext) {
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      case 'doc':
      case 'docx':
      case 'rtf':
      case 'odt':
        return Icons.description_rounded;
      case 'ppt':
      case 'pptx':
      case 'odp':
        return Icons.slideshow_rounded;
      case 'xls':
      case 'xlsx':
      case 'csv':
      case 'ods':
        return Icons.table_chart_rounded;
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return Icons.folder_zip_rounded;
      case 'txt':
      case 'md':
        return Icons.article_rounded;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
        return Icons.image_rounded;
      case 'mp4':
      case 'mkv':
      case 'mov':
      case 'avi':
      case 'webm':
        return Icons.movie_rounded;
      case 'mp3':
      case 'wav':
      case 'm4a':
        return Icons.audiotrack_rounded;
      case 'py':
      case 'java':
      case 'c':
      case 'cpp':
      case 'js':
      case 'ts':
      case 'dart':
      case 'html':
      case 'css':
      case 'ipynb':
      case 'json':
        return Icons.code_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  static IconData iconForCategory(String category) {
    switch (category) {
      case 'notes':
        return Icons.sticky_note_2_rounded;
      case 'pyq':
        return Icons.quiz_rounded;
      case 'lab':
        return Icons.science_rounded;
      case 'study':
        return Icons.menu_book_rounded;
      case 'placement':
        return Icons.work_rounded;
      case 'project':
        return Icons.rocket_launch_rounded;
      case 'programming':
        return Icons.terminal_rounded;
      case 'documents':
        return Icons.folder_special_rounded;
      case 'events':
        return Icons.event_note_rounded;
      default:
        return Icons.folder_rounded;
    }
  }

  // ------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------

  Future<void> _open(BuildContext context, {required bool download}) async {
    if (_fileUrl.isEmpty) {
      showTopAlert(context, 'This file is unavailable.', isError: true);
      return;
    }

    final target =
        download ? CommunityResourceService.downloadUrl(_fileUrl) : _fileUrl;

    try {
      final uri = Uri.parse(target);
      var ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      // If the download flavour of the URL can't be opened, fall back
      // to the plain file URL rather than failing.
      if (!ok && download && target != _fileUrl) {
        ok = await launchUrl(Uri.parse(_fileUrl),
            mode: LaunchMode.externalApplication);
      }
      if (!ok) {
        if (context.mounted) {
          showTopAlert(context, 'No app found to open this file.',
              isError: true);
        }
        return;
      }
      if (download) CommunityResourceService.recordDownload(_id);
    } catch (_) {
      if (context.mounted) {
        showTopAlert(context, 'Couldn\'t open this file.', isError: true);
      }
    }
  }

  Future<void> _copyLink(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _fileUrl));
    if (context.mounted) showTopAlert(context, 'Link copied');
  }

  Future<void> _report(BuildContext context) async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: CommunityColors.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Why are you reporting this resource?',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
              ),
            ),
            for (final r in CommunityResourceService.reportReasons)
              ListTile(
                title: Text(r, style: const TextStyle(color: Colors.white70)),
                onTap: () => Navigator.pop(ctx, r),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (reason == null) return;

    try {
      await CommunityResourceService.reportResource(
          resourceId: _id, uid: _uid, reason: reason);
      if (context.mounted) {
        showTopAlert(
            context, 'Thanks — the resource was reported and hidden for you.');
      }
    } catch (e) {
      if (context.mounted) showTopAlert(context, _clean(e), isError: true);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: CommunityColors.card,
        title: const Text('Delete resource?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'This removes it from the library for everyone. This cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('DELETE',
                style: TextStyle(color: CommunityColors.danger)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await CommunityResourceService.deleteResource(
        resourceId: _id,
        requesterUid: _uid,
        community: community,
      );
      if (context.mounted) showTopAlert(context, 'Resource deleted');
    } catch (e) {
      if (context.mounted) showTopAlert(context, _clean(e), isError: true);
    }
  }

  // ------------------------------------------------------------
  // UI
  // ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final title = (resource['title'] ?? 'Untitled').toString();
    final description = (resource['description'] ?? '').toString();
    final category = (resource['category'] ?? '').toString();
    final ext = (resource['fileExt'] ?? '').toString();
    final fileName = (resource['fileName'] ?? '').toString();
    final uploader = (resource['uploaderName'] ?? 'Member').toString();
    final created = communityToDate(resource['createdAt']);
    final size = CommunityResourceService.formatBytes(
        CommunityResourceService.sizeOf(resource));
    final downloads = CommunityResourceService.downloadCountOf(resource);
    final tags = CommunityResourceService.tagsOf(resource);
    final isUploader = CommunityResourceService.isUploader(resource, _uid);
    final canDelete =
        CommunityResourceService.canDelete(resource, community, _uid);
    final reports = CommunityResourceService.reportCount(resource);
    final showReports = reports > 0 && canDelete && !isUploader;

    final meta = <String>[
      if (ext.isNotEmpty) ext.toUpperCase(),
      if (size.isNotEmpty) size,
      '$downloads download${downloads == 1 ? '' : 's'}',
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: CommunityColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: showReports
              ? CommunityColors.danger.withValues(alpha: .5)
              : CommunityColors.tan.withValues(alpha: .2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: CommunityColors.avatarBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(iconForExt(ext),
                      color: CommunityColors.glow, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        fileName.isEmpty ? meta : '$fileName\n$meta',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11.5, height: 1.3),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  color: CommunityColors.card,
                  icon: const Icon(Icons.more_vert_rounded,
                      color: Colors.white54, size: 20),
                  onSelected: (v) {
                    switch (v) {
                      case 'copy':
                        _copyLink(context);
                        break;
                      case 'report':
                        _report(context);
                        break;
                      case 'delete':
                        _delete(context);
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'copy',
                        child: Text('Copy link',
                            style: TextStyle(color: Colors.white))),
                    if (!isUploader)
                      const PopupMenuItem(
                          value: 'report',
                          child: Text('Report',
                              style: TextStyle(color: Colors.white))),
                    if (canDelete)
                      const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete',
                              style: TextStyle(color: CommunityColors.danger))),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (category.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: onCategoryTap == null
                          ? null
                          : () => onCategoryTap!(category),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: CommunityColors.tan.withValues(alpha: .15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(iconForCategory(category),
                                color: CommunityColors.glow, size: 13),
                            const SizedBox(width: 5),
                            Text(
                              CommunityResourceService.categoryLabel(category),
                              style: const TextStyle(
                                  color: CommunityColors.glow,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      description,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13, height: 1.35),
                    ),
                  ],
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final t in tags)
                          GestureDetector(
                            onTap: onTagTap == null ? null : () => onTagTap!(t),
                            child: Text('#$t',
                                style: const TextStyle(
                                    color: CommunityColors.tan,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      CommunityAvatar(
                          url: (resource['uploaderAvatarUrl'] ?? '').toString(),
                          name: uploader,
                          radius: 11),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Uploaded by ${isUploader ? 'you' : uploader} · ${created == null ? 'just now' : communityFormatDate(created)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                  if (showReports) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.flag_rounded,
                            color: CommunityColors.danger, size: 14),
                        const SizedBox(width: 5),
                        Text(
                          'Reported by $reports member${reports == 1 ? '' : 's'}',
                          style: const TextStyle(
                              color: CommunityColors.danger, fontSize: 11.5),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _open(context, download: false),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: CommunityColors.tan,
                            side: BorderSide(
                                color:
                                    CommunityColors.tan.withValues(alpha: .5)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: const Icon(Icons.visibility_rounded, size: 17),
                          label: const Text('View'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => _open(context, download: true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: CommunityColors.tan,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: const Icon(Icons.download_rounded, size: 17),
                          label: const Text('Download'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

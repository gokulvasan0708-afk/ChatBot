import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/community_media_service.dart';
import '../widgets/community_about_section.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// COLLEGE NOTICE DETAIL
// ----------------------------------------------------------------
// Opened when a member taps a notice that ANOTHER college shared
// with "Show to all College" (announcement / event / notice post).
// Read-only. Top-left shows the posting community's profile image
// and, right next to it, the community's name; below that the
// college name and location.
// ================================================================
class CollegeNoticeSheet extends StatelessWidget {
  /// An item from CollegeNoticeService.watchShared().
  final Map<String, dynamic> item;

  const CollegeNoticeSheet({super.key, required this.item});

  static Future<void> show(BuildContext context, Map<String, dynamic> item) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CollegeNoticeSheet(item: item),
    );
  }

  static const Color _tan = Color(0xFFD2B48C);

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(normalizeCommunityLink(url));
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
    if (!ok && context.mounted) {
      showTopAlert(context, 'Couldn\'t open this link.', isError: true);
    }
  }

  Widget _meta(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _tan, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  Widget _linkRow(BuildContext context, IconData icon, String label, String url) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => _open(context, url),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFFFFE9B0), size: 16),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  color: Color(0xFFFFE9B0),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                  decorationColor: Color(0xFFFFE9B0),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _image(String url) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Image.network(
          url,
          fit: BoxFit.cover,
          width: double.infinity,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _video(BuildContext context, String url) {
    final thumb = CommunityMediaService.videoThumbnailUrl(url);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: GestureDetector(
        onTap: () => _open(context, url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: 200,
            width: double.infinity,
            color: const Color(0xFF120C07),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (thumb.isNotEmpty)
                  Image.network(thumb,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink()),
                const Center(
                  child: Icon(Icons.play_circle_fill_rounded,
                      color: Colors.white70, size: 60),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Title / media / body / meta rows for the item itself.
  List<Widget> _content(BuildContext context) {
    final kind = (item['kind'] ?? '').toString();
    final d = item['data'] is Map
        ? Map<String, dynamic>.from(item['data'] as Map)
        : <String, dynamic>{};
    String s(String k) => (d[k] ?? '').toString().trim();
    DateTime? dt(String k) => d[k] is Timestamp ? (d[k] as Timestamp).toDate() : null;

    final out = <Widget>[];
    Widget title(String t) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(t,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800)),
        );
    Widget body(String t) => Padding(
          padding: const EdgeInsets.only(top: 14),
          child: SelectableText(t,
              style: const TextStyle(
                  color: Colors.white, fontSize: 15, height: 1.4)),
        );

    if (kind == 'announcement') {
      final type = s('type');
      if (s('title').isNotEmpty) out.add(title(s('title')));
      if (type == 'image' && s('mediaUrl').startsWith('http')) {
        out.add(_image(s('mediaUrl')));
      }
      if (s('body').isNotEmpty) out.add(body(s('body')));
      out.add(const SizedBox(height: 14));
      if (s('linkUrl').isNotEmpty) {
        out.add(_linkRow(context, Icons.link_rounded, 'Open link', s('linkUrl')));
      }
      if (s('authorName').isNotEmpty) {
        out.add(_meta(Icons.person_outline_rounded, 'Posted by ${s('authorName')}'));
      }
      final at = dt('publishedAt') ?? dt('createdAt');
      if (at != null) {
        out.add(_meta(Icons.schedule_rounded, 'Posted ${communityFormatDateTime(at)}'));
      }
    } else if (kind == 'event') {
      if (s('title').isNotEmpty) out.add(title(s('title')));
      if (s('coverImageUrl').startsWith('http')) out.add(_image(s('coverImageUrl')));
      if (s('description').isNotEmpty) out.add(body(s('description')));
      out.add(const SizedBox(height: 14));
      final start = dt('startAt');
      final end = dt('endAt');
      if (start != null) {
        out.add(_meta(Icons.event_rounded, 'Starts ${communityFormatDateTime(start)}'));
      }
      if (end != null) {
        out.add(_meta(Icons.schedule_rounded, 'Ends ${communityFormatDateTime(end)}'));
      }
      if (s('category').isNotEmpty) {
        out.add(_meta(Icons.category_outlined, s('category')));
      }
      if (d['isOnline'] == true) {
        out.add(_meta(Icons.videocam_outlined, 'Online event'));
        if (s('onlineLink').isNotEmpty) {
          out.add(_linkRow(context, Icons.link_rounded, 'Open event link', s('onlineLink')));
        }
      } else if (s('location').isNotEmpty) {
        out.add(_meta(Icons.place_outlined, 'Venue: ${s('location')}'));
        if (s('locationLink').isNotEmpty) {
          out.add(_linkRow(context, Icons.open_in_new_rounded,
              'Open location link', s('locationLink')));
        }
      }
      if (s('organizerName').isNotEmpty) {
        out.add(_meta(Icons.person_outline_rounded, 'Organized by ${s('organizerName')}'));
      }
    } else {
      // notice board post
      final mediaType = s('mediaType');
      if (s('title').isNotEmpty) out.add(title(s('title')));
      if (mediaType == 'image' && s('mediaUrl').startsWith('http')) {
        out.add(_image(s('mediaUrl')));
      }
      if (mediaType == 'video' && s('mediaUrl').startsWith('http')) {
        out.add(_video(context, s('mediaUrl')));
      }
      if (s('text').isNotEmpty) out.add(body(s('text')));
      out.add(const SizedBox(height: 14));
      if (s('authorName').isNotEmpty) {
        out.add(_meta(Icons.person_outline_rounded, 'Posted by ${s('authorName')}'));
      }
      final end = dt('endAt');
      if (end != null) {
        out.add(_meta(Icons.schedule_rounded, 'Ends ${communityFormatDateTime(end)}'));
      }
    }
    return out;
  }

  String get _kindLabel {
    switch ((item['kind'] ?? '').toString()) {
      case 'announcement':
        return 'COLLEGE ANNOUNCEMENT';
      case 'event':
        return 'COLLEGE EVENT';
      default:
        return 'COLLEGE NOTICE';
    }
  }

  @override
  Widget build(BuildContext context) {
    final sourceId = (item['sourceId'] ?? '').toString();
    final cached = item['source'] is Map
        ? Map<String, dynamic>.from(item['source'] as Map)
        : <String, dynamic>{};

    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .9),
      decoration: const BoxDecoration(
        color: Color(0xFF1B120A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ---- Top-left: community profile image + community name.
              // Live, so a changed logo / name shows up straight away.
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: sourceId.isEmpty
                    ? null
                    : FirebaseFirestore.instance
                        .collection('communities')
                        .doc(sourceId)
                        .snapshots(),
                builder: (context, snap) {
                  final live = snap.data?.data();
                  String pick(String k) =>
                      ((live ?? cached)[k] ?? cached[k] ?? '').toString().trim();

                  final name = pick('name');
                  final logo = pick('logoUrl');
                  final college = pick('collegeName');
                  final location = pick('location');
                  final link = pick('locationLink');

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: _tan, width: 1.5),
                            ),
                            child: CommunityAvatar(
                                url: logo, name: name, radius: 21),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              name.isEmpty ? 'Community' : name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (college.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            const Icon(Icons.school_rounded,
                                color: Colors.white54, size: 15),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(college,
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 13)),
                            ),
                          ],
                        ),
                      ],
                      if (location.isNotEmpty || link.isNotEmpty)
                        CommunityAboutSection(
                          location: location,
                          locationLink: location.isEmpty ? '' : link,
                        ),
                    ],
                  );
                },
              ),

              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Divider(height: 1, color: Colors.white12),
              ),

              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .4),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _tan.withValues(alpha: .7)),
                  ),
                  child: Text(
                    _kindLabel,
                    style: const TextStyle(
                      color: _tan,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .6,
                    ),
                  ),
                ),
              ),

              ..._content(context),
            ],
          ),
        ),
      ),
    );
  }
}

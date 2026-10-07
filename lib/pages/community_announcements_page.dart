import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'create_announcement_sheet.dart';
import '../services/announcement_service.dart';
import '../services/community_service.dart';
import '../widgets/top_alert.dart';

// ================================================================
// COMMUNITY ANNOUNCEMENTS  (spec — Section 2)
// ----------------------------------------------------------------
// Full loading / empty / error states (spec Section 23), pinned
// announcements always float to the top, an urgent badge for
// isUrgent==true, per-user read/unread dimming, quick reactions,
// and a privileged-only "+" to create new ones. Reuses the same
// visual language (colors, cards, rounded corners) as every other
// Community screen already shipped.
// ================================================================
class CommunityAnnouncementsPage extends StatelessWidget {
  final String communityDocId;

  const CommunityAnnouncementsPage({super.key, required this.communityDocId});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: CommunityService.watchCommunity(communityDocId),
          builder: (context, communitySnap) {
            if (communitySnap.connectionState == ConnectionState.waiting) {
              return const _Center(child: CircularProgressIndicator(color: Color(0xFFA78BFA)));
            }
            final community = communitySnap.data?.data();
            if (community == null) {
              return _StateMessage(
                icon: Icons.public_off_rounded,
                title: 'Community not found',
                subtitle: 'This community may have been deleted.',
              );
            }

            final canCreate = AnnouncementService.canCreate(community, uid);

            return Column(
              children: [
                _Header(
                  title: 'Announcements',
                  onCreate: canCreate
                      ? () => showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (_) => CreateAnnouncementSheet(
                              communityDocId: communityDocId,
                            ),
                          )
                      : null,
                ),
                Expanded(
                  child: StreamBuilder<List<Map<String, dynamic>>>(
                    stream: AnnouncementService.watchAnnouncements(communityDocId),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const _Center(
                          child: CircularProgressIndicator(color: Color(0xFFA78BFA)),
                        );
                      }
                      if (snapshot.hasError) {
                        return _StateMessage(
                          icon: Icons.error_outline_rounded,
                          title: 'Unable to load announcements',
                          subtitle: 'Something went wrong. Please try again.',
                        );
                      }
                      final announcements = snapshot.data ?? [];
                      if (announcements.isEmpty) {
                        return _StateMessage(
                          icon: Icons.campaign_outlined,
                          title: 'No announcements yet',
                          subtitle: canCreate
                              ? 'Post the first announcement for this community.'
                              : 'Check back later for updates from admins.',
                        );
                      }

                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: announcements.length,
                        itemBuilder: (context, index) {
                          final a = announcements[index];
                          return _AnnouncementCard(
                            announcement: a,
                            uid: uid,
                            community: community,
                            communityDocId: communityDocId,
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback? onCreate;

  const _Header({required this.title, this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
          ),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          if (onCreate != null)
            IconButton(
              onPressed: onCreate,
              icon: const Icon(Icons.add_circle_rounded, color: Color(0xFFA78BFA), size: 26),
            ),
        ],
      ),
    );
  }
}

class _AnnouncementCard extends StatelessWidget {
  final Map<String, dynamic> announcement;
  final String uid;
  final Map<String, dynamic> community;
  final String communityDocId;

  const _AnnouncementCard({
    required this.announcement,
    required this.uid,
    required this.community,
    required this.communityDocId,
  });

  @override
  Widget build(BuildContext context) {
    final id = announcement['id'] as String;
    final title = (announcement['title'] ?? '').toString();
    final body = (announcement['body'] ?? '').toString();
    final mediaUrl = (announcement['mediaUrl'] ?? '').toString();
    final linkUrl = (announcement['linkUrl'] ?? '').toString();
    final type = (announcement['type'] ?? 'text').toString();
    final isPinned = announcement['isPinned'] == true;
    final isUrgent = announcement['isUrgent'] == true;
    final authorName = (announcement['authorName'] ?? 'Admin').toString();
    final createdAt = announcement['createdAt'] as Timestamp?;
    final read = AnnouncementService.isRead(announcement, uid);
    final privileged = CommunityService.isPrivileged(community, uid);
    final isAuthor = (announcement['authorUid'] ?? '') == uid;
    final reactions = announcement['reactions'] is Map
        ? Map<String, dynamic>.from(announcement['reactions'])
        : <String, dynamic>{};
    final myReaction = (reactions[uid] ?? '').toString();

    // Mark read the first time it's built and visible (cheap, idempotent).
    if (!read && uid.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AnnouncementService.markRead(id: id, uid: uid);
      });
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isUrgent
              ? Colors.redAccent.withValues(alpha: .6)
              : const Color(0xFFA78BFA).withValues(alpha: read ? .2 : .45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isPinned) ...[
                const Icon(Icons.push_pin_rounded, color: Color(0xFFC4B5FD), size: 15),
                const SizedBox(width: 5),
              ],
              if (isUrgent) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('URGENT',
                      style: TextStyle(
                          color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: read ? FontWeight.w600 : FontWeight.bold,
                  ),
                ),
              ),
              if (privileged || isAuthor)
                PopupMenuButton<String>(
                  color: const Color(0xFF20202A),
                  icon: const Icon(Icons.more_vert_rounded, color: Colors.white54, size: 18),
                  onSelected: (value) => _handleMenu(context, value),
                  itemBuilder: (_) => [
                    if (privileged)
                      PopupMenuItem(
                        value: 'pin',
                        child: Text(isPinned ? 'Unpin' : 'Pin',
                            style: const TextStyle(color: Colors.white)),
                      ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete', style: TextStyle(color: Colors.redAccent)),
                    ),
                  ],
                )
              else
                IconButton(
                  onPressed: () => _report(context),
                  icon: const Icon(Icons.flag_outlined, color: Colors.white38, size: 16),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (body.isNotEmpty)
            Text(body, style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4)),
          if (type == 'image' && mediaUrl.isNotEmpty) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(mediaUrl, fit: BoxFit.cover, width: double.infinity, height: 160),
            ),
          ],
          if (type == 'link' && linkUrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF20202A),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.link_rounded, color: Color(0xFFA78BFA), size: 15),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(linkUrl,
                        style: const TextStyle(color: Color(0xFFC4B5FD), fontSize: 12),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '$authorName${createdAt != null ? ' · ${_formatDate(createdAt.toDate())}' : ''}',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => AnnouncementService.setReaction(
                  id: id,
                  uid: uid,
                  emoji: myReaction == '👍' ? '' : '👍',
                ),
                child: Row(
                  children: [
                    Opacity(
                      opacity: myReaction == '👍' ? 1 : 0.45,
                      child: const Text('👍', style: TextStyle(fontSize: 14)),
                    ),
                    const SizedBox(width: 4),
                    Text('${reactions.length}',
                        style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatDate(DateTime d) {
    final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final minute = d.minute.toString().padLeft(2, '0');
    final period = d.hour >= 12 ? 'PM' : 'AM';
    return '${_months[d.month - 1]} ${d.day}, $hour12:$minute $period';
  }

  void _handleMenu(BuildContext context, String value) async {
    try {
      if (value == 'pin') {
        final isPinned = announcement['isPinned'] == true;
        await AnnouncementService.setPinned(
          id: announcement['id'] as String,
          requesterUid: uid,
          community: community,
          pinned: !isPinned,
        );
      } else if (value == 'delete') {
        await AnnouncementService.deleteAnnouncement(
          id: announcement['id'] as String,
          requesterUid: uid,
          community: community,
        );
      }
    } catch (e) {
      if (context.mounted) {
        showTopAlert(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
      }
    }
  }

  void _report(BuildContext context) async {
    await AnnouncementService.report(id: announcement['id'] as String, uid: uid);
    if (context.mounted) showTopAlert(context, 'Reported. Admins will review this.');
  }
}

class _Center extends StatelessWidget {
  final Widget child;
  const _Center({required this.child});
  @override
  Widget build(BuildContext context) => Center(child: child);
}

class _StateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _StateMessage({required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: const Color(0xFFA78BFA)),
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}

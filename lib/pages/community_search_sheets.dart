import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'community_contribution_section.dart';
import 'community_poll_card.dart';
import 'community_post_detail_page.dart';
import 'community_resource_card.dart';
import 'edit_skills_sheet.dart';
import 'event_detail_page.dart';
import 'groupchat.dart';
import '../services/announcement_service.dart';
import '../services/community_group_service.dart';
import '../services/community_member_profile_service.dart';
import '../services/community_poll_service.dart';
import '../services/community_resource_service.dart';
import '../services/community_search_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// COMMUNITY SEARCH -- OPENING A RESULT
// ----------------------------------------------------------------
// Each result opens the existing screen for that kind of item
// (event page, group chat, post detail) or a sheet that
// reuses the existing card (resource, poll), so every action on the
// result -- vote, download, report, join -- goes through the same
// service and permission checks as everywhere else in Community.
// ================================================================
class CommunitySearchOpener {
  CommunitySearchOpener._();

  static String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  static Future<void> open(
    BuildContext context, {
    required CommunitySearchHit hit,
    required CommunityCorpus corpus,
  }) async {
    switch (hit.kind) {
      case CommunitySearchKind.member:
        return _sheet(
          context,
          _MemberSheet(
            member: hit.data,
            communityDocId: corpus.communityDocId,
          ),
        );

      case CommunitySearchKind.group:
        if (CommunityGroupService.isMember(hit.data, _uid)) {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => GroupChatScreen(groupDocId: hit.id),
          ));
          return;
        }
        return _sheet(context, _GroupSheet(group: hit.data));

      case CommunitySearchKind.event:
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => EventDetailPage(eventDocId: hit.id),
        ));
        return;

      case CommunitySearchKind.post:
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => CommunityPostDetailPage(
            postId: hit.id,
            communityDocId: corpus.communityDocId,
          ),
        ));
        return;

      case CommunitySearchKind.resource:
        return _sheet(
          context,
          _ResourceSheet(resourceId: hit.id, community: corpus.community),
        );

      case CommunitySearchKind.announcement:
        return _sheet(context, _AnnouncementSheet(announcement: hit.data));

      case CommunitySearchKind.poll:
        return _sheet(
          context,
          _PollSheet(pollId: hit.id, community: corpus.community),
        );
    }
  }

  /// Opens a member's Community profile (public info + Contributions).
  /// Used by the Members page; Search opens the same sheet.
  static Future<void> openMember(
    BuildContext context, {
    required String communityDocId,
    required Map<String, dynamic> member,
  }) {
    return _sheet(
      context,
      _MemberSheet(member: member, communityDocId: communityDocId),
    );
  }

  static Future<void> _sheet(BuildContext context, Widget child) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      builder: (_) => child,
    );
  }

  /// Opens the "edit skills" sheet for one of MY profiles (used by the
  /// search page and the member sheet). [profileId] empty -> the profile
  /// I am using in the community right now.
  static Future<bool> editMySkills(
    BuildContext context, {
    required String communityDocId,
    String profileId = '',
  }) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EditSkillsSheet(
        communityDocId: communityDocId,
        profileId: profileId,
      ),
    );
    return saved == true;
  }
}

// ----------------------------------------------------------------
// Member (public information only)
// ----------------------------------------------------------------
class _MemberSheet extends StatelessWidget {
  final Map<String, dynamic> member;
  final String communityDocId;
  const _MemberSheet({required this.member, required this.communityDocId});

  @override
  Widget build(BuildContext context) {
    final role = (member['role'] ?? 'Member').toString();
    // Empty name -> show the role instead (Principal, Student, ...).
    final name = CommunityMemberProfileService.displayName(
        (member['publicName'] ?? '').toString(), role);
    final skills = member['publicSkills'] is List
        ? (member['publicSkills'] as List).map((e) => e.toString()).toList()
        : <String>[];
    final isMe = (member['uid'] ?? '').toString() ==
        (FirebaseAuth.instance.currentUser?.uid ?? '');
    // No name yet -> the role stands in for it, in grey.
    final rawName = (member['publicName'] ?? '').toString().trim();
    // (some callers already pass the role as the name when it is empty)
    final hasName = rawName.isNotEmpty && rawName != role;
    // Principal / HOD / Faculty: no Contributions or Skills.
    final showExtras = !CommunityMemberProfileService.hidesExtras(role);

    return CommunitySheetShell(
      title: 'Member',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          children: [
            CommunityAvatar(
              url: (member['publicImage'] ?? '').toString(),
              name: name,
              radius: 40,
            ),
            const SizedBox(height: 12),
            Text(name,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: hasName ? Colors.white : Colors.grey,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF7C3AED).withValues(alpha: .3),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: CommunityColors.tan.withValues(alpha: .5)),
              ),
              child: Text(role,
                  style: const TextStyle(
                      color: CommunityColors.glow,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600)),
            ),
            if (showExtras) ...[
            const SizedBox(height: 20),
            CommunityContributionSection(
              // Own key per profile: never reuse another profile's numbers.
              key: ValueKey('contrib-${member['profileId'] ?? member['id']}'),
              communityDocId: communityDocId,
              memberUid: (member['uid'] ?? '').toString(),
              memberProfileId:
                  (member['profileId'] ?? member['id'] ?? '').toString(),
              viewerUid: FirebaseAuth.instance.currentUser?.uid ?? '',
              memberName: name,
            ),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Skills',
                  style: TextStyle(
                      color: CommunityColors.tan.withValues(alpha: .9),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: skills.isEmpty
                  ? const Text('No public skills listed.',
                      style: TextStyle(color: Colors.white38, fontSize: 13))
                  : Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final s in skills)
                          Chip(
                            label: Text(s),
                            backgroundColor: const Color(0xFF18181F),
                            labelStyle: const TextStyle(
                                color: CommunityColors.glow, fontSize: 12.5),
                            side: BorderSide(
                                color:
                                    CommunityColors.tan.withValues(alpha: .35)),
                          ),
                      ],
                    ),
            ),
            ],
            if (isMe && showExtras) ...[
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    // Grab a context that outlives this sheet.
                    final rootContext =
                        Navigator.of(context, rootNavigator: true).context;
                    Navigator.of(context).pop();
                    CommunitySearchOpener.editMySkills(
                      rootContext,
                      communityDocId: communityDocId,
                      profileId: (member['profileId'] ?? member['id'] ?? '')
                          .toString(),
                    );
                  },
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  label: const Text('Edit my skills'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: CommunityColors.tan,
                    side: const BorderSide(color: CommunityColors.tan),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------
// Group the user is not in yet: details + join / request
// ----------------------------------------------------------------
class _GroupSheet extends StatefulWidget {
  final Map<String, dynamic> group;
  const _GroupSheet({required this.group});

  @override
  State<_GroupSheet> createState() => _GroupSheetState();
}

class _GroupSheetState extends State<_GroupSheet> {
  bool _busy = false;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';
  String get _id => (widget.group['id'] ?? '').toString();

  Future<void> _join() async {
    setState(() => _busy = true);
    try {
      final result = await CommunityGroupService.joinOrRequest(
        groupDocId: _id,
        uid: _uid,
        group: widget.group,
      );
      if (!mounted) return;
      final navigator = Navigator.of(context);
      navigator.pop();
      if (result == 'joined') {
        navigator.push(MaterialPageRoute(
          builder: (_) => GroupChatScreen(groupDocId: _id),
        ));
      } else {
        showTopAlert(navigator.context, 'Request sent to the group admins');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final name = (g['groupName'] ?? g['name'] ?? 'Group').toString();
    final desc = (g['description'] ?? '').toString();
    final type = (g['groupType'] ?? 'public').toString();
    final count = g['membersCount'] is int ? g['membersCount'] as int : 0;
    final pending = g['pendingMembers'] is List &&
        (g['pendingMembers'] as List).contains(_uid);

    final String actionLabel;
    switch (type) {
      case 'approval':
        actionLabel = pending ? 'Request pending' : 'Request to join';
        break;
      case 'private':
        actionLabel = 'Invite only';
        break;
      default:
        actionLabel = 'Join group';
    }
    final canAct = !_busy && type != 'private' && !pending;

    return CommunitySheetShell(
      title: 'Group',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CommunityAvatar(
                    url: (g['groupProfileImage'] ?? '').toString(),
                    name: name,
                    radius: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(
                          '$count member${count == 1 ? '' : 's'} · '
                          '${type[0].toUpperCase()}${type.substring(1)} group',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12.5)),
                    ],
                  ),
                ),
              ],
            ),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(desc,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 13.5, height: 1.4)),
            ],
            if (type == 'private') ...[
              const SizedBox(height: 14),
              const Text('This group is invite-only. Ask a group admin to add you.',
                  style: TextStyle(color: Colors.white54, fontSize: 12.5)),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: canAct ? _join : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: CommunityColors.tan,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: Colors.white12,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black))
                    : Text(actionLabel,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------
// Resource (live, so a delete/report is reflected immediately)
// ----------------------------------------------------------------
class _ResourceSheet extends StatelessWidget {
  final String resourceId;
  final Map<String, dynamic> community;
  const _ResourceSheet({required this.resourceId, required this.community});

  @override
  Widget build(BuildContext context) {
    return CommunitySheetShell(
      title: 'Resource',
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: CommunityResourceService.resources.doc(resourceId).snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: CommunityStateMessage(
                icon: Icons.error_outline_rounded,
                title: 'Unable to load this resource',
                subtitle: 'Check your connection and try again.',
              ),
            );
          }
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: CommunityLoading(),
            );
          }
          final data = snap.data!.data();
          if (data == null) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: CommunityStateMessage(
                icon: Icons.delete_outline_rounded,
                title: 'Resource removed',
                subtitle: 'This resource is no longer available.',
              ),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            child: CommunityResourceCard(
              resource: {...data, 'id': snap.data!.id},
              community: community,
            ),
          );
        },
      ),
    );
  }
}

// ----------------------------------------------------------------
// Poll (live, so voting and results work exactly like the Polls page)
// ----------------------------------------------------------------
class _PollSheet extends StatelessWidget {
  final String pollId;
  final Map<String, dynamic> community;
  const _PollSheet({required this.pollId, required this.community});

  @override
  Widget build(BuildContext context) {
    return CommunitySheetShell(
      title: 'Poll',
      child: StreamBuilder<Map<String, dynamic>?>(
        stream: CommunityPollService.watchPoll(pollId),
        builder: (context, snap) {
          if (snap.hasError) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: CommunityStateMessage(
                icon: Icons.error_outline_rounded,
                title: 'Unable to load this poll',
                subtitle: 'Check your connection and try again.',
              ),
            );
          }
          if (snap.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: CommunityLoading(),
            );
          }
          final poll = snap.data;
          if (poll == null) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: CommunityStateMessage(
                icon: Icons.delete_outline_rounded,
                title: 'Poll removed',
                subtitle: 'This poll is no longer available.',
              ),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            child: CommunityPollCard(
              poll: poll,
              community: community,
              standalone: true,
            ),
          );
        },
      ),
    );
  }
}

// ----------------------------------------------------------------
// Announcement (read-only view; opening it marks it read, like the
// Announcements page does)
// ----------------------------------------------------------------
class _AnnouncementSheet extends StatefulWidget {
  final Map<String, dynamic> announcement;
  const _AnnouncementSheet({required this.announcement});

  @override
  State<_AnnouncementSheet> createState() => _AnnouncementSheetState();
}

class _AnnouncementSheetState extends State<_AnnouncementSheet> {
  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final id = (widget.announcement['id'] ?? '').toString();
    if (uid.isNotEmpty &&
        id.isNotEmpty &&
        !AnnouncementService.isRead(widget.announcement, uid)) {
      AnnouncementService.markRead(id: id, uid: uid).catchError((_) {});
    }
  }

  Future<void> _openLink(String url) async {
    try {
      final ok =
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        showTopAlert(context, 'Couldn\'t open this link.', isError: true);
      }
    } catch (_) {
      if (mounted) {
        showTopAlert(context, 'Couldn\'t open this link.', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.announcement;
    final title = (a['title'] ?? '').toString();
    final body = (a['body'] ?? '').toString();
    final link = (a['linkUrl'] ?? '').toString();
    final media = (a['mediaUrl'] ?? '').toString();
    final urgent = a['isUrgent'] == true;
    final created = communityToDate(a['createdAt']);

    return CommunitySheetShell(
      title: 'Announcement',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (urgent)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: CommunityColors.danger.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('URGENT',
                    style: TextStyle(
                        color: CommunityColors.danger,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ),
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'by ${(a['authorName'] ?? 'Admin')}'
              '${created == null ? '' : ' · ${communityFormatDate(created)}'}',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(body,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 14, height: 1.45)),
            ],
            if (media.isNotEmpty) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  media,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ],
            if (link.isNotEmpty) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () => _openLink(link),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Open link'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: CommunityColors.tan,
                  side: const BorderSide(color: CommunityColors.tan),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
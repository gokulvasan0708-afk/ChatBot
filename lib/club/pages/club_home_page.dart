import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../club_icons.dart';
import '../models/club_model.dart';
import '../../pages/app_theme.dart';
import '../../services/club_service.dart';
import '../../widgets/top_alert.dart';
import '../widgets/club_section_nav.dart';
import 'club_discussions_page.dart';
import 'club_announcements_page.dart';
import 'club_members_page.dart';
import 'club_polls_page.dart';
import 'club_activities_page.dart';
import 'club_watchlist_page.dart';
import 'club_notifications_page.dart';
import 'club_rules_page.dart';
import 'club_moderation_page.dart';

/// Phase 1 Club Home.
///
/// This screen is intentionally built on top of the existing Nexus visual
/// language instead of introducing a second design system. It is the shell
/// that later phases attach Discussions, Members, Polls, Activities,
/// Watchlist, Notifications and Rules to.
class ClubHomePage extends StatefulWidget {
  final String clubDocId;

  const ClubHomePage({
    super.key,
    required this.clubDocId,
  });

  @override
  State<ClubHomePage> createState() => _ClubHomePageState();
}

class _ClubHomePageState extends State<ClubHomePage> {
  ClubSection _section = ClubSection.home;

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: ClubService.watchClub(widget.clubDocId),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.tan),
              );
            }

            if (snapshot.hasError) {
              return _StateMessage(
                icon: Icons.error_outline_rounded,
                title: 'Unable to load club',
                subtitle: 'Check your connection and try again.',
                onBack: () => Navigator.of(context).pop(),
              );
            }

            final document = snapshot.data;
            if (document == null || !document.exists) {
              return _StateMessage(
                icon: ClubIcons.club,
                title: 'Club not found',
                subtitle: 'This club may have been deleted.',
                onBack: () => Navigator.of(context).pop(),
              );
            }

            final club = ClubModel.fromFirestore(document);
            final raw = document.data() ?? <String, dynamic>{};
            final isMember = club.isMember(uid);
            final isOwner = club.isOwner(uid);
            final isLeader = ClubService.isLeader(raw, uid);
            final canModerate = isLeader || club.isOwner(uid) || club.isModerator(uid);
            final pending = ClubService.hasPendingRequest(raw, uid);

            return Column(
              children: [
                _TopBar(
                  onBack: () => Navigator.of(context).pop(),
                  isLeader: canModerate,
                  onAnnouncements: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ClubAnnouncementsPage(clubDocId: club.id, canModerate: isLeader))),
                  onManage: isLeader
                      ? () => _showProfileEditor(context, club, raw, uid)
                      : null,
                  onModeration: canModerate
                      ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => ClubModerationPage(clubDocId: club.id, moderatorUid: uid)))
                      : null,
                ),
                ClubSectionNav(
                  selected: _section,
                  onChanged: (section) => setState(() => _section = section),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _section == ClubSection.home
                      ? _ClubHomeContent(
                          club: club,
                          rawClub: raw,
                          uid: uid,
                          isMember: isMember,
                          isOwner: isOwner,
                          isLeader: isLeader,
                          pending: pending,
                          onJoin: () => _join(context, uid),
                          onCancelRequest: () => _cancelRequest(context, uid),
                          onLeave: () => _leave(context, club, raw, uid),
                          onShare: () => _shareClub(context, club),
                        )
                      : _buildSection(section: _section, club: club, isLeader: canModerate),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSection({required ClubSection section, required ClubModel club, required bool isLeader}) {
    switch (section) {
      case ClubSection.home:
        return const SizedBox.shrink();
      case ClubSection.discussions:
        return ClubDiscussionsPage(clubDocId: club.id, canModerate: isLeader);
      case ClubSection.members:
        return ClubMembersPage(club: club);
      case ClubSection.polls:
        return ClubPollsPage(clubDocId: club.id, canCreate: isLeader);
      case ClubSection.activities:
        return ClubActivitiesPage(clubDocId: club.id, canCreate: isLeader);
      case ClubSection.watchlist:
        return ClubWatchlistPage(clubDocId: club.id);
      case ClubSection.notifications:
        return const ClubNotificationsPage();
      case ClubSection.rules:
        return ClubRulesPage(club: club);
      default:
        return ClubSectionPlaceholder(section: section);
    }
  }

  Future<void> _join(BuildContext context, String uid) async {
    if (uid.isEmpty) {
      showTopAlert(context, 'Please sign in to join a club.', isError: true);
      return;
    }
    try {
      final result = await ClubService.joinOrRequest(
        clubDocId: widget.clubDocId,
        uid: uid,
      );
      if (!mounted) return;
      showTopAlert(
        context,
        result == 'requested' ? 'Join request sent.' : 'You joined the club.',
      );
    } catch (e) {
      if (!mounted) return;
      showTopAlert(
        context,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    }
  }

  Future<void> _cancelRequest(BuildContext context, String uid) async {
    try {
      await ClubService.cancelRequest(
        clubDocId: widget.clubDocId,
        uid: uid,
      );
      if (!mounted) return;
      showTopAlert(context, 'Join request cancelled.');
    } catch (e) {
      if (!mounted) return;
      showTopAlert(
        context,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    }
  }

  Future<void> _leave(
    BuildContext context,
    ClubModel club,
    Map<String, dynamic> rawClub,
    String uid,
  ) async {
    final shouldLeave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1B120A),
        title: const Text(
          'Leave Club?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'You can join again later if the club allows it.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'Leave',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (shouldLeave != true) return;

    try {
      await ClubService.leaveClub(
        clubDocId: club.id,
        uid: uid,
        club: rawClub,
      );
      if (!mounted) return;
      showTopAlert(context, 'You left the club.');
    } catch (e) {
      if (!mounted) return;
      showTopAlert(
        context,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    }
  }

  Future<void> _shareClub(BuildContext context, ClubModel club) async {
    await Clipboard.setData(
      ClipboardData(
        text: club.clubId.isEmpty
            ? 'Club: ${club.name}'
            : 'Club: ${club.name}\nClub ID: ${club.clubId}',
      ),
    );
    if (!mounted) return;
    showTopAlert(context, 'Club details copied to clipboard.');
  }

  Future<void> _showProfileEditor(
    BuildContext context,
    ClubModel club,
    Map<String, dynamic> raw,
    String uid,
  ) async {
    final nameController = TextEditingController(text: club.name);
    final descriptionController =
        TextEditingController(text: club.description);
    final aboutController = TextEditingController(text: club.about);
    final rulesController = TextEditingController(text: club.rules);
    final avatarController = TextEditingController(text: club.avatarUrl);
    final bannerController = TextEditingController(text: club.bannerUrl);

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF1B120A),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (sheetContext) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              MediaQuery.of(sheetContext).viewInsets.bottom + 18,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Club Profile',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _EditField(
                    controller: nameController,
                    label: 'Name',
                  ),
                  _EditField(
                    controller: descriptionController,
                    label: 'Description',
                    maxLines: 2,
                  ),
                  _EditField(
                    controller: aboutController,
                    label: 'About',
                    maxLines: 4,
                  ),
                  _EditField(
                    controller: rulesController,
                    label: 'Rules',
                    maxLines: 5,
                  ),
                  _EditField(
                    controller: avatarController,
                    label: 'Avatar URL',
                  ),
                  _EditField(
                    controller: bannerController,
                    label: 'Banner URL',
                  ),
                  const SizedBox(height: 8),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: AppColors.goldGradient,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () async {
                          try {
                            await ClubService.updateClubProfile(
                              clubDocId: club.id,
                              requesterUid: uid,
                              club: raw,
                              name: nameController.text,
                              description: descriptionController.text,
                              about: aboutController.text,
                              rules: rulesController.text,
                              avatarUrl: avatarController.text,
                              bannerUrl: bannerController.text,
                            );
                            if (sheetContext.mounted) {
                              Navigator.pop(sheetContext);
                            }
                            if (mounted) {
                              showTopAlert(context, 'Club profile updated.');
                            }
                          } catch (e) {
                            if (sheetContext.mounted) {
                              showTopAlert(
                                sheetContext,
                                e.toString().replaceFirst('Exception: ', ''),
                                isError: true,
                              );
                            }
                          }
                        },
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Center(
                            child: Text(
                              'Save Changes',
                              style: TextStyle(
                                color: Color(0xFF1B120A),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } finally {
      nameController.dispose();
      descriptionController.dispose();
      aboutController.dispose();
      rulesController.dispose();
      avatarController.dispose();
      bannerController.dispose();
    }
  }
}

class _ClubHomeContent extends StatelessWidget {
  final ClubModel club;
  final Map<String, dynamic> rawClub;
  final String uid;
  final bool isMember;
  final bool isOwner;
  final bool isLeader;
  final bool pending;
  final VoidCallback onJoin;
  final VoidCallback onCancelRequest;
  final VoidCallback onLeave;
  final VoidCallback onShare;

  const _ClubHomeContent({
    required this.club,
    required this.rawClub,
    required this.uid,
    required this.isMember,
    required this.isOwner,
    required this.isLeader,
    required this.pending,
    required this.onJoin,
    required this.onCancelRequest,
    required this.onLeave,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: _Banner(
            url: club.bannerUrl,
            height: 180,
          ),
        ),
        SliverToBoxAdapter(
          child: Transform.translate(
            offset: const Offset(0, -42),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  _Avatar(url: club.avatarUrl, size: 88),
                  const SizedBox(height: 10),
                  Text(
                    club.name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .2,
                    ),
                  ),
                  if (club.clubId.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _ClubIdChip(clubId: club.clubId),
                  ],
                  if (club.category.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      club.category,
                      style: const TextStyle(
                        color: Color(0xFFFFE9B0),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (club.description.isNotEmpty) ...[
                    const SizedBox(height: 9),
                    Text(
                      club.description,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _MemberCount(count: club.membersCount),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (!isMember)
                        _JoinButton(
                          pending: pending,
                          joinMode: club.joinMode,
                          onJoin: onJoin,
                          onCancel: onCancelRequest,
                        )
                      else if (!isOwner)
                        OutlinedButton(
                          onPressed: onLeave,
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.white30),
                            foregroundColor: Colors.white70,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                          ),
                          child: const Text('Leave'),
                        )
                      else
                        _RoleBadge(label: 'Owner'),
                      const SizedBox(width: 9),
                      OutlinedButton.icon(
                        onPressed: onShare,
                        icon: const Icon(Icons.share_rounded, size: 17),
                        label: const Text('Share'),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.tan),
                          foregroundColor: const Color(0xFFFFE9B0),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: Column(
              children: [
                _InfoSection(
                  icon: Icons.info_outline_rounded,
                  title: 'About',
                  child: Text(
                    club.about.isEmpty
                        ? 'No about information has been added yet.'
                        : club.about,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _InfoSection(
                  icon: Icons.rule_rounded,
                  title: 'Rules',
                  child: Text(
                    club.rules.isEmpty
                        ? 'Club rules will be added by the owner.'
                        : club.rules,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _PeopleSection(
                  club: club,
                  label: 'Owner',
                  uids: club.ownerUid.isEmpty
                      ? <String>[]
                      : <String>[club.ownerUid],
                ),
                const SizedBox(height: 12),
                _PeopleSection(
                  club: club,
                  label: 'Moderators',
                  uids: club.moderatorUids,
                ),
                const SizedBox(height: 18),
                _ClubMetaCard(
                  createdAt: club.createdAt,
                  category: club.category,
                  joinMode: club.joinMode,
                  isMember: isMember,
                  isLeader: isLeader,
                ),
                const SizedBox(height: 30),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback? onManage;
  final VoidCallback? onModeration;
  final VoidCallback onAnnouncements;
  final bool isLeader;

  const _TopBar({
    required this.onBack,
    required this.isLeader,
    required this.onManage,
    required this.onModeration,
    required this.onAnnouncements,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
          const Expanded(
            child: Text(
              'Club',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            onPressed: onAnnouncements,
            icon: const Icon(Icons.campaign_rounded, color: AppColors.tan, size: 21),
          ),
          if (isLeader)
            IconButton(
              onPressed: onModeration,
              icon: const Icon(Icons.admin_panel_settings_outlined, color: AppColors.tan, size: 21),
              tooltip: 'Moderation',
            ),
          if (isLeader)
            IconButton(
              onPressed: onManage,
              icon: const Icon(
                Icons.edit_rounded,
                color: AppColors.tan,
                size: 21,
              ),
            ),
        ],
      ),
    );
  }
}

/// Shows the Club ID (e.g. "@Coding Club-A1B2") under the club name.
/// Tap to copy it -- same idea as sharing a Group ID.
class _ClubIdChip extends StatelessWidget {
  final String clubId;

  const _ClubIdChip({required this.clubId});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: clubId));
        if (!context.mounted) return;
        showTopAlert(context, 'Club ID copied.');
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF1B120A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.tan.withValues(alpha: .35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tag_rounded, size: 14, color: AppColors.tan),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                clubId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFFFE9B0),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.copy_rounded, size: 12, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String url;
  final double height;

  const _Banner({required this.url, required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: AppColors.accentGradient,
      ),
      child: url.isEmpty
          ? const Center(
              child: Icon(
                ClubIcons.club,
                color: Color(0xFFFFE9B0),
                size: 48,
              ),
            )
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const Center(
                child: Icon(
                  Icons.image_not_supported_outlined,
                  color: Color(0xFFFFE9B0),
                  size: 40,
                ),
              ),
            ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String url;
  final double size;

  const _Avatar({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF2A1B0E),
        border: Border.all(color: AppColors.tan, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 16,
            spreadRadius: 1,
          ),
        ],
      ),
      child: url.isEmpty
          ? const Icon(
              ClubIcons.club,
              color: AppColors.tan,
              size: 38,
            )
          : ClipOval(
              child: Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(
                  ClubIcons.club,
                  color: AppColors.tan,
                  size: 38,
                ),
              ),
            ),
    );
  }
}

class _MemberCount extends StatelessWidget {
  final int count;

  const _MemberCount({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF1B120A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.tan.withValues(alpha: .30),
        ),
      ),
      child: Text(
        '$count member${count == 1 ? '' : 's'}',
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _JoinButton extends StatelessWidget {
  final bool pending;
  final String joinMode;
  final VoidCallback onJoin;
  final VoidCallback onCancel;

  const _JoinButton({
    required this.pending,
    required this.joinMode,
    required this.onJoin,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    if (pending) {
      return OutlinedButton(
        onPressed: onCancel,
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.white30),
          foregroundColor: Colors.white70,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
        child: const Text('Cancel Request'),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: AppColors.goldGradient,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onJoin,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 22,
              vertical: 13,
            ),
            child: Text(
              joinMode == 'approval' ? 'Request to Join' : 'Join Club',
              style: const TextStyle(
                color: Color(0xFF1B120A),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  final String label;

  const _RoleBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFF8B4513).withValues(alpha: .30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.tan.withValues(alpha: .45)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFFFE9B0),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _InfoSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _InfoSection({
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1B120A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppColors.tan.withValues(alpha: .25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.tan, size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _PeopleSection extends StatelessWidget {
  final ClubModel club;
  final String label;
  final List<String> uids;

  const _PeopleSection({
    required this.club,
    required this.label,
    required this.uids,
  });

  @override
  Widget build(BuildContext context) {
    if (uids.isEmpty) {
      return _InfoSection(
        icon: label == 'Owner'
            ? Icons.workspace_premium_rounded
            : Icons.shield_rounded,
        title: label,
        child: Text(
          label == 'Owner' ? 'Owner information unavailable.' : 'No moderators added yet.',
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
      );
    }

    return _InfoSection(
      icon: label == 'Owner'
          ? Icons.workspace_premium_rounded
          : Icons.shield_rounded,
      title: label,
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _loadUsers(uids),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const SizedBox(
              height: 42,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.tan,
                  ),
                ),
              ),
            );
          }

          final users = snapshot.data ?? const <Map<String, dynamic>>[];
          if (users.isEmpty) {
            return const Text(
              'Profile information unavailable.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            );
          }

          return Column(
            children: users
                .map(
                  (user) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        _Avatar(
                          url: (user['publicImage'] ?? '').toString(),
                          size: 38,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            (user['publicName'] ?? 'Member').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (label == 'Owner')
                          const _RoleBadge(label: 'Owner')
                        else
                          const _RoleBadge(label: 'Moderator'),
                      ],
                    ),
                  ),
                )
                .toList(),
          );
        },
      ),
    );
  }

  Future<List<Map<String, dynamic>>> _loadUsers(List<String> ids) async {
    final result = <Map<String, dynamic>>[];
    final firestore = FirebaseFirestore.instance;

    for (var start = 0; start < ids.length; start += 10) {
      final end = start + 10 > ids.length ? ids.length : start + 10;
      final batch = ids.sublist(start, end);
      if (batch.isEmpty) continue;

      final snapshot = await firestore
          .collection('users')
          .where(FieldPath.documentId, whereIn: batch)
          .get();

      for (final document in snapshot.docs) {
        result.add({...document.data(), 'uid': document.id});
      }
    }

    return result;
  }
}

class _ClubMetaCard extends StatelessWidget {
  final DateTime? createdAt;
  final String category;
  final String joinMode;
  final bool isMember;
  final bool isLeader;

  const _ClubMetaCard({
    required this.createdAt,
    required this.category,
    required this.joinMode,
    required this.isMember,
    required this.isLeader,
  });

  @override
  Widget build(BuildContext context) {
    final date = createdAt == null
        ? 'Recently'
        : '${createdAt!.day.toString().padLeft(2, '0')}/'
            '${createdAt!.month.toString().padLeft(2, '0')}/'
            '${createdAt!.year}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF120C07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.tan.withValues(alpha: .20),
        ),
      ),
      child: Wrap(
        spacing: 9,
        runSpacing: 9,
        children: [
          _MetaChip(icon: Icons.category_rounded, text: category.isEmpty ? 'Club' : category),
          _MetaChip(
            icon: joinMode == 'approval'
                ? Icons.fact_check_rounded
                : Icons.lock_open_rounded,
            text: joinMode == 'approval' ? 'Approval' : 'Open',
          ),
          if (isMember)
            const _MetaChip(icon: Icons.verified_rounded, text: 'Member'),
          if (isLeader)
            const _MetaChip(icon: Icons.shield_rounded, text: 'Leader'),
          _MetaChip(icon: Icons.calendar_today_rounded, text: date),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MetaChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF1B120A),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.tan),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(color: Colors.white60, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _EditField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final int maxLines;

  const _EditField({
    required this.controller,
    required this.label,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white54),
          filled: true,
          fillColor: const Color(0xFF2A1B0E),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class _StateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onBack;

  const _StateMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: AppColors.tan),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
            if (onBack != null) ...[
              const SizedBox(height: 18),
              OutlinedButton(
                onPressed: onBack,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.tan),
                  foregroundColor: const Color(0xFFFFE9B0),
                ),
                child: const Text('Go Back'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'club_detail_page.dart';
import 'create_club_dialog.dart';
import '../club/club_icons.dart';
import '../services/club_service.dart';

// ================================================================
// COMMUNITY CLUBS
// ----------------------------------------------------------------
// Lists the clubs that belong to ONE community (communityDocId),
// the same way CommunityGroupsPage lists its groups. Tapping a club
// opens the normal Club module (club/pages/club_home_page.dart), so
// everything a club can do (discussions, polls, activities,
// announcements, members, moderation, recruitment ...) works here.
//
// These clubs live in their own collections (club/club_paths.dart),
// so they are NEVER mixed with the clubs on the Hubs > Clubs page.
// ================================================================
class CommunityClubsPage extends StatefulWidget {
  final String communityDocId;

  const CommunityClubsPage({super.key, required this.communityDocId});

  @override
  State<CommunityClubsPage> createState() => _CommunityClubsPageState();
}

class _CommunityClubsPageState extends State<CommunityClubsPage> {
  // Created once -- building the stream inside build() would
  // re-subscribe to Firestore on every rebuild.
  late final Stream<List<Map<String, dynamic>>> _clubs =
      ClubService.watchCommunityClubs(widget.communityDocId);

  void _create() {
    showDialog(
      context: context,
      builder: (_) => CreateClubDialog(communityDocId: widget.communityDocId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white, size: 18),
                  ),
                  const Expanded(
                    child: Text(
                      'Clubs',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _create,
                    icon: const Icon(Icons.add_circle_rounded,
                        color: Color(0xFFD2B48C), size: 26),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _clubs,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(
                          color: Color(0xFFD2B48C)),
                    );
                  }
                  if (snapshot.hasError) {
                    return const _ClubsMessage(
                      icon: Icons.error_outline_rounded,
                      title: 'Unable to load clubs',
                      subtitle: 'Something went wrong. Please try again.',
                    );
                  }
                  final clubs = snapshot.data ?? [];
                  if (clubs.isEmpty) {
                    return _ClubsMessage(
                      icon: ClubIcons.club,
                      title: 'No clubs yet',
                      subtitle: 'Start the first club in this community.',
                      actionLabel: 'Create Club',
                      onAction: _create,
                    );
                  }

                  // My clubs first, then the rest (each newest first).
                  final mine = <Map<String, dynamic>>[];
                  final others = <Map<String, dynamic>>[];
                  for (final c in clubs) {
                    (ClubService.isMember(c, uid) ? mine : others).add(c);
                  }

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      if (mine.isNotEmpty) ...[
                        const _SectionLabel('My clubs'),
                        for (final c in mine) _ClubCard(club: c, uid: uid),
                      ],
                      if (others.isNotEmpty) ...[
                        _SectionLabel(
                            mine.isEmpty ? 'Clubs in this community' : 'Discover'),
                        for (final c in others) _ClubCard(club: c, uid: uid),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ClubCard extends StatelessWidget {
  final Map<String, dynamic> club;
  final String uid;

  const _ClubCard({required this.club, required this.uid});

  @override
  Widget build(BuildContext context) {
    final id = (club['id'] ?? '').toString();
    final name = (club['name'] ?? '').toString();
    final category = (club['category'] ?? '').toString();
    final logoUrl = (club['logoUrl'] ?? '').toString();
    final membersCount =
        (club['membersCount'] is int) ? club['membersCount'] as int : 0;
    final isMember = ClubService.isMember(club, uid);
    final requested = ClubService.hasPendingRequest(club, uid);
    final isLeader = ClubService.isLeader(club, uid);
    final pending = club['pendingRequests'] is List
        ? (club['pendingRequests'] as List).length
        : 0;

    String? tag;
    if (isLeader) {
      tag = pending > 0 ? 'Leader · $pending request${pending == 1 ? '' : 's'}' : 'Leader';
    } else if (isMember) {
      tag = 'Joined';
    } else if (requested) {
      tag = 'Requested';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: const Color(0xFF1B120A),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          // The club page itself shows Join / Request / Leave.
          onTap: id.isEmpty
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ClubDetailPage(clubDocId: id),
                    ),
                  ),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFFD2B48C).withValues(alpha: .3),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF2A1B0E),
                    border: Border.all(
                      color: const Color(0xFFD2B48C).withValues(alpha: .6),
                    ),
                  ),
                  child: logoUrl.isEmpty
                      ? const Icon(ClubIcons.club,
                          color: Color(0xFFD2B48C), size: 22)
                      : ClipOval(
                          child: Image.network(
                            logoUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(
                                ClubIcons.club,
                                color: Color(0xFFD2B48C),
                                size: 22),
                          ),
                        ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? 'Unnamed Club' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (category.isNotEmpty) category,
                          '$membersCount member${membersCount == 1 ? '' : 's'}',
                        ].join(' · '),
                        style:
                            const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      if (tag != null) ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF8B4513).withValues(alpha: .45),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            tag,
                            style: const TextStyle(
                              color: Color(0xFFFFE9B0),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ClubsMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _ClubsMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: const Color(0xFFD2B48C)),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFD2B48C)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: Text(actionLabel!,
                    style: const TextStyle(color: Color(0xFFFFE9B0))),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'community_poll_card.dart';
import 'create_poll_sheet.dart';
import '../services/community_poll_service.dart';
import '../services/community_service.dart';
import '../widgets/community_widgets.dart';

// ================================================================
// COMMUNITY POLLS  (spec -- Section 7)
// ----------------------------------------------------------------
// Dedicated poll list: Active / Ended / My polls. Group-
// specific polls are only listed for members of that group.
// ================================================================
class CommunityPollsPage extends StatefulWidget {
  final String communityDocId;

  const CommunityPollsPage({super.key, required this.communityDocId});

  @override
  State<CommunityPollsPage> createState() => _CommunityPollsPageState();
}

class _CommunityPollsPageState extends State<CommunityPollsPage> {
  String _tab = 'active'; // active | ended | mine
  late Future<PollAudience> _audienceFuture;
  int _reloadKey = 0;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _audienceFuture = _loadAudience();
  }

  Future<PollAudience> _loadAudience() {
    return CommunityPollService.loadAudience(
      communityDocId: widget.communityDocId,
      uid: _uid,
    );
  }

  void _retry() {
    setState(() {
      _audienceFuture = _loadAudience();
      _reloadKey++;
    });
  }

  Future<void> _create() async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CreatePollSheet(communityDocId: widget.communityDocId),
    );
    if (!mounted) return;
    // A new group membership may have changed the audience.
    setState(() => _audienceFuture = _loadAudience());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: CommunityService.watchCommunity(widget.communityDocId),
          builder: (context, communitySnap) {
            if (communitySnap.connectionState == ConnectionState.waiting) {
              return const CommunityLoading();
            }
            final community = communitySnap.data?.data();
            if (community == null) {
              return const CommunityStateMessage(
                icon: Icons.public_off_rounded,
                title: 'Community not found',
                subtitle: 'This community may have been deleted.',
              );
            }
            final isMember = (community['members'] is List) &&
                (community['members'] as List).contains(_uid);

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 12, 4),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back_ios_new_rounded,
                            color: Colors.white, size: 18),
                      ),
                      const Expanded(
                        child: Text('Polls',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold)),
                      ),
                      if (isMember)
                        IconButton(
                          onPressed: _create,
                          tooltip: 'Create poll',
                          icon: const Icon(Icons.add_circle_outline_rounded,
                              color: CommunityColors.tan, size: 26),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Row(
                    children: [
                      for (final t in const [
                        ['active', 'Active'],
                        ['ended', 'Ended'],
                        ['mine', 'My polls'],
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(t[1]),
                            selected: _tab == t[0],
                            onSelected: (_) => setState(() => _tab = t[0]),
                            selectedColor: CommunityColors.tan,
                            backgroundColor: CommunityColors.card,
                            labelStyle: TextStyle(
                              color: _tab == t[0] ? Colors.black : Colors.white70,
                              fontWeight: FontWeight.w600,
                            ),
                            side: BorderSide(
                                color:
                                    CommunityColors.tan.withValues(alpha: .3)),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: FutureBuilder<PollAudience>(
                    key: ValueKey(_reloadKey),
                    future: _audienceFuture,
                    builder: (context, audienceSnap) {
                      if (audienceSnap.connectionState ==
                          ConnectionState.waiting) {
                        return const CommunityLoading();
                      }
                      if (audienceSnap.hasError) {
                        return CommunityStateMessage(
                          icon: Icons.error_outline_rounded,
                          title: 'Unable to load polls',
                          subtitle: 'Check your connection and try again.',
                          actionLabel: 'Retry',
                          onAction: _retry,
                        );
                      }
                      final audience = audienceSnap.data ?? PollAudience.empty;
                      return _buildList(community, audience);
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

  Widget _buildList(Map<String, dynamic> community, PollAudience audience) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: CommunityPollService.watchPolls(widget.communityDocId),
      builder: (context, snap) {
        if (snap.hasError) {
          return CommunityStateMessage(
            icon: Icons.error_outline_rounded,
            title: 'Unable to load polls',
            subtitle: 'Something went wrong. Please try again.',
            actionLabel: 'Retry',
            onAction: _retry,
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const CommunityLoading();
        }

        var polls = (snap.data ?? [])
            .where((p) => CommunityPollService.isVisibleTo(p, _uid, audience))
            .toList();

        switch (_tab) {
          case 'ended':
            polls = polls.where(CommunityPollService.isEnded).toList();
            break;
          case 'mine':
            polls = polls
                .where((p) => CommunityPollService.isAuthor(p, _uid))
                .toList();
            break;
          case 'active':
          default:
            polls = polls.where((p) => !CommunityPollService.isEnded(p)).toList();
        }

        if (polls.isEmpty) {
          final label = _tab == 'ended'
              ? 'No ended polls'
              : _tab == 'mine'
                  ? 'You haven\'t created any polls'
                  : 'No active polls';
          return CommunityStateMessage(
            icon: Icons.poll_outlined,
            title: label,
            subtitle: 'Polls created in this community will appear here.',
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: polls.length,
          itemBuilder: (_, i) => CommunityPollCard(
            key: ValueKey(polls[i]['id']),
            poll: polls[i],
            community: community,
            standalone: true,
          ),
        );
      },
    );
  }
}

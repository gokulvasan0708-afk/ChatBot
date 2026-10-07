import 'package:flutter/material.dart';

import '../services/community_contribution_service.dart';
import '../widgets/community_widgets.dart';

// ================================================================
// COMMUNITY CONTRIBUTION SECTION  (Community spec -- Section 18)
// ----------------------------------------------------------------
// Drop-in section for a member's Community profile (used by the
// member sheet in community_search_sheets.dart, which is opened from
// both Members and Search). It shows what the member has actually
// DONE in this Community -- resources shared, questions answered,
// events attended (real check-ins) and achievements --
// as plain counts and a few recent items.
//
// Deliberately NOT a popularity system: no points, levels, ranks,
// leaderboards, like/reaction totals or comparisons between people.
// ================================================================
class CommunityContributionSection extends StatefulWidget {
  final String communityDocId;
  final String memberUid;
  final String viewerUid;

  /// The member PROFILE (Profile ID) whose contributions are shown. Two
  /// profiles of one account never share contributions.
  final String memberProfileId;

  /// First name / display name, used in the empty-state sentence.
  final String memberName;

  const CommunityContributionSection({
    super.key,
    required this.communityDocId,
    required this.memberUid,
    required this.viewerUid,
    this.memberProfileId = '',
    this.memberName = '',
  });

  @override
  State<CommunityContributionSection> createState() =>
      _CommunityContributionSectionState();
}

class _CommunityContributionSectionState
    extends State<CommunityContributionSection> {
  late Future<CommunityContribution> _future;

  bool get _isMe => widget.memberUid == widget.viewerUid;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<CommunityContribution> _load() {
    return CommunityContributionService.load(
      communityDocId: widget.communityDocId,
      memberUid: widget.memberUid,
      viewerUid: widget.viewerUid,
      memberProfileId: widget.memberProfileId,
    );
  }

  @override
  void didUpdateWidget(covariant CommunityContributionSection old) {
    super.didUpdateWidget(old);
    // A different profile (Profile ID) must never keep showing the
    // previous profile's numbers.
    if (old.memberProfileId != widget.memberProfileId ||
        old.memberUid != widget.memberUid ||
        old.communityDocId != widget.communityDocId) {
      _future = _load();
    }
  }

  void _retry() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Contributions',
          style: TextStyle(
            color: CommunityColors.tan.withValues(alpha: .9),
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        FutureBuilder<CommunityContribution>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: CommunityColors.tan,
                    ),
                  ),
                ),
              );
            }
            if (snap.hasError) {
              return _ErrorBox(
                message: snap.error
                    .toString()
                    .replaceFirst('Exception: ', ''),
                onRetry: _retry,
              );
            }
            final c = snap.data;
            if (c == null) {
              return _ErrorBox(
                message: 'Contributions are not available right now.',
                onRetry: _retry,
              );
            }
            return _Body(
              contribution: c,
              isMe: _isMe,
              memberName: widget.memberName,
              onRetry: _retry,
            );
          },
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  final CommunityContribution contribution;
  final bool isMe;
  final String memberName;
  final VoidCallback onRetry;

  const _Body({
    required this.contribution,
    required this.isMe,
    required this.memberName,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final c = contribution;
    final failed = c.failedSections.toSet();

    // A section that failed to load must never look like "0".
    String count(int n, String section) => failed.contains(section) ? '–' : '$n';

    final tiles = <_StatTile>[
      _StatTile(
        icon: Icons.folder_copy_rounded,
        value: count(c.resourcesShared, 'Resources'),
        label: 'Resources shared',
      ),
      _StatTile(
        icon: Icons.question_answer_rounded,
        value: count(c.questionsAnswered, 'Answers'),
        label: 'Questions answered',
      ),
      _StatTile(
        icon: Icons.event_available_rounded,
        value: count(c.eventsAttended, 'Events'),
        label: 'Events attended',
      ),
      _StatTile(
        icon: Icons.emoji_events_rounded,
        value: count(c.achievementsCount, 'Achievements'),
        label: 'Achievements',
      ),
      _StatTile(
        icon: Icons.task_alt_rounded,
        value: count(c.answersOnSolved, 'Answers'),
        label: 'Answers on solved questions',
      ),
    ];

    final nothingYet = c.isEmpty && !c.hasFailures;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (c.fromCache) ...[
          const _Note(
            icon: Icons.cloud_off_rounded,
            text: 'Offline — showing saved data.',
          ),
          const SizedBox(height: 8),
        ],
        if (c.hasFailures) ...[
          _Note(
            icon: Icons.info_outline_rounded,
            text: "Couldn't load: ${c.failedSections.join(', ')}.",
            actionLabel: 'Retry',
            onAction: onRetry,
          ),
          const SizedBox(height: 8),
        ],
        if (nothingYet)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              isMe
                  ? 'Nothing yet. Share a resource, answer a question or '
                      'attend an event and it will show up here.'
                  : '${memberName.isEmpty ? 'This member' : memberName} '
                      "hasn't contributed anything yet.",
              style: const TextStyle(
                  color: Colors.white54, fontSize: 13, height: 1.35),
            ),
          )
        else ...[
          LayoutBuilder(builder: (context, box) {
            const gap = 8.0;
            final w = (box.maxWidth - gap) / 2;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [for (final t in tiles) SizedBox(width: w, child: t)],
            );
          }),
          if (c.answersScanCapped && !failed.contains('Answers')) ...[
            const SizedBox(height: 6),
            const Text(
              'Answers are counted from the most recent '
              '${CommunityContributionService.answerScanLimit} questions.',
              style: TextStyle(color: Colors.white30, fontSize: 11),
            ),
          ],
          if (c.recentAchievements.isNotEmpty)
            _EntryGroup(
              title: 'Recent achievements',
              entries: c.recentAchievements,
            ),
          if (c.recentResources.isNotEmpty)
            _EntryGroup(
              title: 'Recent resources',
              entries: c.recentResources,
            ),
          if (c.recentEvents.isNotEmpty)
            _EntryGroup(
              title: 'Events attended',
              entries: c.recentEvents,
            ),
        ],
        const SizedBox(height: 10),
        const Text(
          'A summary of participation — not a ranking.',
          style: TextStyle(color: Colors.white30, fontSize: 11),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _StatTile({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CommunityColors.tan.withValues(alpha: .25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: CommunityColors.glow, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryGroup extends StatelessWidget {
  final String title;
  final List<ContributionEntry> entries;
  final bool showDate;

  const _EntryGroup({
    required this.title,
    required this.entries,
  }) : showDate = true;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.circle,
                      size: 6, color: CommunityColors.tan),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                        ),
                        if (_subtitle(e).isNotEmpty)
                          Text(
                            _subtitle(e),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _subtitle(ContributionEntry e) {
    final parts = <String>[
      if (e.subtitle.isNotEmpty) e.subtitle,
      if (showDate && e.date != null) communityFormatDate(e.date!),
    ];
    return parts.join(' · ');
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _Note({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.white38),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: Colors.white38, fontSize: 11.5)),
        ),
        if (actionLabel != null && onAction != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: CommunityColors.tan,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(actionLabel!, style: const TextStyle(fontSize: 12)),
          ),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBox({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CommunityColors.danger.withValues(alpha: .4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: CommunityColors.danger, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
          ),
          TextButton(
            onPressed: onRetry,
            child: const Text('Retry',
                style: TextStyle(color: CommunityColors.tan)),
          ),
        ],
      ),
    );
  }
}

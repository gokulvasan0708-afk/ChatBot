import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/community_poll_service.dart';
import '../services/community_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// POLL CARD  (Community spec -- Section 7)
// ----------------------------------------------------------------
// Renders one poll and enforces its configuration in the UI:
//   - single vs multiple choice
//   - can't vote after the deadline / manual close
//   - can't vote twice (the service enforces it in a transaction;
//     the UI simply never offers the button again)
//   - results shown only when the poll's result mode allows it
//   - anonymous polls never list voters
// ================================================================

/// Loads a poll by id and renders it -- used inside feed posts.
class CommunityPollLoader extends StatelessWidget {
  final String pollId;
  final Map<String, dynamic> community;

  const CommunityPollLoader({
    super.key,
    required this.pollId,
    required this.community,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>?>(
      stream: CommunityPollService.watchPoll(pollId),
      builder: (context, snap) {
        if (snap.hasError) {
          return const _PollMessage('Unable to load this poll.');
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: CommunityColors.tan),
              ),
            ),
          );
        }
        final poll = snap.data;
        if (poll == null) return const _PollMessage('This poll was removed.');
        return CommunityPollCard(poll: poll, community: community);
      },
    );
  }
}

class _PollMessage extends StatelessWidget {
  final String text;
  const _PollMessage(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(14),
        child: Text(text,
            style: const TextStyle(color: Colors.white54, fontSize: 13)),
      );
}

class CommunityPollCard extends StatefulWidget {
  final Map<String, dynamic> poll;
  final Map<String, dynamic> community;

  /// When true the card draws its own container (Polls page). Inside a
  /// feed post the surrounding post card provides the container.
  final bool standalone;

  const CommunityPollCard({
    super.key,
    required this.poll,
    required this.community,
    this.standalone = false,
  });

  @override
  State<CommunityPollCard> createState() => _CommunityPollCardState();
}

class _CommunityPollCardState extends State<CommunityPollCard> {
  final Set<String> _selected = {};
  bool _voting = false;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';
  Map<String, dynamic> get _poll => widget.poll;
  String get _pollId => (_poll['id'] ?? '').toString();

  List<Map<String, dynamic>> get _options {
    final raw = _poll['options'];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((o) => Map<String, dynamic>.from(o))
        .toList();
  }

  int _countOf(String id) {
    final counts = _poll['counts'];
    if (counts is Map && counts[id] is int) return counts[id] as int;
    return 0;
  }

  int get _totalVoters =>
      _poll['totalVotes'] is int ? _poll['totalVotes'] as int : 0;

  Future<void> _submitVote() async {
    if (_selected.isEmpty || _voting) return;
    setState(() => _voting = true);
    try {
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(_uid).get();
      final name = (userDoc.data()?['publicName'] ?? 'Member').toString();

      await CommunityPollService.vote(
        pollId: _pollId,
        uid: _uid,
        voterName: name,
        optionIds: _selected.toList(),
      );
      if (!mounted) return;
      setState(() => _selected.clear());
      showTopAlert(context, 'Vote recorded');
    } catch (e) {
      if (!mounted) return;
      showTopAlert(context, _cleanError(e), isError: true);
    } finally {
      if (mounted) setState(() => _voting = false);
    }
  }

  String _cleanError(Object e) =>
      e.toString().replaceFirst('Exception: ', '').replaceFirst('Exception:', '');

  Future<void> _closePoll() async {
    try {
      await CommunityPollService.closePoll(
        pollId: _pollId,
        requesterUid: _uid,
        community: widget.community,
      );
      if (!mounted) return;
      showTopAlert(context, 'Poll closed');
    } catch (e) {
      if (!mounted) return;
      showTopAlert(context, _cleanError(e), isError: true);
    }
  }

  Future<void> _deletePoll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CommunityColors.card,
        title: const Text('Delete poll?',
            style: TextStyle(color: Colors.white)),
        content: const Text('The poll and all its votes will be removed.',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete',
                  style: TextStyle(color: CommunityColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await CommunityPollService.deletePoll(
        pollId: _pollId,
        requesterUid: _uid,
        community: widget.community,
      );
      if (!mounted) return;
      showTopAlert(context, 'Poll deleted');
    } catch (e) {
      if (!mounted) return;
      showTopAlert(context, _cleanError(e), isError: true);
    }
  }

  Future<void> _showVoters() async {
    try {
      final voters = await CommunityPollService.loadVoters(
          pollId: _pollId, requesterUid: _uid);
      if (!mounted) return;
      final optionText = {
        for (final o in _options) (o['id'] ?? '').toString(): (o['text'] ?? '').toString(),
      };
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => CommunitySheetShell(
          title: 'Who voted (${voters.length})',
          child: voters.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(28),
                  child: Text('No votes yet.',
                      style: TextStyle(color: Colors.white54)),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                  itemCount: voters.length,
                  separatorBuilder: (_, _) =>
                      const Divider(color: Colors.white12, height: 14),
                  itemBuilder: (_, i) {
                    final v = voters[i];
                    final ids = v['optionIds'] is List
                        ? (v['optionIds'] as List).map((e) => e.toString())
                        : <String>[];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((v['voterName'] ?? 'Member').toString(),
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(ids.map((id) => optionText[id] ?? id).join(', '),
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12.5)),
                      ],
                    );
                  },
                ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showTopAlert(context, _cleanError(e), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ended = CommunityPollService.isEnded(_poll);
    final voted = CommunityPollService.hasVoted(_poll, _uid);
    final isAuthor = CommunityPollService.isAuthor(_poll, _uid);
    final canManage =
        isAuthor || CommunityService.isPrivileged(widget.community, _uid);
    final showResults = CommunityPollService.canSeeResults(_poll, _uid);
    final canVote = !ended && !voted;
    final allowMultiple = _poll['allowMultiple'] == true;
    final anonymous = _poll['isAnonymous'] == true;
    final deadline = CommunityPollService.deadlineOf(_poll);
    final scope = (_poll['scope'] ?? 'community').toString();
    final scopeName = (_poll['scopeName'] ?? '').toString();
    final resultMode = (_poll['resultMode'] ?? 'afterVote').toString();

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.poll_rounded,
                  color: CommunityColors.glow, size: 20),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                (_poll['question'] ?? '').toString(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
            ),
            if (canManage)
              PopupMenuButton<String>(
                color: CommunityColors.card,
                icon: const Icon(Icons.more_vert_rounded,
                    color: Colors.white54, size: 20),
                onSelected: (v) {
                  if (v == 'close') _closePoll();
                  if (v == 'voters') _showVoters();
                  if (v == 'delete') _deletePoll();
                },
                itemBuilder: (_) => [
                  if (!ended)
                    const PopupMenuItem(
                        value: 'close',
                        child: Text('Close poll now',
                            style: TextStyle(color: Colors.white))),
                  if (isAuthor && !anonymous)
                    const PopupMenuItem(
                        value: 'voters',
                        child: Text('See who voted',
                            style: TextStyle(color: Colors.white))),
                  const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete poll',
                          style: TextStyle(color: CommunityColors.danger))),
                ],
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _Tag(allowMultiple ? 'Multiple choice' : 'Single choice'),
            if (anonymous) const _Tag('Anonymous', icon: Icons.visibility_off_rounded),
            if (resultMode == 'public') const _Tag('Public results'),
            if (scope == 'group')
              _Tag(scopeName.isEmpty ? 'Group poll' : 'Group: $scopeName',
                  icon: Icons.groups_rounded),
            if (ended)
              const _Tag('Ended', color: CommunityColors.danger)
            else if (deadline != null)
              _Tag(communityTimeLeft(deadline), icon: Icons.schedule_rounded),
          ],
        ),
        const SizedBox(height: 12),

        // ---- Options ----
        if (canVote)
          ..._options.map(_buildVoteOption)
        else if (showResults)
          StreamBuilder<List<String>?>(
            stream: CommunityPollService.watchMyVote(_pollId, _uid),
            builder: (context, mine) {
              final myChoices = mine.data ?? const <String>[];
              return Column(
                children: _options
                    .map((o) => _buildResultRow(o, myChoices))
                    .toList(),
              );
            },
          )
        else
          _HiddenResults(
            ended: ended,
            message: voted
                ? 'Your vote is in. Results will be visible after the poll ends.'
                : 'Results will be visible after the poll ends.',
          ),

        if (canVote) ...[
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (_selected.isEmpty || _voting) ? null : _submitVote,
              style: ElevatedButton.styleFrom(
                backgroundColor: CommunityColors.tan,
                foregroundColor: Colors.black,
                disabledBackgroundColor: Colors.white12,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: _voting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black),
                    )
                  : const Text('Vote',
                      style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          '$_totalVoters ${_totalVoters == 1 ? 'vote' : 'votes'}',
          style: const TextStyle(color: Colors.white38, fontSize: 11.5),
        ),
      ],
    );

    if (!widget.standalone) return content;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CommunityColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: CommunityColors.tan.withValues(alpha: .22)),
      ),
      child: content,
    );
  }

  Widget _buildVoteOption(Map<String, dynamic> option) {
    final id = (option['id'] ?? '').toString();
    final selected = _selected.contains(id);
    final multiple = _poll['allowMultiple'] == true;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _voting
            ? null
            : () => setState(() {
                  if (multiple) {
                    selected ? _selected.remove(id) : _selected.add(id);
                  } else {
                    _selected
                      ..clear()
                      ..add(id);
                  }
                }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? CommunityColors.tan.withValues(alpha: .16)
                : const Color(0xFF18181F),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? CommunityColors.tan
                  : CommunityColors.tan.withValues(alpha: .2),
            ),
          ),
          child: Row(
            children: [
              Icon(
                multiple
                    ? (selected
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded)
                    : (selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded),
                color: selected ? CommunityColors.tan : Colors.white38,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  (option['text'] ?? '').toString(),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultRow(Map<String, dynamic> option, List<String> mine) {
    final id = (option['id'] ?? '').toString();
    final count = _countOf(id);
    final fraction = _totalVoters == 0 ? 0.0 : count / _totalVoters;
    final isMine = mine.contains(id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: const Color(0xFF18181F),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isMine
                ? CommunityColors.tan
                : CommunityColors.tan.withValues(alpha: .2),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isMine) ...[
                  const Icon(Icons.check_circle_rounded,
                      color: CommunityColors.tan, size: 16),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    (option['text'] ?? '').toString(),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
                Text(
                  '${(fraction * 100).round()}%  ·  $count',
                  style: const TextStyle(
                      color: CommunityColors.glow,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 6,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(
                  isMine ? CommunityColors.tan : const Color(0xFF777784),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HiddenResults extends StatelessWidget {
  final bool ended;
  final String message;
  const _HiddenResults({required this.ended, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF18181F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CommunityColors.tan.withValues(alpha: .2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_clock_rounded,
              color: CommunityColors.tan, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;

  const _Tag(this.label, {this.icon, this.color = CommunityColors.tan});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
          ],
          Text(label, style: TextStyle(color: color, fontSize: 10.5)),
        ],
      ),
    );
  }
}

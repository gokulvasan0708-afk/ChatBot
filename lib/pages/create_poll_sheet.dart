import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/community_poll_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// CREATE POLL SHEET  (Community spec -- Section 7)
// ----------------------------------------------------------------
// Used both from the Feed ("Poll" post type) and from the Polls
// page. Scope picker only offers the groups the current
// user is actually a member of.
// ================================================================
class CreatePollSheet extends StatefulWidget {
  final String communityDocId;

  const CreatePollSheet({super.key, required this.communityDocId});

  @override
  State<CreatePollSheet> createState() => _CreatePollSheetState();
}

class _CreatePollSheetState extends State<CreatePollSheet> {
  final TextEditingController _question = TextEditingController();
  final TextEditingController _caption = TextEditingController();
  final List<TextEditingController> _options = [
    TextEditingController(),
    TextEditingController(),
  ];

  bool _multiple = false;
  bool _anonymous = false;
  String _resultMode = 'afterVote';
  DateTime? _deadline;

  String _scope = 'community';
  String _scopeId = '';

  PollAudience _audience = PollAudience.empty;
  bool _loadingAudience = true;
  bool _posting = false;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _loadAudience();
  }

  @override
  void dispose() {
    _question.dispose();
    _caption.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadAudience() async {
    try {
      final a = await CommunityPollService.loadAudience(
        communityDocId: widget.communityDocId,
        uid: _uid,
      );
      if (!mounted) return;
      setState(() {
        _audience = a;
        _loadingAudience = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingAudience = false);
    }
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _deadline ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
          _deadline ?? now.add(const Duration(hours: 1))),
    );
    if (time == null || !mounted) return;
    setState(() => _deadline =
        DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }

  Future<void> _submit() async {
    if (_posting) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _posting = true);
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final data = userDoc.data() ?? {};

      final scopeName =
          _scope == 'group' ? (_audience.groups[_scopeId] ?? '') : '';

      await CommunityPollService.createPoll(
        communityDocId: widget.communityDocId,
        authorUid: user.uid,
        authorName: (data['publicName'] ?? 'Member').toString(),
        authorAvatarUrl: (data['publicImage'] ?? '').toString(),
        question: _question.text,
        options: _options.map((c) => c.text).toList(),
        allowMultiple: _multiple,
        isAnonymous: _anonymous,
        resultMode: _resultMode,
        deadline: _deadline,
        scope: _scope,
        scopeId: _scopeId,
        scopeName: scopeName,
        caption: _caption.text,
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
      showTopAlert(context, 'Poll created');
    } catch (e) {
      if (!mounted) return;
      setState(() => _posting = false);
      showTopAlert(
        context,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: CommunitySheetShell(
        title: 'Create poll',
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _question,
                maxLength: 300,
                minLines: 1,
                maxLines: 3,
                style: const TextStyle(color: Colors.white),
                decoration: communityInputDecoration('Ask a question…',
                    label: 'Question'),
              ),
              const SizedBox(height: 4),
              const Text('Options',
                  style: TextStyle(
                      color: CommunityColors.tan,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
              const SizedBox(height: 8),
              for (var i = 0; i < _options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _options[i],
                          maxLength: 120,
                          style: const TextStyle(color: Colors.white),
                          decoration: communityInputDecoration('Option ${i + 1}')
                              .copyWith(counterText: ''),
                        ),
                      ),
                      if (_options.length > CommunityPollService.minOptions)
                        IconButton(
                          onPressed: () => setState(() {
                            _options.removeAt(i).dispose();
                          }),
                          icon: const Icon(Icons.remove_circle_outline_rounded,
                              color: Colors.white38),
                        ),
                    ],
                  ),
                ),
              if (_options.length < CommunityPollService.maxOptions)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(
                        () => _options.add(TextEditingController())),
                    icon: const Icon(Icons.add_rounded,
                        color: CommunityColors.tan, size: 18),
                    label: const Text('Add option',
                        style: TextStyle(color: CommunityColors.tan)),
                  ),
                ),
              const SizedBox(height: 6),
              _SwitchRow(
                title: 'Allow multiple choices',
                subtitle: _multiple
                    ? 'Members can select more than one option'
                    : 'Members pick exactly one option',
                value: _multiple,
                onChanged: (v) => setState(() => _multiple = v),
              ),
              _SwitchRow(
                title: 'Anonymous poll',
                subtitle: 'Nobody (not even you) can see who voted for what',
                value: _anonymous,
                onChanged: (v) => setState(() => _anonymous = v),
              ),
              const SizedBox(height: 10),
              const Text('Results',
                  style: TextStyle(
                      color: CommunityColors.tan,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
              const SizedBox(height: 6),
              for (final mode in CommunityPollService.resultModes)
                InkWell(
                  onTap: () => setState(() => _resultMode = mode),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Icon(
                          _resultMode == mode
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: _resultMode == mode
                              ? CommunityColors.tan
                              : Colors.white38,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            CommunityPollService.resultModeLabels[mode] ?? mode,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              const Text('Deadline',
                  style: TextStyle(
                      color: CommunityColors.tan,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDeadline,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                            color: CommunityColors.tan.withValues(alpha: .4)),
                        alignment: Alignment.centerLeft,
                      ),
                      icon: const Icon(Icons.schedule_rounded,
                          color: CommunityColors.tan, size: 18),
                      label: Text(
                        _deadline == null
                            ? 'No deadline'
                            : communityFormatDateTime(_deadline!),
                      ),
                    ),
                  ),
                  if (_deadline != null)
                    IconButton(
                      onPressed: () => setState(() => _deadline = null),
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white54),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              const Text('Who can vote',
                  style: TextStyle(
                      color: CommunityColors.tan,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
              const SizedBox(height: 8),
              if (_loadingAudience)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: CommunityColors.tan),
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Whole community'),
                      selected: _scope == 'community',
                      onSelected: (_) => setState(() {
                        _scope = 'community';
                        _scopeId = '';
                      }),
                      selectedColor: CommunityColors.tan,
                      backgroundColor: const Color(0xFF120C07),
                      labelStyle: TextStyle(
                          color: _scope == 'community'
                              ? Colors.black
                              : Colors.white70),
                    ),
                    if (_audience.groups.isNotEmpty)
                      ChoiceChip(
                        label: const Text('A group'),
                        selected: _scope == 'group',
                        onSelected: (_) => setState(() {
                          _scope = 'group';
                          _scopeId = _audience.groups.keys.first;
                        }),
                        selectedColor: CommunityColors.tan,
                        backgroundColor: const Color(0xFF120C07),
                        labelStyle: TextStyle(
                            color: _scope == 'group'
                                ? Colors.black
                                : Colors.white70),
                      ),
                  ],
                ),
              if (!_loadingAudience &&
                  _audience.groups.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Join a group to create polls just for its members.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
              if (_scope == 'group') ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: _scopeId.isEmpty ? null : _scopeId,
                  dropdownColor: CommunityColors.card,
                  style: const TextStyle(color: Colors.white),
                  decoration: communityInputDecoration('Select group'),
                  items: _audience.groups.entries
                      .map((e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (v) => setState(() => _scopeId = v ?? ''),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Group polls are only visible to their members and are not shown in the community feed.',
                  style: TextStyle(color: Colors.white38, fontSize: 11.5),
                ),
              ] else ...[
                const SizedBox(height: 14),
                TextField(
                  controller: _caption,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 500,
                  style: const TextStyle(color: Colors.white),
                  decoration: communityInputDecoration(
                      'Add context or #hashtags (optional)',
                      label: 'Caption'),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _posting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: CommunityColors.tan,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _posting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black),
                        )
                      : const Text('Create poll',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      activeThumbColor: CommunityColors.tan,
      title: Text(title,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: Colors.white38, fontSize: 12)),
    );
  }
}

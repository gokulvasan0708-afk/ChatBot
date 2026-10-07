import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/community_member_profile_service.dart';
import '../services/user_profile_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// EDIT PUBLIC SKILLS  (Community Search -- Section 11)
// ----------------------------------------------------------------
// Lets a member choose which skills people can find them by
// ("Flutter", "UI design", ...). Nothing is public until the member
// adds it here; removing a skill removes it from search immediately.
// Skills belong to ONE member profile (Profile ID) and are stored on that
// profile (CommunityMemberProfileService.saveSkills), so two profiles of
// the same account never share skills.
// ================================================================
class EditSkillsSheet extends StatefulWidget {
  final String communityDocId;

  /// The profile whose skills are edited. Empty -> the profile the
  /// account is using in the community right now.
  final String profileId;

  const EditSkillsSheet({
    super.key,
    required this.communityDocId,
    this.profileId = '',
  });

  @override
  State<EditSkillsSheet> createState() => _EditSkillsSheetState();
}

class _EditSkillsSheetState extends State<EditSkillsSheet> {
  final TextEditingController _input = TextEditingController();
  List<String> _skills = [];
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;
  String _profileId = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      if (_profileId.isEmpty) {
        _profileId = widget.profileId;
      }
      if (_profileId.isEmpty) {
        _profileId = await CommunityMemberProfileService.activeProfileId(
            widget.communityDocId,
            FirebaseAuth.instance.currentUser?.uid ?? '');
      }
      if (_profileId.isEmpty) throw Exception('No profile');
      final skills = await CommunityMemberProfileService.loadSkills(
          widget.communityDocId, _profileId);
      if (!mounted) return;
      setState(() {
        _skills = skills;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  void _add() {
    final added = UserProfileService.normalizeSkills(
      _input.text.split(RegExp(r'[,\n]')),
    );
    if (added.isEmpty) return;

    final merged = UserProfileService.normalizeSkills([..._skills, ...added]);
    if (merged.length == _skills.length &&
        _skills.length >= UserProfileService.maxPublicSkills) {
      showTopAlert(
        context,
        'You can add up to ${UserProfileService.maxPublicSkills} skills.',
        isError: true,
      );
      return;
    }
    setState(() {
      _skills = merged;
      _input.clear();
    });
  }

  Future<void> _save() async {
    // Include anything typed but not yet added.
    if (_input.text.trim().isNotEmpty) _add();

    setState(() => _saving = true);
    try {
      await CommunityMemberProfileService.saveSkills(
          widget.communityDocId, _profileId, _skills);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      showTopAlert(context, 'Skills updated');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: CommunitySheetShell(
        title: 'Skills of this profile',
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: _loading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: CommunityLoading(),
                )
              : _loadFailed
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: CommunityStateMessage(
                        icon: Icons.error_outline_rounded,
                        title: 'Couldn\'t load your skills',
                        subtitle: 'Check your connection and try again.',
                        actionLabel: 'Retry',
                        onAction: _load,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Members can find this profile in Community Search by these skills. '
                          'They belong to this profile only - your other profiles keep their own skills.',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 12.5, height: 1.4),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _input,
                                enabled: !_saving,
                                maxLength: UserProfileService.maxPublicSkillLength,
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _add(),
                                style: const TextStyle(color: Colors.white),
                                decoration: communityInputDecoration(
                                        'e.g. Flutter, UI design',
                                        label: 'Add a skill')
                                    .copyWith(counterText: ''),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: _saving ? null : _add,
                              tooltip: 'Add',
                              icon: const Icon(Icons.add_circle_rounded,
                                  color: CommunityColors.tan, size: 32),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_skills.isEmpty)
                          const Text('No public skills yet.',
                              style:
                                  TextStyle(color: Colors.white38, fontSize: 13))
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final s in _skills)
                                InputChip(
                                  label: Text(s),
                                  onDeleted: _saving
                                      ? null
                                      : () => setState(() => _skills =
                                          _skills.where((e) => e != s).toList()),
                                  backgroundColor: const Color(0xFF18181F),
                                  deleteIconColor: CommunityColors.tan,
                                  labelStyle: const TextStyle(
                                      color: CommunityColors.glow, fontSize: 12.5),
                                  side: BorderSide(
                                      color: CommunityColors.tan
                                          .withValues(alpha: .35)),
                                ),
                            ],
                          ),
                        const SizedBox(height: 4),
                        Text(
                          '${_skills.length}/${UserProfileService.maxPublicSkills} skills',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11.5),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _saving ? null : _save,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: CommunityColors.tan,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                            ),
                            child: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.black),
                                  )
                                : const Text('Save',
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

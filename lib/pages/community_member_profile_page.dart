import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'community_contribution_section.dart';
import 'edit_skills_sheet.dart';
import 'join_community_sheet.dart';
import '../services/community_join_password_service.dart';
import '../services/community_member_profile_service.dart';
import '../services/community_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// MY COMMUNITY PROFILE  (one MEMBER PROFILE -- identified by Profile ID)
// ----------------------------------------------------------------
// An account can hold several profiles in the same community (one per
// role, e.g. Controller + Student). This page shows ONE of them at a
// time -- with its own name, password, role and details -- and lets the
// member switch between them, join with another role, or leave with the
// profile that is open. The other profiles stay members.
//
// Opened from the top-right profile button on Community Home
// (it replaced the old Settings / Leave icons).
//
//   * Avatar, name (tap the pencil to set / change it), role
//   * Join password (under the name, every role): protects the register number /
//     staff name this member joined with. After it is set, joining
//     again (after leaving, or by someone else) with that register
//     number / name asks for the password. See
//     community_join_password_service.dart.
//   * Community info (name, ID, college, members)
//   * Skills  -- add / edit; these are the same public skills other
//     members see when they tap this member in the Community
//   * Contributions (same section other members see)
//   * Bottom: "Leave Community" for every role
//
// Pops with `true` after leaving / deleting so Community Home can
// close itself too.
// ================================================================
class CommunityMemberProfilePage extends StatefulWidget {
  final String communityDocId;

  /// The member profile to open. null -> the profile this account is
  /// using in the community right now.
  final String? profileId;

  const CommunityMemberProfilePage({
    super.key,
    required this.communityDocId,
    this.profileId,
  });

  @override
  State<CommunityMemberProfilePage> createState() =>
      _CommunityMemberProfilePageState();
}

class _CommunityMemberProfilePageState
    extends State<CommunityMemberProfilePage> {
  final String _uid = FirebaseAuth.instance.currentUser?.uid ?? '';
  bool _busy = false;

  // The profile (Profile ID) shown on this page.
  String _profileId = '';
  bool _resolved = false;
  int _pwRefresh = 0;

  @override
  void initState() {
    super.initState();
    _profileId = widget.profileId ?? '';
    _prepare();
  }

  /// Old (uid-based) members get their profile created, then the profile
  /// to show is worked out.
  Future<void> _prepare() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('communities')
          .doc(widget.communityDocId)
          .get();
      await CommunityMemberProfileService.ensureMyProfile(
          widget.communityDocId, snap.data() ?? <String, dynamic>{});
      // Old account-level skills move onto the profile (single-profile
      // accounts only) -- skills are kept per Profile ID from now on.
      await CommunityMemberProfileService.adoptLegacySkills(
          widget.communityDocId, _uid);
      if (_profileId.isEmpty) {
        _profileId = await CommunityMemberProfileService.activeProfileId(
            widget.communityDocId, _uid);
      }
    } catch (_) {}
    if (mounted) setState(() => _resolved = true);
  }

  Future<void> _selectProfile(String id) async {
    if (id == _profileId) return;
    setState(() => _profileId = id);
    await CommunityMemberProfileService.setActiveProfile(
        widget.communityDocId, _uid, id);
  }

  late final Stream<List<Map<String, dynamic>>> _myProfilesStream =
      CommunityMemberProfileService.watchMyProfiles(
          widget.communityDocId, _uid);

  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _userStream =
      FirebaseFirestore.instance.collection('users').doc(_uid).snapshots();
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _communityStream =
      CommunityService.watchCommunity(widget.communityDocId);

  // ==========================================================
  // NAME
  // ==========================================================

  Future<void> _editName(String current) async {
    final controller = TextEditingController(text: current);
    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: CommunityColors.card,
        title:
            const Text('Your name', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          style: const TextStyle(color: Colors.white),
          decoration: communityInputDecoration(
            'Leave empty to show your role',
            label: 'Name',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('CANCEL'),
          ),
          TextButton(
            // An empty name is allowed: the role is shown again instead.
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
    controller.dispose();

    // null = cancelled; '' = name cleared on purpose (role shown again).
    if (saved == null || saved == current.trim()) return;

    try {
      await CommunityMemberProfileService.saveName(
          widget.communityDocId, _profileId, saved);
      if (mounted) {
        showTopAlert(context,
            saved.isEmpty ? 'Name removed - role is shown' : 'Name updated');
      }
    } catch (e) {
      if (mounted) {
        showTopAlert(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    }
  }

  // ==========================================================
  // JOIN PASSWORD
  // ==========================================================

  /// One dialog for set / change / remove.
  ///   set     -> new + confirm
  ///   change  -> current + new + confirm
  ///   remove  -> current
  Future<void> _passwordDialog(String mode) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    var hide = true;
    String? error;

    final needsCurrent = mode != 'set';
    final needsNew = mode != 'remove';

    final done = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocal) {
          Widget field(TextEditingController c, String label) => Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TextField(
                  controller: c,
                  obscureText: hide,
                  style: const TextStyle(color: Colors.white),
                  decoration: communityInputDecoration(label),
                ),
              );

          return AlertDialog(
            backgroundColor: CommunityColors.card,
            title: Text(
              mode == 'set'
                  ? 'Set password'
                  : mode == 'change'
                      ? 'Change password'
                      : 'Remove password',
              style: const TextStyle(color: Colors.white),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (mode == 'set')
                    const Text(
                      'After you set this, joining again with your register '
                      'number / name will ask for this password.',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  if (needsCurrent) field(current, 'Current password'),
                  if (needsNew) ...[
                    field(next, 'New password'),
                    field(confirm, 'Confirm new password'),
                  ],
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setLocal(() => hide = !hide),
                      icon: Icon(
                        hide
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                        size: 16,
                        color: Colors.white54,
                      ),
                      label: Text(hide ? 'Show' : 'Hide',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                    ),
                  ),
                  if (error != null)
                    Text(error!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 12.5)),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('CANCEL'),
              ),
              TextButton(
                onPressed: () async {
                  if (needsCurrent && current.text.isEmpty) {
                    setLocal(() => error = 'Enter your current password.');
                    return;
                  }
                  if (needsNew) {
                    if (next.text.length <
                        CommunityJoinPasswordService.minLength) {
                      setLocal(() => error =
                          'Password must be at least ${CommunityJoinPasswordService.minLength} characters.');
                      return;
                    }
                    if (next.text != confirm.text) {
                      setLocal(() => error = 'Passwords do not match.');
                      return;
                    }
                  }
                  try {
                    if (mode == 'remove') {
                      await CommunityJoinPasswordService.removePassword(
                        communityId: widget.communityDocId,
                        profileId: _profileId,
                        currentPassword: current.text,
                      );
                    } else {
                      await CommunityJoinPasswordService.setPassword(
                        communityId: widget.communityDocId,
                        profileId: _profileId,
                        newPassword: next.text,
                        currentPassword: current.text,
                      );
                    }
                    if (dialogContext.mounted) {
                      Navigator.pop(dialogContext, true);
                    }
                  } catch (e) {
                    setLocal(() => error =
                        e.toString().replaceFirst('Exception: ', ''));
                  }
                },
                child: Text(mode == 'remove' ? 'REMOVE' : 'SAVE'),
              ),
            ],
          );
        },
      ),
    );

    current.dispose();
    next.dispose();
    confirm.dispose();

    if (done == true && mounted) {
      setState(() => _pwRefresh++);
      showTopAlert(
        context,
        mode == 'set'
            ? 'Password set'
            : mode == 'change'
                ? 'Password changed'
                : 'Password removed',
      );
    }
  }

  Widget _passwordCard() {
    return FutureBuilder<bool>(
      key: ValueKey('$_profileId-$_pwRefresh'),
      future: CommunityJoinPasswordService.hasPassword(
          widget.communityDocId, _profileId),
      builder: (context, snap) {
        final has = snap.data == true;
        return _SectionCard(
          title: 'Password',
          trailing: has
              ? PopupMenuButton<String>(
                  tooltip: 'Password options',
                  color: CommunityColors.card,
                  icon: const Icon(Icons.more_vert_rounded,
                      color: CommunityColors.tan, size: 20),
                  onSelected: _passwordDialog,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'change',
                      child: Text('Change password',
                          style: TextStyle(color: Colors.white)),
                    ),
                    PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove password',
                          style: TextStyle(color: Colors.redAccent)),
                    ),
                  ],
                )
              : IconButton(
                  tooltip: 'Set password',
                  onPressed: () => _passwordDialog('set'),
                  icon: const Icon(Icons.lock_outline_rounded,
                      color: CommunityColors.tan, size: 20),
                ),
          child: GestureDetector(
            onTap: has ? null : () => _passwordDialog('set'),
            child: Row(
              children: [
                Icon(
                  has ? Icons.lock_rounded : Icons.lock_open_rounded,
                  size: 16,
                  color: has ? CommunityColors.success : Colors.white38,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    has
                        ? 'Password is set for this profile. It is asked when joining again.'
                        : 'Set a password to protect this profile\'s register number / name',
                    style: TextStyle(
                      color: has ? Colors.white70 : Colors.white38,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==========================================================
  // SKILLS
  // ==========================================================

  Future<void> _editSkills() async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EditSkillsSheet(
        communityDocId: widget.communityDocId,
        profileId: _profileId,
      ),
    );
    // The profile stream refreshes the chips once the sheet saves.
  }

  // ==========================================================
  // LEAVE
  // ==========================================================

  void _confirmLeave(String label) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: CommunityColors.card,
        title: const Text('Leave Community?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'You will leave with this profile only ($label). Your other '
          'profiles in this community, if any, stay members. If you set a '
          'password on this profile, it will be asked when you join again '
          'with the same role.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _leave();
            },
            child: const Text('LEAVE', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  Future<void> _leave() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await CommunityService.leaveProfile(
        communityDocId: widget.communityDocId,
        profileId: _profileId,
        uid: _uid,
      );
      final remaining = await CommunityMemberProfileService.loadMyProfiles(
          widget.communityDocId, _uid);
      if (!mounted) return;
      if (remaining.isEmpty) {
        // No profile left -> the account has left the community.
        Navigator.of(context).pop(true);
        return;
      }
      final next = (remaining.first['id'] ?? '').toString();
      setState(() {
        _busy = false;
        _profileId = next;
      });
      await CommunityMemberProfileService.setActiveProfile(
          widget.communityDocId, _uid, next);
      if (mounted) showTopAlert(context, 'You left with this profile');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  /// Joins the same community with ANOTHER role -> a new, separate
  /// member profile with its own Profile ID.
  Future<void> _joinAnotherRole(Map<String, dynamic> community) async {
    await showJoinCommunitySheet(
      context,
      initialCommunity: {...community, 'docId': widget.communityDocId},
    );
    if (!mounted) return;
    // Joining makes the new profile the one in use.
    final id = await CommunityMemberProfileService.activeProfileId(
        widget.communityDocId, _uid);
    if (mounted && id.isNotEmpty) setState(() => _profileId = id);
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('My profile',
            style: TextStyle(color: Colors.white, fontSize: 18)),
      ),
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _communityStream,
          builder: (context, communitySnap) {
            if (communitySnap.connectionState == ConnectionState.waiting &&
                !communitySnap.hasData) {
              return const CommunityLoading();
            }
            final community = communitySnap.data?.data();
            if (community == null) {
              return const Center(
                child: Text('Community not found',
                    style: TextStyle(color: Colors.white54)),
              );
            }

            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _userStream,
              builder: (context, userSnap) {
                final user = userSnap.data?.data() ?? <String, dynamic>{};
                return StreamBuilder<List<Map<String, dynamic>>>(
                  stream: _myProfilesStream,
                  builder: (context, profileSnap) {
                    if (!_resolved || !profileSnap.hasData) {
                      return const CommunityLoading();
                    }
                    final mine = CommunityMemberProfileService.sorted(
                        profileSnap.data!, community);
                    if (mine.isEmpty) {
                      return const Center(
                        child: Text(
                          'You are not a member of this community.',
                          style: TextStyle(color: Colors.white54),
                        ),
                      );
                    }
                    Map<String, dynamic> current = mine.first;
                    for (final p in mine) {
                      if (p['id'] == _profileId) current = p;
                    }
                    _profileId = (current['id'] ?? '').toString();
                    return _buildBody(community, user, current, mine);
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildBody(
    Map<String, dynamic> community,
    Map<String, dynamic> user,
    Map<String, dynamic> profile,
    List<Map<String, dynamic>> mine,
  ) {
    // Only the name set on THIS profile; none -> the role, in grey.
    final name = (profile['name'] ?? '').toString().trim();
    // Skills of THIS profile only (Profile ID) -- never the account's.
    final skills =
        CommunityMemberProfileService.skillsOf(profile) ?? <String>[];

    final role = CommunityMemberProfileService.effectiveRole(profile, community);
    // Empty name -> show the role instead (Principal, Student, ...),
    // in grey, until a name is set.
    final shownName = CommunityMemberProfileService.displayName(name, role);
    // Principal / HOD / Faculty have no Skills or Contributions section.
    final showExtras = !CommunityMemberProfileService.hidesExtras(role);

    final communityName = (community['name'] ?? '').toString();
    final communityId = (community['communityId'] ?? '').toString();
    final collegeName = (community['collegeName'] ?? '').toString();
    final type = (community['type'] ?? 'normal').toString();
    final membersCount = (community['membersCount'] is int)
        ? community['membersCount'] as int
        : (community['members'] is List
            ? (community['members'] as List).length
            : 0);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        // -------- Avatar + role --------
        Center(
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: CommunityColors.tan, width: 2),
            ),
            // No photo: the avatar is the first letter of the name.
            child: CommunityAvatar(url: '', name: shownName, radius: 46),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF7C3AED).withValues(alpha: .3),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: CommunityColors.tan.withValues(alpha: .5)),
            ),
            child: Text(role,
                style: const TextStyle(
                    color: CommunityColors.glow,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 20),

        // -------- Switch between this account's profiles --------
        if (mine.length > 1) ...[
          _SectionCard(
            title: 'Your profiles in this community',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in mine)
                  ChoiceChip(
                    selected: p['id'] == _profileId,
                    onSelected: (_) => _selectProfile((p['id'] ?? '').toString()),
                    label: Text(
                      () {
                        final r = CommunityMemberProfileService.effectiveRole(
                            p, community);
                        final n = (p['name'] ?? '').toString().trim();
                        return n.isEmpty ? r : '$r - $n';
                      }(),
                    ),
                    backgroundColor: const Color(0xFF18181F),
                    selectedColor: const Color(0xFF7C3AED).withValues(alpha: .55),
                    labelStyle: const TextStyle(
                        color: CommunityColors.glow, fontSize: 12.5),
                    side: BorderSide(
                        color: CommunityColors.tan.withValues(alpha: .4)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],

        // -------- Name --------
        _SectionCard(
          title: 'Name',
          trailing: IconButton(
            tooltip: 'Set name',
            onPressed: () => _editName(name),
            icon: const Icon(Icons.edit_rounded,
                color: CommunityColors.tan, size: 20),
          ),
          child: Text(
            shownName,
            style: TextStyle(
              color: name.trim().isEmpty ? Colors.grey : Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 14),

        // -------- Join password (under the name) --------
        _passwordCard(),
        const SizedBox(height: 14),

        if (showExtras) ...[
        // -------- Skills --------
        _SectionCard(
          title: 'Skills',
          trailing: IconButton(
            tooltip: 'Edit skills',
            onPressed: _editSkills,
            icon: const Icon(Icons.edit_rounded,
                color: CommunityColors.tan, size: 20),
          ),
          child: skills.isEmpty
              ? GestureDetector(
                  onTap: _editSkills,
                  child: const Text('Add your skills',
                      style: TextStyle(color: Colors.white38, fontSize: 14)),
                )
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
                            color: CommunityColors.tan.withValues(alpha: .35)),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 14),
        ],

        // -------- Community info --------
        _SectionCard(
          title: 'Community',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(communityName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              if (communityId.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(communityId,
                    style: const TextStyle(
                        color: CommunityColors.glow,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
              ],
              if (type == 'college' && collegeName.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.school_rounded,
                        color: Colors.white54, size: 14),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(collegeName,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12.5)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              Text(
                '$membersCount member${membersCount == 1 ? '' : 's'}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // -------- Contributions --------
        if (showExtras) ...[
          CommunityContributionSection(
            // New key per profile: switching profiles rebuilds the
            // section so it never shows the previous profile's data.
            key: ValueKey('contrib-$_profileId'),
            communityDocId: widget.communityDocId,
            memberUid: _uid,
            memberProfileId: _profileId,
            viewerUid: _uid,
            memberName: shownName,
          ),
          const SizedBox(height: 28),
        ] else
          const SizedBox(height: 14),

        // -------- Join with another role (Controller profile only) --------
        if (role == CommunityMemberProfileService.roleController) ...[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _joinAnotherRole(community),
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 20),
              label: const Text('Join with another role'),
              style: OutlinedButton.styleFrom(
                foregroundColor: CommunityColors.glow,
                side: BorderSide(
                    color: CommunityColors.tan.withValues(alpha: .6)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // -------- Leave --------
        // Every role (Controller, Principal, HOD, Faculty, Rep,
        // Student) can leave. Delete Community is not shown here.
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _confirmLeave(shownName),
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.redAccent),
                  )
                : const Icon(Icons.logout_rounded, size: 20),
            label: const Text('Leave with this profile'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const _SectionCard({required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
      decoration: BoxDecoration(
        color: CommunityColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CommunityColors.tan.withValues(alpha: .25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 40,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: CommunityColors.tan.withValues(alpha: .9),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: child,
          ),
        ],
      ),
    );
  }
}
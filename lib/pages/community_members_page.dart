import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'chat_screen.dart' show PublicMemberProfilePage;
import 'community_member_profile_page.dart';
import 'community_members_directory_page.dart';
import 'community_search_sheets.dart';
import 'private_chat_screen.dart' show PrivateMemberProfilePage;
import '../services/community_member_profile_service.dart';
import '../services/community_service.dart';
import '../widgets/community_widgets.dart';
import '../widgets/top_alert.dart';

// ================================================================
// COMMUNITY MEMBERS (spec section 10)  --  PROFILE-ID based
// ----------------------------------------------------------------
// A member here is a MEMBER PROFILE (communities/{id}/memberProfiles/
// {profileId}), never a login account (UID). When one account joined
// with two roles it shows up twice -- "Controller - Gokulvasan" and
// "Student - Gokulvasan" -- as two separate members.
//
// Category bar under the "Members" title:
//   All | Principal | Controller | HOD | Faculty | Students
//
//   All                      -> every active member profile
//   Principal/Controller/
//   HOD/Faculty              -> profiles with that role
//   Students                 -> Student / Rep profiles with TWO
//                               independent filters shown only here:
//                               Year (alone) and Department (alone).
//                               Both can also be combined.
//
// Long-press any member profile for a menu:
//   Remove (Role)   -- only when the viewer's role may remove theirs
//                      (never shown to Students / Reps / Members):
//                        Principal  -> HOD, Faculty, Controller, Student
//                        HOD        -> Faculty, Student
//                        Faculty    -> Student
//                        Controller -> HOD, Faculty, Controller, Student,
//                                      Rep, Member
//   Assign Representative -- only for HOD / Controller / Faculty viewers,
//                      on a Student profile: makes it a Rep. A Rep gets
//                      "Remove Representative" for the same viewers.
//   (Role)          -- opens that profile
//   Personal Profile-- private profile when connected with the viewer's
//                      account, otherwise the public profile. Not shown
//                      on the profile marked "You".
//
// "You" is shown ONLY on the profile the account is using right now
// (its active Profile ID) -- never on its other profiles.
// ================================================================

const Color _tan = Color(0xFFA78BFA);

const List<String> _kCategories = [
  'All',
  'Principal',
  'Controller',
  'HOD',
  'Faculty',
  'Students',
];

/// Profile / badge colour that matches the role.
/// Principal = gold, Controller = purple, HOD = blue, Faculty = green.
/// Other roles keep the default tan.
Color _roleColor(String role) {
  switch (role) {
    case 'Principal':
      return const Color(0xFFF59E0B);
    case 'Controller':
      return const Color(0xFFA78BFA);
    case 'HOD':
      return const Color(0xFF22D3EE);
    case 'Faculty':
      return const Color(0xFF10B981);
    default:
      return _tan;
  }
}

bool _isStaffRole(String role) =>
    role == 'Principal' ||
    role == 'Controller' ||
    role == 'HOD' ||
    role == 'Faculty';

/// Coloured ring around the avatar of Principal / Controller / HOD / Faculty.
class _RoleRing extends StatelessWidget {
  final String role;
  final Widget child;

  const _RoleRing({required this.role, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!_isStaffRole(role)) return child;
    final c = _roleColor(role);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: c, width: 2),
        boxShadow: [BoxShadow(color: c.withValues(alpha: .35), blurRadius: 6)],
      ),
      child: child,
    );
  }
}

class CommunityMembersPage extends StatefulWidget {
  final String communityDocId;

  const CommunityMembersPage({super.key, required this.communityDocId});

  @override
  State<CommunityMembersPage> createState() => _CommunityMembersPageState();
}

class _CommunityMembersPageState extends State<CommunityMembersPage> {
  String _category = 'All';

  // The viewer's own role in this community. The 3-line menu in the top
  // right corner is shown ONLY for Principal / Controller / HOD / Faculty.
  String _myRole = CommunityMemberProfileService.roleMember;

  String get _id => widget.communityDocId;

  static const List<String> _menuRoles = [
    CommunityMemberProfileService.rolePrincipal,
    CommunityMemberProfileService.roleController,
    CommunityMemberProfileService.roleHod,
    CommunityMemberProfileService.roleFaculty,
  ];

  bool get _canSeeMenu => _menuRoles.contains(_myRole);

  @override
  void initState() {
    super.initState();
    _loadMyRole();
  }

  Future<void> _loadMyRole() async {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (myUid.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('communities')
          .doc(_id)
          .get();
      final community = snap.data() ?? <String, dynamic>{};

      // Members of the old (uid-based) data get their profile first.
      await CommunityMemberProfileService.ensureMyProfile(_id, community);

      // Quick answer first, so the menu appears fast.
      final quick = CommunityMemberProfileService.quickRole(myUid, community);
      if (mounted && quick != _myRole) setState(() => _myRole = quick);

      // Re-read after the profile was created; the BEST role among all of
      // this account's profiles decides what the menu offers.
      final fresh = await FirebaseFirestore.instance
          .collection('communities')
          .doc(_id)
          .get();
      final role = CommunityMemberProfileService.quickRole(
          myUid, fresh.data() ?? community);
      if (mounted && role != _myRole) setState(() => _myRole = role);
    } catch (_) {}
  }

  void _openMenu() {
    Widget tile(IconData icon, String title, Widget Function() page) {
      return ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFF20202A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _tan.withValues(alpha: .4)),
          ),
          child: Icon(icon, color: _tan, size: 22),
        ),
        title: Text(title,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.chevron_right_rounded,
            color: Colors.white38),
        onTap: () {
          Navigator.pop(context);
          Navigator.push(context, MaterialPageRoute(builder: (_) => page()));
        },
      );
    }

    Widget roleTile(IconData icon, String role) => tile(
          icon,
          role,
          () => CommunityRoleListPage(communityDocId: _id, role: role),
        );

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF18181F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            roleTile(Icons.school_rounded,
                CommunityMemberProfileService.rolePrincipal),
            roleTile(Icons.admin_panel_settings_rounded,
                CommunityMemberProfileService.roleController),
            roleTile(Icons.account_tree_rounded,
                CommunityMemberProfileService.roleHod),
            roleTile(Icons.person_pin_rounded,
                CommunityMemberProfileService.roleFaculty),
            tile(
              Icons.groups_rounded,
              'Students',
              () => CommunityDepartmentsPage(communityDocId: _id),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('Members', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          // 3-line menu: Principal / Controller / HOD / Faculty only.
          if (_canSeeMenu)
            IconButton(
              tooltip: 'Menu',
              icon: const Icon(Icons.menu_rounded, color: Colors.white),
              onPressed: _openMenu,
            ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 52,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _kCategories.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final c = _kCategories[i];
                return _PillChip(
                  label: c,
                  selected: _category == c,
                  onTap: () => setState(() => _category = c),
                );
              },
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          Expanded(child: _buildCategory()),
        ],
      ),
    );
  }

  Widget _buildCategory() {
    switch (_category) {
      case 'All':
        return _AllMembersView(communityDocId: _id);
      case 'Students':
        return _StudentsView(communityDocId: _id);
      default:
        return _StaffView(
          key: ValueKey(_category),
          communityDocId: _id,
          role: _category,
        );
    }
  }
}

// ----------------------------------------------------------------
// Shared small widgets
// ----------------------------------------------------------------
class _PillChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PillChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF7C3AED).withValues(alpha: .55)
              : const Color(0xFF18181F),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? _tan : _tan.withValues(alpha: .3),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFFC4B5FD) : Colors.white70,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  final String role;

  const _RoleBadge(this.role);

  @override
  Widget build(BuildContext context) {
    final staff = _isStaffRole(role);
    final c = _roleColor(role);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: staff
            ? c.withValues(alpha: .18)
            : const Color(0xFF7C3AED).withValues(alpha: .3),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: staff ? .8 : .5)),
      ),
      child: Text(
        role,
        style: TextStyle(
          color: staff ? c : const Color(0xFFC4B5FD),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  final String name;
  final String subtitle;
  final String image;
  final String? badge;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// True when no name was set and the role is shown instead (grey).
  final bool greyName;

  const _PersonTile({
    required this.name,
    required this.subtitle,
    required this.image,
    this.badge,
    this.onTap,
    this.onLongPress,
    this.greyName = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = image.startsWith('http');
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: _RoleRing(
        role: badge ?? '',
        child: CircleAvatar(
          radius: 22,
          backgroundColor: const Color(0xFF20202A),
          backgroundImage: hasImage ? NetworkImage(image) : null,
          // No photo -> first letter of the shown name (or role), same
          // as the "All" list.
          child: hasImage
              ? null
              : Text(
                  name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(),
                  style: const TextStyle(
                    color: CommunityColors.glow,
                    fontWeight: FontWeight.bold,
                    fontSize: 19.8,
                  ),
                ),
        ),
      ),
      title: Text(
        name.isEmpty ? 'Unnamed' : name,
        style: TextStyle(color: greyName ? Colors.grey : Colors.white),
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, style: const TextStyle(color: Colors.white54)),
      trailing: badge == null ? null : _RoleBadge(badge!),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  final IconData icon;
  final String text;

  const _CenteredMessage({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: _tan),
          const SizedBox(height: 12),
          Text(text, style: const TextStyle(color: Colors.white54)),
        ],
      ),
    );
  }
}

/// Opens a member PROFILE.
///  * one of the viewer's own profiles -> the editable profile page
///  * anybody else's -> the read-only profile sheet
Future<void> _openProfile(
  BuildContext context, {
  required String communityDocId,
  required Map<String, dynamic> profile,
  required String role,
}) async {
  final profileId = (profile['id'] ?? '').toString();
  final uid = (profile['uid'] ?? '').toString();
  final name = (profile['name'] ?? '').toString().trim();
  final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

  if (profileId.isNotEmpty &&
      !profileId.startsWith('legacy_') &&
      uid.isNotEmpty &&
      uid == myUid) {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CommunityMemberProfilePage(
        communityDocId: communityDocId,
        profileId: profileId,
      ),
    ));
    return;
  }

  // Skills of THIS profile (Profile ID). Read straight from the profile
  // that is already loaded -- no extra request in the normal case.
  var skills = <String>[];
  try {
    skills = await CommunityMemberProfileService.resolveSkills(
        communityDocId, profile);
  } catch (_) {}
  if (!context.mounted) return;
  await CommunitySearchOpener.openMember(
    context,
    communityDocId: communityDocId,
    member: {
      'uid': uid,
      'id': profileId,
      'profileId': profileId,
      'publicName': name,
      'publicImage': '',
      'publicSkills': skills,
      'role': role,
    },
  );
}

// ----------------------------------------------------------------
// Long-press menu: Remove (Role) / (Role) / Personal Profile
// ----------------------------------------------------------------

/// Which roles each role may remove.
const Map<String, List<String>> _kCanRemove = {
  'Principal': ['HOD', 'Faculty', 'Controller', 'Student'],
  'HOD': ['Faculty', 'Student'],
  'Faculty': ['Student'],
  'Controller': ['HOD', 'Faculty', 'Controller', 'Student', 'Rep', 'Member'],
};

/// Viewer roles that may assign / remove a Representative.
const Set<String> _kCanAssignRep = {'Controller', 'HOD', 'Faculty'};

/// Cache first (instant when the doc is already streamed on this page),
/// server when it isn't cached yet.
Future<DocumentSnapshot<Map<String, dynamic>>> _getFast(
    DocumentReference<Map<String, dynamic>> ref) async {
  try {
    final cached = await ref.get(const GetOptions(source: Source.cache));
    if (cached.exists) return cached;
  } catch (_) {}
  return ref.get();
}

/// Profile ID the account [uid] is using in this community, worked out
/// from the community doc's profileIndex + the stored pointer. '' when
/// the community has no profile index (old uid-based data).
String _activeIdOf(
    Map<String, dynamic> community, String uid, String pointer) {
  final idx = community['profileIndex'];
  if (idx is! Map) return '';
  final mine = <Map<String, dynamic>>[
    for (final e in idx.entries)
      if (e.value is Map && (e.value['uid'] ?? '').toString() == uid)
        {'id': e.key.toString(), 'role': (e.value['role'] ?? '').toString()},
  ];
  return CommunityMemberProfileService.pickActiveId(mine, pointer);
}

Future<void> _showMemberActions(
  BuildContext context, {
  required String communityDocId,
  required Map<String, dynamic> profile,
  required String role,
}) async {
  final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final profileId = (profile['id'] ?? '').toString();
  final uid = (profile['uid'] ?? '').toString();
  final name = (profile['name'] ?? '').toString().trim();
  if (profileId.isEmpty || myUid.isEmpty) return;

  // The viewer's best role among ALL their profiles decides what is
  // offered (e.g. Controller + Student profiles -> Controller rights).
  // The community doc is already streamed on this page, so it is read
  // from the local cache first (instant); both reads run together.
  var myRole = CommunityMemberProfileService.roleMember;
  var ownerUid = '';
  var activePointer = '';
  var community = <String, dynamic>{};
  final fs = FirebaseFirestore.instance;
  await Future.wait<void>([
    () async {
      try {
        final snap =
            await _getFast(fs.collection('communities').doc(communityDocId));
        community = snap.data() ?? <String, dynamic>{};
      } catch (_) {}
    }(),
    () async {
      try {
        final snap = await _getFast(fs.collection('users').doc(myUid));
        final all = snap.data()?['activeCommunityProfiles'];
        activePointer =
            all is Map ? (all[communityDocId] ?? '').toString() : '';
      } catch (_) {}
    }(),
  ]);
  ownerUid = (community['ownerUid'] ?? '').toString();
  myRole = CommunityMemberProfileService.quickRole(myUid, community);
  if (!context.mounted) return;

  // Members of the old uid-based data have no profile yet: view only.
  final legacy = profile['legacy'] == true;

  // "You" = the profile this account is using right now. Its other
  // profiles are ordinary members (they keep "Personal Profile").
  final activeId = _activeIdOf(community, myUid, activePointer);
  final isYou =
      uid == myUid && (legacy || activeId.isEmpty || profileId == activeId);

  // Other profiles of the viewer's OWN account can be managed like anyone
  // else's. Never the profile of the person who created the community.
  final isOwnerProfile =
      uid == ownerUid && role == CommunityMemberProfileService.roleController;
  // Old uid-based members (no profile yet) can be removed too.
  final canRemove = !isOwnerProfile &&
      (_kCanRemove[myRole]?.contains(role) ?? false);
  final shownName = CommunityMemberProfileService.displayName(name, role);
  final title = name.isEmpty ? role : '$role - $name';

  // Assign Representative: HOD / Controller / Faculty, on a Student.
  final canAssignRep = !legacy &&
      _kCanAssignRep.contains(myRole) &&
      role == CommunityMemberProfileService.roleStudent;
  final canRemoveRep = !legacy &&
      _kCanAssignRep.contains(myRole) &&
      role == CommunityMemberProfileService.roleRep;

  Widget option(IconData icon, String label, String value,
      {Color color = Colors.white}) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: () => Navigator.of(context).pop(value),
    );
  }

  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF18181F),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (canRemove)
            option(Icons.person_remove_rounded, 'Remove $role', 'remove',
                color: Colors.redAccent),
          if (canAssignRep)
            option(Icons.how_to_reg_rounded, 'Assign Representative',
                'assignRep',
                color: const Color(0xFFC4B5FD)),
          if (canRemoveRep)
            option(Icons.person_off_rounded, 'Remove Representative',
                'removeRep'),
          option(Icons.badge_rounded, role, 'profile'),
          // Never offered on the profile marked "You".
          if (!isYou)
            option(Icons.person_rounded, 'Personal Profile', 'personal'),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'remove':
      await _confirmRemove(
        context,
        communityDocId: communityDocId,
        profileId: profileId,
        uid: uid,
        name: shownName,
        role: role,
      );
      break;
    case 'assignRep':
      await _confirmRep(
        context,
        communityDocId: communityDocId,
        profileId: profileId,
        name: shownName,
        assign: true,
      );
      break;
    case 'removeRep':
      await _confirmRep(
        context,
        communityDocId: communityDocId,
        profileId: profileId,
        name: shownName,
        assign: false,
      );
      break;
    case 'profile':
      await _openProfile(
        context,
        communityDocId: communityDocId,
        profile: profile,
        role: role,
      );
      break;
    case 'personal':
      await _openPersonalProfile(context, myUid: myUid, uid: uid);
      break;
  }
}

/// Makes a Student profile a Representative (tag Student -> Rep) or takes
/// it back. A Rep is a PROFILE ID in the community's moderators list --
/// the same account's other profiles are not affected.
Future<void> _confirmRep(
  BuildContext context, {
  required String communityDocId,
  required String profileId,
  required String name,
  required bool assign,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: CommunityColors.card,
      title: Text(assign ? 'Assign Representative?' : 'Remove Representative?',
          style: const TextStyle(color: Colors.white)),
      content: Text(
        assign
            ? '$name will become a Representative (Rep).'
            : '$name will go back to being a Student.',
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('CANCEL'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(assign ? 'ASSIGN' : 'REMOVE',
              style: const TextStyle(color: Color(0xFFC4B5FD))),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  try {
    await CommunityService.setModerator(
      communityDocId: communityDocId,
      profileId: profileId,
      isModerator: assign,
    );
    // A Rep who was made admin elsewhere keeps the Rep tag only while
    // they are in one of the lists; clear the other one when removing.
    if (!assign) {
      await CommunityService.setAdmin(
        communityDocId: communityDocId,
        profileId: profileId,
        isAdmin: false,
      );
    }
    if (context.mounted) {
      showTopAlert(context,
          assign ? '$name is now a Representative' : '$name is a Student again');
    }
  } catch (e) {
    if (context.mounted) {
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }
}

Future<void> _confirmRemove(
  BuildContext context, {
  required String communityDocId,
  required String profileId,
  required String uid,
  required String name,
  required String role,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: CommunityColors.card,
      title: Text('Remove $role?',
          style: const TextStyle(color: Colors.white)),
      content: Text(
        '$name will be removed from this community.',
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('CANCEL'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child:
              const Text('REMOVE', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  try {
    if (profileId.startsWith('legacy_')) {
      await CommunityService.removeLegacyMember(
        communityDocId: communityDocId,
        uid: uid,
      );
    } else {
      await CommunityService.removeMember(
        communityDocId: communityDocId,
        profileId: profileId,
      );
    }
    if (context.mounted) showTopAlert(context, '$name removed');
  } catch (e) {
    if (context.mounted) {
      showTopAlert(context, e.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }
}

/// Private profile when the person is connected with the viewer,
/// otherwise their public profile.
///
/// Opens at once on a small loading screen; the connection check (ONE
/// document read) and the cached user doc run together instead of one
/// after the other, and the real profile page replaces the loader the
/// moment the answer is known. The profile pages stream the user doc
/// themselves, so it is not awaited here.
Future<void> _openPersonalProfile(
  BuildContext context, {
  required String myUid,
  required String uid,
}) {
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => _PersonalProfileLoader(myUid: myUid, uid: uid),
  ));
}

Future<bool> _isConnectedWith(String myUid, String uid) async {
  // Another profile of my own account is not a "connection".
  if (myUid.isEmpty || uid.isEmpty || myUid == uid) return false;
  final ids = [myUid, uid]..sort();
  final ref =
      FirebaseFirestore.instance.collection('connections').doc(ids.join('_'));
  try {
    final snap = await ref.get().timeout(const Duration(seconds: 6));
    return (snap.data()?['status'] ?? '') == 'connected';
  } catch (_) {
    // Slow / offline: use what is cached instead of waiting longer.
    try {
      final snap = await ref.get(const GetOptions(source: Source.cache));
      return (snap.data()?['status'] ?? '') == 'connected';
    } catch (_) {
      return false;
    }
  }
}

class _PersonalProfileLoader extends StatefulWidget {
  final String myUid;
  final String uid;

  const _PersonalProfileLoader({required this.myUid, required this.uid});

  @override
  State<_PersonalProfileLoader> createState() => _PersonalProfileLoaderState();
}

class _PersonalProfileLoaderState extends State<_PersonalProfileLoader> {
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    var connected = false;
    var data = <String, dynamic>{};
    await Future.wait<void>([
      () async {
        connected = await _isConnectedWith(widget.myUid, widget.uid);
      }(),
      () async {
        // Only a head start for the page; it streams the live doc itself.
        try {
          final user = await FirebaseFirestore.instance
              .collection('users')
              .doc(widget.uid)
              .get(const GetOptions(source: Source.cache));
          data = user.data() ?? <String, dynamic>{};
        } catch (_) {}
      }(),
    ]);
    if (!mounted) return;

    Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => connected
          ? PrivateMemberProfilePage(uid: widget.uid, initialData: data)
          : PublicMemberProfilePage(uid: widget.uid, initialData: data),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Profile',
            style:
                TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: _loader,
    );
  }
}

const Widget _loader = Center(
  child: CircularProgressIndicator(color: _tan),
);

const Widget _thinDivider = Divider(
  color: Colors.white12,
  height: 1,
  indent: 72,
);

/// Live community doc + every ACTIVE member profile, handed to [builder].
class _CommunityProfiles extends StatefulWidget {
  final String communityDocId;
  final Widget Function(
    BuildContext context,
    Map<String, dynamic> community,
    List<Map<String, dynamic>> profiles,
  ) builder;

  const _CommunityProfiles({
    required this.communityDocId,
    required this.builder,
  });

  @override
  State<_CommunityProfiles> createState() => _CommunityProfilesState();
}

class _CommunityProfilesState extends State<_CommunityProfiles> {
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _communityStream =
      CommunityService.watchCommunity(widget.communityDocId);
  late final Stream<List<Map<String, dynamic>>> _profileStream =
      CommunityMemberProfileService.watchAllProfiles(widget.communityDocId);

  // Members of the old (uid-based) data who have no profile yet. They are
  // listed (and counted) until they open the community once.
  String _legacyKey = '';
  List<Map<String, dynamic>> _legacyRows = [];
  int _healedCount = -1;

  Future<void> _loadLegacy(
    String key,
    List<String> uids,
    Map<String, dynamic> community,
  ) async {
    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < uids.length; i += 10) {
      final chunk =
          uids.sublist(i, i + 10 > uids.length ? uids.length : i + 10);
      try {
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        for (final doc in snap.docs) {
          final d = doc.data();
          final all = d['communityProfiles'];
          final mine = all is Map ? all[widget.communityDocId] : null;
          var name = mine is Map ? (mine['name'] ?? '').toString().trim() : '';
          rows.add({
            'id': 'legacy_${doc.id}',
            'profileId': '',
            'uid': doc.id,
            'name': name,
            'role': CommunityMemberProfileService.quickRole(doc.id, community),
            'legacy': true,
            'active': true,
          });
        }
      } catch (_) {}
    }
    if (!mounted || key != _legacyKey) return;
    setState(() => _legacyRows = rows);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _communityStream,
      builder: (context, communitySnap) {
        if (communitySnap.hasError) {
          return const _CenteredMessage(
            icon: Icons.error_outline_rounded,
            text: 'Unable to load members',
          );
        }
        if (!communitySnap.hasData) return _loader;
        final community = communitySnap.data?.data() ?? <String, dynamic>{};

        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: _profileStream,
          builder: (context, profileSnap) {
            if (profileSnap.hasError) {
              return const _CenteredMessage(
                icon: Icons.error_outline_rounded,
                text: 'Unable to load members',
              );
            }
            if (!profileSnap.hasData) return _loader;

            final raw = profileSnap.data!;
            final active = [
              for (final p in raw)
                if (CommunityMemberProfileService.isActive(p)) p,
            ];
            final known = {for (final p in raw) (p['uid'] ?? '').toString()};
            final members = community['members'] is List
                ? (community['members'] as List).map((e) => e.toString())
                : const <String>[];
            final legacyUids = [
              for (final u in members)
                if (u.isNotEmpty && !known.contains(u)) u,
            ]..sort();

            final key = legacyUids.join(',');
            if (key != _legacyKey) {
              _legacyKey = key;
              if (legacyUids.isEmpty) {
                _legacyRows = [];
              } else {
                Future.microtask(() => _loadLegacy(key, legacyUids, community));
              }
            }

            // Keep the stored member count equal to the profiles that are
            // really in the community (active profiles + not-yet-migrated
            // members), so the count and this list always agree.
            final total = active.length + legacyUids.length;
            final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
            final stored = community['membersCount'];
            if (members.contains(myUid) &&
                stored != total &&
                _healedCount != total) {
              _healedCount = total;
              Future.microtask(() async {
                try {
                  await FirebaseFirestore.instance
                      .collection('communities')
                      .doc(widget.communityDocId)
                      .update({'membersCount': total});
                } catch (_) {}
              });
            }

            final rows = [
              ...active,
              if (_legacyRows.length == legacyUids.length) ..._legacyRows,
            ];
            return widget.builder(context, community, rows);
          },
        );
      },
    );
  }
}

// ----------------------------------------------------------------
// All
// ----------------------------------------------------------------
class _AllMembersView extends StatefulWidget {
  final String communityDocId;

  const _AllMembersView({required this.communityDocId});

  @override
  State<_AllMembersView> createState() => _AllMembersViewState();
}

class _AllMembersViewState extends State<_AllMembersView> {
  final String _myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

  // Which of my profiles is active right now (live: switching profiles
  // moves "You" straight away).
  late final Stream<String> _pointerStream =
      CommunityMemberProfileService.watchActivePointer(
          widget.communityDocId, _myUid);

  @override
  Widget build(BuildContext context) {
    final communityDocId = widget.communityDocId;
    final myUid = _myUid;

    return StreamBuilder<String>(
      stream: _pointerStream,
      builder: (context, pointerSnap) {
        final pointer = pointerSnap.data ?? '';
        return _CommunityProfiles(
          communityDocId: communityDocId,
          builder: (context, community, all) {
            if (all.isEmpty) {
              return const _CenteredMessage(
                icon: Icons.people_outline_rounded,
                text: 'No members yet',
              );
            }

            // Order: Principal, Controller, HOD, Faculty, Rep, then Students.
            final profiles =
                CommunityMemberProfileService.sorted(all, community);

            // "You" belongs to ONE profile only: the active one. The
            // account's other profiles are shown like any other member.
            final mine = [
              for (final p in all)
                if ((p['uid'] ?? '').toString() == myUid &&
                    p['legacy'] != true)
                  p,
            ];
            final activeId =
                CommunityMemberProfileService.pickActiveId(mine, pointer);

            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: profiles.length,
              separatorBuilder: (_, _) => _thinDivider,
              itemBuilder: (context, index) {
                final profile = profiles[index];
                final uid = (profile['uid'] ?? '').toString();
                final profileId = (profile['id'] ?? '').toString();
                final role = CommunityMemberProfileService.effectiveRole(
                    profile, community);
                // Name set on this profile; none -> the role (grey).
                final rawName = (profile['name'] ?? '').toString().trim();
                final name =
                    CommunityMemberProfileService.displayName(rawName, role);
                final isYou = uid == myUid &&
                    (profile['legacy'] == true ||
                        (activeId.isNotEmpty && profileId == activeId));

                return ListTile(
                  onLongPress: () => _showMemberActions(
                    context,
                    communityDocId: communityDocId,
                    profile: profile,
                    role: role,
                  ),
                  onTap: () => _openProfile(
                    context,
                    communityDocId: communityDocId,
                    profile: profile,
                    role: role,
                  ),
                  leading: _RoleRing(
                    role: role,
                    child: CommunityAvatar(url: '', name: name, radius: 22),
                  ),
                  title: Text(
                    name,
                    style: TextStyle(
                      color: rawName.isEmpty ? Colors.grey : Colors.white,
                    ),
                  ),
                  subtitle: isYou
                      ? const Text('You',
                          style:
                              TextStyle(color: Colors.white38, fontSize: 12))
                      : null,
                  trailing: _RoleBadge(role),
                );
              },
            );
          },
        );
      },
    );
  }
}

// ----------------------------------------------------------------
// Principal / HOD / Faculty / Controller
// ----------------------------------------------------------------
class _StaffView extends StatelessWidget {
  final String communityDocId;
  final String role;

  const _StaffView({
    super.key,
    required this.communityDocId,
    required this.role,
  });

  @override
  Widget build(BuildContext context) {
    return _CommunityProfiles(
      communityDocId: communityDocId,
      builder: (context, community, all) {
        // Every profile with this role -- the community creator's
        // Controller profile is one of them like any other.
        final rows = CommunityMemberProfileService.sorted([
          for (final p in all)
            if (CommunityMemberProfileService.effectiveRole(p, community) ==
                role)
              p,
        ], community);

        if (rows.isEmpty) {
          return _CenteredMessage(
            icon: Icons.person_search_rounded,
            text: 'No $role added yet',
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: rows.length,
          separatorBuilder: (_, _) => _thinDivider,
          itemBuilder: (context, i) {
            final profile = rows[i];
            final name = (profile['name'] ?? '').toString().trim();
            return _PersonTile(
              // No name -> the role, in grey.
              name: CommunityMemberProfileService.displayName(name, role),
              greyName: name.isEmpty,
              subtitle: (profile['department'] ?? '').toString(),
              image: (profile['image'] ?? '').toString(),
              badge: role,
              onLongPress: () => _showMemberActions(
                context,
                communityDocId: communityDocId,
                profile: profile,
                role: role,
              ),
              onTap: () => _openProfile(
                context,
                communityDocId: communityDocId,
                profile: profile,
                role: role,
              ),
            );
          },
        );
      },
    );
  }
}

// ----------------------------------------------------------------
// Students  (Year filter + Department filter, independent)
// ----------------------------------------------------------------
class _StudentsView extends StatefulWidget {
  final String communityDocId;

  const _StudentsView({required this.communityDocId});

  @override
  State<_StudentsView> createState() => _StudentsViewState();
}

class _StudentsViewState extends State<_StudentsView> {
  String? _year; // null = all years
  String? _department; // null = all departments

  @override
  Widget build(BuildContext context) {
    return _CommunityProfiles(
      communityDocId: widget.communityDocId,
      builder: (context, community, all) {
        final custom = community['departments'] is List
            ? (community['departments'] as List)
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList()
            : <String>[];
        final departments = custom.isEmpty ? kDefaultDepartments : custom;

        return Column(
          children: [
            _FilterRow(
              label: 'Year',
              options: kCommunityYears,
              selected: _year,
              onChanged: (v) => setState(() => _year = v),
            ),
            _FilterRow(
              label: 'Dept',
              options: departments,
              selected: _department,
              onChanged: (v) => setState(() => _department = v),
            ),
            const Divider(color: Colors.white12, height: 1),
            Expanded(child: _studentList(community, all)),
          ],
        );
      },
    );
  }

  Widget _studentList(
    Map<String, dynamic> community,
    List<Map<String, dynamic>> all,
  ) {
    // Student and Rep profiles (a Rep is a Student profile that was
    // appointed), narrowed by the Year / Department filters.
    final rows = all.where((p) {
      final role = CommunityMemberProfileService.effectiveRole(p, community);
      if (role != CommunityMemberProfileService.roleStudent &&
          role != CommunityMemberProfileService.roleRep) {
        return false;
      }
      final yearOk =
          _year == null || (p['year'] ?? '').toString().trim() == _year;
      final deptOk = _department == null ||
          (p['department'] ?? '').toString().trim() == _department;
      return yearOk && deptOk;
    }).toList()
      ..sort((a, b) => (a['name'] ?? '')
          .toString()
          .toLowerCase()
          .compareTo((b['name'] ?? '').toString().toLowerCase()));

    if (rows.isEmpty) {
      return const _CenteredMessage(
        icon: Icons.people_outline_rounded,
        text: 'No students yet',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length,
      separatorBuilder: (_, _) => _thinDivider,
      itemBuilder: (context, i) {
        final profile = rows[i];
        final role =
            CommunityMemberProfileService.effectiveRole(profile, community);
        // Name set on this profile (none -> role, grey).
        final name = (profile['name'] ?? '').toString().trim();
        final parts = <String>[
          (profile['registerNumber'] ?? '').toString(),
          (profile['department'] ?? '').toString(),
          (profile['year'] ?? '').toString(),
        ].where((e) => e.trim().isNotEmpty).toList();

        return _PersonTile(
          // Empty name -> show the role instead.
          name: CommunityMemberProfileService.displayName(name, role),
          greyName: name.isEmpty,
          subtitle: parts.join(' • '),
          image: (profile['image'] ?? '').toString(),
          badge: role,
          onLongPress: () => _showMemberActions(
            context,
            communityDocId: widget.communityDocId,
            profile: profile,
            role: role,
          ),
          onTap: () => _openProfile(
            context,
            communityDocId: widget.communityDocId,
            profile: profile,
            role: role,
          ),
        );
      },
    );
  }
}

class _FilterRow extends StatelessWidget {
  final String label;
  final List<String> options;
  final String? selected;
  final ValueChanged<String?> onChanged;

  const _FilterRow({
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: SizedBox(
              width: 38,
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 16),
              itemCount: options.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Center(
                    child: _PillChip(
                      label: 'All',
                      selected: selected == null,
                      onTap: () => onChanged(null),
                    ),
                  );
                }
                final o = options[i - 1];
                return Center(
                  child: _PillChip(
                    label: o,
                    selected: selected == o,
                    onTap: () => onChanged(o),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
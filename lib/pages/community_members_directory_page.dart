import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'community_join_requirements_page.dart';
import 'community_role_requirements_page.dart';
import '../services/community_member_profile_service.dart';
import '../services/community_service.dart';

// ================================================================
// COMMUNITY MEMBERS DIRECTORY (Phase 1)
// ----------------------------------------------------------------
// Navigation opened from the 3-line menu on the Members bar:
//   Principal / HOD / Faculty / Controller -> CommunityRoleListPage
//            (owner: "Set Join Requirements" = the name(s) allowed to
//             join with that role)
//   Students -> CommunityDepartmentsPage (e.g. CSE)
//            -> CommunityYearsPage (years of that department)
//            -> CommunityYearStudentsPage (students of that year)
//
// Data sources used in this phase (formalised in Phase 2):
//   communities/{id}.departments        List<String>, optional;
//                                       falls back to the defaults below
//   communities/{id}/memberProfiles    one doc per MEMBER PROFILE
//                                       (Profile ID, not the account UID):
//                                       {role, name, registerNumber,
//                                       image, department, year, active}
//                                       role = Principal | HOD | Faculty |
//                                       Controller | Student
// Empty collections simply show an empty state, nothing crashes.
// ================================================================

const List<String> kDefaultDepartments = [
  'CSE',
  'IT',
  'ECE',
  'EEE',
  'MECH',
  'CIVIL',
  'AI&DS',
  'Fashion Technology',
];

const List<String> kCommunityYears = [
  '1st Year',
  '2nd Year',
  '3rd Year',
  '4th Year',
];

const Color _tan = Color(0xFFA78BFA);

AppBar _bar(String title) => AppBar(
      backgroundColor: Colors.black,
      elevation: 0,
      title: Text(title, style: const TextStyle(color: Colors.white)),
      iconTheme: const IconThemeData(color: Colors.white),
    );

class _Empty extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Empty({required this.icon, required this.text});

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

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _NavTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: const Color(0xFF20202A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _tan.withValues(alpha: .4)),
        ),
        child: Icon(icon, color: _tan, size: 22),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: Colors.white38,
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  final String name;
  final String subtitle;
  final String image;
  final String fallbackName; // shown when the name is empty (the role)

  const _PersonTile({
    required this.name,
    required this.subtitle,
    required this.image,
    this.fallbackName = 'Unnamed',
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = image.startsWith('http');
    final shown = name.trim().isEmpty ? fallbackName : name.trim();
    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: const Color(0xFF20202A),
        backgroundImage: hasImage ? NetworkImage(image) : null,
        // No photo -> first letter of the shown name (or role).
        child: hasImage
            ? null
            : Text(
                shown.isEmpty ? '?' : shown[0].toUpperCase(),
                style: const TextStyle(
                  color: Color(0xFFFDE68A),
                  fontWeight: FontWeight.bold,
                  fontSize: 19.8,
                ),
              ),
      ),
      title: Text(
        name.isEmpty ? fallbackName : name,
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, style: const TextStyle(color: Colors.white54)),
    );
  }
}

// ----------------------------------------------------------------
// Principal / HOD / Faculty / Controller
// ----------------------------------------------------------------

class CommunityRoleListPage extends StatefulWidget {
  final String communityDocId;
  final String role; // Principal | HOD | Faculty | Controller

  const CommunityRoleListPage({
    super.key,
    required this.communityDocId,
    required this.role,
  });

  @override
  State<CommunityRoleListPage> createState() => _CommunityRoleListPageState();
}

class _CommunityRoleListPageState extends State<CommunityRoleListPage> {
  late final Stream<List<Map<String, dynamic>>> _profiles =
      CommunityMemberProfileService.watchProfiles(widget.communityDocId);

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _bar(widget.role),
      body: Column(
        children: [
          // Owner-only entry at the top of the page.
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: CommunityService.watchCommunity(widget.communityDocId),
            builder: (context, communitySnap) {
              final ownerUid =
                  (communitySnap.data?.data()?['ownerUid'] ?? '').toString();
              if (uid.isEmpty || ownerUid != uid) {
                return const SizedBox.shrink();
              }
              return Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF7C3AED).withValues(alpha: .25),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _tan.withValues(alpha: .5)),
                ),
                child: ListTile(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CommunityRoleRequirementsPage(
                        communityDocId: widget.communityDocId,
                        role: widget.role,
                      ),
                    ),
                  ),
                  leading: const Icon(Icons.tune_rounded, color: _tan),
                  title: const Text(
                    'Set Join Requirements',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white38,
                  ),
                ),
              );
            },
          ),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _list() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _profiles,
      builder: (context, snap) {
        if (snap.hasError) {
          return const _Empty(
            icon: Icons.error_outline_rounded,
            text: 'Unable to load',
          );
        }
        if (!snap.hasData) {
          return const Center(
            child: CircularProgressIndicator(color: _tan),
          );
        }
        // Every ACTIVE member profile with this role (the creator's
        // Controller profile is one of them like any other).
        final rows = [
          for (final p in snap.data!)
            if ((p['role'] ?? '').toString() == widget.role) p,
        ]..sort((a, b) => (a['name'] ?? '')
            .toString()
            .toLowerCase()
            .compareTo((b['name'] ?? '').toString().toLowerCase()));

        if (rows.isEmpty) {
          return _Empty(
            icon: Icons.person_search_rounded,
            text: 'No ${widget.role} added yet',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const Divider(
            color: Colors.white12,
            height: 1,
            indent: 72,
          ),
          itemBuilder: (context, i) {
            final d = rows[i];
            return _PersonTile(
              name: (d['name'] ?? '').toString(),
              subtitle: (d['department'] ?? '').toString(),
              image: (d['image'] ?? '').toString(),
              fallbackName: widget.role,
            );
          },
        );
      },
    );
  }
}

// ----------------------------------------------------------------
// Students -> Departments
// ----------------------------------------------------------------
class CommunityDepartmentsPage extends StatelessWidget {
  final String communityDocId;

  const CommunityDepartmentsPage({super.key, required this.communityDocId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _bar('Departments'),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: CommunityService.watchCommunity(communityDocId),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: _tan),
            );
          }
          final data = snap.data?.data();
          final custom = data?['departments'] is List
              ? (data!['departments'] as List)
                  .map((e) => e.toString().trim())
                  .where((e) => e.isNotEmpty)
                  .toList()
              : <String>[];
          final departments = custom.isEmpty ? kDefaultDepartments : custom;

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: departments.length,
            separatorBuilder: (_, _) => const Divider(
              color: Colors.white12,
              height: 1,
              indent: 72,
            ),
            itemBuilder: (context, i) {
              final dept = departments[i];
              return _NavTile(
                icon: Icons.apartment_rounded,
                title: dept,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CommunityYearsPage(
                      communityDocId: communityDocId,
                      department: dept,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ----------------------------------------------------------------
// Department -> Years
// ----------------------------------------------------------------
class CommunityYearsPage extends StatelessWidget {
  final String communityDocId;
  final String department;

  const CommunityYearsPage({
    super.key,
    required this.communityDocId,
    required this.department,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _bar(department),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: kCommunityYears.length,
        separatorBuilder: (_, _) => const Divider(
          color: Colors.white12,
          height: 1,
          indent: 72,
        ),
        itemBuilder: (context, i) {
          final year = kCommunityYears[i];
          return _NavTile(
            icon: Icons.school_rounded,
            title: year,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CommunityYearStudentsPage(
                  communityDocId: communityDocId,
                  department: department,
                  year: year,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ----------------------------------------------------------------
// Year -> Students
// ----------------------------------------------------------------
class CommunityYearStudentsPage extends StatelessWidget {
  final String communityDocId;
  final String department;
  final String year;

  const CommunityYearStudentsPage({
    super.key,
    required this.communityDocId,
    required this.department,
    required this.year,
  });

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _bar('$department • $year'),
      body: Column(
        children: [
          // Owner-only entry at the top of the page.
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: CommunityService.watchCommunity(communityDocId),
            builder: (context, communitySnap) {
              final ownerUid =
                  (communitySnap.data?.data()?['ownerUid'] ?? '').toString();
              if (uid.isEmpty || ownerUid != uid) {
                return const SizedBox.shrink();
              }
              return Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF7C3AED).withValues(alpha: .25),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _tan.withValues(alpha: .5)),
                ),
                child: ListTile(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CommunityJoinRequirementsPage(
                        communityDocId: communityDocId,
                        department: department,
                        year: year,
                      ),
                    ),
                  ),
                  leading: const Icon(Icons.tune_rounded, color: _tan),
                  title: const Text(
                    'Set Join Requirements',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white38,
                  ),
                ),
              );
            },
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: CommunityMemberProfileService.profilesRef(communityDocId)
                  .where('department', isEqualTo: department)
                  .where('year', isEqualTo: year)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: _tan),
                  );
                }
                if (snap.hasError) {
                  return const _Empty(
                    icon: Icons.error_outline_rounded,
                    text: 'Unable to load students',
                  );
                }
                // Active Student profiles of this class.
                final docs = [
                  for (final d in snap.data?.docs ?? const [])
                    if (d.data()['active'] != false &&
                        (d.data()['role'] ?? '').toString() == 'Student')
                      d,
                ];
                if (docs.isEmpty) {
                  return const _Empty(
                    icon: Icons.people_outline_rounded,
                    text: 'No students yet',
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: docs.length,
                  separatorBuilder: (_, _) => const Divider(
                    color: Colors.white12,
                    height: 1,
                    indent: 72,
                  ),
                  itemBuilder: (context, i) {
                    final d = docs[i].data();
                    return _PersonTile(
                      name: (d['name'] ?? '').toString(),
                      subtitle: (d['registerNumber'] ?? '').toString(),
                      image: (d['image'] ?? '').toString(),
                      fallbackName: 'Student',
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'community_members_directory_page.dart';
import '../services/community_join_service.dart';
import '../services/community_service.dart';
import '../widgets/top_alert.dart';

// ================================================================
// JOIN COMMUNITY SHEET
// ----------------------------------------------------------------
// Same bottom-sheet shell used for "Add Member" in
// _CreateGroupDialog._openAddMember (dark card, rounded top, drag
// handle).
//
// Step 1 (only when opened without a community): type the Community
//   ID, the community name, or the institution (college) name.
//   * exact Community ID  -> that community
//   * name / institution  -> matching communities; if more than one
//     matches, the student picks one from a list
// Step 2 (join requirements): when the community's owner has set join
//   requirements, the student must pick department + year and provide
//   what the owner asked for (e.g. Register Number, digits only). The
//   number is validated against the owner's range / disabled /
//   extra-allowed rules before joining.
//   When the owner also set a name for Principal / HOD / Faculty /
//   Controller, the person first picks a Role. Student -> the class
//   requirements above; a staff role -> they type their name and are
//   let in only when it matches a name the owner set for that role.
// A community with no requirements is joined straight away.
//
// Opened from a search suggestion, the sheet skips step 1 and goes
// straight to the join requirements.
// ================================================================
///
/// [pickOnly]: when the sheet is opened without a community, picking
/// one (exact ID, a single name match, or a tap in the match list)
/// does NOT start joining -- the sheet closes and returns the picked
/// community so the caller can show its profile details first (with
/// a Join button) before the join requirements.
Future<Map<String, dynamic>?> showJoinCommunitySheet(
  BuildContext context, {
  Map<String, dynamic>? initialCommunity,
  bool pickOnly = false,
}) async {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    backgroundColor: const Color(0xFF18181F),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
    ),
    builder: (_) => _JoinCommunitySheet(
      initialCommunity: initialCommunity,
      pickOnly: pickOnly,
    ),
  );
}

class _JoinCommunitySheet extends StatefulWidget {
  // A community picked from the search suggestions (needs 'docId').
  final Map<String, dynamic>? initialCommunity;

  // Step 1 only picks the community and returns it (see
  // showJoinCommunitySheet).
  final bool pickOnly;

  const _JoinCommunitySheet({this.initialCommunity, this.pickOnly = false});

  @override
  State<_JoinCommunitySheet> createState() => _JoinCommunitySheetState();
}

class _JoinCommunitySheetState extends State<_JoinCommunitySheet> {
  final TextEditingController _idController = TextEditingController();
  final TextEditingController _regController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  bool _joining = false;

  // Step 1b: several communities matched the typed name.
  List<Map<String, dynamic>> _choices = [];

  // Step 2: the community that needs join requirements filled in.
  Map<String, dynamic>? _pending;
  String? _department;
  String? _year;
  JoinRequirements? _classRequirements;

  // Role option: 'Student' + every staff role the owner set a name for.
  List<String> _roleOptions = const ['Student'];
  bool _hasStudentRules = true;
  String? _role;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialCommunity;
    if (initial != null) {
      _joining = true; // shows a spinner until the community is checked
      WidgetsBinding.instance.addPostFrameCallback((_) => _proceed(initial));
    }
  }

  @override
  void dispose() {
    _idController.dispose();
    _regController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  List<String> get _departments {
    final custom = _pending?['departments'];
    final list = custom is List
        ? custom
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList()
        : <String>[];
    return list.isEmpty ? kDefaultDepartments : list;
  }

  // Register Number is the only requirement type the owner can set so
  // far (see JoinRequirements.requiredField).
  String get _requiredLabel => 'Register Number';

  void _finish(Map<String, dynamic> community, Map<String, dynamic> result) {
    Navigator.of(context).pop();
    showTopAlert(
      context,
      result['alreadyMember'] == true
          ? 'You\'re already a member of "${community['name']}" with this profile'
          : 'Joined "${community['name']}"',
    );
  }

  // ---------------- step 1: find the community ----------------

  Future<void> _join() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final text = _idController.text.trim();
    if (text.isEmpty) {
      showTopAlert(context, 'Enter a Community ID or institution name',
          isError: true);
      return;
    }

    setState(() => _joining = true);

    try {
      // 1) exact Community ID
      final byId = await CommunityService.findByCommunityId(text);
      if (byId != null) {
        if (widget.pickOnly) {
          setState(() {
            _choices = [byId];
            _joining = false;
          });
          return;
        }
        await _select(byId);
        return;
      }

      // 2) community name / institution name
      final matches = await _searchByName(text);
      if (!mounted) return;

      if (matches.isEmpty) {
        setState(() => _joining = false);
        showTopAlert(context, 'No community found with that ID or name',
            isError: true);
        return;
      }

      if (matches.length == 1 && !widget.pickOnly) {
        await _select(matches.first);
        return;
      }

      setState(() {
        _choices = matches;
        _joining = false;
      });
    } catch (e) {
      debugPrint('Join community error: $e');
      if (!mounted) return;
      setState(() => _joining = false);
      showTopAlert(context, 'Failed to join community.', isError: true);
    }
  }

  /// A community was found / tapped in step 1. In pick-only mode the
  /// sheet closes and hands it back; otherwise joining starts here.
  Future<void> _select(Map<String, dynamic> community) async {
    if (widget.pickOnly && widget.initialCommunity == null) {
      if (mounted) Navigator.of(context).pop(community);
      return;
    }
    await _proceed(community);
  }

  Future<List<Map<String, dynamic>>> _searchByName(String text) async {
    final query = text.toLowerCase();
    final snap = await FirebaseFirestore.instance
        .collection('communities')
        .limit(300)
        .get();

    final found = snap.docs
        .map((d) => <String, dynamic>{...d.data(), 'docId': d.id})
        .where((c) {
      final name = (c['name'] ?? '').toString().toLowerCase();
      final college = (c['collegeName'] ?? '').toString().toLowerCase();
      return name.contains(query) || college.contains(query);
    }).toList();

    int rank(Map<String, dynamic> c) {
      final name = (c['name'] ?? '').toString().toLowerCase();
      final college = (c['collegeName'] ?? '').toString().toLowerCase();
      if (name == query || college == query) return 0;
      if (name.startsWith(query) || college.startsWith(query)) return 1;
      return 2;
    }

    found.sort((a, b) => rank(a).compareTo(rank(b)));
    return found.take(10).toList();
  }

  // ---------------- step 2: requirements, or join ----------------

  /// A failure while checking / joining a community. Opened from a
  /// search suggestion the sheet just closes with the message (there is
  /// no ID box to fall back to); otherwise it stays on the ID step.
  void _failProceed(String message) {
    if (widget.initialCommunity != null) {
      Navigator.of(context).pop();
      showTopAlert(context, message, isError: true);
      return;
    }
    setState(() => _joining = false);
    showTopAlert(context, message, isError: true);
  }

  /// Reads the community fresh, then either asks for the join
  /// requirements or joins straight away.
  Future<void> _proceed(Map<String, dynamic> picked) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (mounted) setState(() => _joining = true);

    try {
      final docId = (picked['docId'] ?? '').toString();
      final snap = await FirebaseFirestore.instance
          .collection('communities')
          .doc(docId)
          .get();

      if (!mounted) return;

      if (!snap.exists) {
        _failProceed('Community not found');
        return;
      }

      final community = <String, dynamic>{...snap.data()!, 'docId': docId};

      // Join requirements are asked every time -- an account that is
      // already a member can still join with ANOTHER role (e.g. Student
      // after Controller) and gets a separate member profile for it.
      final options = await CommunityJoinService.joinOptions(docId);
      if (!mounted) return;
      if (!options.isEmpty) {
        setState(() {
          _pending = community;
          _hasStudentRules = options.hasStudentRules;
          _roleOptions = ['Student', ...options.roles];
          // Only Student on offer -> no Role question to ask.
          _role = options.roles.isEmpty ? 'Student' : null;
          _choices = [];
          _joining = false;
        });
        return;
      }

      // No roles / class rules to choose from: an account that is already
      // a member has nothing new to join with (no extra profile, no count).
      final already = community['members'] is List &&
          (community['members'] as List).map((e) => e.toString()).contains(user.uid);
      if (already) {
        _finish(community, {'success': true, 'alreadyMember': true});
        return;
      }

      final result = await CommunityService.joinCommunity(
        communityDocId: docId,
        uid: user.uid,
      );

      if (!mounted) return;

      if (result['success'] != true) {
        _failProceed((result['message'] ?? 'Failed to join').toString());
        return;
      }

      _finish(community, result);
    } catch (e) {
      debugPrint('Join community error: $e');
      if (!mounted) return;
      _failProceed('Failed to join community.');
    }
  }

  /// Loads what the owner set for the chosen department + year, so the
  /// student sees exactly what they are being asked for.
  Future<void> _loadClassRequirements() async {
    final community = _pending;
    final dept = _department;
    final year = _year;
    if (community == null || dept == null || year == null) return;

    setState(() => _classRequirements = null);
    try {
      final req = await CommunityJoinService.getRequirements(
        (community['docId'] ?? '').toString(),
        dept,
        year,
      );
      if (!mounted || _department != dept || _year != year) return;
      setState(() => _classRequirements = req);
    } catch (e) {
      debugPrint('Load join requirements error: $e');
    }
  }

  /// Asks for the join password (set on the member profile). Returns
  /// null when cancelled.
  Future<String?> _askPassword({
    required String what,
    bool wrong = false,
  }) async {
    final controller = TextEditingController();
    var hide = true;
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF18181F),
          title: const Text('Password required',
              style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                wrong
                    ? 'Wrong password. Try again.'
                    : 'This $what has a password. Enter it to join.',
                style: TextStyle(
                  color: wrong ? Colors.redAccent : Colors.white70,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: hide,
                style: const TextStyle(color: Colors.white),
                onSubmitted: (v) {
                  if (v.isNotEmpty) Navigator.pop(dialogContext, v);
                },
                decoration: InputDecoration(
                  hintText: 'Password',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF18181F),
                  suffixIcon: IconButton(
                    onPressed: () => setLocal(() => hide = !hide),
                    icon: Icon(
                      hide
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      color: Colors.white54,
                      size: 20,
                    ),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('CANCEL'),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.isEmpty) return;
                Navigator.pop(dialogContext, controller.text);
              },
              child: const Text('JOIN'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return value;
  }

  /// Runs [join]; while the result says a password is needed, asks for
  /// it and tries again (until it is right or the person cancels).
  Future<Map<String, dynamic>?> _withPassword(
    String what,
    Future<Map<String, dynamic>> Function(String password) join,
  ) async {
    var result = await join('');
    while (result['needsPassword'] == true) {
      if (!mounted) return null;
      final pw = await _askPassword(
        what: what,
        wrong: result['wrongPassword'] == true,
      );
      if (pw == null) return null; // cancelled
      result = await join(pw);
    }
    return result;
  }

  Future<void> _joinWithRegisterNumber() async {
    final community = _pending;
    if (community == null || _joining) return;

    if (_department == null || _year == null) {
      showTopAlert(context, 'Select your department and year',
          isError: true);
      return;
    }

    setState(() => _joining = true);
    try {
      final result = await _withPassword(
        'register number',
        (pw) => CommunityJoinService.joinAsStudent(
          communityDocId: (community['docId'] ?? '').toString(),
          department: _department!,
          year: _year!,
          registerNumber: _regController.text,
          password: pw,
        ),
      );

      if (!mounted) return;

      if (result == null) {
        setState(() => _joining = false); // password cancelled
        return;
      }

      if (result['success'] != true) {
        setState(() => _joining = false);
        showTopAlert(
          context,
          (result['message'] ?? 'Failed to join').toString(),
          isError: true,
        );
        return;
      }

      _finish(community, result);
    } catch (e) {
      debugPrint('Join with register number error: $e');
      if (!mounted) return;
      setState(() => _joining = false);
      showTopAlert(context, 'Failed to join community.', isError: true);
    }
  }

  /// Student in a community that only set staff names: no class
  /// requirements to check, so join straight away.
  Future<void> _joinPlain() async {
    final community = _pending;
    final user = FirebaseAuth.instance.currentUser;
    if (community == null || user == null || _joining) return;

    setState(() => _joining = true);
    try {
      // Records the Student role so the member tag is "Student".
      final result = await CommunityJoinService.joinAsPlainStudent(
        communityDocId: (community['docId'] ?? '').toString(),
      );

      if (!mounted) return;

      if (result['success'] != true) {
        setState(() => _joining = false);
        showTopAlert(
          context,
          (result['message'] ?? 'Failed to join').toString(),
          isError: true,
        );
        return;
      }

      _finish(community, result);
    } catch (e) {
      debugPrint('Join community error: $e');
      if (!mounted) return;
      setState(() => _joining = false);
      showTopAlert(context, 'Failed to join community.', isError: true);
    }
  }

  /// Principal / HOD / Faculty / Controller: the typed name must match
  /// a name the owner set for the chosen role.
  Future<void> _joinAsRole() async {
    final community = _pending;
    final role = _role;
    if (community == null || role == null || _joining) return;

    if (_nameController.text.trim().isEmpty) {
      showTopAlert(context, 'Enter your name', isError: true);
      return;
    }

    setState(() => _joining = true);
    try {
      final result = await _withPassword(
        'name',
        (pw) => CommunityJoinService.joinAsRole(
          communityDocId: (community['docId'] ?? '').toString(),
          role: role,
          name: _nameController.text,
          password: pw,
        ),
      );

      if (!mounted) return;

      if (result == null) {
        setState(() => _joining = false); // password cancelled
        return;
      }

      if (result['success'] != true) {
        setState(() => _joining = false);
        showTopAlert(
          context,
          (result['message'] ?? 'Failed to join').toString(),
          isError: true,
        );
        return;
      }

      _finish(community, result);
    } catch (e) {
      debugPrint('Join as role error: $e');
      if (!mounted) return;
      setState(() => _joining = false);
      showTopAlert(context, 'Failed to join community.', isError: true);
    }
  }

  void _backToStart() {
    setState(() {
      _pending = null;
      _choices = [];
      _department = null;
      _year = null;
      _classRequirements = null;
      _role = null;
      _roleOptions = const ['Student'];
      _hasStudentRules = true;
      _regController.clear();
      _nameController.clear();
    });
  }

  // ---------------- widgets ----------------

  InputDecoration _decoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xFF20202A),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      );

  Widget _dropdown({
    required String hint,
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF20202A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: const Color(0xFF20202A),
          iconEnabledColor: Colors.white54,
          hint: Text(hint, style: const TextStyle(color: Colors.white38)),
          style: const TextStyle(color: Colors.white),
          items: [
            for (final item in items)
              DropdownMenuItem(value: item, child: Text(item)),
          ],
          onChanged: _joining ? null : onChanged,
        ),
      ),
    );
  }

  Widget _goldButton(String label, VoidCallback onTap) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: AppColors.goldGradient,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _joining ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: _joining
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Color(0xFF18181F),
                      ),
                    )
                  : Text(
                      label,
                      style: const TextStyle(
                        color: Color(0xFF18181F),
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _choiceTile(Map<String, dynamic> c) {
    final name = (c['name'] ?? '').toString();
    final college = (c['collegeName'] ?? '').toString();
    final id = (c['communityId'] ?? '').toString();
    final logo = (c['logoUrl'] ?? '').toString();
    final hasLogo = logo.startsWith('http');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFF20202A),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _joining ? null : () => _select(c),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: const Color(0xFF18181F),
                  backgroundImage: hasLogo ? NetworkImage(logo) : null,
                  child: hasLogo
                      ? null
                      : const Icon(Icons.public_rounded,
                          color: Colors.white70, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? 'Unnamed Community' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        [
                          if (college.isNotEmpty) college,
                          if (id.isNotEmpty) id,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (widget.pickOnly) ...[
                  const SizedBox(width: 8),
                  const Text(
                    'View',
                    style: TextStyle(
                      color: Color(0xFFA78BFA),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_forward_ios_rounded,
                      color: Color(0xFFA78BFA), size: 13),
                ] else
                  const Icon(Icons.chevron_right_rounded,
                      color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final registering = _pending != null;
    final choosing = !registering && _choices.isNotEmpty;
    // Opened from a suggestion and still checking the community.
    final preparing = widget.initialCommunity != null && !registering;

    String title = 'Join Community';
    String subtitle =
        'Enter the Community ID or institution name to find the community.';
    if (registering) {
      title = 'Join Requirements';
      final college = (_pending!['collegeName'] ?? '').toString();
      subtitle = _roleOptions.length > 1
          ? 'To join "${_pending!['name']}"${college.isEmpty ? '' : ' ($college)'}, '
              'select your role and provide the details the community asks for.'
          : 'To join "${_pending!['name']}"${college.isEmpty ? '' : ' ($college)'}, '
              'select your department and year and provide the details the community asks for.';
    } else if (choosing) {
      title = 'Select Community';
      subtitle = 'More than one community matches. Pick the one to join.';
    } else if (preparing) {
      subtitle = 'Checking join requirements...';
    }

    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.only(
          left: 22,
          right: 22,
          top: 14,
          bottom: MediaQuery.of(context).viewInsets.bottom + 22,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
            const SizedBox(height: 18),
            if (preparing)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: CircularProgressIndicator(color: Color(0xFFA78BFA)),
                ),
              )
            else if (registering) ...[
              if (_roleOptions.length > 1) ...[
                _dropdown(
                  hint: 'Role',
                  value: _role,
                  items: _roleOptions,
                  onChanged: (v) => setState(() => _role = v),
                ),
                const SizedBox(height: 14),
              ],
              if (_role == null)
                const Text(
                  'Select your role to see what is required.',
                  style: TextStyle(
                    color: Color(0xFFA78BFA),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                )
              else if (_role == 'Student' && _hasStudentRules) ...[
              _dropdown(
                hint: 'Department',
                value: _department,
                items: _departments,
                onChanged: (v) {
                  setState(() => _department = v);
                  _loadClassRequirements();
                },
              ),
              const SizedBox(height: 12),
              _dropdown(
                hint: 'Year',
                value: _year,
                items: kCommunityYears,
                onChanged: (v) {
                  setState(() => _year = v);
                  _loadClassRequirements();
                },
              ),
              const SizedBox(height: 14),
              Text(
                (_department != null && _year != null)
                    ? 'Required to join: $_requiredLabel'
                    : 'Select department and year to see what is required.',
                style: const TextStyle(
                  color: Color(0xFFA78BFA),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _regController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: Colors.white),
                enabled: !_joining,
                onSubmitted: (_) => _joinWithRegisterNumber(),
                decoration: _decoration('$_requiredLabel (numbers only)'),
              ),
              const SizedBox(height: 18),
              _goldButton('Join', _joinWithRegisterNumber),
              ] else if (_role == 'Student')
                _goldButton('Join', _joinPlain)
              else ...[
                Text(
                  'Required to join as $_role: your name',
                  style: const TextStyle(
                    color: Color(0xFFA78BFA),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  style: const TextStyle(color: Colors.white),
                  enabled: !_joining,
                  onSubmitted: (_) => _joinAsRole(),
                  decoration: _decoration('Your name as set by the community'),
                ),
                const SizedBox(height: 18),
                _goldButton('Join as $_role', _joinAsRole),
              ],
              if (widget.initialCommunity == null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _joining ? null : _backToStart,
                  child: const Text(
                    'Back',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ],
            ] else if (choosing) ...[
              ..._choices.map(_choiceTile),
              const SizedBox(height: 4),
              TextButton(
                onPressed: _joining ? null : _backToStart,
                child: const Text(
                  'Back',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            ] else ...[
              TextField(
                controller: _idController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                onSubmitted: (_) => _join(),
                decoration:
                    _decoration('Community ID or institution name'),
              ),
              const SizedBox(height: 18),
              _goldButton('Join', _join),
            ],
          ],
        ),
      ),
    );
  }
}
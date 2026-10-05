import 'package:flutter/material.dart';

import '../services/community_join_service.dart';

// ================================================================
// SET JOIN REQUIREMENTS FOR A ROLE (owner only)
// ----------------------------------------------------------------
// Opened from "Set Join Requirements" at the top of the Principal /
// HOD / Faculty / Controller pages in the 3-line menu.
//
// The owner sets the NAME(S) a person must type when joining with
// this role. In the Join sheet a person picks the Role, types their
// name, and is allowed in only when the name matches one set here
// (case and extra spaces are ignored).
// ================================================================

const Color _tan = Color(0xFFD2B48C);
const Color _brown = Color(0xFF8B4513);

class CommunityRoleRequirementsPage extends StatefulWidget {
  final String communityDocId;
  final String role; // Principal | HOD | Faculty | Controller

  const CommunityRoleRequirementsPage({
    super.key,
    required this.communityDocId,
    required this.role,
  });

  @override
  State<CommunityRoleRequirementsPage> createState() =>
      _CommunityRoleRequirementsPageState();
}

class _CommunityRoleRequirementsPageState
    extends State<CommunityRoleRequirementsPage> {
  late final Future<bool> _ownerFuture;
  late final Stream<List<String>> _names;
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ownerFuture = CommunityJoinService.isOwner(widget.communityDocId);
    _names = CommunityJoinService.watchRoleNames(
      widget.communityDocId,
      widget.role,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _add() async {
    final value = _controller.text.trim();
    if (value.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await CommunityJoinService.addRoleName(
        widget.communityDocId,
        widget.role,
        value,
      );
      _controller.clear();
      _toast('Name added.');
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String name) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await CommunityJoinService.removeRoleName(
        widget.communityDocId,
        widget.role,
        name,
      );
      _toast('Name removed.');
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _decoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xFF14100B),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _tan.withValues(alpha: .3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _tan.withValues(alpha: .3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _tan),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: Text(
          '${widget.role} • Join Requirements',
          style: const TextStyle(color: Colors.white, fontSize: 17),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: FutureBuilder<bool>(
        future: _ownerFuture,
        builder: (context, ownerSnap) {
          if (ownerSnap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: _tan),
            );
          }
          if (ownerSnap.data != true) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Only the community owner can change join requirements.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            );
          }
          return _buildOwnerBody();
        },
      ),
    );
  }

  Widget _buildOwnerBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _brown.withValues(alpha: .2),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _tan.withValues(alpha: .35)),
          ),
          child: Text(
            'Set the name a ${widget.role} must enter to join. When someone '
            'joins and selects the ${widget.role} role, the name they type '
            'must match one of the names below.',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Allowed names',
          style: TextStyle(
            color: _tan,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          widget.role == 'Faculty'
              ? 'Add one name per faculty member.'
              : 'Add the name of the ${widget.role}.',
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                maxLength: 60,
                textCapitalization: TextCapitalization.words,
                style: const TextStyle(color: Colors.white),
                cursorColor: _tan,
                onSubmitted: (_) => _add(),
                decoration: _decoration('${widget.role} name').copyWith(
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filled(
              onPressed: _busy ? null : _add,
              style: IconButton.styleFrom(
                backgroundColor: _brown,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
        const SizedBox(height: 14),
        StreamBuilder<List<String>>(
          stream: _names,
          builder: (context, snap) {
            if (snap.hasError) {
              return const Text(
                'Unable to load names.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              );
            }
            final names = snap.data ?? const <String>[];
            if (names.isEmpty) {
              return Text(
                'No name set yet. Nobody can join as ${widget.role} until '
                'you add one.',
                style: const TextStyle(color: Colors.white30, fontSize: 12),
              );
            }
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final n in names)
                  InputChip(
                    label: Text(
                      n,
                      style: const TextStyle(color: _tan, fontSize: 13),
                    ),
                    backgroundColor: const Color(0xFF14100B),
                    side: BorderSide(color: _tan.withValues(alpha: .5)),
                    deleteIconColor: Colors.white54,
                    onDeleted: _busy ? null : () => _remove(n),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

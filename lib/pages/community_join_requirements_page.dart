import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/community_join_service.dart';

// ================================================================
// SET JOIN REQUIREMENTS (Phase 3 -- owner only)
// ----------------------------------------------------------------
// Opened from the top of a year's students page. The owner chooses
// WHAT a student must provide to join this department + year:
//   * Register Number (digits only)
//   * a Restriction Range, e.g. 711225205001 to 711225205063
//   * Disabled numbers that can never join
//   * Extra join permissions for specific numbers outside the range
// Join is enforced with these rules in Phase 5.
// ================================================================

const Color _tan = Color(0xFFD2B48C);
const Color _brown = Color(0xFF8B4513);

class CommunityJoinRequirementsPage extends StatefulWidget {
  final String communityDocId;
  final String department;
  final String year;

  const CommunityJoinRequirementsPage({
    super.key,
    required this.communityDocId,
    required this.department,
    required this.year,
  });

  @override
  State<CommunityJoinRequirementsPage> createState() =>
      _CommunityJoinRequirementsPageState();
}

class _CommunityJoinRequirementsPageState
    extends State<CommunityJoinRequirementsPage> {
  late final Future<bool> _ownerFuture;
  final TextEditingController _tryController = TextEditingController();
  String? _tryMessage;
  bool _tryOk = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ownerFuture = CommunityJoinService.isOwner(widget.communityDocId);
  }

  @override
  void dispose() {
    _tryController.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _selectField(String field) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await CommunityJoinService.setRequiredField(
        widget.communityDocId,
        widget.department,
        widget.year,
        field,
      );
      _toast('Join requirement saved.');
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Runs a service call, shows the error (if any) and returns success.
  Future<bool> _run(Future<void> Function() action, String okMessage) async {
    try {
      await action();
      _toast(okMessage);
      return true;
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
      return false;
    }
  }

  Future<bool> _saveRange(String start, String end) {
    if (start.trim().isEmpty || end.trim().isEmpty) {
      _toast('Enter both the first and last register number.');
      return Future.value(false);
    }
    return _run(
      () => CommunityJoinService.setRange(
        widget.communityDocId,
        widget.department,
        widget.year,
        start: start,
        end: end,
      ),
      'Range saved.',
    );
  }

  Future<bool> _clearRange() => _run(
        () => CommunityJoinService.setRange(
          widget.communityDocId,
          widget.department,
          widget.year,
          start: '',
          end: '',
        ),
        'Range cleared.',
      );

  Future<bool> _addDisabled(String n) => _run(
        () => CommunityJoinService.addDisabledNumber(
            widget.communityDocId, widget.department, widget.year, n),
        'Disabled number added.',
      );

  Future<bool> _removeDisabled(String n) => _run(
        () => CommunityJoinService.removeDisabledNumber(
            widget.communityDocId, widget.department, widget.year, n),
        'Disabled number removed.',
      );

  Future<bool> _addExtra(String n) => _run(
        () => CommunityJoinService.addExtraAllowedNumber(
            widget.communityDocId, widget.department, widget.year, n),
        'Extra permission added.',
      );

  Future<bool> _removeExtra(String n) => _run(
        () => CommunityJoinService.removeExtraAllowedNumber(
            widget.communityDocId, widget.department, widget.year, n),
        'Extra permission removed.',
      );

  void _runTry(JoinRequirements req) {
    final result = req.check(_tryController.text);
    setState(() {
      _tryOk = result.allowed;
      _tryMessage = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'Set Join Requirements',
          style: TextStyle(color: Colors.white),
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
              child: Text(
                'Only the community owner can set join requirements.',
                style: TextStyle(color: Colors.white54),
                textAlign: TextAlign.center,
              ),
            );
          }

          return StreamBuilder<JoinRequirements>(
            stream: CommunityJoinService.watchRequirements(
              widget.communityDocId,
              widget.department,
              widget.year,
            ),
            builder: (context, snap) {
              final req = snap.data ??
                  JoinRequirements.empty(widget.department, widget.year);

              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    '${widget.department} • ${widget.year}',
                    style: const TextStyle(
                      color: _tan,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Choose what a student must provide to join this class.',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const SizedBox(height: 18),
                  _FieldOptionCard(
                    icon: Icons.badge_rounded,
                    title: 'Register Number',
                    subtitle:
                        'Numbers only. Students join only with a valid register number.',
                    selected: req.requiredField == 'registerNumber',
                    enabled: !_saving,
                    onTap: () => _selectField('registerNumber'),
                  ),
                  const SizedBox(height: 24),

                  _RangeSection(
                    start: req.rangeStart,
                    end: req.rangeEnd,
                    onSave: _saveRange,
                    onClear: _clearRange,
                  ),
                  const SizedBox(height: 24),
                  _NumberListSection(
                    title: 'Disabled Register Numbers',
                    subtitle:
                        'These register numbers can never join, even if they are inside the range.',
                    hint: 'e.g. 711225205061',
                    emptyText: 'No disabled numbers',
                    numbers: req.disabledNumbers,
                    chipColor: Colors.redAccent.shade100,
                    onAdd: _addDisabled,
                    onRemove: _removeDisabled,
                  ),
                  const SizedBox(height: 24),
                  _NumberListSection(
                    title: 'Extra Join Permissions',
                    subtitle:
                        'These register numbers can join even if they are outside the range.',
                    hint: 'e.g. 7112252050301',
                    emptyText: 'No extra permissions',
                    numbers: req.extraAllowedNumbers,
                    chipColor: Colors.greenAccent,
                    onAdd: _addExtra,
                    onRemove: _removeExtra,
                  ),
                  const SizedBox(height: 24),

                  const Text(
                    'Try a register number',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Only digits can be typed. Checks against the rules saved above.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _tryController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(color: Colors.white),
                    cursorColor: _tan,
                    onChanged: (_) => setState(() => _tryMessage = null),
                    decoration: InputDecoration(
                      hintText: 'e.g. 711225205001',
                      hintStyle: const TextStyle(color: Colors.white30),
                      filled: true,
                      fillColor: const Color(0xFF14100B),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.check_rounded, color: _tan),
                        onPressed: () => _runTry(req),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide:
                            BorderSide(color: _tan.withValues(alpha: .35)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: _tan),
                      ),
                    ),
                    onSubmitted: (_) => _runTry(req),
                  ),
                  if (_tryMessage != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _tryMessage!,
                      style: TextStyle(
                        color: _tryOk
                            ? Colors.greenAccent
                            : Colors.redAccent.shade100,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _FieldOptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _FieldOptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? _brown.withValues(alpha: .25)
              : const Color(0xFF14100B),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? _tan : _tan.withValues(alpha: .25),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: _tan, size: 26),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              color: selected ? _tan : Colors.white38,
            ),
          ],
        ),
      ),
    );
  }
}

InputDecoration _fieldDecoration(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white30),
      filled: true,
      fillColor: const Color(0xFF14100B),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: _tan.withValues(alpha: .35)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _tan),
      ),
    );

class _SectionTitle extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionTitle({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
        const SizedBox(height: 10),
      ],
    );
  }
}

// ---------------- Range ----------------
class _RangeSection extends StatefulWidget {
  final String start;
  final String end;
  final Future<bool> Function(String start, String end) onSave;
  final Future<bool> Function() onClear;

  const _RangeSection({
    required this.start,
    required this.end,
    required this.onSave,
    required this.onClear,
  });

  @override
  State<_RangeSection> createState() => _RangeSectionState();
}

class _RangeSectionState extends State<_RangeSection> {
  late final TextEditingController _start =
      TextEditingController(text: widget.start);
  late final TextEditingController _end =
      TextEditingController(text: widget.end);
  bool _busy = false;

  @override
  void didUpdateWidget(covariant _RangeSection old) {
    super.didUpdateWidget(old);
    // Keep the boxes in sync when the saved range changes
    // (e.g. after Clear or an edit from another device).
    if (old.start != widget.start && _start.text != widget.start) {
      _start.text = widget.start;
    }
    if (old.end != widget.end && _end.text != widget.end) {
      _end.text = widget.end;
    }
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.onSave(_start.text, _end.text);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await widget.onClear();
    if (ok) {
      _start.clear();
      _end.clear();
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasSaved = widget.start.isNotEmpty && widget.end.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          title: 'Restriction Range',
          subtitle:
              'Anyone whose register number is inside this range can join.',
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _start,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: Colors.white),
                cursorColor: _tan,
                decoration: _fieldDecoration('From  711225205001'),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('to', style: TextStyle(color: Colors.white54)),
            ),
            Expanded(
              child: TextField(
                controller: _end,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: Colors.white),
                cursorColor: _tan,
                decoration: _fieldDecoration('To  711225205063'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: _brown,
                  foregroundColor: Colors.white,
                ),
                child: Text(_busy ? 'Saving...' : 'Save Range'),
              ),
            ),
            if (hasSaved) ...[
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: _busy ? null : _clear,
                style: OutlinedButton.styleFrom(
                  foregroundColor: _tan,
                  side: BorderSide(color: _tan.withValues(alpha: .5)),
                ),
                child: const Text('Clear'),
              ),
            ],
          ],
        ),
        if (hasSaved) ...[
          const SizedBox(height: 8),
          Text(
            'Active range: ${widget.start} - ${widget.end}',
            style: const TextStyle(color: _tan, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

// ---------------- Add / remove list of numbers ----------------
class _NumberListSection extends StatefulWidget {
  final String title;
  final String subtitle;
  final String hint;
  final String emptyText;
  final List<String> numbers;
  final Color chipColor;
  final Future<bool> Function(String number) onAdd;
  final Future<bool> Function(String number) onRemove;

  const _NumberListSection({
    required this.title,
    required this.subtitle,
    required this.hint,
    required this.emptyText,
    required this.numbers,
    required this.chipColor,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  State<_NumberListSection> createState() => _NumberListSectionState();
}

class _NumberListSectionState extends State<_NumberListSection> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final value = _controller.text.trim();
    if (value.isEmpty || _busy) return;
    setState(() => _busy = true);
    final ok = await widget.onAdd(value);
    if (ok) _controller.clear();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _remove(String number) async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.onRemove(number);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(title: widget.title, subtitle: widget.subtitle),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: Colors.white),
                cursorColor: _tan,
                onSubmitted: (_) => _add(),
                decoration: _fieldDecoration(widget.hint),
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
        const SizedBox(height: 10),
        if (widget.numbers.isEmpty)
          Text(
            widget.emptyText,
            style: const TextStyle(color: Colors.white30, fontSize: 12),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final n in widget.numbers)
                InputChip(
                  label: Text(
                    n,
                    style: TextStyle(color: widget.chipColor, fontSize: 12),
                  ),
                  backgroundColor: const Color(0xFF14100B),
                  side: BorderSide(
                    color: widget.chipColor.withValues(alpha: .5),
                  ),
                  deleteIconColor: Colors.white54,
                  onDeleted: _busy ? null : () => _remove(n),
                ),
            ],
          ),
      ],
    );
  }
}
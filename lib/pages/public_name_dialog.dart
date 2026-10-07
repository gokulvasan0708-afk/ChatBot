import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/user_profile_service.dart';

// ================================================================
// PUBLIC NAME  ==  ACCOUNT ID  (dialog)
// ----------------------------------------------------------------
// The public name is compulsory and doubles as the Account ID.
//
//   * [mandatory] = true  -> cannot be cancelled / dismissed / backed
//     out of (used right after login until a name is saved).
//   * [mandatory] = false -> normal "Set / Change Name" with CANCEL.
//
// Rules are enforced by UserProfileService.validatePublicName and
// uniqueness by UserProfileService.setPublicNameAsAccountId.
//
// Returns the saved name, or null if the user cancelled.
// ================================================================

Future<String?> showPublicNameDialog(
  BuildContext context, {
  bool mandatory = false,
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: !mandatory,
    builder: (_) => _PublicNameDialog(
      mandatory: mandatory,
      initial: initial,
    ),
  );
}

class _PublicNameDialog extends StatefulWidget {
  final bool mandatory;
  final String initial;

  const _PublicNameDialog({
    required this.mandatory,
    required this.initial,
  });

  @override
  State<_PublicNameDialog> createState() => _PublicNameDialogState();
}

class _PublicNameDialogState extends State<_PublicNameDialog> {
  static const Color _bg = Color(0xFF18181F);
  static const Color _tan = Color(0xFFA78BFA);

  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  bool _saving = false;
  String? _serverError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _value => _controller.text.trim();

  bool get _hasLetter => RegExp(r'[A-Za-z]').hasMatch(_value);
  bool get _hasDigit => RegExp(r'[0-9]').hasMatch(_value);
  bool get _hasSpecial => RegExp(r'[^A-Za-z0-9\s]').hasMatch(_value);

  bool get _valid => UserProfileService.validatePublicName(_value) == null;

  Future<void> _save() async {
    if (_saving) return;

    final error = UserProfileService.validatePublicName(_value);
    if (error != null) {
      setState(() => _serverError = error);
      return;
    }

    setState(() {
      _saving = true;
      _serverError = null;
    });

    try {
      await UserProfileService.setPublicNameAsAccountId(_value);
      if (!mounted) return;
      Navigator.of(context).pop(_value);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _serverError = e is String
            ? e
            : 'Could not save the name. Check your connection and try again.';
      });
    }
  }

  Widget _rule(String label, bool ok) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
            size: 16,
            color: ok ? Color(0xFF10B981) : Colors.white38,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: ok ? Colors.white : Colors.white54,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final kinds =
        (_hasLetter ? 1 : 0) + (_hasDigit ? 1 : 0) + (_hasSpecial ? 1 : 0);

    return PopScope(
      canPop: !widget.mandatory,
      child: AlertDialog(
        backgroundColor: _bg,
        title: Text(
          widget.mandatory ? 'Choose your public name' : 'Set / Change Name',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your public name is your Account ID. Other people '
                'find you with it, so it must be unique.',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _controller,
                autofocus: true,
                enabled: !_saving,
                style: const TextStyle(color: Colors.white),
                inputFormatters: [
                  FilteringTextInputFormatter.deny(RegExp(r'\s')),
                  LengthLimitingTextInputFormatter(
                    UserProfileService.maxPublicNameLength,
                  ),
                ],
                onChanged: (_) => setState(() => _serverError = null),
                onSubmitted: (_) => _save(),
                decoration: InputDecoration(
                  hintText: 'e.g. rahul_07',
                  hintStyle: const TextStyle(color: Colors.white54),
                  errorText: _serverError,
                  enabledBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: _tan),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: _tan, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _rule(
                '${UserProfileService.minPublicNameLength}-'
                '${UserProfileService.maxPublicNameLength} characters, '
                'no spaces',
                _value.length >= UserProfileService.minPublicNameLength &&
                    !RegExp(r'\s').hasMatch(_controller.text),
              ),
              _rule('At least 2 of the 3 types below', kinds >= 2),
              Padding(
                padding: const EdgeInsets.only(left: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _rule('Letters (a-z, A-Z)', _hasLetter),
                    _rule('Numbers (0-9)', _hasDigit),
                    _rule('Special characters (@ # \$ % _ . -)', _hasSpecial),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (!widget.mandatory)
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('CANCEL'),
            ),
          TextButton(
            onPressed: (_saving || !_valid) ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    'SAVE',
                    style: TextStyle(
                      color: _tan,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

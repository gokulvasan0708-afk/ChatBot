import 'package:flutter/material.dart';

import '../../widgets/top_alert.dart';
import 'translator_service.dart';

const _bg = Color(0xFF18181F);
const _chipBg = Color(0xFF20202A);
const _tan = Color(0xFFA78BFA);
const _brown = Color(0xFF7C3AED);

Future<void> _show(BuildContext context, Widget sheet) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => sheet,
    );

Future<void> showTranslatorSettings(BuildContext context) =>
    _show(context, const _SettingsSheet());

/// [getTexts] returns the last (up to 5) received texts, oldest first.
Future<void> showTranslatorResults(
        BuildContext context, Future<List<String>> Function() getTexts) =>
    _show(context, _ResultsSheet(getTexts: getTexts));

Widget _handle() => Center(
      child: Container(
        width: 38,
        height: 4,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
            color: Colors.white24, borderRadius: BorderRadius.circular(2)),
      ),
    );

// ---------------------------------------------------------------- results
class _ResultsSheet extends StatefulWidget {
  final Future<List<String>> Function() getTexts;
  const _ResultsSheet({required this.getTexts});
  @override
  State<_ResultsSheet> createState() => _ResultsSheetState();
}

class _ResultsSheetState extends State<_ResultsSheet> {
  bool _loading = true;
  String? _error;
  List<String> _texts = const [];
  List<TranslationResult> _results = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await TranslatorService.loadPrefs();
      final texts = await widget.getTexts();
      final res = texts.isEmpty
          ? const <TranslationResult>[]
          : await TranslatorService.translate(texts);
      if (!mounted) return;
      setState(() {
        _texts = texts;
        _results = res;
        _loading = false;
      });
    } on TranslatorException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'Something went wrong. Please try again.'; _loading = false; });
    }
  }

  Future<void> _openSettings() async {
    await showTranslatorSettings(context);
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: mq.size.height * 0.6),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _handle(),
                Row(children: [
                  Expanded(
                    child: ValueListenableBuilder<TranslatorPrefs>(
                      valueListenable: TranslatorService.prefs,
                      builder: (_, p, __) => Text(
                        'Translated to ${TranslatorService.nameOf(p.target)}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _loading ? null : _load,
                    icon: const Icon(Icons.refresh_rounded, color: _tan),
                  ),
                  IconButton(
                    onPressed: _openSettings,
                    icon: const Icon(Icons.settings_rounded, color: _tan),
                  ),
                ]),
                const SizedBox(height: 4),
                Flexible(child: _body()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
            child: CircularProgressIndicator(color: _tan, strokeWidth: 2.5)),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(children: [
          Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent)),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );
    }
    if (_texts.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
            child: Text('No received messages to translate yet.',
                style: TextStyle(color: Colors.white54))),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _texts.length,
      separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 20),
      itemBuilder: (_, i) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_texts[i],
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 4),
          SelectableText(_results[i].text,
              style: const TextStyle(color: Colors.white, fontSize: 15)),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- settings
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  @override
  void initState() {
    super.initState();
    TranslatorService.loadPrefs();
  }

  Future<void> _save(TranslatorPrefs p) async {
    try {
      await TranslatorService.savePrefs(p);
    } on TranslatorException catch (e) {
      if (mounted) showTopAlert(context, e.message, isError: true);
    }
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        selectedColor: _brown,
        backgroundColor: _chipBg,
        side: BorderSide(color: _tan.withValues(alpha: 0.35)),
        labelStyle: TextStyle(
            color: selected ? Colors.white : Colors.white70, fontSize: 13),
      );

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: Text(t,
            style: const TextStyle(
                color: _tan, fontSize: 13, fontWeight: FontWeight.w600)),
      );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: ValueListenableBuilder<TranslatorPrefs>(
          valueListenable: TranslatorService.prefs,
          builder: (_, p, __) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _handle(),
              const Text('Translator Settings',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600)),
              _title('Source language'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _chip('Auto-detect', p.source == 'auto',
                    () => _save(TranslatorPrefs(target: p.target, source: 'auto'))),
                for (final l in TranslatorService.languages)
                  _chip(l.name, p.source == l.code,
                      () => _save(TranslatorPrefs(target: p.target, source: l.code))),
              ]),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Auto-detect works for most messages. Pick a language to override it.',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
              _title('Preferred language (translate into)'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final l in TranslatorService.languages)
                  _chip('${l.name} · ${l.native}', p.target == l.code,
                      () => _save(TranslatorPrefs(target: l.code, source: p.source))),
              ]),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Saved automatically and used in all chats.',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

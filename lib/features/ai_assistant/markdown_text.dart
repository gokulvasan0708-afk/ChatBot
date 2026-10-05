import 'package:flutter/material.dart';

// Tiny markdown renderer for chat bubbles (no package needed).
// Supports **bold**, *italic*, `code`, ``` blocks, # headings, - / * bullets.
final _inline = RegExp(r'\*\*(.+?)\*\*|`([^`\n]+)`|\*([^*\s][^*\n]*?)\*');
final _bullet = RegExp(r'^(\s*)[-*]\s+');
final _head = RegExp(r'^#{1,6}\s+');

TextSpan markdownSpan(String text, TextStyle base) {
  final out = <InlineSpan>[];
  final mono = base.copyWith(
    fontFamily: 'monospace',
    fontSize: (base.fontSize ?? 14) - 1,
    backgroundColor: (base.color ?? Colors.grey).withAlpha(36),
  );
  var inCode = false;
  var first = true;

  for (final line in text.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      inCode = !inCode;
      continue;
    }
    if (!first) out.add(const TextSpan(text: '\n'));
    first = false;

    if (inCode) {
      out.add(TextSpan(text: line, style: mono));
      continue;
    }

    var s = line;
    var st = base;
    if (_head.hasMatch(s)) {
      s = s.replaceFirst(_head, '');
      st = base.copyWith(fontWeight: FontWeight.w700);
    } else if (_bullet.hasMatch(s)) {
      s = s.replaceFirstMapped(_bullet, (m) => '${m[1]}• ');
    }

    var pos = 0;
    for (final m in _inline.allMatches(s)) {
      if (m.start > pos) {
        out.add(TextSpan(text: s.substring(pos, m.start), style: st));
      }
      if (m[1] != null) {
        out.add(TextSpan(
            text: m[1], style: st.copyWith(fontWeight: FontWeight.w700)));
      } else if (m[2] != null) {
        out.add(TextSpan(text: m[2], style: mono));
      } else {
        out.add(TextSpan(
            text: m[3], style: st.copyWith(fontStyle: FontStyle.italic)));
      }
      pos = m.end;
    }
    if (pos < s.length) out.add(TextSpan(text: s.substring(pos), style: st));
  }
  return TextSpan(style: base, children: out);
}

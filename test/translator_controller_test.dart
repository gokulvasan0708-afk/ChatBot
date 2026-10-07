import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Relative import so no package name is needed.
import '../lib/features/translator/translator_controller.dart';
import '../lib/features/translator/translator_service.dart';

void main() {
  late TextEditingController input;
  late TranslatorController tc;

  setUp(() {
    input = TextEditingController();
    tc = TranslatorController(input);
    TranslatorService.translateOverride =
        (t) async => [for (final x in t) TranslationResult('T($x)', 'ta')];
  });
  tearDown(() {
    tc.dispose();
    input.dispose();
    TranslatorService.translateOverride = null;
  });

  test('swipe translates field, swipe again restores exact original', () async {
    input.text = 'vanakkam  ';
    expect(await tc.onSwipe(), TypingAction.translated);
    expect(input.text, 'T(vanakkam)');
    expect(tc.canRestore, true);
    expect(await tc.onSwipe(), TypingAction.restored);
    expect(input.text, 'vanakkam  ');
    expect(tc.canRestore, false);
  });

  test('empty field arms; beforeSend translates and disarms', () async {
    expect(await tc.onSwipe(), TypingAction.armed);
    expect(tc.armed, true);
    final r = await tc.beforeSend('hello');
    expect(r.text, 'T(hello)');
    expect(r.original, 'hello');
    expect(tc.armed, false);
  });

  test('swipe on armed + empty disarms', () async {
    await tc.onSwipe();
    expect(await tc.onSwipe(), TypingAction.disarmed);
  });

  test('beforeSend after in-field translation returns original', () async {
    input.text = 'hi';
    await tc.onSwipe();
    final r = await tc.beforeSend(input.text);
    expect(r.text, 'T(hi)');
    expect(r.original, 'hi');
    expect(tc.canRestore, false);
  });

  test('failure keeps text untouched and rethrows', () async {
    TranslatorService.translateOverride =
        (_) async => throw TranslatorException('offline');
    input.text = 'keep me';
    await expectLater(tc.onSwipe(), throwsA(isA<TranslatorException>()));
    expect(input.text, 'keep me');
    expect(tc.canRestore, false);
    expect(tc.busy, false);
  });

  test('plain send when not armed', () async {
    final r = await tc.beforeSend('x');
    expect(r.text, 'x');
    expect(r.original, null);
  });
}

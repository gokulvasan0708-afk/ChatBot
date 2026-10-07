import 'package:flutter/material.dart';

import '../../widgets/top_alert.dart';
import 'translator_controller.dart';
import 'translator_service.dart';
import 'translator_sheets.dart';

export 'translator_controller.dart';
export 'translator_service.dart' show TranslatorService, TranslatorException;

/// Global reusable translator. Wrap ANY chat input bar with it:
///
///   TranslatorInputHost(
///     controller: _translator,            // TranslatorController(textController)
///     getReceivedTexts: _lastReceived5,   // last <=5 texts from others, oldest first
///     child: <existing input bar>,
///   )
///
/// The icon floats (in the Overlay, anchored to the child's top-right), so the
/// child's layout, keyboard handling and hit-testing are untouched.
class TranslatorInputHost extends StatefulWidget {
  final TranslatorController controller;
  final Future<List<String>> Function() getReceivedTexts;
  final Widget child;

  const TranslatorInputHost({
    super.key,
    required this.controller,
    required this.getReceivedTexts,
    required this.child,
  });

  @override
  State<TranslatorInputHost> createState() => _TranslatorInputHostState();
}

class _TranslatorInputHostState extends State<TranslatorInputHost> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    TranslatorService.loadPrefs();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _portal.show();
    });
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (_) => Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(-10, -6),
          child: _TranslatorButton(
            controller: widget.controller,
            getReceivedTexts: widget.getReceivedTexts,
          ),
        ),
      ),
      child: CompositedTransformTarget(link: _link, child: widget.child),
    );
  }
}

class _TranslatorButton extends StatelessWidget {
  final TranslatorController controller;
  final Future<List<String>> Function() getReceivedTexts;

  const _TranslatorButton(
      {required this.controller, required this.getReceivedTexts});

  Future<void> _swipe(BuildContext context, DragEndDetails d) async {
    final v = d.primaryVelocity ?? 0;
    if (v.abs() < 150) return;
    // right->left always; left->right only to undo (disarm / restore)
    if (v > 0 && !(controller.armed || controller.canRestore)) return;
    final lang = TranslatorService.nameOf(TranslatorService.prefs.value.target);
    String? msg;
    var error = false;
    try {
      final a = await controller.onSwipe();
      msg = switch (a) {
        TypingAction.armed => 'Typing translation on. Your message is translated to $lang when you send.',
        TypingAction.disarmed => 'Typing translation off.',
        TypingAction.translated => 'Translated to $lang. Swipe again to restore your original text.',
        TypingAction.restored => 'Original text restored.',
        TypingAction.unchanged => 'Already in $lang.',
        TypingAction.ignored => null,
      };
    } on TranslatorException catch (e) {
      msg = e.message;
      error = true;
    } catch (_) {
      msg = 'Translation failed. Please try again.';
      error = true;
    }
    if (msg != null && context.mounted) showTopAlert(context, msg, isError: error);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final on = controller.armed || controller.canRestore;
          return SizedBox(
            width: 96,
            height: 40,
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              alignment:
                  controller.armed ? Alignment.centerLeft : Alignment.centerRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => showTranslatorResults(context, getReceivedTexts),
                onLongPress: () => showTranslatorSettings(context),
                onHorizontalDragEnd: (d) => _swipe(context, d),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? const Color(0xFF7C3AED) : const Color(0xFF20202A),
                    border: Border.all(
                        color: const Color(0xFFA78BFA).withValues(alpha: 0.6)),
                  ),
                  child: controller.busy
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Color(0xFFA78BFA)),
                        )
                      : Stack(alignment: Alignment.center, children: [
                          Icon(Icons.translate_rounded,
                              size: 20,
                              color: on ? Colors.white : const Color(0xFFA78BFA)),
                          if (controller.canRestore)
                            Positioned(
                              right: 6,
                              top: 6,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                    color: Color(0xFF10B981),
                                    shape: BoxShape.circle),
                              ),
                            ),
                        ]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

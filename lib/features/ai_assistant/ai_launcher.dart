import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../pages/app_theme.dart';
import 'ai_chat_controller.dart';
import 'ai_chat_panel.dart';

/// Global floating chat button + inline popup panel.
/// Mounted once in MaterialApp.builder, so it sits above every page.
class AiLauncher extends StatefulWidget {
  const AiLauncher({super.key});

  /// Set true once the splash is finished.
  static final ValueNotifier<bool> ready = ValueNotifier(false);

  /// Any page can set true to hide the assistant (e.g. fullscreen player).
  static final ValueNotifier<bool> suppressed = ValueNotifier(false);

  /// True only while the Home screen (Chats / Hubs / Me tabs) is the page
  /// the user is looking at. The AI button is shown ONLY then, so it never
  /// appears on pages pushed above those tabs (Community Home, Members,
  /// settings, ...). Driven by HomeShell via [AiHomeVisibility].
  static final ValueNotifier<bool> onHome = ValueNotifier(false);

  /// Observer that tells HomeShell when another page is pushed over it or
  /// popped back to it. Pass to MaterialApp.navigatorObservers.
  static final RouteObserver<PageRoute<dynamic>> routeObserver =
      RouteObserver<PageRoute<dynamic>>();

  static Object? _homeOwner;

  static void showOnHome(Object owner) {
    _homeOwner = owner;
    onHome.value = true;
  }

  static void hideOnHome(Object owner) {
    // Only the shell that switched it on may switch it off (a new shell
    // can already have taken over, e.g. after login).
    if (_homeOwner == owner) {
      _homeOwner = null;
      onHome.value = false;
    }
  }

  static int _holds = 0;

  /// Ref-counted hide: call [hold] when a screen needs the button hidden and
  /// [release] when it goes away. Prefer the [AiLauncherHide] mixin.
  static void hold() {
    _holds++;
    suppressed.value = true;
  }

  static void release() {
    if (_holds > 0) _holds--;
    suppressed.value = _holds > 0;
  }

  @override
  State<AiLauncher> createState() => _AiLauncherState();
}

class _AiLauncherState extends State<AiLauncher> {
  bool _open = false;
  bool _signedIn = FirebaseAuth.instance.currentUser != null;
  String? _uid = FirebaseAuth.instance.currentUser?.uid;
  StreamSubscription<User?>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = FirebaseAuth.instance.authStateChanges().listen((u) {
      if (!mounted) return;
      // sign-out OR account switch -> never leak the old account's chat
      if (u?.uid != _uid) AiChatController.instance.clear(force: true);
      _uid = u?.uid;
      setState(() {
        _signedIn = u != null;
        if (u == null) _open = false;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [AiLauncher.ready, AiLauncher.suppressed, AiLauncher.onHome]),
      builder: (context, _) {
        final mq = MediaQuery.of(context);
        // Hide only on short screens (phone landscape). Desktop/web stays visible.
        final tooShort = mq.size.height < 420;
        final visible = _signedIn &&
            AiLauncher.ready.value &&
            AiLauncher.onHome.value &&
            !AiLauncher.suppressed.value &&
            !tooShort;
        if (!visible) return const SizedBox.shrink();

        final wide = mq.size.width >= 600;
        final size = AiChatPanel.sizeFor(mq);
        final double bottom =
            12.0 + math.max(mq.viewInsets.bottom, mq.padding.bottom);

        return Stack(
          children: [
            if (_open)
              Positioned(
                right: wide ? 24 : 12,
                bottom: bottom,
                width: size.width,
                height: size.height,
                child: AiChatPanel(onClose: () => setState(() => _open = false)),
              )
            else
              Positioned(
                right: wide ? 24 : 16,
                // sits above the bottom nav bar
                bottom: 90 + mq.padding.bottom,
                child: _fab(context),
              ),
          ],
        );
      },
    );
  }

  Widget _fab(BuildContext context) {
    final c = AppColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final a = dark ? AppColors.tan : AppColors.saddleBrown;
    return Tooltip(
        message: 'Nexus AI',
        child: Material(
          color: c.card,
          elevation: 8,
          shape: CircleBorder(side: BorderSide(color: a.withAlpha(128))),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => setState(() => _open = true),
            child: SizedBox(
              width: 52,
              height: 52,
              child: Icon(Icons.auto_awesome, color: a, size: 24),
            ),
          ),
        ),
      );
  }
}

/// Add to a screen's State (`with AiLauncherHide`) to hide the floating AI
/// button while that screen is alive (chat input bars, call screens, splash).
mixin AiLauncherHide<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    // post-frame: notifier must not change during build
    WidgetsBinding.instance.addPostFrameCallback((_) => AiLauncher.hold());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.addPostFrameCallback((_) => AiLauncher.release());
    super.dispose();
  }
}

/// Add to HomeShell's State (`with AiHomeVisibility`): the AI button is
/// visible while this screen is the top page, hidden when any other page
/// is pushed over it, visible again when it comes back.
/// Needs `navigatorObservers: [AiLauncher.routeObserver]` on MaterialApp.
mixin AiHomeVisibility<T extends StatefulWidget> on State<T>
    implements RouteAware {
  bool _aiSubscribed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!_aiSubscribed && route is PageRoute) {
      AiLauncher.routeObserver.subscribe(this, route);
      _aiSubscribed = true;
    }
  }

  void _aiShow() => WidgetsBinding.instance
      .addPostFrameCallback((_) => AiLauncher.showOnHome(this));

  void _aiHide() => WidgetsBinding.instance
      .addPostFrameCallback((_) => AiLauncher.hideOnHome(this));

  @override
  void didPush() => _aiShow();

  @override
  void didPopNext() => _aiShow();

  @override
  void didPushNext() => _aiHide();

  @override
  void didPop() => _aiHide();

  @override
  void dispose() {
    AiLauncher.routeObserver.unsubscribe(this);
    _aiHide();
    super.dispose();
  }
}

/// Use in MaterialApp.builder: keeps the app on its own Overlay layer and puts
/// the AI launcher above every route.
class AiOverlayHost extends StatefulWidget {
  final Widget? child;
  const AiOverlayHost({super.key, this.child});

  @override
  State<AiOverlayHost> createState() => _AiOverlayHostState();
}

class _AiOverlayHostState extends State<AiOverlayHost> {
  late final OverlayEntry _app =
      OverlayEntry(builder: (_) => widget.child ?? const SizedBox.shrink());
  late final OverlayEntry _ai = OverlayEntry(builder: (_) => const AiLauncher());

  @override
  void didUpdateWidget(AiOverlayHost old) {
    super.didUpdateWidget(old);
    if (old.child != widget.child) _app.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_app, _ai]);
}
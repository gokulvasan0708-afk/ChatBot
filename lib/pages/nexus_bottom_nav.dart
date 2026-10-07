import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Shared bottom navigation used by both Chats and Me so the two pages
/// always have exactly the same size, background, border and animation.
class NexusBottomNav extends StatefulWidget {
  final int selectedIndex;
  final VoidCallback onChats;
  final VoidCallback onCommunity;
  final VoidCallback onMe;

  const NexusBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onChats,
    required this.onCommunity,
    required this.onMe,
  });

  @override
  State<NexusBottomNav> createState() => _NexusBottomNavState();
}

class _NexusBottomNavState extends State<NexusBottomNav>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _tap(int index) async {
    if (index == widget.selectedIndex) return;
    await _controller.forward(from: 0);
    if (!mounted) return;

    // The trace is a one-shot "comet" meant to be visible only while a
    // tab switch is actually happening. Left at value == 1 it would
    // stay statically visible the next time this bar is idle (progress
    // 1 paints almost the same segment as progress 0, so without this
    // it never truly disappears -- it just gets stuck "on"). Resetting
    // it back to 0 now that the transition has finished restores the
    // idle/hidden state without changing the travel animation itself.
    _controller.reset();

    if (index == 0) {
      widget.onChats();
    } else if (index == 1) {
      widget.onCommunity();
    } else {
      widget.onMe();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(left: 25, right: 25, bottom: 15),
        child: SizedBox(
          height: 70,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: c.navBg.withValues(alpha: isDark ? .96 : 1),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: c.cardBorder),
                    boxShadow: [
                      BoxShadow(
                        color: isDark
                            ? Colors.black.withValues(alpha: .45)
                            : AppColors.primary.withValues(alpha: .10),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (_, _) => _controller.value == 0
                        ? const SizedBox.shrink()
                        : CustomPaint(
                            painter: _NexusTracePainter(
                              progress: _controller.value,
                            ),
                          ),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _item(
                    index: 0,
                    icon: Icons.chat_bubble_rounded,
                    label: 'Chats',
                  ),
                  _item(
                    index: 1,
                    icon: Icons.hub_rounded,
                    label: 'Hubs',
                  ),
                  _item(
                    index: 2,
                    icon: Icons.person_rounded,
                    label: 'Me',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item({required int index, required IconData icon, required String label}) {
    final c = AppColors.of(context);
    final selected = widget.selectedIndex == index;
    final activeColor = AppColors.primaryLight;
    final idleColor = c.textMuted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _tap(index),
      child: Container(
        width: 65,
        height: 55,
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: .20)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 26, color: selected ? activeColor : idleColor),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? activeColor : idleColor,
                fontSize: label.length > 6 ? 9 : 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NexusTracePainter extends CustomPainter {
  final double progress;
  const _NexusTracePainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(22),
      ));
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final metric = metrics.first;
    final total = metric.length;
    const travel = .30;
    final start = (progress * total) % total;
    final end = start + total * travel;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = AppColors.primaryLight;

    if (end <= total) {
      canvas.drawPath(metric.extractPath(start, end), paint);
    } else {
      canvas.drawPath(metric.extractPath(start, total), paint);
      canvas.drawPath(metric.extractPath(0, end - total), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _NexusTracePainter oldDelegate) =>
      oldDelegate.progress != progress;
}
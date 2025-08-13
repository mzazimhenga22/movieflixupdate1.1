import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const List<String> emojis = [
  "❤️", "😂", "👍", "😮", "😢",
  "🔥", "😡", "🙏", "🎉", "😍",
];

/// Show a lightweight, self-closing overlay for message actions.
/// - Doesn't require RouteObserver registration.
/// - Auto-dismisses when the message's RenderBox is detached or when the message's route is not current.
Future<void> showMessageActionsOverlay({
  required BuildContext context,
  required GlobalKey messageKey,
  required Widget messageWidget,
  required ValueChanged<String> onReactEmoji,
  required VoidCallback onReply,
  required VoidCallback onPin,
  required VoidCallback onDelete,
  required VoidCallback onBlock,
  required VoidCallback onForward,
  required VoidCallback onEdit,
}) async {
  // Wait a frame to ensure layout is ready
  SchedulerBinding.instance.addPostFrameCallback((_) {
    final OverlayState? overlay = Overlay.of(context);
    if (overlay == null) return;

    // Safety: get RenderBox for message
    final RenderBox? renderBox =
        messageKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached) return;

    final Offset offset = renderBox.localToGlobal(Offset.zero);
    final Size size = renderBox.size;
    final MediaQueryData mq = MediaQuery.of(context);
    final double screenHeight = mq.size.height;
    final double paddingTop = mq.padding.top;

    const double overlayPadding = 8.0;
    const double estimatedOverlayHeight = 240.0;
    final double spaceAbove = offset.dy;
    final double spaceBelow = screenHeight - (offset.dy + size.height);

    final bool showAbove = spaceAbove > spaceBelow;
    double topPosition = showAbove
        ? offset.dy - estimatedOverlayHeight - overlayPadding
        : offset.dy + size.height + overlayPadding;

    // Clamp so overlay stays within screen bounds
    topPosition = topPosition.clamp(
      paddingTop + overlayPadding,
      screenHeight - estimatedOverlayHeight - overlayPadding,
    );

    OverlayEntry? entry;
    double opacity = 0.0;
    Timer? monitorTimer;

    // Remove helper (fade out then remove)
    void removeOverlay() {
      if (entry == null) return;
      // animate fade out
      try {
        // the stateful builder will pick up opacity change
        opacity = 0.0;
      } catch (_) {}
      // wait fade duration then remove
      Future.delayed(const Duration(milliseconds: 160), () {
        try {
          monitorTimer?.cancel();
          entry?.remove();
          entry = null;
        } catch (_) {}
      });
    }

    entry = OverlayEntry(
      builder: (ctx) {
        // StatefulBuilder used so we can change opacity locally without setState in outer scope
        return StatefulBuilder(
          builder: (context, setState) {
            // trigger fade-in once at first build
            if (opacity == 0.0) {
              // schedule microtask to animate to 1.0 (avoids synchronous setState during build)
              Future.microtask(() {
                try {
                  opacity = 1.0;
                  setState(() {}); // animate in
                } catch (_) {}
              });
            }

            return AnimatedOpacity(
              opacity: opacity,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              child: Stack(
                children: [
                  // translucent scrim - tapping outside dismisses
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() => opacity = 0.0);
                      Future.delayed(const Duration(milliseconds: 140), () {
                        monitorTimer?.cancel();
                        entry?.remove();
                        entry = null;
                      });
                    },
                    child: Container(color: Colors.black.withOpacity(0.28)),
                  ),

                  // Compact positioned panel (keeps blur area small)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: topPosition,
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: Colors.black.withOpacity(0.16),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: BackdropFilter(
                            // moderate blur (keeps it light)
                            filter: ImageFilter.blur(sigmaX: 3.0, sigmaY: 3.0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                              // Limit width/height to keep render cost small
                              constraints: const BoxConstraints(maxHeight: 240),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // message preview (small)
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.blueAccent.withOpacity(0.9),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: DefaultTextStyle(
                                      style: const TextStyle(color: Colors.white, fontSize: 14),
                                      child: messageWidget,
                                    ),
                                  ),

                                  const SizedBox(height: 8),

                                  // emoji row - compact, single-line
                                  SizedBox(
                                    height: 44,
                                    child: ListView.builder(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: emojis.length,
                                      itemBuilder: (_, i) {
                                        final emoji = emojis[i];
                                        return GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () {
                                            // fade-out then call
                                            setState(() => opacity = 0.0);
                                            Future.delayed(const Duration(milliseconds: 140), () {
                                              monitorTimer?.cancel();
                                              entry?.remove();
                                              entry = null;
                                              onReactEmoji(emoji);
                                            });
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                            child: Text(emoji, style: const TextStyle(fontSize: 22)),
                                          ),
                                        );
                                      },
                                    ),
                                  ),

                                  const Divider(height: 14, thickness: 0.4, color: Colors.white24),

                                  // actions (compact list tiles)
                                  _overlayTileSimple(Icons.reply, "Reply", () {
                                    monitorTimer?.cancel();
                                    entry?.remove();
                                    entry = null;
                                    onReply();
                                  }),
                                  _overlayTileSimple(Icons.push_pin, "Pin", () {
                                    monitorTimer?.cancel();
                                    entry?.remove();
                                    entry = null;
                                    onPin();
                                  }),
                                  _overlayTileSimple(Icons.forward, "Forward", () {
                                    monitorTimer?.cancel();
                                    entry?.remove();
                                    entry = null;
                                    onForward();
                                  }),
                                  _overlayTileSimple(Icons.link, "Copy Link", () {
                                    monitorTimer?.cancel();
                                    entry?.remove();
                                    entry = null;
                                    onEdit();
                                  }),
                                  _overlayTileSimple(Icons.delete_outline, "Delete", () {
                                    monitorTimer?.cancel();
                                    entry?.remove();
                                    entry = null;
                                    onDelete();
                                  }, isDestructive: true),
                                  _overlayTileSimple(Icons.block, "Block", () {
                                    monitorTimer?.cancel();
                                    entry?.remove();
                                    entry = null;
                                    onBlock();
                                  }, isDestructive: true),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    // Insert overlay
    overlay.insert(entry!);

    // Start a lightweight monitor to auto-dismiss overlay when:
    //  - message's RenderBox is no longer attached
    //  - or message's route is no longer current (user navigated away)
    monitorTimer = Timer.periodic(const Duration(milliseconds: 200), (t) {
      try {
        // If overlay already removed, cancel timer
        if (entry == null) {
          t.cancel();
          return;
        }

        final ctx = messageKey.currentContext;
        if (ctx == null) {
          // message widget gone -> remove overlay
          removeOverlay();
          t.cancel();
          return;
        }

        final RenderBox? rb = ctx.findRenderObject() as RenderBox?;
        if (rb == null || !rb.attached) {
          removeOverlay();
          t.cancel();
          return;
        }

        // If the route that contains the message is not current -> remove overlay
        final ModalRoute<dynamic>? messageRoute = ModalRoute.of(ctx);
        if (messageRoute != null && messageRoute.isCurrent == false) {
          removeOverlay();
          t.cancel();
          return;
        }
      } catch (e) {
        // if anything goes wrong, remove and cancel to be safe
        removeOverlay();
        t.cancel();
      }
    });
  });
}

/// Compact tile used inside the overlay (lighter than ListTile)
Widget _overlayTileSimple(IconData icon, String label, VoidCallback action, {bool isDestructive = false}) {
  return InkWell(
    onTap: action,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 18, color: isDestructive ? Colors.redAccent : Colors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: isDestructive ? Colors.redAccent : Colors.white,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

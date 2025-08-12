import 'dart:ui';
import 'package:flutter/material.dart';

const List<String> emojis = [
  "❤️", "😂", "👍", "😮", "😢",
  "🔥", "😡", "🙏", "🎉", "😍",
];

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
  // Delay until after layout
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final overlay = Overlay.of(context);
    final RenderBox? renderBox = messageKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final Offset offset = renderBox.localToGlobal(Offset.zero);
    final Size size = renderBox.size;
    final screenHeight = MediaQuery.of(context).size.height;
    final paddingTop = MediaQuery.of(context).padding.top;

    const double overlayPadding = 8.0;
    const double estimatedOverlayHeight = 260.0; // A better estimate
    final double spaceAbove = offset.dy;
    final double spaceBelow = screenHeight - (offset.dy + size.height);

    final bool showAbove = spaceAbove > spaceBelow;

    double topPosition = showAbove
        ? offset.dy - estimatedOverlayHeight - overlayPadding
        : offset.dy + size.height + overlayPadding;

    // Clamp to ensure the overlay doesn't go off-screen
    topPosition = topPosition.clamp(
      paddingTop + overlayPadding,
      screenHeight - estimatedOverlayHeight - overlayPadding,
    );

    OverlayEntry? entry;

    entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          GestureDetector(
            onTap: () => entry?.remove(),
            behavior: HitTestBehavior.opaque,
            child: Container(color: Colors.black.withOpacity(0.3)),
          ),
          Positioned(
            left: 10,
            right: 10,
            top: topPosition,
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.black.withOpacity(0.2),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.blueAccent.withOpacity(0.9),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: messageWidget,
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 40,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: emojis.map((emoji) {
                                return GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    entry?.remove();
                                    onReactEmoji(emoji);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    child: Text(emoji, style: const TextStyle(fontSize: 20)),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                          const Divider(height: 16, thickness: 0.4, color: Colors.white24),
                          _overlayTile(Icons.reply, "Reply", onReply, entry),
                          _overlayTile(Icons.push_pin, "Pin", onPin, entry),
                          _overlayTile(Icons.forward, "Forward", onForward, entry),
                          _overlayTile(Icons.link, "Copy Link", onEdit, entry, isDestructive: false),
                          _overlayTile(Icons.delete_outline, "Delete", onDelete, entry, isDestructive: true),
                          _overlayTile(Icons.block, "Block", onBlock, entry, isDestructive: true),
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

    overlay.insert(entry);
  });
}

Widget _overlayTile(
  IconData icon,
  String label,
  VoidCallback action,
  OverlayEntry? entry, {
  bool isDestructive = false,
}) {
  return ListTile(
    dense: true,
    leading: Icon(icon, size: 20, color: isDestructive ? Colors.redAccent : Colors.white),
    title: Text(
      label,
      style: TextStyle(
        color: isDestructive ? Colors.redAccent : Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.w400,
      ),
    ),
    onTap: () {
      entry?.remove();
      action();
    },
  );
}

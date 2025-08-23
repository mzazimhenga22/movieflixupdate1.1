// message_actions_overlay.dart
import 'dart:async';
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
  await Future.microtask(() {});

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.36),
    builder: (ctx) {
      return SafeArea(
        top: false,
        child: DraggableScrollableSheet(
          // make it taller by default
          initialChildSize: 0.55,
          minChildSize: 0.45,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.72),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.04)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 6.0, sigmaY: 6.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Handle
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10.0),
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),

                      // Message preview
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14.0),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white.withOpacity(0.04)),
                          ),
                          child: DefaultTextStyle(
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            child: messageWidget,
                          ),
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Emoji row
                      SizedBox(
                        height: 56,
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          scrollDirection: Axis.horizontal,
                          itemBuilder: (c, i) {
                            final emoji = emojis[i];
                            return GestureDetector(
                              onTap: () {
                                Navigator.of(ctx).pop();
                                Future.delayed(
                                    const Duration(milliseconds: 60),
                                    () => onReactEmoji(emoji));
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.03),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Center(
                                    child: Text(emoji, style: const TextStyle(fontSize: 22))),
                              ),
                            );
                          },
                          separatorBuilder: (_, __) => const SizedBox(width: 10),
                          itemCount: emojis.length,
                        ),
                      ),

                      const SizedBox(height: 10),

                      const Divider(color: Colors.white12, thickness: 0.5, height: 6),

                      // All actions (scrollable if screen too small)
                      Expanded(
                        child: SingleChildScrollView(
                          controller: scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            children: [
                              _bottomSheetTile(
                                icon: Icons.reply,
                                label: "Reply",
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  Future.delayed(const Duration(milliseconds: 60), onReply);
                                },
                              ),
                              _bottomSheetTile(
                                icon: Icons.push_pin,
                                label: "Pin",
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  Future.delayed(const Duration(milliseconds: 60), onPin);
                                },
                              ),
                              _bottomSheetTile(
                                icon: Icons.forward,
                                label: "Forward",
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  Future.delayed(const Duration(milliseconds: 60), onForward);
                                },
                              ),
                              _bottomSheetTile(
                                icon: Icons.edit,
                                label: "Edit / Copy Link",
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  Future.delayed(const Duration(milliseconds: 60), onEdit);
                                },
                              ),
                              _bottomSheetTile(
                                icon: Icons.delete_outline,
                                label: "Delete",
                                iconColor: Colors.redAccent,
                                labelColor: Colors.redAccent,
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  Future.delayed(const Duration(milliseconds: 60), onDelete);
                                },
                              ),
                              _bottomSheetTile(
                                icon: Icons.block,
                                label: "Block",
                                iconColor: Colors.redAccent,
                                labelColor: Colors.redAccent,
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  Future.delayed(const Duration(milliseconds: 60), onBlock);
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    },
  );
}

/// Helper for bottom-sheet action row
Widget _bottomSheetTile({
  required IconData icon,
  required String label,
  required VoidCallback onTap,
  Color? iconColor,
  Color? labelColor,
}) {
  final ic = iconColor ?? Colors.white;
  final lc = labelColor ?? Colors.white;
  return InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: ic, size: 20),
          const SizedBox(width: 14),
          Expanded(child: Text(label, style: TextStyle(color: lc, fontSize: 15))),
          const Icon(Icons.chevron_right, color: Colors.white24),
        ],
      ),
    ),
  );
}

Widget _overlayTileSimple(IconData icon, String label, VoidCallback action,
    {bool isDestructive = false}) {
  return _bottomSheetTile(
    icon: icon,
    label: label,
    onTap: action,
    iconColor: isDestructive ? Colors.redAccent : null,
    labelColor: isDestructive ? Colors.redAccent : null,
  );
}

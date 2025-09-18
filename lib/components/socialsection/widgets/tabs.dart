// message_tabs.dart
import 'package:flutter/material.dart';
import '../messages_controller.dart';

/// A sleek Sliver header that shows the message tabs and an unread badge.
/// Uses the provided [MessagesController] as a Listenable to rebuild the badge
/// efficiently (AnimatedBuilder), avoiding async futures inside the UI.
class MessageTabs extends StatelessWidget {
  final TabController tabController;
  final Color accentColor;
  final MessagesController controller;

  const MessageTabs({
    Key? key,
    required this.tabController,
    required this.accentColor,
    required this.controller,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _SliverTabBarDelegate(
        tabController: tabController,
        accentColor: accentColor,
        controller: controller,
      ),
    );
  }
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabController tabController;
  final Color accentColor;
  final MessagesController controller;

  _SliverTabBarDelegate({
    required this.tabController,
    required this.accentColor,
    required this.controller,
  });

  // Make header slightly taller to accommodate the rounded background and padding:
  @override
  double get minExtent => 56.0;
  @override
  double get maxExtent => 56.0;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    // AnimatedBuilder listens to the controller ChangeNotifier and rebuilds
    // only the badge/TabBar when controller notifies (cheap).
    return Container(
      // subtle translucent backdrop to match messages screen
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.02)),
          bottom: BorderSide(color: accentColor.withOpacity(0.06)),
        ),
      ),
      child: Center(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final unread = controller.totalUnread;
            return ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Container(
                // pill background behind the TabBar to make it "floating"
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: TabBar(
                  controller: tabController,
                  indicator: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: accentColor.withOpacity(0.18),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  indicatorPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  indicatorSize: TabBarIndicatorSize.tab,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white70,
                  labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  unselectedLabelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  tabs: [
                    const Tab(text: 'All'),
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Unread'),
                          if (unread > 0) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: accentColor,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: accentColor.withOpacity(0.14),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  )
                                ],
                              ),
                              child: Text(
                                '$unread',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const Tab(text: 'Pinned'),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _SliverTabBarDelegate oldDelegate) {
    // Rebuild if anything relevant changed (controller instance or color or tabController)
    return oldDelegate.controller != controller ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.tabController != tabController;
  }
}

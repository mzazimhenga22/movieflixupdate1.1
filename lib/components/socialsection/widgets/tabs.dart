import 'package:flutter/material.dart';
import '../messages_controller.dart';

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
        FutureBuilder<int>(
          future: controller.getUnreadCount(controller.currentUser['id']),
          builder: (context, snapshot) {
            final unreadCount = snapshot.data ?? 0;
            return TabBar(
              controller: tabController,
              labelColor: accentColor,
              unselectedLabelColor: Colors.white70,
              indicatorColor: accentColor,
              tabs: [
                const Tab(text: 'All'),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Unread'),
                      if (unreadCount > 0) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: accentColor,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$unreadCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Tab(text: 'Favorites'),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final FutureBuilder<int> tabBar;

  _SliverTabBarDelegate(this.tabBar);

  @override
  double get minExtent => 48.0; // Approximate height for TabBar
  @override
  double get maxExtent => 48.0;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: Colors.black.withOpacity(0.5),
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(covariant _SliverTabBarDelegate oldDelegate) => true;
}

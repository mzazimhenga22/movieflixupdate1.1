// storiecomponents.dart
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

// Adjust these imports to match your project structure:
import 'PostStoryScreen.dart';
import 'stories.dart'; // provides StoryScreen

/// StoriesRow - horizontal stories strip
class StoriesRow extends StatelessWidget {
  final List<Map<String, dynamic>> stories;
  final double height;
  final String? currentUserAvatar;
  final VoidCallback? onAddStory;
  final EdgeInsets padding;
  final bool showBorder;
  final Map<String, dynamic>? currentUser; // passed to PostStoryScreen & StoryScreen
  final Color? accentColor;

  /// If true (default) the Add Story card WILL navigate to PostStoryScreen,
  /// even if parent passed an `onAddStory` handler that opens a bottom sheet.
  final bool forceNavigateOnAdd;

  const StoriesRow({
    Key? key,
    required this.stories,
    this.height = 96,
    this.currentUserAvatar,
    this.onAddStory,
    this.showBorder = false,
    this.currentUser,
    this.accentColor,
    this.forceNavigateOnAdd = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
  }) : super(key: key);

  void _navigateToPostStory(BuildContext context) {
    if (currentUser != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PostStoryScreen(
            accentColor: accentColor ?? Theme.of(context).colorScheme.primary,
            currentUser: currentUser!,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User not available to post a story')),
      );
    }
  }

  void _handleAddTap(BuildContext context) {
    if (forceNavigateOnAdd) {
      _navigateToPostStory(context);
      return;
    }
    if (onAddStory != null) {
      onAddStory!();
      return;
    }
    _navigateToPostStory(context);
  }

  /// When tapping an individual story card:
  /// - gather all stories from `stories` that have the same userId
  /// - sort them by timestamp ascending (older first) to match StoryScreen expectation
  /// - compute the initialIndex for the tapped story and navigate to StoryScreen
  void _openStory(BuildContext context, Map<String, dynamic> tappedStory) {
    final tappedUserId = (tappedStory['userId'] ?? tappedStory['user_id'] ?? '').toString();
    if (tappedUserId.isEmpty) {
      // fallback: open story item alone
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => StoryScreen(
            stories: [tappedStory],
            currentUserId: (currentUser?['id'] ?? '').toString(),
            initialIndex: 0,
          ),
        ),
      );
      return;
    }

    // Gather stories for the same user from the provided list
    final group = stories.where((s) {
      final uid = (s['userId'] ?? s['user_id'] ?? '').toString();
      return uid == tappedUserId;
    }).toList();

    // If group empty (unlikely), show just tapped story
    if (group.isEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => StoryScreen(
            stories: [tappedStory],
            currentUserId: (currentUser?['id'] ?? '').toString(),
            initialIndex: 0,
          ),
        ),
      );
      return;
    }

    // Sort by timestamp ascending (older -> newer). If parse fails, keep original order.
    group.sort((a, b) {
      try {
        final ta = DateTime.parse((a['timestamp'] ?? a['time'] ?? DateTime.now().toIso8601String()).toString());
        final tb = DateTime.parse((b['timestamp'] ?? b['time'] ?? DateTime.now().toIso8601String()).toString());
        return ta.compareTo(tb);
      } catch (_) {
        return 0;
      }
    });

    // find index of tapped story within the group (by id if available else by matching media/timestamp)
    int initialIndex = 0;
    final tappedId = (tappedStory['id'] ?? '').toString();
    for (var i = 0; i < group.length; i++) {
      final g = group[i];
      final gid = (g['id'] ?? '').toString();
      if (gid.isNotEmpty && tappedId.isNotEmpty) {
        if (gid == tappedId) {
          initialIndex = i;
          break;
        }
      } else {
        // fallback: match by media url and timestamp
        final gm = (g['media'] ?? '').toString();
        final tm = (g['timestamp'] ?? '').toString();
        final mm = (tappedStory['media'] ?? '').toString();
        final tm2 = (tappedStory['timestamp'] ?? '').toString();
        if (gm == mm && tm == tm2) {
          initialIndex = i;
          break;
        }
      }
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StoryScreen(
          stories: group,
          currentUserId: (currentUser?['id'] ?? '').toString(),
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleStories = stories;
    return SizedBox(
      height: height,
      child: ListView.separated(
        padding: padding,
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemBuilder: (context, index) {
          if (index == 0) {
            return AddStoryCard(
              avatarUrl: currentUserAvatar,
              height: height,
              onTap: () => _handleAddTap(context),
            );
          }
          final story = visibleStories[index - 1];
          return StoryCard(
            story: story,
            height: height,
            onTap: () => _openStory(context, story),
          );
        },
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemCount: visibleStories.length + 1,
      ),
    );
  }
}

/// Add Story card (top-left avatar, center plus, bottom label).
class AddStoryCard extends StatelessWidget {
  final double height;
  final String? avatarUrl;
  final VoidCallback? onTap;

  const AddStoryCard({
    Key? key,
    this.height = 96,
    this.avatarUrl,
    this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final width = height * 0.62;
    return SizedBox(
      width: width,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: height,
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(
                colors: [Color(0xFF4A148C), Color(0xFF880E4F)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 4))],
            ),
            clipBehavior: Clip.hardEdge,
            child: Stack(
              children: [
                // Center plus
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      CircleAvatar(radius: 18, backgroundColor: Colors.white, child: Icon(Icons.add, color: Colors.black, size: 24)),
                      SizedBox(height: 8),
                    ],
                  ),
                ),

                // Top-left avatar
                Positioned(
                  left: 8,
                  top: 8,
                  child: _AvatarBadge(avatarUrl: avatarUrl, size: 36, showBorder: false, showGradientBorder: true),
                ),

                // Bottom label
                Positioned(
                  bottom: 8,
                  left: 8,
                  right: 8,
                  child: Center(
                    child: Text('Your story', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Single story card (thumbnail, username, top-left avatar, video tag)
class StoryCard extends StatelessWidget {
  final Map<String, dynamic> story;
  final double height;
  final VoidCallback? onTap;

  const StoryCard({
    Key? key,
    required this.story,
    this.height = 96,
    this.onTap,
  }) : super(key: key);

  String? get thumbnail => (story['media'] as String?)?.isNotEmpty == true ? story['media'] as String? : null;
  String? get avatar => (story['avatar'] as String?)?.isNotEmpty == true ? story['avatar'] as String? : null;
  String get username => (story['user'] ?? story['username'] ?? 'User').toString();

  @override
  Widget build(BuildContext context) {
    final width = height * 0.62;
    return SizedBox(
      width: width,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: height,
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Colors.grey[900],
              border: Border.all(color: Colors.white.withOpacity(0.03)),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.28), blurRadius: 6, offset: Offset(0, 4))],
            ),
            clipBehavior: Clip.hardEdge,
            child: Stack(
              children: [
                // thumbnail or fallback
                Positioned.fill(
                  child: thumbnail != null
                      ? CachedNetworkImage(
                          imageUrl: thumbnail!,
                          fit: BoxFit.cover,
                          fadeInDuration: Duration.zero,
                          placeholder: (c, u) => Container(color: Colors.grey[850]),
                          errorWidget: (c, u, e) => Container(color: Colors.grey[800], child: Icon(Icons.broken_image, color: Colors.white38)),
                        )
                      : Container(alignment: Alignment.center, color: Colors.grey[850], child: Text(username, style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.w500))),
                ),

                // bottom gradient
                Positioned(left: 0, right: 0, bottom: 0, height: height * 0.34, child: Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [Colors.transparent, Colors.black54], begin: Alignment.topCenter, end: Alignment.bottomCenter)))),

                // username
                Positioned(left: 10, right: 10, bottom: 8, child: Text(username, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13))),

                // avatar top-left
                Positioned(left: 8, top: 8, child: _AvatarBadge(avatarUrl: avatar, size: 34, showBorder: true, showGradientBorder: false)),

                // video tag
                if ((story['type'] as String?) == 'video')
                  Positioned(right: 8, bottom: 8, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)), child: Row(mainAxisSize: MainAxisSize.min, children: const [Icon(Icons.videocam, size: 12, color: Colors.white70), SizedBox(width: 6), Text('Video', style: TextStyle(color: Colors.white70, fontSize: 11))]))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Avatar badge with optional white border or gradient ring.
class _AvatarBadge extends StatelessWidget {
  final String? avatarUrl;
  final double size;
  final bool showBorder;
  final bool showGradientBorder;

  const _AvatarBadge({Key? key, this.avatarUrl, this.size = 40, this.showBorder = false, this.showGradientBorder = false}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final ringThickness = showGradientBorder ? 3.0 : (showBorder ? 2.0 : 0.0);
    final outerSize = size + ringThickness * 2;

    Widget image = avatarUrl != null && avatarUrl!.isNotEmpty
        ? CachedNetworkImage(
            imageUrl: avatarUrl!,
            fit: BoxFit.cover,
            width: size,
            height: size,
            fadeInDuration: Duration.zero,
            placeholder: (c, u) => Container(width: size, height: size, color: Colors.grey[800]),
            errorWidget: (c, u, e) => Container(width: size, height: size, color: Colors.grey[700], child: const Icon(Icons.person, color: Colors.white30)),
          )
        : Container(width: size, height: size, color: Colors.grey[800], child: const Icon(Icons.person, color: Colors.white70));

    if (showGradientBorder) {
      return Container(
        width: outerSize,
        height: outerSize,
        alignment: Alignment.center,
        decoration: const BoxDecoration(shape: BoxShape.circle, gradient: SweepGradient(colors: [Colors.red, Colors.orange, Colors.yellow, Colors.purple, Colors.red], stops: [0.0, 0.25, 0.5, 0.75, 1.0])),
        child: Container(width: size, height: size, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.grey[800]), clipBehavior: Clip.hardEdge, child: ClipOval(child: image)),
      );
    }

    if (showBorder) {
      return Container(width: outerSize, height: outerSize, alignment: Alignment.center, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withOpacity(0.9), width: ringThickness)), child: ClipOval(child: SizedBox(width: size, height: size, child: image)));
    }

    return ClipOval(child: SizedBox(width: size, height: size, child: image));
  }
}

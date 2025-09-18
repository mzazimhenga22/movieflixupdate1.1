// storiecomponents.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

// Adjust these imports to match your project structure:
import 'PostStoryScreen.dart';
import 'stories.dart'; // provides StoryScreen

/// Lightweight, memory-friendly StoriesRow
class StoriesRow extends StatelessWidget {
  final List<Map<String, dynamic>> stories;
  final double height;
  final String? currentUserAvatar;
  final VoidCallback? onAddStory;
  final EdgeInsets padding;
  final bool showBorder;
  final Map<String, dynamic>? currentUser;
  final Color? accentColor;
  final bool forceNavigateOnAdd;

  const StoriesRow({
    Key? key,
    required this.stories,
    this.height = 140,
    this.currentUserAvatar,
    this.onAddStory,
    this.showBorder = false,
    this.currentUser,
    this.accentColor,
    this.forceNavigateOnAdd = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
  }) : super(key: key);

  void _navigateToPostStory(BuildContext context) {
    if (currentUser != null) {
      try {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PostStoryScreen(
              accentColor: accentColor ?? Theme.of(context).colorScheme.primary,
              currentUser: currentUser!,
            ),
          ),
        );
      } catch (e, st) {
        debugPrint('Navigation to PostStoryScreen failed: $e\n$st');
      }
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
      try {
        onAddStory!();
        return;
      } catch (e, st) {
        debugPrint('onAddStory callback failed: $e\n$st');
      }
    }
    _navigateToPostStory(context);
  }

  void _openStory(BuildContext context, Map<String, dynamic> tappedStory) {
    try {
      final tappedUserId = (tappedStory['userId'] ?? tappedStory['user_id'] ?? '').toString();

      // Collect group of stories for the tapped user (or single story if no user id)
      final group = (tappedUserId.isNotEmpty)
          ? stories.where((s) {
              final uid = (s['userId'] ?? s['user_id'] ?? '').toString();
              return uid == tappedUserId;
            }).toList()
          : <Map<String, dynamic>>[tappedStory];

      final effectiveGroup = group.isNotEmpty ? group : [tappedStory];

      // --- SAFE / FAST SORT: parse each timestamp ONCE and sort by parsed DateTime ---
      final parsed = <MapEntry<Map<String, dynamic>, DateTime>>[];
      for (var s in effectiveGroup) {
        DateTime t;
        try {
          final ts = (s['timestamp'] ?? s['time'] ?? '').toString();
          t = ts.isNotEmpty ? DateTime.parse(ts) : DateTime.now();
        } catch (_) {
          t = DateTime.now();
        }
        parsed.add(MapEntry(s, t));
      }

      parsed.sort((a, b) => a.value.compareTo(b.value));
      final sortedGroup = parsed.map((e) => e.key).toList();

      // find initial index (look for id match, fallback to media+timestamp match)
      int initialIndex = 0;
      final tappedId = (tappedStory['id'] ?? '').toString();
      for (var i = 0; i < sortedGroup.length; i++) {
        final g = sortedGroup[i];
        final gid = (g['id'] ?? '').toString();
        if (gid.isNotEmpty && tappedId.isNotEmpty) {
          if (gid == tappedId) {
            initialIndex = i;
            break;
          }
        } else {
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
            stories: sortedGroup,
            currentUserId: (currentUser?['id'] ?? '').toString(),
            initialIndex: initialIndex,
          ),
        ),
      );
    } catch (e, st) {
      debugPrint('Failed to open story: $e\n$st');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to open story')));
    }
  }

  // helper to ensure we always produce a double (avoid num from clamp())
  double _clampDouble(double value, double min, double max) {
    if (value.isNaN) return min;
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final visibleStories = stories;
    final safeHeight = _clampDouble(height, 80.0, 320.0);

    try {
      return SizedBox(
        height: safeHeight,
        child: ListView.separated(
          padding: padding,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          itemBuilder: (context, index) {
            // first slot is always the "Add story" card
            if (index == 0) {
              return AddStoryCard(
                avatarUrl: currentUserAvatar,
                height: safeHeight,
                onTap: () => _handleAddTap(context),
                accentColor: accentColor,
              );
            }

            final itemIdx = index - 1;
            if (itemIdx < 0 || itemIdx >= visibleStories.length) {
              // defensive fallback
              return const SizedBox.shrink();
            }

            final story = visibleStories[itemIdx];
            return StoryCard(
              key: ValueKey(story['id']?.toString() ?? '${story['user'] ?? story['username'] ?? 'user'}_$itemIdx'),
              story: story,
              height: safeHeight,
              onTap: () => _openStory(context, story),
              accentColor: accentColor,
              currentUserId: (currentUser?['id'] ?? '').toString(),
            );
          },
          separatorBuilder: (_, __) => const SizedBox(width: 14),
          itemCount: visibleStories.length + 1,
        ),
      );
    } catch (e, st) {
      // If any unexpected error happens during build, avoid crashing: show minimal fallback
      debugPrint('StoriesRow build error: $e\n$st');
      return SizedBox(
        height: safeHeight,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.45),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text('Failed to render stories', style: TextStyle(color: Colors.white70)),
          ),
        ),
      );
    }
  }
}

/// Add Story card (lighter effects — no expensive blur)
class AddStoryCard extends StatelessWidget {
  final double height;
  final String? avatarUrl;
  final VoidCallback? onTap;
  final Color? accentColor;

  const AddStoryCard({
    Key? key,
    this.height = 140,
    this.avatarUrl,
    this.onTap,
    this.accentColor,
  }) : super(key: key);

  double _clampDouble(double value, double min, double max) {
    if (value.isNaN) return min;
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final color = accentColor ?? Theme.of(context).colorScheme.primary;
    final safeHeight = _clampDouble(height, 80.0, 320.0);
    final width = _clampDouble(safeHeight * 0.72, 72.0, 220.0);

    // lightweight card: simple translucent background + small shadow
    return SizedBox(
      width: width,
      height: safeHeight, // <-- ensure card is bounded vertically
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: RepaintBoundary(
            child: Container(
              decoration: BoxDecoration(
                color: color.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: color.withOpacity(0.12)),
                // very subtle shadow only
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 4, offset: const Offset(0, 2)),
                ],
              ),
              // scale padding with safeHeight to avoid overflow on small heights
              padding: EdgeInsets.symmetric(
                horizontal: _clampDouble(safeHeight * 0.08, 8.0, 16.0),
                vertical: _clampDouble(safeHeight * 0.06, 6.0, 14.0),
              ),
              child: Column(
                // Prevent the column from expanding to available vertical space (fixes overflow)
                mainAxisSize: MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // avatar top-left using simple row to avoid stacking overhead
                  Row(
                    children: [
                      _AvatarBadge(
                        avatarUrl: avatarUrl,
                        size: _clampDouble(safeHeight * 0.20, 24.0, 56.0),
                        showBorder: true,
                        showGradientBorder: false,
                        accentColor: color,
                      ),
                      const Spacer(),
                    ],
                  ),

                  // small flexible spacing based on card height instead of Spacer()
                  SizedBox(height: safeHeight * 0.06),

                  // large plus in the middle
                  Center(
                    child: Container(
                      width: safeHeight * 0.28,
                      height: safeHeight * 0.28,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        // minimal shadow
                        boxShadow: [BoxShadow(color: color.withOpacity(0.18), blurRadius: 6, offset: const Offset(0, 4))],
                      ),
                      child: Icon(Icons.add, size: safeHeight * 0.14, color: Colors.white),
                    ),
                  ),

                  // another small fixed spacing
                  SizedBox(height: safeHeight * 0.06),

                  // bottom label (centered)
                  Align(
                    alignment: Alignment.center,
                    child: Text(
                      'Your story',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.95),
                        fontWeight: FontWeight.w700,
                        fontSize: _clampDouble(safeHeight * 0.10, 10.0, 18.0),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Single story card (reduced visual weight but similar layout)
class StoryCard extends StatelessWidget {
  final Map<String, dynamic> story;
  final double height;
  final VoidCallback? onTap;
  final Color? accentColor;
  final String? currentUserId;

  const StoryCard({
    Key? key,
    required this.story,
    this.height = 140,
    this.onTap,
    this.accentColor,
    this.currentUserId,
  }) : super(key: key);

  // Safe getters that coerce to string if possible
  String? get thumbnail {
    try {
      final v = story['media'];
      if (v == null) return null;
      final s = v.toString();
      return s.isNotEmpty ? s : null;
    } catch (_) {
      return null;
    }
  }

  String? get avatar {
    try {
      final v = story['avatar'] ?? story['userAvatar'] ?? story['profilePic'];
      if (v == null) return null;
      final s = v.toString();
      return s.isNotEmpty ? s : null;
    } catch (_) {
      return null;
    }
  }

  String get username {
    try {
      final u = story['user'] ?? story['username'] ?? story['displayName'] ?? 'User';
      return u.toString();
    } catch (_) {
      return 'User';
    }
  }

  bool get isVideo {
    try {
      final t = story['type'] ?? story['mediaType'];
      return t?.toString().toLowerCase() == 'video';
    } catch (_) {
      return false;
    }
  }

  double _clampDouble(double value, double min, double max) {
    if (value.isNaN) return min;
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final color = accentColor ?? Theme.of(context).colorScheme.primary;
    final safeHeight = _clampDouble(height, 80.0, 320.0);
    final width = _clampDouble(safeHeight * 0.72, 72.0, 220.0);

    return SizedBox(
      width: width,
      height: safeHeight, // <-- ensure card is bounded vertically
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: RepaintBoundary(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // thumbnail or fallback — lightweight placeholder
                  if (thumbnail != null)
                    CachedNetworkImage(
                      imageUrl: thumbnail!,
                      fit: BoxFit.cover,
                      placeholder: (c, u) => Container(color: Colors.grey[900]),
                      errorWidget: (c, u, e) => Container(color: Colors.grey[850], alignment: Alignment.center, child: const Icon(Icons.broken_image, color: Colors.white24, size: 24)),
                      // small fade to avoid heavy animations
                      fadeInDuration: const Duration(milliseconds: 150),
                      fadeOutDuration: const Duration(milliseconds: 80),
                    )
                  else
                    Container(
                      alignment: Alignment.center,
                      color: Colors.grey[900],
                      child: Text(username, style: TextStyle(color: Colors.white.withOpacity(0.85), fontWeight: FontWeight.w600)),
                    ),

                  // simple translucent overlay instead of blur/gradient stacks
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.06),
                      border: Border.all(color: color.withOpacity(0.06)),
                    ),
                  ),

                  // bottom vignette (lighter)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: safeHeight * 0.30,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.transparent, Colors.black.withOpacity(0.36)],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                  ),

                  // username
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: Text(username, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                  ),

                  // avatar top-left with simple ring
                  Positioned(
                    left: 10,
                    top: 10,
                    child: _AvatarBadge(
                      avatarUrl: avatar,
                      size: _clampDouble(safeHeight * 0.22, 28.0, 64.0),
                      showBorder: true,
                      showGradientBorder: false,
                      accentColor: color,
                    ),
                  ),

                  // video tag (lighter)
                  if (isVideo)
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: color.withOpacity(0.18)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.videocam, size: 12, color: Colors.white70),
                            const SizedBox(width: 6),
                            Text('Video', style: TextStyle(color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small avatar badge — simple border variant (no heavy gradients)
class _AvatarBadge extends StatelessWidget {
  final String? avatarUrl;
  final double size;
  final bool showBorder;
  final bool showGradientBorder;
  final Color? accentColor;

  const _AvatarBadge({
    Key? key,
    this.avatarUrl,
    this.size = 48,
    this.showBorder = false,
    this.showGradientBorder = false,
    this.accentColor,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final color = accentColor ?? Theme.of(context).colorScheme.primary;
    final ringThickness = showGradientBorder ? 3.0 : (showBorder ? 2.0 : 0.0);
    final outerSize = size + ringThickness * 2;

    Widget image = (avatarUrl != null && avatarUrl!.isNotEmpty)
        ? CachedNetworkImage(
            imageUrl: avatarUrl!,
            fit: BoxFit.cover,
            width: size,
            height: size,
            placeholder: (c, u) => Container(width: size, height: size, color: Colors.grey[800]),
            errorWidget: (c, u, e) => Container(width: size, height: size, color: Colors.grey[700], child: const Icon(Icons.person, color: Colors.white30)),
            fadeInDuration: const Duration(milliseconds: 120),
          )
        : Container(width: size, height: size, decoration: BoxDecoration(color: Colors.grey[800], borderRadius: BorderRadius.circular(size / 2)), child: const Icon(Icons.person, color: Colors.white70));

    if (showGradientBorder) {
      return Container(
        width: outerSize,
        height: outerSize,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color.withOpacity(0.9), width: ringThickness),
        ),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.grey[850]),
          clipBehavior: Clip.hardEdge,
          child: ClipOval(child: image),
        ),
      );
    }

    if (showBorder) {
      return Container(
        width: outerSize,
        height: outerSize,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withOpacity(0.12), width: ringThickness)),
        child: ClipOval(child: SizedBox(width: size, height: size, child: image)),
      );
    }

    return ClipOval(child: SizedBox(width: size, height: size, child: image));
  }
}

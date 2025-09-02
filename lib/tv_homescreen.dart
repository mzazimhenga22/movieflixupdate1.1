// tv_homescreen.dart (updated)
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // for LogicalKeyboardKey
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/tmdb_api.dart' as tmdb;
import 'package:movie_app/components/stories_section.dart';
import 'package:movie_app/sub_home_screen.dart';
import 'package:palette_generator/palette_generator.dart';

class TVHomeScreen extends StatefulWidget {
  const TVHomeScreen({super.key});

  @override
  State<TVHomeScreen> createState() => _TVHomeScreenState();
}

class _TVHomeScreenState extends State<TVHomeScreen> {
  Color currentBackgroundColor = Colors.black;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: currentBackgroundColor,
      body: Stack(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 600),
            color: currentBackgroundColor,
            width: double.infinity,
            height: double.infinity,
          ),
          Column(
            children: [
              TVFeaturedBanner(
                onBackgroundColorChanged: (color) {
                  if (color != currentBackgroundColor && mounted) {
                    setState(() => currentBackgroundColor = color);
                  }
                },
              ),
              Expanded(
                child: CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                        child: SubHomeScreen(),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  ],
                ),
              ),
            ],
          ),
          const LeftNavigation(),
        ],
      ),
    );
  }
}

class LeftNavigation extends StatelessWidget {
  const LeftNavigation({super.key});

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.82;
    return Positioned(
      left: 0,
      top: 0,
      child: ClipRect(
        child: Container(
          width: 88,
          height: height,
          decoration: BoxDecoration(
            color: Color.fromRGBO(0, 0, 0, 0.65),
            backgroundBlendMode: BlendMode.darken,
          ),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  _NavButton(icon: Icons.search, routeName: '/search'),
                  _NavButton(icon: Icons.home, routeName: '/'),
                  _NavButton(icon: Icons.category, routeName: '/categories'),
                  _NavButton(icon: Icons.download, routeName: '/downloads'),
                  _NavButton(icon: Icons.live_tv, routeName: '/interactive'),
                  _NavButton(icon: Icons.list, routeName: '/mylist'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final IconData icon;
  final String? routeName;
  const _NavButton({required this.icon, this.routeName, super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10.0),
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        child: Builder(builder: (ctx) {
          final hasFocus = Focus.of(ctx).hasPrimaryFocus || Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: routeName == null ? null : () => Navigator.pushNamed(context, routeName!),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: hasFocus ? Color.fromRGBO(255, 255, 255, 0.06) : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.white, size: 28),
            ),
          );
        }),
      ),
    );
  }
}

/// ----------------------------
/// Featured Banner
/// ----------------------------
class TVFeaturedBanner extends StatefulWidget {
  final Function(Color)? onBackgroundColorChanged;
  const TVFeaturedBanner({super.key, this.onBackgroundColorChanged});

  @override
  State<TVFeaturedBanner> createState() => _TVFeaturedBannerState();
}

class _TVFeaturedBannerState extends State<TVFeaturedBanner> {
  List<Map<String, dynamic>> featuredContent = [];
  int currentIndex = 0;
  Color backgroundColor = Colors.black;
  bool isLoading = false;

  final Map<String, Color> _paletteCache = {};
  static List<Map<String, dynamic>> _globalCachedContent = [];

  late final PageController _pageController;
  Timer? _autoPlayTimer;
  final bool enableHeavyVisual = true;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 1.0);
    if (_globalCachedContent.isNotEmpty) {
      featuredContent = _globalCachedContent;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scheduleExtractDominantColor();
          _startAutoPlay();
        }
      });
    } else {
      loadInitialContent();
    }
  }

  Future<void> loadInitialContent() async {
    if (isLoading) return;
    setState(() => isLoading = true);

    final content = await fetchFeaturedContent(limit: 6);
    if (!mounted) return;

    // Precache hero images
    await Future.wait(content.map((item) async {
      final url = _getImageUrl(item, hero: true);
      try {
        await precacheImage(NetworkImage(url), context);
      } catch (_) {}
    }));

    setState(() {
      featuredContent = content;
      _globalCachedContent = content;
      isLoading = false;
    });

    if (featuredContent.isNotEmpty) {
      _scheduleExtractDominantColor();
      _startAutoPlay();
    }
  }

  Future<List<Map<String, dynamic>>> fetchFeaturedContent({int limit = 5}) async {
    try {
      final results = await Future.wait([
        tmdb.TMDBApi.fetchFeaturedMovies(),
        tmdb.TMDBApi.fetchFeaturedTVShows(),
      ]);
      final movies = (results[0] as List).cast<Map<String, dynamic>>();
      final tvShows = (results[1] as List).cast<Map<String, dynamic>>();
      List<Map<String, dynamic>> content = [];
      content.addAll(movies);
      content.addAll(tvShows);
      content.sort((a, b) {
        final num aPop = (a['popularity'] as num?) ?? 0;
        final num bPop = (b['popularity'] as num?) ?? 0;
        return bPop.compareTo(aPop);
      });
      return content.take(limit).toList();
    } catch (e) {
      debugPrint("Error fetching featured content: $e");
      return [];
    }
  }

  void _startAutoPlay() {
    _autoPlayTimer?.cancel();
    _autoPlayTimer = Timer.periodic(const Duration(seconds: 14), (_) {
      if (featuredContent.isEmpty || !mounted) return;
      final next = (currentIndex + 1) % featuredContent.length;
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeInOut,
      );
    });
  }

  void _scheduleExtractDominantColor() {
    Future.delayed(const Duration(milliseconds: 120), extractDominantColor);
  }

  Future<void> extractDominantColor() async {
    if (featuredContent.isEmpty || !mounted) return;
    final item = featuredContent[currentIndex];
    final imageUrl = _getImageUrl(item, hero: true);

    if (_paletteCache.containsKey(imageUrl)) {
      final cached = _paletteCache[imageUrl]!;
      setState(() {
        backgroundColor = _blendColors(backgroundColor, cached);
        widget.onBackgroundColorChanged?.call(backgroundColor);
      });
      return;
    }

    try {
      final paletteGenerator = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(imageUrl),
        size: const Size(48, 48),
        maximumColorCount: 6,
      );

      final dominant = paletteGenerator.dominantColor?.color ?? Colors.black;
      _paletteCache[imageUrl] = dominant;

      if (!mounted) return;
      setState(() {
        backgroundColor = _blendColors(backgroundColor, dominant);
        widget.onBackgroundColorChanged?.call(backgroundColor);
      });
    } catch (e) {
      debugPrint("Error extracting color: $e");
      if (!mounted) return;
      setState(() {
        backgroundColor = Colors.black;
        widget.onBackgroundColorChanged?.call(backgroundColor);
      });
    }
  }

  Color _blendColors(Color a, Color b, [double t = 0.6]) {
    return Color.lerp(a, b, t) ?? b;
  }

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.82;
    if (isLoading || featuredContent.isEmpty) {
      return Shimmer.fromColors(
        baseColor: Colors.grey[850]!,
        highlightColor: Colors.grey[700]!,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
            color: Colors.grey[850],
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
        child: SizedBox(
          height: height,
          child: Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                itemCount: featuredContent.length,
                onPageChanged: (index) {
                  if (!mounted) return;
                  setState(() {
                    currentIndex = index;
                  });
                  extractDominantColor();
                },
                itemBuilder: (context, index) {
                  final item = featuredContent[index];
                  return _TVBannerContentV2(
                    key: ValueKey('banner_$index'),
                    item: item,
                    height: height,
                    leftNavWidth: 88,
                    enableHeavyVisual: enableHeavyVisual,
                  );
                },
              ),
              Positioned(
                left: 104,
                bottom: 12,
                child: Row(
                  children: List.generate(featuredContent.length, (i) {
                    final active = i == currentIndex;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: active ? 18 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: active ? Color.fromRGBO(255, 255, 255, 0.95) : Color.fromRGBO(255, 255, 255, 0.24),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getImageUrl(Map<String, dynamic> item, {bool hero = false}) {
    final backdrop = item['backdrop_path'] as String?;
    final poster = item['poster_path'] as String?;
    final heroSize = 'w1280';
    final posterSize = 'w500';
    if (hero && backdrop != null && backdrop.isNotEmpty) {
      return 'https://image.tmdb.org/t/p/$heroSize$backdrop';
    } else if (hero && poster != null && poster.isNotEmpty) {
      return 'https://image.tmdb.org/t/p/$heroSize$poster';
    } else if (!hero && poster != null && poster.isNotEmpty) {
      return 'https://image.tmdb.org/t/p/$posterSize$poster';
    } else {
      return 'https://via.placeholder.com/500x320';
    }
  }
}

/// Banner variant with nicer layout & glass buttons
class _TVBannerContentV2 extends StatefulWidget {
  final Map<String, dynamic> item;
  final double height;
  final double leftNavWidth;
  final bool enableHeavyVisual;

  const _TVBannerContentV2({
    required this.item,
    required this.height,
    required this.leftNavWidth,
    required this.enableHeavyVisual,
    super.key,
  });

  @override
  State<_TVBannerContentV2> createState() => _TVBannerContentV2State();
}

class _TVBannerContentV2State extends State<_TVBannerContentV2> {
  double _parallax = 0.0;

  @override
  Widget build(BuildContext context) {
    final imageUrl = _getImageUrl(widget.item);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setParallax(6),
      onTapUp: (_) => _setParallax(0),
      child: Stack(
        children: [
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(_parallax, 0),
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: Colors.grey[850]),
                errorWidget: (_, __, ___) => Container(color: Colors.grey),
              ),
            ),
          ),
          if (widget.enableHeavyVisual) ...[
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(seconds: 3),
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0.0 + (_parallax / 100), 0.3),
                      radius: 1.2,
                      colors: [
                        Color.fromRGBO(0, 0, 0, 0.55),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.85],
                    ),
                  ),
                ),
              ),
            ),
          ] else
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color.fromRGBO(0, 0, 0, 0.9), Colors.transparent],
                  ),
                ),
              ),
            ),
          Positioned(
            left: widget.leftNavWidth + 28,
            right: 24,
            bottom: 24,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 220,
                    height: widget.height * 0.6,
                    child: CachedNetworkImage(
                      imageUrl: _getPosterUrl(widget.item),
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: Colors.grey[800]),
                      errorWidget: (_, __, ___) => Container(color: Colors.grey),
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item['title'] ?? widget.item['name'] ?? 'Featured',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 40,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          if (widget.item['release_date'] != null)
                            Text(
                              widget.item['release_date'].toString().split('-').first,
                              style: const TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                          const SizedBox(width: 12),
                          if (widget.item['vote_average'] != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Color.fromRGBO(255, 255, 255, 0.06),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.star, size: 14, color: Colors.amber),
                                  const SizedBox(width: 6),
                                  Text(
                                    (widget.item['vote_average']?.toString() ?? '-'),
                                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.item['overview'] ?? 'No description available.',
                        style: const TextStyle(color: Colors.white70, fontSize: 16),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          _glassButton(
                            label: 'Play',
                            icon: Icons.play_arrow,
                            onPressed: () {
                              // implement play action
                            },
                            emphasize: true,
                          ),
                          const SizedBox(width: 12),
                          _glassButton(
                            label: 'More Info',
                            icon: Icons.info_outline,
                            onPressed: () {
                              if (widget.item.containsKey('id')) {
                                Navigator.pushNamed(context, '/movie_detail', arguments: widget.item);
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Invalid movie data')),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: widget.leftNavWidth + 28,
            right: 24,
            bottom: 12,
            child: SizedBox(height: 110, child: StoriesSection()),
          ),
        ],
      ),
    );
  }

  Widget _glassButton({
    required String label,
    IconData? icon,
    required VoidCallback onPressed,
    bool emphasize = false,
  }) {
    final bg = emphasize ? Colors.white : Color.fromRGBO(255, 255, 255, 0.08);
    final fg = emphasize ? Colors.black : Colors.white;
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: icon != null ? Icon(icon, color: fg) : const SizedBox.shrink(),
      label: Text(label, style: TextStyle(color: fg)),
      style: ElevatedButton.styleFrom(
        backgroundColor: bg,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        elevation: emphasize ? 8 : 0,
      ),
    );
  }

  void _setParallax(double v) {
    setState(() => _parallax = v);
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _parallax = 0.0);
    });
  }

  String _getPosterUrl(Map<String, dynamic> item) {
    final poster = item['poster_path'] as String?;
    final size = 'w500';
    if (poster != null && poster.isNotEmpty) {
      return 'https://image.tmdb.org/t/p/$size$poster';
    } else {
      return 'https://via.placeholder.com/500x700';
    }
  }

  String _getImageUrl(Map<String, dynamic> item) {
    final backdrop = item['backdrop_path'] as String?;
    final poster = item['poster_path'] as String?;
    final size = 'w1280';
    if (backdrop != null && backdrop.isNotEmpty) {
      return 'https://image.tmdb.org/t/p/$size$backdrop';
    } else if (poster != null && poster.isNotEmpty) {
      return 'https://image.tmdb.org/t/p/$size$poster';
    } else {
      return 'https://via.placeholder.com/1280x720';
    }
  }
}

/// PosterTile: focusable & scalable for remote navigation
class PosterTile extends StatefulWidget {
  final String imageUrl;
  final double width;
  final double height;
  final VoidCallback? onPressed;
  const PosterTile({
    required this.imageUrl,
    this.width = 220,
    this.height = 330,
    this.onPressed,
    super.key,
  });

  @override
  State<PosterTile> createState() => _PosterTileState();
}

class _PosterTileState extends State<PosterTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowHoverHighlight: (_) {},
      onShowFocusHighlight: (hasFocus) => setState(() => _focused = hasFocus),
      onFocusChange: (hasFocus) => setState(() => _focused = hasFocus),
      shortcuts: {
        SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): const ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onPressed?.call();
          return null;
        }),
      },
      child: AnimatedScale(
        scale: _focused ? 1.14 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: Container(
          width: widget.width,
          height: widget.height,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: Color.fromRGBO(255, 255, 255, 0.12),
                      blurRadius: 22,
                      spreadRadius: 1,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black45,
                      blurRadius: 6,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedNetworkImage(
              imageUrl: widget.imageUrl,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: Colors.grey[900]),
              errorWidget: (_, __, ___) => Container(color: Colors.grey),
            ),
          ),
        ),
      ),
    );
  }
}

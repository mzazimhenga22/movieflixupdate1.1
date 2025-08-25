// reels_section.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:movie_app/tmdb_api.dart';
import '../reel_player_screen.dart';
import '../models/reel.dart';

class ReelsSection extends StatefulWidget {
  const ReelsSection({super.key});

  @override
  State<ReelsSection> createState() => _ReelsSectionState();
}

class _ReelsSectionState extends State<ReelsSection>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  static List<dynamic> _cachedReels = [];
  List<dynamic> reelsData = [];
  List<Reel> reelModels = [];

  // small shine animation — kept lightweight
  late final AnimationController _controller;
  late final Animation<double> _shineAnimation;

  // Scroll controller to prefetch thumbnails near the viewport
  final ScrollController _scrollController = ScrollController();
  Timer? _prefetchDebounce;

  bool _isInitialized = false;

  static const double _itemWidth = 160.0;
  static const double _itemHorizontalPadding = 20.0; // left+right combined per item
  static const int _initialPrecacheCount = 6;
  static const int _dynamicPrefetchRange = 5;

  static final _loadingWidget = Shimmer.fromColors(
    baseColor: Color.fromARGB(255, 48, 48, 48),
    highlightColor: Color.fromARGB(255, 66, 66, 66),
    child: SizedBox(
      height: 360,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: 3,
        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 20.0),
            child: Container(
              width: _itemWidth,
              height: 320,
              decoration: BoxDecoration(
                color: Colors.grey,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          );
        },
      ),
    ),
  );

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _shineAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    _isInitialized = true;

    _scrollController.addListener(_onScrollForPrefetch);

    if (_cachedReels.isNotEmpty) {
      reelsData = _cachedReels;
      _prepareModels();
    } else {
      fetchReels();
    }
  }

  Future<void> fetchReels({bool forceRefresh = false}) async {
    if (_cachedReels.isNotEmpty && !forceRefresh) {
      if (reelsData != _cachedReels) {
        setState(() {
          reelsData = _cachedReels;
          _prepareModels();
        });
      }
      return;
    }

    try {
      final fetchedReels = await TMDBApi.fetchReels();
      if (!mounted) return;

      // keep the full list, but only precache a small number of thumbnails eagerly
      setState(() {
        reelsData = fetchedReels;
        _cachedReels = fetchedReels;
        _prepareModels();
      });

      // precache first N thumbnails only — lightweight and prevents startup jank
      final toPrecache = fetchedReels.take(_initialPrecacheCount);
      for (var r in toPrecache) {
        final thumb = r['thumbnail_url'] as String?;
        if (thumb != null && thumb.isNotEmpty) {
          // don't await; fire-and-forget
          precacheImage(NetworkImage(thumb), context);
        }
      }
    } catch (e) {
      debugPrint('Error fetching reels: $e');
    }
  }

  void _prepareModels() {
    // map once, not inside itemBuilder.
    reelModels = reelsData.map<Reel>((r) {
      return Reel(
        videoUrl: (r['videoUrl'] as String?) ?? '',
        movieTitle: (r['title'] as String?) ?? 'Reel',
        movieDescription: 'Watch the trailer',
      );
    }).toList();
  }

  void _onScrollForPrefetch() {
    // debounce prefetching to avoid firing many precache operations while user is actively dragging
    _prefetchDebounce?.cancel();
    _prefetchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || reelModels.isEmpty) return;

      final offset = _scrollController.offset;
      final viewportWidth = MediaQuery.of(context).size.width;

      // approximate the first visible index
      final itemSpacing = _itemWidth + _itemHorizontalPadding;
      int firstVisible = (offset / itemSpacing).floor();
      firstVisible = firstVisible.clamp(0, reelModels.length - 1);

      final end = (firstVisible + _dynamicPrefetchRange).clamp(0, reelModels.length - 1);

      for (int i = firstVisible; i <= end; i++) {
        final thumb = (reelsData[i]['thumbnail_url'] as String?) ?? '';
        if (thumb.isNotEmpty) {
          // fire-and-forget; don't await
          precacheImage(NetworkImage(thumb), context);
        }
      }
    });
  }

  @override
  void dispose() {
    _prefetchDebounce?.cancel();
    _scrollController.removeListener(_onScrollForPrefetch);
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16.0, bottom: 10.0),
          child: AnimatedBuilder(
            animation: _shineAnimation,
            builder: (context, child) {
              return ShaderMask(
                shaderCallback: (rect) {
                  return LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.red.withOpacity(0.8 - _shineAnimation.value * 0.4),
                      Colors.redAccent.withOpacity(0.8 + _shineAnimation.value * 0.4),
                      Colors.red.withOpacity(0.8 - _shineAnimation.value * 0.4),
                    ],
                    stops: [0.0, 0.5 + _shineAnimation.value * 0.5, 1.0],
                  ).createShader(rect);
                },
                child: const Text(
                  'Movie Reels',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                ),
              );
            },
          ),
        ),
        SizedBox(
          height: 360,
          child: reelModels.isEmpty
              ? _loadingWidget
              : ListView.builder(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: reelModels.length,
                  cacheExtent: 300, // keep this small to limit offscreen work
                  itemBuilder: (context, index) {
                    final model = reelModels[index];
                    final thumbnailUrl = (reelsData[index]['thumbnail_url'] as String?) ?? '';

                    // keep the item build cheap and mostly const
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 20.0),
                      child: GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ReelPlayerScreen(reels: reelModels, initialIndex: index),
                            ),
                          );
                        },
                        child: Container(
                          width: _itemWidth,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: const [
                              BoxShadow(
                                color: Color.fromRGBO(103, 58, 183, 0.6),
                                blurRadius: 15,
                                spreadRadius: 1,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: CachedNetworkImage(
                                    imageUrl: thumbnailUrl,
                                    fit: BoxFit.cover,
                                    placeholder: (context, url) => const ColoredBox(
                                      color: Color.fromRGBO(33, 33, 33, 1),
                                      child: Center(child: CircularProgressIndicator()),
                                    ),
                                    errorWidget: (context, url, error) => const ColoredBox(
                                      color: Color.fromRGBO(33, 33, 33, 1),
                                      child: Icon(Icons.error, color: Colors.red, size: 40),
                                    ),
                                  ),
                                ),
                              ),
                              const Positioned.fill(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [Colors.transparent, Color.fromRGBO(0, 0, 0, 0.7)],
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                bottom: 10,
                                left: 10,
                                right: 10,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      model.movieTitle,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 8),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: Container(
                                        padding: const EdgeInsets.all(6.0),
                                        decoration: const BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.deepPurpleAccent,
                                        ),
                                        child: const Icon(
                                          Icons.play_arrow,
                                          color: Colors.white,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

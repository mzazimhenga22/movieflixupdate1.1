// reels_section.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:movie_app/tmdb_api.dart';
import '../reel_player_screen.dart';
import '../models/reel.dart';

/// Implementation notes:
/// - Heavy parsing/processing is done in an isolate with compute() and returns
///   a lightweight List<Map<String, String>> ("light models") that contain only
///   primitives (safe for isolate transfer).
/// - The UI uses those light models (fast). Full Reel objects are constructed only
///   when user opens the player (cheap, on-demand).
/// - Initial thumbnail precache is limited to _initialPrecacheCount; the rest is
///   precached asynchronously with throttling to avoid jank.
/// - ValueNotifier is used to minimize rebuild scope.

class ReelsSection extends StatefulWidget {
  const ReelsSection({super.key});

  @override
  State<ReelsSection> createState() => _ReelsSectionState();
}

class _ReelsSectionState extends State<ReelsSection>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  // --- Static cache across widget recreations to avoid re-fetching every time.
  static List<dynamic> _cachedRawReels = [];

  // The original fetched raw data (kept for full details if needed).
  List<dynamic> _rawReels = [];

  // Lightweight UI-ready models produced in background isolate:
  // each map contains only primitive fields used in the list: title, thumbnail, videoUrl.
  final ValueNotifier<List<Map<String, String>>> _lightModelsNotifier =
      ValueNotifier<List<Map<String, String>>>([]);

  // small shine animation — kept lightweight
  late final AnimationController _controller;
  late final Animation<double> _shineAnimation;

  // Scroll controller to prefetch thumbnails near the viewport
  final ScrollController _scrollController = ScrollController();
  Timer? _prefetchDebounce;

  bool _isInitialized = false;
  bool _backgroundPrecacheRunning = false;

  static const double _itemWidth = 160.0;
  static const double _itemHorizontalPadding = 20.0; // left+right combined per item
  static const int _initialPrecacheCount = 6;
  static const int _dynamicPrefetchRange = 5;
  static const int _backgroundPrecacheThrottleMs = 120; // throttle between precache ops

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

    if (_cachedRawReels.isNotEmpty) {
      _rawReels = _cachedRawReels;
      // Build light models quickly on main thread for cached data;
      // this is cheap because cached data should already be small/ready.
      _buildLightModelsFast(_rawReels);
      // start background precache slowly
      _startBackgroundPrecache();
    } else {
      // fresh fetch
      fetchReels();
    }
  }

  @override
  void dispose() {
    _prefetchDebounce?.cancel();
    _scrollController.removeListener(_onScrollForPrefetch);
    _scrollController.dispose();
    _controller.dispose();
    _lightModelsNotifier.dispose();
    super.dispose();
  }

  /// Public fetcher — keeps main-thread work minimal and offloads heavier
  /// processing to compute().
  Future<void> fetchReels({bool forceRefresh = false}) async {
    if (_cachedRawReels.isNotEmpty && !forceRefresh) {
      if (!listEquals(_rawReels, _cachedRawReels)) {
        setState(() {
          _rawReels = _cachedRawReels;
        });
        _buildLightModelsFast(_rawReels);
      }
      return;
    }

    try {
      final fetched = await TMDBApi.fetchReels(); // assume returns List<Map>
      if (!mounted) return;

      _rawReels = fetched;
      _cachedRawReels = fetched;

      // Immediately create a very small UI-ready slice synchronously so the UI can render fast:
      final initialSlice = _rawReels.take(_initialPrecacheCount).toList();
      _buildLightModelsFast(initialSlice);

      // schedule isolate work to create the full light-model list off main thread
      // compute returns a List<Map<String,String>> (only primitives) which is safe
      // to send across isolates.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _createFullLightModelsInBackground(_rawReels);
      });

      // precache first N thumbnails eagerly (small number to avoid jank)
      for (var r in initialSlice) {
        final thumb = (r['thumbnail_url'] as String?) ?? '';
        if (thumb.isNotEmpty) {
          // fire-and-forget; precacheImage runs on UI but it's a small number
          precacheImage(NetworkImage(thumb), context);
        }
      }

      // start background prefetch for remaining thumbnails (throttled)
      _startBackgroundPrecache();
    } catch (e) {
      debugPrint('Error fetching reels: $e');
    }
  }

  /// Quick, small mapping on main thread used for the very first visible items.
  void _buildLightModelsFast(List<dynamic> rawSlice) {
    final small = rawSlice.map<Map<String, String>>((r) {
      return {
        'videoUrl': (r['videoUrl'] as String?) ?? (r['video_url'] as String?) ?? '',
        'title': (r['title'] as String?) ?? 'Reel',
        'thumbnail': (r['thumbnail_url'] as String?) ?? '',
      };
    }).toList();

    // Merge with existing list if any (e.g., initialSlice).
    final merged = List<Map<String, String>>.from(_lightModelsNotifier.value);
    // Replace or append first N as necessary
    for (int i = 0; i < small.length; i++) {
      if (i < merged.length) {
        merged[i] = small[i];
      } else {
        merged.add(small[i]);
      }
    }
    _lightModelsNotifier.value = merged;
  }

  /// Runs in an isolate using compute: strips raw objects into primitive-only light maps.
  Future<void> _createFullLightModelsInBackground(List<dynamic> fullRaw) async {
    try {
      final result = await compute(_stripToLightModels, fullRaw);
      if (!mounted) return;

      // Only update if different / longer than current
      _lightModelsNotifier.value = result;
    } catch (e) {
      debugPrint('Error building light models in background: $e');
    }
  }

  /// Background prefetch loop: throttled precache of remaining thumbnails.
  void _startBackgroundPrecache() {
    if (_backgroundPrecacheRunning) return;
    _backgroundPrecacheRunning = true;

    // Run this asynchronously without blocking UI frames
    Future.microtask(() async {
      final list = _lightModelsNotifier.value;
      for (int i = 0; i < list.length; i++) {
        if (!mounted) break;

        // skip first already eagerly precached ones
        if (i < _initialPrecacheCount) continue;

        final thumb = list[i]['thumbnail'] ?? '';
        if (thumb.isNotEmpty) {
          try {
            // Throttle: give the system breathing room between precache ops
            await Future.delayed(const Duration(milliseconds: _backgroundPrecacheThrottleMs));
            if (!mounted) break;
            // precache in UI thread but spaced out:
            await precacheImage(NetworkImage(thumb), context);
          } catch (e) {
            // ignore individual precache failures
            debugPrint('Precache failed for $thumb: $e');
          }
        }
      }
      _backgroundPrecacheRunning = false;
    });
  }

  void _onScrollForPrefetch() {
    _prefetchDebounce?.cancel();
    _prefetchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || _lightModelsNotifier.value.isEmpty) return;

      final offset = _scrollController.offset;
      final itemSpacing = _itemWidth + _itemHorizontalPadding;
      int firstVisible = (offset / itemSpacing).floor();
      firstVisible = firstVisible.clamp(0, _lightModelsNotifier.value.length - 1);

      final end = (firstVisible + _dynamicPrefetchRange).clamp(0, _lightModelsNotifier.value.length - 1);

      // fire-and-forget, throttled ergonomically by spacing in _startBackgroundPrecache.
      for (int i = firstVisible; i <= end; i++) {
        final thumb = _lightModelsNotifier.value[i]['thumbnail'] ?? '';
        if (thumb.isNotEmpty) {
          // Don't await — avoid blocking frames
          precacheImage(NetworkImage(thumb), context);
        }
      }
    });
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
          child: ValueListenableBuilder<List<Map<String, String>>>(
            valueListenable: _lightModelsNotifier,
            builder: (context, lightModels, child) {
              if (lightModels.isEmpty) {
                return _loadingWidget;
              }

              return ListView.builder(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                itemCount: lightModels.length,
                cacheExtent: 300, // keep this small to limit offscreen work
                itemBuilder: (context, index) {
                  final item = lightModels[index];
                  final thumbnailUrl = item['thumbnail'] ?? '';
                  final title = item['title'] ?? 'Reel';

                  // Use RepaintBoundary to reduce repaints for complex parents.
                  return RepaintBoundary(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 20.0),
                      child: GestureDetector(
                        onTap: () {
                          // Build full Reel list on-demand when entering player.
                          // Creating full Reel objects from light models is cheap (strings only).
                          final fullReels = _lightModelsToFullReels(lightModels);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ReelPlayerScreen(reels: fullReels, initialIndex: index),
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
                                      title,
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
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  /// Convert lightweight maps into full Reel objects on-demand (cheap).
  List<Reel> _lightModelsToFullReels(List<Map<String, String>> light) {
    return light.map<Reel>((m) {
      return Reel(
        videoUrl: m['videoUrl'] ?? '',
        movieTitle: m['title'] ?? 'Reel',
        movieDescription: 'Watch the trailer',
      );
    }).toList();
  }
}

/// Top-level function for compute() — must be a top-level or static function.
/// It strips the raw data into primitive-only maps (safe to transfer across isolates).
List<Map<String, String>> _stripToLightModels(List<dynamic> raw) {
  return raw.map<Map<String, String>>((r) {
    // Be defensive with keys—TMDB responses vary
    final video = (r['videoUrl'] as String?) ?? (r['video_url'] as String?) ?? '';
    final title = (r['title'] as String?) ?? (r['name'] as String?) ?? 'Reel';
    final thumb = (r['thumbnail_url'] as String?) ?? (r['thumbnail'] as String?) ?? '';
    return <String, String>{
      'videoUrl': video,
      'title': title,
      'thumbnail': thumb,
    };
  }).toList();
}

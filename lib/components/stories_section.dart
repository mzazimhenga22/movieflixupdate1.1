// stories_section.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:movie_app/tmdb_api.dart' as tmdb;
import 'package:shimmer/shimmer.dart';
import '../story_player_screen.dart';

/// Optimized StoriesSection:
/// - Quick small "light models" used to render UI asap (only primitives)
/// - Heavy work (fetching trailers per item + bulk precache) done in
///   throttled background loops so the UI thread isn't blocked.
/// - ValueNotifier for minimal rebuilds, RepaintBoundary on items.

class StoriesSection extends StatefulWidget {
  const StoriesSection({super.key});

  @override
  State<StoriesSection> createState() => _StoriesSectionState();
}

bool _imagesPreloaded = false; // app-level flag to avoid repeated full precache

class _StoriesSectionState extends State<StoriesSection>
    with AutomaticKeepAliveClientMixin {
  // persistent cache across widget recreations
  static List<Map<String, dynamic>> _cachedStories = [];

  // raw stories for full data if needed (kept but not used for list rendering)
  List<Map<String, dynamic>> _rawStories = [];

  // lightweight UI-friendly maps (only primitives) used by the list builder.
  // Keys: id, name, imageUrl, videoUrl, title, description, type
  final ValueNotifier<List<Map<String, String>>> _lightModelsNotifier =
      ValueNotifier<List<Map<String, String>>>([]);

  // paging + autoplay
  late PageController _pageController;
  Timer? _timer;
  static const int _itemsPerPage = 4;
  int _currentIndex = 0;

  // background control
  bool _backgroundWorkRunning = false;
  bool _isDisposed = false;
  static const int _initialPrecacheCount = 4; // keep very small to avoid jank
  static const int _backgroundThrottleMs = 150; // throttle between background ops

  static final _loadingWidget = Shimmer.fromColors(
    baseColor: Colors.grey,
    highlightColor: Colors.grey,
    child: SizedBox(
      height: 150,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _skeletonColumn(),
            _skeletonColumn(),
            _skeletonColumn(),
            _skeletonColumn(),
          ],
        ),
      ),
    ),
  );

  static Widget _skeletonColumn() {
    return Column(
      children: [
        Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.grey,
          ),
        ),
        SizedBox(height: 8),
        Container(
          width: 70,
          height: 16,
          color: Colors.grey,
        ),
      ],
    );
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 1.0);

    if (_cachedStories.isNotEmpty) {
      // Use cached raw stories but render a small initial slice immediately.
      _rawStories = _cachedStories;
      _buildInitialLightModels(_rawStories.take(_initialPrecacheCount).toList());
      // schedule background work to finish building & precaching
      _scheduleBackgroundWork();
    } else {
      // fresh fetch
      _fetchStories();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Start preloading images & timer only once when we have models and not already preloaded
    if (_lightModelsNotifier.value.isNotEmpty && !_imagesPreloaded) {
      _imagesPreloaded = true;
      _startTimer();
      // start background precache once models are available
      _scheduleBackgroundWork();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _timer?.cancel();
    _pageController.dispose();
    _lightModelsNotifier.dispose();
    super.dispose();
  }

  /// Quick fetch to get trending movies + tv shows,
  /// build a tiny initial slice and show the UI right away.
  Future<void> _fetchStories({bool forceRefresh = false}) async {
    if (_cachedStories.isNotEmpty && !forceRefresh) {
      if (_rawStories != _cachedStories) {
        setState(() {
          _rawStories = _cachedStories;
        });
      }
      _buildInitialLightModels(_rawStories.take(_initialPrecacheCount).toList());
      _scheduleBackgroundWork();
      _startTimer();
      return;
    }

    try {
      // fetch trending movies and tv in parallel (these are the heavier network calls)
      final results = await Future.wait([
        tmdb.TMDBApi.fetchTrendingMovies(),
        tmdb.TMDBApi.fetchTrendingTVShows(),
      ]);

      final movies = results[0] as List<dynamic>;
      final tvShows = results[1] as List<dynamic>;

      // Build combined raw list (we keep raw for fallback / player)
      List<Map<String, dynamic>> rawList = [];

      // Convert movies quickly—no per-item trailer fetching here (that's background)
      for (var movie in movies) {
        try {
          final id = movie['id']?.toString() ?? '';
          final poster = movie['poster_path'] != null
              ? 'https://image.tmdb.org/t/p/w200${movie['poster_path']}'
              : 'https://source.unsplash.com/random/100x100/?movie';
          final title = (movie['title']?.toString() ?? movie['original_title']?.toString() ?? 'Untitled').trim();

          rawList.add({
            'id': id,
            'name': title,
            'imageUrl': poster,
            'videoUrl': '', // placeholder, will fetch in background
            'title': title,
            'description': movie['overview'] ?? 'Watch this trailer',
            'type': 'movie',
            'raw': movie,
          });
        } catch (e) {
          // skip bad entries
        }
      }

      for (var tvShow in tvShows) {
        try {
          final id = tvShow['id']?.toString() ?? '';
          final poster = tvShow['poster_path'] != null
              ? 'https://image.tmdb.org/t/p/w200${tvShow['poster_path']}'
              : 'https://source.unsplash.com/random/100x100/?tvshow';
          final title = (tvShow['name'] ?? tvShow['original_name'] ?? 'TV Show').toString().trim();

          rawList.add({
            'id': id,
            'name': title,
            'imageUrl': poster,
            'videoUrl': '',
            'title': title,
            'description': tvShow['overview'] ?? 'Watch this trailer',
            'type': 'tvshow',
            'raw': tvShow,
          });
        } catch (e) {
          // skip
        }
      }

      // Save raw + cache
      setState(() {
        _rawStories = rawList;
        _cachedStories = rawList;
      });

      // Immediately render a very small initial slice so UI is responsive
      final initialSlice = _rawStories.take(_initialPrecacheCount).toList();
      _buildInitialLightModels(initialSlice);

      // Eagerly precache the initial small set (safe, small number)
      for (var s in initialSlice) {
        final thumb = (s['imageUrl'] as String?) ?? '';
        if (thumb.isNotEmpty) {
          precacheImage(CachedNetworkImageProvider(thumb), context);
        }
      }

      // Schedule background work to:
      //  - fetch trailers per item (throttled)
      //  - build full light models for the rest
      //  - precache remaining images (throttled)
      _scheduleBackgroundWork();

      // Start timer now we have something to show
      _startTimer();
    } catch (e) {
      debugPrint("Error fetching stories: $e");
      // create fallback placeholder stories
      final fallback = List.generate(5, (index) {
        final idx = index + 1;
        return {
          'id': 'fallback_$idx',
          'name': 'Movie $idx',
          'imageUrl': 'https://source.unsplash.com/random/100x100/?movie,$idx',
          'videoUrl': 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
          'title': 'Movie $idx',
          'description': 'Watch this trailer',
          'type': 'movie',
        };
      });

      setState(() {
        _rawStories = fallback;
        _cachedStories = fallback;
      });

      _buildInitialLightModels(_rawStories.take(_initialPrecacheCount).toList());
      _scheduleBackgroundWork();
      _startTimer();
    }
  }

  /// Build a tiny list quickly on main thread (only primitives) so UI can render fast.
  void _buildInitialLightModels(List<Map<String, dynamic>> rawSlice) {
    final small = rawSlice.map<Map<String, String>>((r) {
      return {
        'id': (r['id']?.toString() ?? ''),
        'name': (r['name']?.toString() ?? 'Untitled'),
        'imageUrl': (r['imageUrl']?.toString() ?? ''),
        'videoUrl': (r['videoUrl']?.toString() ?? ''), // may be empty for now
        'title': (r['title']?.toString() ?? ''),
        'description': (r['description']?.toString() ?? ''),
        'type': (r['type']?.toString() ?? ''),
      };
    }).toList();

    // merge into existing notifier value (overwrite first N)
    final merged = List<Map<String, String>>.from(_lightModelsNotifier.value);
    for (int i = 0; i < small.length; i++) {
      if (i < merged.length) {
        merged[i] = small[i];
      } else {
        merged.add(small[i]);
      }
    }
    _lightModelsNotifier.value = merged;
  }

  /// Schedules the background work that finishes light model creation, fetches trailers,
  /// and precaches images without blocking the UI. Throttled to avoid jank.
  void _scheduleBackgroundWork() {
    if (_backgroundWorkRunning || _isDisposed) return;
    _backgroundWorkRunning = true;

    Future.microtask(() async {
      try {
        // Step 1: ensure the full light-model list is present (strip raw -> primitives)
        final fullLight = _rawStories.map<Map<String, String>>((r) {
          return {
            'id': (r['id']?.toString() ?? ''),
            'name': (r['name']?.toString() ?? 'Untitled'),
            'imageUrl': (r['imageUrl']?.toString() ?? ''),
            'videoUrl': '', // we'll fetch/trickle-in trailers below
            'title': (r['title']?.toString() ?? ''),
            'description': (r['description']?.toString() ?? ''),
            'type': (r['type']?.toString() ?? ''),
          };
        }).toList();

        if (_isDisposed) return;
        _lightModelsNotifier.value = fullLight;

        // Step 2: Throttled loop to fetch trailers per item and update notifier as we get them.
        for (int i = 0; i < fullLight.length; i++) {
          if (_isDisposed) break;

          final item = fullLight[i];
          // Skip if we already have a videoUrl (e.g., fallback)
          if ((item['videoUrl'] ?? '').isNotEmpty) continue;

          // Throttle between network calls to avoid spikes
          await Future.delayed(Duration(milliseconds: _backgroundThrottleMs));
          if (_isDisposed) break;

          final idStr = item['id'] ?? '';
          if (idStr.isEmpty) continue;

          try {
            // Try to parse id as int, fallback to skip if not parseable
            final id = int.tryParse(idStr);
            if (id == null) continue;

            // Fetch trailers for this item (TV vs Movie)
            List<dynamic> videos = [];
            if (item['type'] == 'tvshow') {
              videos = await tmdb.TMDBApi.fetchTrailers(id, isTVShow: true);
            } else {
              videos = await tmdb.TMDBApi.fetchTrailers(id);
            }

            String videoUrl = '';
            if (videos.isNotEmpty) {
              final selectedVideo = videos.firstWhere(
                (v) =>
                    v['type'] == 'Trailer' ||
                    v['type'] == 'Teaser' ||
                    v['type'] == 'Clip' ||
                    v['type'] == 'Featurette',
                orElse: () => videos[0],
              );
              if (selectedVideo != null && selectedVideo['key'] != null) {
                videoUrl = 'https://www.youtube.com/watch?v=${selectedVideo['key']}';
              }
            }

            if (videoUrl.isEmpty) {
              // fallback sample video (cheap)
              videoUrl = 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4';
            }

            // Update the light model for this index — make a copy, mutate, then assign
            final current = List<Map<String, String>>.from(_lightModelsNotifier.value);
            if (i < current.length) {
              current[i] = {
                ...current[i],
                'videoUrl': videoUrl,
              };
              if (_isDisposed) break;
              _lightModelsNotifier.value = current;
            }
          } catch (e) {
            debugPrint('Error fetching trailers for item ${item['id']}: $e');
            // ignore and continue — the videoUrl will remain empty / fallback when opening story
          }
        }

        if (_isDisposed) return;

        // Step 3: Throttled background precache for remaining images (skip the first small set)
        final models = _lightModelsNotifier.value;
        for (int i = 0; i < models.length; i++) {
          if (_isDisposed) break;
          if (i < _initialPrecacheCount) continue; // already precached eagerly
          final thumb = models[i]['imageUrl'] ?? '';
          if (thumb.isEmpty) continue;

          try {
            await Future.delayed(Duration(milliseconds: _backgroundThrottleMs));
            if (_isDisposed) break;
            await precacheImage(CachedNetworkImageProvider(thumb), context);
          } catch (e) {
            // ignore single failures
            debugPrint('Precache failed for $thumb: $e');
          }
        }
      } catch (e) {
        debugPrint('Background stories work failed: $e');
      } finally {
        _backgroundWorkRunning = false;
      }
    });
  }

  void _startTimer() {
    _timer?.cancel();
    if (_lightModelsNotifier.value.isEmpty) return;

    _timer = Timer.periodic(const Duration(seconds: 7), (timer) {
      if (_pageController.hasClients && _lightModelsNotifier.value.isNotEmpty) {
        final int pageCount = (_lightModelsNotifier.value.length / _itemsPerPage).ceil();
        _currentIndex = (_currentIndex + 1) % max(1, pageCount);
        _pageController.animateToPage(
          _currentIndex,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  void _openStoryAtIndex(int index) {
    final models = _lightModelsNotifier.value;
    if (index < 0 || index >= models.length) return;

    final story = models[index];
    // The StoryPlayerScreen expects full list and index — we can convert light models to the expected raw shape
    final storiesForPlayer = models.map<Map<String, dynamic>>((m) {
      return {
        'id': m['id'],
        'name': m['name'],
        'imageUrl': m['imageUrl'],
        'videoUrl': m['videoUrl'] ?? '',
        'title': m['title'],
        'description': m['description'],
        'type': m['type'],
      };
    }).toList();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StoryPlayerScreen(
          videoUrl: story['videoUrl'] ?? '',
          storyTitle: story['title'] ?? story['name'] ?? '',
          storyDescription: story['description'] ?? '',
          durationSeconds: 30,
          stories: storiesForPlayer,
          currentIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return ValueListenableBuilder<List<Map<String, String>>>(
      valueListenable: _lightModelsNotifier,
      builder: (context, models, child) {
        if (models.isEmpty) {
          return _loadingWidget;
        }

        final int pageCount = (models.length / _itemsPerPage).ceil();
        return SizedBox(
          height: 150,
          child: PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: pageCount,
            itemBuilder: (context, pageIndex) {
              final int startIndex = pageIndex * _itemsPerPage;
              final int endIndex = min(startIndex + _itemsPerPage, models.length);
              final pageStories = models.sublist(startIndex, endIndex);

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: pageStories.asMap().entries.map((entry) {
                    final localIndex = entry.key;
                    final story = entry.value;
                    final globalIndex = startIndex + localIndex;
                    final imageUrl = story['imageUrl'] ?? '';
                    final name = story['name'] ?? '';

                    return RepaintBoundary(
                      child: GestureDetector(
                        key: ValueKey(imageUrl + name),
                        onTap: () => _openStoryAtIndex(globalIndex),
                        child: Column(
                          children: [
                            Container(
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border(
                                  top: BorderSide(color: Colors.pinkAccent, width: 3),
                                  bottom: BorderSide(color: Colors.pinkAccent, width: 3),
                                  left: BorderSide(color: Colors.pinkAccent, width: 3),
                                  right: BorderSide(color: Colors.pinkAccent, width: 3),
                                ),
                              ),
                              child: CircleAvatar(
                                radius: 35,
                                backgroundColor: Colors.transparent,
                                child: ClipOval(
                                  child: CachedNetworkImage(
                                    imageUrl: imageUrl,
                                    imageBuilder: (context, imageProvider) => Container(
                                      width: 70,
                                      height: 70,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        image: DecorationImage(
                                          image: imageProvider,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                    placeholder: (context, url) => const SizedBox(
                                      width: 70,
                                      height: 70,
                                      child: Center(child: CircularProgressIndicator()),
                                    ),
                                    errorWidget: (context, url, error) => const SizedBox(
                                      width: 70,
                                      height: 70,
                                      child: Icon(Icons.error),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: 70,
                              child: Text(
                                name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// home_screen_optimized.dart
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/tmdb_api.dart' as tmdb;
import 'package:movie_app/search_screen.dart';
import 'package:movie_app/profile_screen.dart';
import 'package:movie_app/categories_screen.dart';
import 'package:movie_app/downloads_screen.dart';
import 'package:movie_app/movie_detail_screen.dart';
import 'package:movie_app/mylist_screen.dart';
import 'package:movie_app/components/stories_section.dart';
import 'package:movie_app/components/reels_section.dart';
import 'package:movie_app/interactive_features_screen.dart';
import 'package:movie_app/components/song_of_movies_screen.dart';
import 'package:movie_app/sub_home_screen.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:movie_app/components/common_widgets.dart';

/// ---------------------------------------------------------------------------
/// Top-level compute functions
/// These must be top-level or static functions to be usable by `compute`.
/// They accept a single argument that is serializable (Map/List/primitive).
/// ---------------------------------------------------------------------------

/// Process featured results: merge movies & tv, normalize required fields, sort by popularity,
/// and return list of maps with only the fields we need on the UI (lightweight).
Future<List<Map<String, dynamic>>> _processFeaturedCompute(Map<String, dynamic> args) async {
  // args contains: {'movies': List, 'tv': List, 'limit': int}
  final movies = (args['movies'] as List<dynamic>? ?? <dynamic>[]).cast<Map<String, dynamic>>();
  final tv = (args['tv'] as List<dynamic>? ?? <dynamic>[]).cast<Map<String, dynamic>>();
  final int limit = args['limit'] as int? ?? 5;

  final List<Map<String, dynamic>> content = [];
  content.addAll(movies);
  content.addAll(tv);

  // Normalize & map to lightweight map
  final String imageBase = 'https://image.tmdb.org/t/p/w500';
  List<Map<String, dynamic>> normalized = content.map((raw) {
    final String title = (raw['title'] as String?)?.trim().isNotEmpty == true
        ? raw['title'] as String
        : (raw['name'] as String?)?.trim().isNotEmpty == true
            ? raw['name'] as String
            : 'Featured';
    final String releaseDate = (raw['release_date'] as String?)?.trim().isNotEmpty == true
        ? raw['release_date'] as String
        : (raw['first_air_date'] as String?)?.trim().isNotEmpty == true
            ? raw['first_air_date'] as String
            : 'Unknown';
    final String trailerUrl = (raw['trailer_url'] as String?)?.trim().isNotEmpty == true
        ? raw['trailer_url'] as String
        : (raw['trailer'] as String?)?.trim().isNotEmpty == true
            ? raw['trailer'] as String
            : 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';
    final String? backdropPath = raw['backdrop_path'] as String?;
    final String? posterPath = raw['poster_path'] as String?;
    final String imageUrl = (backdropPath?.isNotEmpty == true)
        ? '$imageBase$backdropPath'
        : (posterPath?.isNotEmpty == true)
            ? '$imageBase$posterPath'
            : 'https://via.placeholder.com/500x320';
    final List<int> genres = (raw['genre_ids'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList() ?? <int>[];
    final double rating = (raw['vote_average'] != null) ? double.tryParse(raw['vote_average'].toString()) ?? 0.0 : 0.0;
    final num popularity = (raw['popularity'] as num?) ?? 0;

    return <String, dynamic>{
      'title': title,
      'releaseDate': releaseDate,
      'trailerUrl': trailerUrl,
      'imageUrl': imageUrl,
      'genres': genres,
      'rating': rating,
      'popularity': popularity,
      'original': raw, // keep a reference to original payload if needed for detail screen
    };
  }).toList();

  // Sort descending by popularity
  normalized.sort((a, b) => (b['popularity'] as num).compareTo(a['popularity'] as num));

  if (normalized.length > limit) {
    return normalized.take(limit).toList();
  } else {
    return normalized;
  }
}

/// Merge lists and pick a random item (returns single normalized map or null).
Future<Map<String, dynamic>?> _mergeAndPickRandomCompute(Map<String, dynamic> args) async {
  // args: {'movies': List, 'tv': List, 'seed': int}
  final movies = (args['movies'] as List<dynamic>? ?? <dynamic>[]).cast<Map<String, dynamic>>();
  final tv = (args['tv'] as List<dynamic>? ?? <dynamic>[]).cast<Map<String, dynamic>>();
  final int seed = args['seed'] as int? ?? DateTime.now().millisecondsSinceEpoch;

  final List<Map<String, dynamic>> all = [];
  all.addAll(movies);
  all.addAll(tv);

  if (all.isEmpty) return null;

  final rng = Random(seed);
  final choice = all[rng.nextInt(all.length)];

  // Normalize minimal fields for MovieDetailScreen input (keep original payload too)
  final String imageBase = 'https://image.tmdb.org/t/p/w500';
  final String title = (choice['title'] as String?)?.trim().isNotEmpty == true
      ? choice['title'] as String
      : (choice['name'] as String?)?.trim().isNotEmpty == true
          ? choice['name'] as String
          : 'Random';
  final String releaseDate = (choice['release_date'] as String?)?.trim().isNotEmpty == true
      ? choice['release_date'] as String
      : (choice['first_air_date'] as String?)?.trim().isNotEmpty == true
          ? choice['first_air_date'] as String
          : 'Unknown';
  final String? backdropPath = choice['backdrop_path'] as String?;
  final String? posterPath = choice['poster_path'] as String?;
  final String imageUrl = (backdropPath?.isNotEmpty == true)
      ? '$imageBase$backdropPath'
      : (posterPath?.isNotEmpty == true)
          ? '$imageBase$posterPath'
          : 'https://via.placeholder.com/500x320';

  return <String, dynamic>{
    'title': title,
    'releaseDate': releaseDate,
    'imageUrl': imageUrl,
    'original': choice,
  };
}

/// Convert genres list to a short comma-separated string (used during processing)
String _genresToTextCompute(Map<String, dynamic> args) {
  final List<dynamic> genreIds = args['genreIds'] as List<dynamic>? ?? <dynamic>[];
  final Map<int, String> genreMap = const {
    28: "Action",
    12: "Adventure",
    16: "Animation",
    35: "Comedy",
    80: "Crime",
    18: "Drama",
    10749: "Romance",
    878: "Sci-Fi",
  };
  final List<String> names = genreIds.map((e) => genreMap[(e as num).toInt()] ?? 'Unknown').toList();
  return names.join(', ');
}

/// ---------------------------------------------------------------------------
/// Widgets (your UI preserved, optimized to use compute where heavy work happened)
/// ---------------------------------------------------------------------------

/// AnimatedBackground widget: Static gradient background with const and RepaintBoundary
class AnimatedBackground extends StatelessWidget {
  const AnimatedBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.redAccent, Colors.blueAccent],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SizedBox.expand(),
      ),
    );
  }
}

/// RandomMovieScreen widget: Displays a random movie or TV show with batched network calls
class RandomMovieScreen extends StatefulWidget {
  const RandomMovieScreen({super.key});

  @override
  RandomMovieScreenState createState() => RandomMovieScreenState();
}

class RandomMovieScreenState extends State<RandomMovieScreen> {
  Map<String, dynamic>? randomMovie;
  bool isLoading = true;
  int _seed = DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    fetchRandomMovie();
  }

  Future<void> fetchRandomMovie() async {
    setState(() => isLoading = true);
    try {
      final results = await Future.wait([
        tmdb.TMDBApi.fetchTrendingMovies(),
        tmdb.TMDBApi.fetchTrendingTVShows(),
      ]);
      // Offload merge & random pick to compute
      final Map<String, dynamic>? processed =
          await compute(_mergeAndPickRandomCompute, {'movies': results[0], 'tv': results[1], 'seed': _seed});
      if (!mounted) return;
      setState(() {
        randomMovie = processed != null ? (processed['original'] ?? processed) as Map<String, dynamic> : null;
        isLoading = false;
      });
    } catch (e) {
      debugPrint("Error fetching random content: $e");
      if (!mounted) return;
      setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: isLoading
          ? Shimmer.fromColors(
              baseColor: Colors.grey[800]!,
              highlightColor: Colors.grey[600]!,
              child: Container(
                color: Colors.grey[800]!,
                child: const Center(
                  child: Text(
                    'Loading Random Movie...',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            )
          : randomMovie == null
              ? const Center(child: Text('No content found'))
              : MovieDetailScreen(movie: randomMovie!),
    );
  }
}

/// FeaturedMovieCard widget: Optimized with lazy-loaded video and caching
class FeaturedMovieCard extends StatefulWidget {
  final String imageUrl;
  final String title;
  final String releaseDate;
  final String genresText; // precomputed genre string for fast rendering
  final double rating;
  final String trailerUrl;
  final bool isCurrentPage;
  final VoidCallback? onTap;

  const FeaturedMovieCard({
    super.key,
    required this.imageUrl,
    required this.title,
    required this.releaseDate,
    required this.genresText,
    required this.rating,
    required this.trailerUrl,
    required this.isCurrentPage,
    this.onTap,
  });

  @override
  FeaturedMovieCardState createState() => FeaturedMovieCardState();
}

class FeaturedMovieCardState extends State<FeaturedMovieCard> {
  bool isFavorite = false;
  bool showVideo = false;
  YoutubePlayerController? videoController;
  double _buttonScale = 1.0;

  @override
  void dispose() {
    videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    return GestureDetector(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(16)),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                child: showVideo && videoController != null
                    ? YoutubePlayer(
                        key: const ValueKey('video'),
                        controller: videoController!,
                        aspectRatio: 16 / 9,
                      )
                    : Hero(
                        tag: widget.imageUrl,
                        child: CachedNetworkImage(
                          key: const ValueKey('image'),
                          imageUrl: widget.imageUrl,
                          height: 320,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Shimmer.fromColors(
                            baseColor: Colors.grey[800]!,
                            highlightColor: Colors.grey[600]!,
                            child: Container(height: 320, color: Colors.grey[800]!),
                          ),
                          errorWidget: (context, url, error) => Container(
                            height: 320,
                            color: Colors.grey,
                            child: const Center(child: Icon(Icons.error, size: 50)),
                          ),
                        ),
                      ),
              ),
            ),
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      shadows: [
                        Shadow(
                          blurRadius: 4,
                          color: Colors.black,
                          offset: Offset(1, 1),
                        ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        'Release Date: ${widget.releaseDate}',
                        style: const TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          const Icon(Icons.star, color: Colors.yellow, size: 18),
                          const SizedBox(width: 4),
                          Text(
                            widget.rating.toStringAsFixed(1),
                            style: const TextStyle(color: Colors.white70, fontSize: 16),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Genres: ${widget.genresText}',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      GestureDetector(
                        onTapDown: (_) => setState(() => _buttonScale = 0.95),
                        onTapUp: (_) => setState(() => _buttonScale = 1.0),
                        onTapCancel: () => setState(() => _buttonScale = 1.0),
                        child: AnimatedScale(
                          scale: _buttonScale,
                          duration: const Duration(milliseconds: 100),
                          child: ElevatedButton.icon(
                            onPressed: () {
                              if (!showVideo && widget.trailerUrl.isNotEmpty) {
                                final videoId = YoutubePlayer.convertUrlToId(widget.trailerUrl);
                                if (videoId != null) {
                                  setState(() {
                                    videoController = YoutubePlayerController(
                                      initialVideoId: videoId,
                                      flags: const YoutubePlayerFlags(
                                        autoPlay: true,
                                        mute: false,
                                        hideControls: true,
                                      ),
                                    );
                                    showVideo = true;
                                  });
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid trailer URL')));
                                }
                              }
                            },
                            icon: const Icon(Icons.play_arrow, color: Colors.black),
                            label: const Text('Watch Trailer', style: TextStyle(color: Colors.black)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.all(Radius.circular(8)),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () => setState(() => isFavorite = !isFavorite),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: isFavorite ? settings.accentColor : Colors.white.withOpacity(0.2),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            isFavorite ? Icons.favorite : Icons.favorite_border,
                            color: isFavorite ? Colors.white : settings.accentColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (showVideo && videoController != null)
              Positioned(
                top: 10,
                right: 10,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () {
                    setState(() {
                      showVideo = false;
                      videoController?.pause();
                    });
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// FeaturedSlider widget: Optimized with debounced scrolling and compute-based preprocessing
class FeaturedSlider extends StatefulWidget {
  const FeaturedSlider({super.key});

  @override
  FeaturedSliderState createState() => FeaturedSliderState();
}

class FeaturedSliderState extends State<FeaturedSlider> {
  late PageController pageController;
  List<Map<String, dynamic>> featuredContent = [];
  int currentPage = 0;
  int pageCount = 0;
  bool isLoading = false;
  Timer? timer;
  Timer? _debounceTimer;
  static List<Map<String, dynamic>> _cachedProcessedContent = [];

  @override
  void initState() {
    super.initState();
    pageController = PageController();
    if (_cachedProcessedContent.isNotEmpty) {
      featuredContent = _cachedProcessedContent;
      pageCount = featuredContent.length;
      startTimer();
    } else {
      loadInitialContent();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Add listener once safely
      if (pageController.hasClients) {
        try {
          pageController.position.isScrollingNotifier.addListener(onScroll);
        } catch (_) {}
      }
    });
  }

  Future<void> loadInitialContent() async {
    if (isLoading) return;
    setState(() => isLoading = true);
    try {
      final results = await Future.wait([tmdb.TMDBApi.fetchFeaturedMovies(), tmdb.TMDBApi.fetchFeaturedTVShows()]);
      // Offload normalization & sorting to compute
      final processed = await compute(_processFeaturedCompute, {'movies': results[0], 'tv': results[1], 'limit': 5});
      if (!mounted) return;
      // Precompute small genresText string for each item using compute (optional, but cheap)
      final List<Map<String, dynamic>> withGenresText = [];
      for (final itm in processed) {
        final genres = itm['genres'] as List<int>? ?? <int>[];
        final genresText = await compute(_genresToTextCompute, {'genreIds': genres});
        final mapped = Map<String, dynamic>.from(itm);
        mapped['genresText'] = genresText;
        withGenresText.add(mapped);
      }

      setState(() {
        featuredContent = withGenresText;
        _cachedProcessedContent = withGenresText;
        pageCount = featuredContent.length;
        isLoading = false;
      });
      startTimer();
    } catch (e) {
      debugPrint("Error loading featured content: $e");
      if (!mounted) return;
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<List<Map<String, dynamic>>> fetchFeaturedContent({int limit = 5}) async {
    // This function still uses compute for heavier work
    try {
      final results = await Future.wait([tmdb.TMDBApi.fetchFeaturedMovies(), tmdb.TMDBApi.fetchFeaturedTVShows()]);
      final processed = await compute(_processFeaturedCompute, {'movies': results[0], 'tv': results[1], 'limit': limit});
      // add small genres text
      final List<Map<String, dynamic>> out = [];
      for (final itm in processed) {
        final genres = itm['genres'] as List<int>? ?? <int>[];
        final genresText = await compute(_genresToTextCompute, {'genreIds': genres});
        final mapped = Map<String, dynamic>.from(itm);
        mapped['genresText'] = genresText;
        out.add(mapped);
      }
      return out;
    } catch (e) {
      debugPrint("Error fetching featured content: $e");
      return [];
    }
  }

  void startTimer() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 20), (timer) {
      if (pageController.hasClients && pageCount > 0 && !pageController.position.isScrollingNotifier.value) {
        currentPage++;
        if (currentPage >= pageCount) {
          currentPage = 0;
          pageController.jumpToPage(0);
        } else {
          pageController.animateToPage(
            currentPage,
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOut,
          );
        }
      }
    });
  }

  void onScroll() {
    if (pageController.position.isScrollingNotifier.value) {
      timer?.cancel();
    } else if (_debounceTimer == null || !_debounceTimer!.isActive) {
      _debounceTimer = Timer(const Duration(milliseconds: 250), startTimer);
    }
  }

  Future<void> loadMoreContent() async {
    if (isLoading) return;
    setState(() => isLoading = true);
    final newContent = await fetchFeaturedContent(limit: 5);
    setState(() {
      featuredContent.addAll(newContent);
      _cachedProcessedContent = featuredContent;
      pageCount = featuredContent.length;
      isLoading = false;
    });
  }

  /// Placeholder while loading featured items
  Widget buildFeaturedPlaceholder() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[800]!,
      highlightColor: Colors.grey[600]!,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(16)),
              child: Container(
                height: 320,
                width: double.infinity,
                color: Colors.grey[800]!,
              ),
            ),
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    try {
      if (pageController.hasClients) {
        pageController.position.isScrollingNotifier.removeListener(onScroll);
      }
    } catch (_) {}
    timer?.cancel();
    _debounceTimer?.cancel();
    pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const String defaultImageUrl = 'https://via.placeholder.com/500x320';
    return SizedBox(
      height: 320,
      child: featuredContent.isEmpty
          ? buildFeaturedPlaceholder()
          : PageView.builder(
              controller: pageController,
              scrollDirection: Axis.vertical,
              itemCount: featuredContent.length,
              onPageChanged: (index) {
                setState(() => currentPage = index);
                if (index >= featuredContent.length - 2 && !isLoading) {
                  loadMoreContent();
                }
              },
              itemBuilder: (context, index) {
                final item = featuredContent[index];

                // Use preprocessed fields (very cheap on the UI thread)
                final String title = item['title'] as String? ?? 'Featured';
                final String releaseDate = item['releaseDate'] as String? ?? 'Unknown';
                final String trailerUrl = item['trailerUrl'] as String? ?? 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';
                final String imageUrl = (item['imageUrl'] as String?) ?? defaultImageUrl;
                final String genresText = item['genresText'] as String? ?? '';
                final double rating = (item['rating'] as num?)?.toDouble() ?? 0.0;

                return FeaturedMovieCard(
                  key: ValueKey(imageUrl),
                  imageUrl: imageUrl,
                  title: title,
                  releaseDate: releaseDate,
                  genresText: genresText,
                  rating: rating,
                  trailerUrl: trailerUrl,
                  isCurrentPage: index == currentPage,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => MovieDetailScreen(movie: item['original'] ?? item),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

/// HomeScreenMain widget: Optimized structure with extracted widgets
class HomeScreenMain extends StatefulWidget {
  final String? profileName;
  const HomeScreenMain({super.key, this.profileName});

  @override
  HomeScreenMainState createState() => HomeScreenMainState();
}

class HomeScreenMainState extends State<HomeScreenMain>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late AnimationController _textAnimationController;
  late Animation<double> _textFadeAnimation;
  final _subHomeScreenKey = GlobalKey<SubHomeScreenState>();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _textAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _textFadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _textAnimationController, curve: Curves.easeIn),
    );
    _textAnimationController.forward();
  }

  Future<void> refreshData() async {
    await _subHomeScreenKey.currentState?.refreshData();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final screenHeight = MediaQuery.of(context).size.height;

    return Selector<SettingsProvider, Color>(
      selector: (_, settings) => settings.accentColor,
      builder: (context, accentColor, child) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            automaticallyImplyLeading: false,
            backgroundColor: accentColor.withOpacity(0.1),
            elevation: 0,
            title: FadeTransition(
              opacity: _textFadeAnimation,
              child: Text(
                widget.profileName != null ? "Welcome, ${widget.profileName}" : "Movie App",
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            actions: const [
              _AppBarActions(), // uses search, list, person icons and navigates accordingly
            ],
          ),
          body: Stack(
            children: [
              // Background base gradient (fills entire screen)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        accentColor.withOpacity(0.18),
                        const Color(0xFF0B1220),
                      ],
                    ),
                  ),
                ),
              ),

              // Accent radial glow to match the sleek look (soft, centered)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.08, -0.4),
                        radius: 1.2,
                        colors: [
                          accentColor.withAlpha((0.20 * 255).round()),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 1.0],
                      ),
                    ),
                  ),
                ),
              ),

              // Main frosted content container positioned below the app bar
              Positioned.fill(
                top: kToolbarHeight + MediaQuery.of(context).padding.top,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Container(
                    decoration: BoxDecoration(
                      // outer radial tint + shadow to lift the frosted panel
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 1.6,
                        colors: [
                          accentColor.withAlpha((0.12 * 255).round()),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 1.0],
                      ),
                      borderRadius: const BorderRadius.all(Radius.circular(18)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.6),
                          blurRadius: 16,
                          spreadRadius: 2,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(18)),
                      child: Container(
                        // inner frosted panel (keeps the soft tint, border and subtle shadow)
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.03),
                          borderRadius: const BorderRadius.all(Radius.circular(18)),
                          border: Border.all(color: accentColor.withOpacity(0.06)),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withOpacity(0.16), blurRadius: 8, offset: const Offset(0, 4)),
                            BoxShadow(color: accentColor.withOpacity(0.02), blurRadius: 24, spreadRadius: 2),
                          ],
                        ),
                        child: Theme(
                          data: ThemeData.dark().copyWith(
                            scaffoldBackgroundColor: Colors.transparent,
                            textTheme: ThemeData.dark().textTheme,
                          ),
                          // keep the frosted card contents identical
                          child: _FrostedCard(
                            accentColor: accentColor,
                            screenHeight: screenHeight,
                            onRefresh: refreshData,
                            subHomeKey: _subHomeScreenKey,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            backgroundColor: accentColor,
            child: const Icon(Icons.shuffle),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (context) => const RandomMovieScreen()));
            },
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _textAnimationController.dispose();
    super.dispose();
  }
}

/// Extracted AppBar actions to reduce rebuilds
class _AppBarActions extends StatelessWidget {
  const _AppBarActions();

  @override
  Widget build(BuildContext context) {
    final accentColor = Provider.of<SettingsProvider>(context, listen: false).accentColor;
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.search, color: accentColor),
          onPressed: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const SearchScreen()));
          },
        ),
        IconButton(
          icon: Icon(Icons.list, color: accentColor),
          onPressed: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const MyListScreen()));
          },
        ),
        IconButton(
          icon: Icon(Icons.person, color: accentColor),
          onPressed: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const ProfileScreen()));
          },
        ),
      ],
    );
  }
}

/// First radial overlay (separate widget to avoid rebuilds on scroll)
class _RadialOverlayOne extends StatelessWidget {
  final Color accentColor;
  const _RadialOverlayOne({required this.accentColor});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(-0.06, -0.34),
            radius: 1.0,
            colors: [
              accentColor.withOpacity(0.5),
              const Color.fromARGB(255, 0, 0, 0),
            ],
            stops: const [0.0, 0.59],
          ),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Second radial overlay
class _RadialOverlayTwo extends StatelessWidget {
  final Color accentColor;
  const _RadialOverlayTwo({required this.accentColor});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.64, 0.3),
            radius: 1.0,
            colors: [
              accentColor.withOpacity(0.3),
              Colors.transparent,
            ],
            stops: const [0.0, 0.55],
          ),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// The frosted card that contains the scrollable content.
/// This widget is isolated (keeps RepaintBoundary to limit re-rasterization).
class _FrostedCard extends StatelessWidget {
  final Color accentColor;
  final double screenHeight;
  final Future<void> Function() onRefresh;
  final GlobalKey<SubHomeScreenState> subHomeKey;

  const _FrostedCard({
    required this.accentColor,
    required this.screenHeight,
    required this.onRefresh,
    required this.subHomeKey,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: RepaintBoundary(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.white.withOpacity(0.035), Colors.white.withOpacity(0.02)],
            ),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 16, offset: const Offset(0, 6)),
              BoxShadow(color: accentColor.withOpacity(0.02), blurRadius: 24, spreadRadius: 2),
            ],
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Colors.white.withOpacity(0.012), Colors.transparent, Colors.white.withOpacity(0.008)],
                        stops: const [0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                ),
              ),

              // Main content (kept same as your previous structure)
              RefreshIndicator(
                onRefresh: onRefresh,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: screenHeight),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      // No heavy setState here — keep logic minimal
                      return false;
                    },
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              StoriesSection(),
                              SizedBox(height: 10),
                              FeaturedSlider(),
                              SizedBox(height: 20),
                              _SongOfMoviesCard(),
                              SizedBox(height: 20),
                              SizedBox(
                                height: 430,
                                child: Opacity(
                                  opacity: 0.7,
                                  child: ReelsSection(),
                                ),
                              ),
                              SizedBox(height: 20),
                              SubHomeScreen(key: GlobalObjectKey('subHome')),
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
        ),
      ),
    );
  }
}

/// Extracted Song of Movies card to minimize rebuilds
class _SongOfMoviesCard extends StatelessWidget {
  const _SongOfMoviesCard();

  @override
  Widget build(BuildContext context) {
    final accentColor = Provider.of<SettingsProvider>(context, listen: false).accentColor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const SongOfMoviesScreen()));
          },
          child: Container(
            height: 180,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(24)),
              gradient: LinearGradient(
                colors: [accentColor.withOpacity(0.2), accentColor.withOpacity(0.2)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [BoxShadow(color: accentColor.withOpacity(0.6), blurRadius: 12, offset: const Offset(0, 6))],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(Icons.music_note, color: Colors.white.withOpacity(0.3), size: 120),
                Container(
                  decoration: const BoxDecoration(
                    borderRadius: BorderRadius.all(Radius.circular(24)),
                    gradient: LinearGradient(
                      colors: [Color.fromRGBO(0, 0, 0, 0.2), Colors.transparent],
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                    ),
                  ),
                ),
                const Positioned(
                  bottom: 20,
                  child: Text(
                    'Song of Movies',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      shadows: [
                        Shadow(blurRadius: 4, color: Colors.black54, offset: Offset(2, 2)),
                      ],
                    ),
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

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/tmdb_api.dart' as tmdb;
import 'package:movie_app/search_screen.dart';
import 'package:movie_app/profile_screen.dart';
import 'package:movie_app/movie_detail_screen.dart';
import 'package:movie_app/mylist_screen.dart';
import 'package:movie_app/components/stories_section.dart';
import 'package:movie_app/components/reels_section.dart';
import 'package:movie_app/components/song_of_movies_screen.dart';
import 'package:movie_app/sub_home_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:movie_app/components/common_widgets.dart';

/// HomeScreenLite widget: Lightweight version of HomeScreenMain with no blur effects
class HomeScreenLite extends StatefulWidget {
  final String? profileName;
  const HomeScreenLite({super.key, this.profileName});

  @override
  HomeScreenLiteState createState() => HomeScreenLiteState();
}

class HomeScreenLiteState extends State<HomeScreenLite>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late AnimationController _textAnimationController;
  late Animation<double> _textFadeAnimation;
  final _subHomeScreenKey = GlobalKey<SubHomeScreenState>();
  Color currentBackgroundColor = Colors.black;

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
    final accentColor = Provider.of<SettingsProvider>(context).accentColor;
    final screenHeight = MediaQuery.of(context).size.height;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: accentColor.withOpacity(0.2),
        elevation: 0,
        title: FadeTransition(
          opacity: _textFadeAnimation,
          child: Text(
            widget.profileName != null
                ? "Welcome, ${widget.profileName}"
                : "Movie App",
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        actions: const [
          _AppBarActions(),
        ],
      ),
      body: Stack(
        children: [
          AnimatedContainer(
            duration: const Duration(seconds: 1),
            color: currentBackgroundColor,
            width: double.infinity,
            height: double.infinity,
          ),
          RefreshIndicator(
            onRefresh: refreshData,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: screenHeight),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const StoriesSection(),
                        const SizedBox(height: 10),
                        FeaturedSliderLite(
                          onBackgroundColorChanged: (color) {
                            setState(() => currentBackgroundColor = color);
                          },
                        ),
                        const SizedBox(height: 20),
                        const _SongOfMoviesCardLite(),
                        const SizedBox(height: 20),
                        const SizedBox(
                          height: 430,
                          child: Opacity(
                            opacity: 0.7,
                            child: ReelsSection(),
                          ),
                        ),
                        const SizedBox(height: 20),
                        SubHomeScreen(key: _subHomeScreenKey),
                      ],
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
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const RandomMovieScreen()),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _textAnimationController.dispose();
    super.dispose();
  }
}

/// RandomMovieScreen widget: Displays a random movie or TV show
class RandomMovieScreen extends StatefulWidget {
  const RandomMovieScreen({super.key});

  @override
  RandomMovieScreenState createState() => RandomMovieScreenState();
}

class RandomMovieScreenState extends State<RandomMovieScreen> {
  Map<String, dynamic>? randomMovie;
  bool isLoading = true;

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
      final movies = results[0];
      final tvShows = results[1];
      List<Map<String, dynamic>> allContent = [];
      allContent.addAll(movies.cast<Map<String, dynamic>>());
      allContent.addAll(tvShows.cast<Map<String, dynamic>>());
      if (allContent.isNotEmpty) {
        allContent.shuffle();
        setState(() {
          randomMovie = allContent.first;
          isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Error fetching random content: $e");
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

/// Extracted AppBar actions to reduce rebuilds
class _AppBarActions extends StatelessWidget {
  const _AppBarActions();

  @override
  Widget build(BuildContext context) {
    final accentColor =
        Provider.of<SettingsProvider>(context, listen: false).accentColor;
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.search, color: accentColor),
          onPressed: () {
            Navigator.push(context,
                MaterialPageRoute(builder: (context) => const SearchScreen()));
          },
        ),
        IconButton(
          icon: Icon(Icons.list, color: accentColor),
          onPressed: () {
            Navigator.push(context,
                MaterialPageRoute(builder: (context) => const MyListScreen()));
          },
        ),
        IconButton(
          icon: Icon(Icons.person, color: accentColor),
          onPressed: () {
            Navigator.push(context,
                MaterialPageRoute(builder: (context) => const ProfileScreen()));
          },
        ),
      ],
    );
  }
}

/// Lightweight Song of Movies card
class _SongOfMoviesCardLite extends StatelessWidget {
  const _SongOfMoviesCardLite();

  @override
  Widget build(BuildContext context) {
    final accentColor =
        Provider.of<SettingsProvider>(context, listen: false).accentColor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: () {
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (context) => const SongOfMoviesScreen()));
          },
          child: Container(
            height: 180,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(24)),
              color: accentColor.withOpacity(0.2),
            ),
            child: const Center(
              child: Text(
                'Song of Movies',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Improved FeaturedMovieCardLite with modern UI
class FeaturedMovieCardLite extends StatelessWidget {
  final String imageUrl;
  final String title;
  final String releaseDate;
  final List<int> genres;
  final double rating;
  final VoidCallback? onTap;

  const FeaturedMovieCardLite({
    super.key,
    required this.imageUrl,
    required this.title,
    required this.releaseDate,
    required this.genres,
    required this.rating,
    this.onTap,
  });

  static const Map<int, String> _genreMap = {
    28: "Action",
    12: "Adventure",
    16: "Animation",
    35: "Comedy",
    80: "Crime",
    18: "Drama",
    10749: "Romance",
    878: "Sci-Fi",
  };

  String getGenresText() {
    return genres.map((id) => _genreMap[id] ?? "Unknown").join(', ');
  }

  List<Widget> buildGenreChips(Color accent) {
    final genreNames =
        genres.map((id) => _genreMap[id] ?? "Unknown").take(3).toList();
    return genreNames
        .map((g) => Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: accent.withOpacity(0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                g,
                style: TextStyle(color: Colors.white.withOpacity(0.95), fontSize: 12),
              ),
            ))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final accent = settings.accentColor;
    return GestureDetector(
      onTap: onTap,
      child: Material(
        color: Colors.transparent,
        child: Container(
          height: 320,
          margin: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.55),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Image
                Hero(
                  tag: imageUrl,
                  child: CachedNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => Shimmer.fromColors(
                      baseColor: Colors.grey[800]!,
                      highlightColor: Colors.grey[600]!,
                      child: Container(color: Colors.grey[800]!),
                    ),
                    errorWidget: (context, url, error) => Container(
                      color: Colors.grey,
                      child: const Center(child: Icon(Icons.error, size: 48)),
                    ),
                  ),
                ),

                // Dark gradient overlay for readability
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withOpacity(0.78),
                        Colors.black.withOpacity(0.45),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.45, 0.95],
                    ),
                  ),
                ),

                // Top-left rating badge
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.45),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: accent.withOpacity(0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.star, size: 16, color: Colors.yellow),
                        const SizedBox(width: 6),
                        Text(
                          rating.toStringAsFixed(1),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),

                // Center play button overlay
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.center,
                    child: Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.32),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Icon(Icons.play_arrow, size: 36, color: Colors.white.withOpacity(0.95)),
                    ),
                  ),
                ),

                // Bottom information panel
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title
                      Text(
                        title,
                        style: TextStyle(
                          color: accent,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          shadows: [
                            Shadow(blurRadius: 6, color: Colors.black54, offset: const Offset(1, 1)),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),

                      // Small meta row: release date + spacer + genres chips
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            releaseDate.isNotEmpty ? releaseDate : 'Unknown',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                          const Spacer(),
                          ...buildGenreChips(accent),
                        ],
                      ),

                      const SizedBox(height: 8),
                    ],
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

/// Updated FeaturedSliderLite with callback for background color
class FeaturedSliderLite extends StatefulWidget {
  final Function(Color)? onBackgroundColorChanged;
  const FeaturedSliderLite({super.key, this.onBackgroundColorChanged});

  @override
  FeaturedSliderLiteState createState() => FeaturedSliderLiteState();
}

class FeaturedSliderLiteState extends State<FeaturedSliderLite> {
  List<Map<String, dynamic>> featuredContent = [];
  int currentIndex = 0;
  Color backgroundColor = Colors.black;
  Timer? timer;
  bool isLoading = false;
  static List<Map<String, dynamic>> _cachedContent = [];

  @override
  void initState() {
    super.initState();
    if (_cachedContent.isNotEmpty) {
      featuredContent = _cachedContent;
      startTimer();
      extractDominantColor();
    } else {
      loadInitialContent();
    }
  }

  Future<void> loadInitialContent() async {
    if (isLoading) return;
    setState(() => isLoading = true);
    final content = await fetchFeaturedContent(limit: 5);
    setState(() {
      featuredContent = content;
      _cachedContent = content;
      isLoading = false;
    });
    if (featuredContent.isNotEmpty) {
      startTimer();
      extractDominantColor();
    }
  }

  Future<List<Map<String, dynamic>>> fetchFeaturedContent({int limit = 5}) async {
    try {
      final results = await Future.wait([
        tmdb.TMDBApi.fetchFeaturedMovies(),
        tmdb.TMDBApi.fetchTrendingTVShows(),
      ]);
      final movies = results[0];
      final tvShows = results[1];
      List<Map<String, dynamic>> content = [];
      content.addAll(movies.cast<Map<String, dynamic>>());
      content.addAll(tvShows.cast<Map<String, dynamic>>());
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

  void startTimer() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 20), (timer) {
      if (featuredContent.isNotEmpty) {
        setState(() {
          currentIndex = (currentIndex + 1) % featuredContent.length;
        });
        extractDominantColor();
      }
    });
  }

  Future<void> extractDominantColor() async {
    if (featuredContent.isEmpty) return;
    final item = featuredContent[currentIndex];
    final imageUrl = getImageUrl(item);
    try {
      final paletteGenerator = await PaletteGenerator.fromImageProvider(
        NetworkImage(imageUrl),
        size: const Size(200, 200),
        maximumColorCount: 8,
      );
      setState(() {
        backgroundColor =
            paletteGenerator.dominantColor?.color ?? Colors.black;
        widget.onBackgroundColorChanged?.call(backgroundColor);
      });
    } catch (e) {
      debugPrint("Error extracting color: $e");
      setState(() {
        backgroundColor = Colors.black;
        widget.onBackgroundColorChanged?.call(backgroundColor);
      });
    }
  }

  String getImageUrl(Map<String, dynamic> item) {
    const String defaultImageUrl = 'https://via.placeholder.com/500x320';
    final String? backdropPath = item['backdrop_path'] as String?;
    final String? posterPath = item['poster_path'] as String?;
    return (backdropPath?.isNotEmpty == true)
        ? 'https://image.tmdb.org/t/p/w500$backdropPath'
        : (posterPath?.isNotEmpty == true)
            ? 'https://image.tmdb.org/t/p/w500$posterPath'
            : defaultImageUrl;
  }

  Widget buildFeaturedPlaceholder() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[800]!,
      highlightColor: Colors.grey[600]!,
      child: Container(height: 320, color: Colors.grey[800]!),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return SizedBox(
      height: 320,
      child: isLoading || featuredContent.isEmpty
          ? buildFeaturedPlaceholder()
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Center(
                child: SizedBox(
                  width: screenWidth * 0.95,
                  child: FeaturedMovieCardLite(
                    imageUrl: getImageUrl(featuredContent[currentIndex]),
                    title: (featuredContent[currentIndex]['title'] as String?)?.trim().isNotEmpty ==
                            true
                        ? featuredContent[currentIndex]['title'] as String
                        : (featuredContent[currentIndex]['name'] as String?)?.trim().isNotEmpty ==
                                true
                            ? featuredContent[currentIndex]['name'] as String
                            : 'Featured',
                    releaseDate:
                        (featuredContent[currentIndex]['release_date'] as String?)
                                    ?.trim()
                                    .isNotEmpty ==
                                true
                            ? featuredContent[currentIndex]['release_date'] as String
                            : (featuredContent[currentIndex]['first_air_date'] as String?)
                                        ?.trim()
                                        .isNotEmpty ==
                                    true
                                ? featuredContent[currentIndex]['first_air_date'] as String
                                : 'Unknown',
                    genres: (featuredContent[currentIndex]['genre_ids'] as List<dynamic>?)
                            ?.map((e) => e as int)
                            .toList() ??
                        <int>[],
                    rating: (featuredContent[currentIndex]['vote_average'] != null)
                        ? double.tryParse(featuredContent[currentIndex]['vote_average'].toString()) ?? 0.0
                        : 0.0,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => MovieDetailScreen(movie: featuredContent[currentIndex]),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
    );
  }
}

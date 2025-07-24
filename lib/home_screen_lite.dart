import 'dart:async';
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
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:palette_generator/palette_generator.dart';

/// HomeScreenLite widget: Lightweight version of HomeScreenMain with no blur effects
class HomeScreenLite extends StatefulWidget {
  final String? profileName;
  const HomeScreenLite({super.key, this.profileName});

  @override
  HomeScreenLiteState createState() => HomeScreenLiteState();
}

class HomeScreenLiteState extends State<HomeScreenLite>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  int selectedIndex = 0;
  late AnimationController _textAnimationController;
  late Animation<double> _textFadeAnimation;
  final _subHomeScreenKey = GlobalKey<SubHomeScreenState>();
  Color currentBackgroundColor = Colors.black; // State for dynamic background

  static const _navItems = [
    BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
    BottomNavigationBarItem(icon: Icon(Icons.category), label: 'Categories'),
    BottomNavigationBarItem(icon: Icon(Icons.download), label: 'Downloads'),
    BottomNavigationBarItem(icon: Icon(Icons.live_tv), label: 'Interactive'),
  ];

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

  void onItemTapped(int index) {
    setState(() => selectedIndex = index);
    if (index == 1) {
      Navigator.push(context,
          MaterialPageRoute(builder: (context) => const CategoriesScreen()));
    } else if (index == 2) {
      Navigator.push(context,
          MaterialPageRoute(builder: (context) => const DownloadsScreen()));
    } else if (index == 3) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => InteractiveFeaturesScreen(
            isDarkMode: false,
            onThemeChanged: (bool newValue) {},
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final screenHeight = MediaQuery.of(context).size.height;
    return Selector<SettingsProvider, Color>(
      selector: (_, settings) => settings.accentColor,
      builder: (context, accentColor, child) {
        return Scaffold(
          // Removed static backgroundColor to allow AnimatedContainer to take over
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
              // Animated background layer covering the entire screen
              AnimatedContainer(
                duration: const Duration(seconds: 1), // Smooth 1-second transition
                color: currentBackgroundColor,
                width: double.infinity,
                height: double.infinity,
              ),
              // Content layer on top
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
          bottomNavigationBar: _BottomNavBarLite(
            accentColor: accentColor,
            selectedIndex: selectedIndex,
            onItemTapped: onItemTapped,
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
              color: accentColor.withOpacity(0.2), // Semi-transparent background
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

/// Lightweight BottomNavigationBar
class _BottomNavBarLite extends StatelessWidget {
  final Color accentColor;
  final int selectedIndex;
  final ValueChanged<int> onItemTapped;

  const _BottomNavBarLite({
    required this.accentColor,
    required this.selectedIndex,
    required this.onItemTapped,
  });

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      backgroundColor: Colors.black.withOpacity(0.8),
      selectedItemColor: Colors.white,
      unselectedItemColor: accentColor.withOpacity(0.6),
      currentIndex: selectedIndex,
      items: HomeScreenLiteState._navItems,
      onTap: onItemTapped,
    );
  }
}

/// Lightweight FeaturedMovieCard without video playback but with shadow effect
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

  String getGenresText() {
    return genres.map((id) => genreMap[id] ?? "Unknown").join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 10,
              spreadRadius: 2,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            children: [
              CachedNetworkImage(
                imageUrl: imageUrl,
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
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(8.0),
                  color: Colors.black.withOpacity(0.7),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: settings.accentColor,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Release: $releaseDate',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      Text(
                        'Genres: ${getGenresText()}',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Row(
                        children: [
                          const Icon(Icons.star, color: Colors.yellow, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            rating.toStringAsFixed(1),
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ],
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
  Color backgroundColor = Colors.black; // Local state for extraction
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
        tmdb.TMDBApi.fetchFeaturedTVShows(),
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
        size: const Size(100, 100), // Optimize for performance
        maximumColorCount: 8,
      );
      setState(() {
        backgroundColor = paletteGenerator.dominantColor?.color ?? Colors.black;
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
              padding: const EdgeInsets.all(16.0),
              child: Center(
                child: SizedBox(
                  width: screenWidth * 0.9,
                  child: FeaturedMovieCardLite(
                    imageUrl: getImageUrl(featuredContent[currentIndex]),
                    title: (featuredContent[currentIndex]['title'] as String?)?.trim().isNotEmpty == true
                        ? featuredContent[currentIndex]['title'] as String
                        : (featuredContent[currentIndex]['name'] as String?)?.trim().isNotEmpty == true
                            ? featuredContent[currentIndex]['name'] as String
                            : 'Featured',
                    releaseDate: (featuredContent[currentIndex]['release_date'] as String?)?.trim().isNotEmpty == true
                        ? featuredContent[currentIndex]['release_date'] as String
                        : (featuredContent[currentIndex]['first_air_date'] as String?)?.trim().isNotEmpty == true
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
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
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
          duration: const Duration(seconds: 1),
          color: currentBackgroundColor,
          width: double.infinity,
          height: double.infinity,
        ),
        Column(
          children: [
            TVFeaturedBanner(
              onBackgroundColorChanged: (color) {
                setState(() => currentBackgroundColor = color);
              },
            ),
            // ✅ Wrap SubHomeScreen with a scrollable layout
            Expanded(
              child:   SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                physics: const BouncingScrollPhysics(),
                child: SubHomeScreen(),
              ),
            ),
          ],
        ),
        _buildLeftNavigation(),
      ],
    ),
  );
}


  Widget _buildLeftNavigation() {
return Positioned(
  left: 0,
  top: 0,
  child: ClipRect(
    child: Container(
      width: 80,
      height: MediaQuery.of(context).size.height * 0.82,// 👈 Only blur up to banner height
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        backgroundBlendMode: BlendMode.darken,
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Column(
          children: [
            const SizedBox(height: 40),
            _navIcon(Icons.search, '/search'),
            _navIcon(Icons.home, null),
            _navIcon(Icons.category, '/categories'),
            _navIcon(Icons.download, '/downloads'),
            _navIcon(Icons.live_tv, '/interactive'),
            _navIcon(Icons.list, '/mylist'),
          ],
        ),
      ),
    ),
  ),
);
  }

  Widget _navIcon(IconData icon, String? route) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 30),
        onPressed:
            route == null ? null : () => Navigator.pushNamed(context, route),
      ),
    );
  }
}

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

  Future<List<Map<String, dynamic>>> fetchFeaturedContent({
    int limit = 5,
  }) async {
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
        size: const Size(100, 100),
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
    final backdrop = item['backdrop_path'] as String?;
    final poster = item['poster_path'] as String?;
    return backdrop != null && backdrop.isNotEmpty
        ? 'https://image.tmdb.org/t/p/w1280$backdrop'
        : (poster != null && poster.isNotEmpty
            ? 'https://image.tmdb.org/t/p/w1280$poster'
            : 'https://via.placeholder.com/500x320');
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.82;

    if (isLoading || featuredContent.isEmpty) {
      return Shimmer.fromColors(
        baseColor: Colors.grey[800]!,
        highlightColor: Colors.grey[600]!,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(30),
            ),
            color: Colors.grey[800]!,
          ),
        ),
      );
    }

    return _TVBannerContent(
      item: featuredContent[currentIndex],
      height: height,
    );
  }
}

class _TVBannerContent extends StatelessWidget {
  final Map<String, dynamic> item;
  final double height;

  const _TVBannerContent({required this.item, required this.height});

  String getImageUrl(Map<String, dynamic> item) {
    final backdrop = item['backdrop_path'] as String?;
    final poster = item['poster_path'] as String?;
    return backdrop != null && backdrop.isNotEmpty
        ? 'https://image.tmdb.org/t/p/w1280$backdrop'
        : (poster != null && poster.isNotEmpty
            ? 'https://image.tmdb.org/t/p/w1280$poster'
            : 'https://via.placeholder.com/500x320');
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = getImageUrl(item);
    final screenWidth = MediaQuery.of(context).size.width;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
      child: Stack(
        children: [
          CachedNetworkImage(
            imageUrl: imageUrl,
            width: double.infinity,
            height: height,
            fit: BoxFit.cover,
            placeholder:
                (_, __) => Shimmer.fromColors(
                  baseColor: Colors.grey[800]!,
                  highlightColor: Colors.grey[600]!,
                  child: Container(height: height, color: Colors.grey[800]!),
                ),
            errorWidget:
                (_, __, ___) => Container(
                  height: height,
                  color: Colors.grey,
                  child: const Center(child: Icon(Icons.error, size: 50)),
                ),
          ),
          Container(
            height: height,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black.withOpacity(0.9), Colors.transparent],
              ),
            ),
          ),
          Positioned(
            left: 100, // Adjusted to account for navigation bar width
            right: 20,
            bottom: 160, // Raised to make space for StoriesSection
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['title'] ?? item['name'] ?? 'Featured',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 38,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  item['overview'] ?? 'No description available.',
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    _bannerButton(
                      context,
                      icon: Icons.play_arrow,
                      label: 'Play',
                      bgColor: Colors.white,
                      textColor: Colors.black,
                      onPressed: () {
                        // TODO: Implement play functionality
                      },
                    ),
                    const SizedBox(width: 16),
                    _bannerButton(
                      context,
                      label: 'More Info',
                      bgColor: Colors.grey[700]!,
                      textColor: Colors.white,
                      onPressed: () {
                        if (item.containsKey('id') && item['id'] != null) {
                          Navigator.pushNamed(
                            context,
                            '/movie_detail',
                            arguments: item,
                          );
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
          Positioned(
            left: 100, // Align with content to avoid navigation bar
            right: 20,
            bottom: 20,
            child: SizedBox(height: 120, child: StoriesSection()),
          ),
        ],
      ),
    );
  }

  Widget _bannerButton(
    BuildContext context, {
    required String label,
    required Color bgColor,
    required Color textColor,
    required VoidCallback onPressed,
    IconData? icon,
  }) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon:
          icon != null ? Icon(icon, color: textColor) : const SizedBox.shrink(),
      label: Text(label, style: TextStyle(color: textColor)),
      style: ElevatedButton.styleFrom(
        backgroundColor: bgColor,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      ),
    );
  }
}

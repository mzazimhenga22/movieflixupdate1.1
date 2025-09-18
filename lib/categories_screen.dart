// categories_screen_optimized.dart
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/tmdb_api.dart' as tmdb;
import 'package:movie_app/movie_detail_screen.dart';
import 'package:movie_app/components/movie_card.dart';
import 'package:movie_app/components/common_widgets.dart';
import 'package:shimmer/shimmer.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// ---------------------------------------------------------------------------
/// Compute helpers (top-level so `compute` can call them)
/// ---------------------------------------------------------------------------

/// Convert genre id list to text
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

/// Lightweight normalization for category items (movies or tv shows).
/// Keeps only fields needed by UI and keeps original payload under 'original'.
Future<List<Map<String, dynamic>>> _processCategoryItems(Map<String, dynamic> args) async {
  // args: { 'items': List, 'limit': int (optional) }
  final List<dynamic> rawList = (args['items'] as List<dynamic>?) ?? <dynamic>[];
  final int limit = args['limit'] as int? ?? 0;
  const String imageBase = 'https://image.tmdb.org/t/p/w500';

  final List<Map<String, dynamic>> mapped = rawList.map<Map<String, dynamic>>((raw) {
    final Map<String, dynamic> r = Map<String, dynamic>.from(raw as Map);
    final String title = (r['title'] as String?)?.trim().isNotEmpty == true
        ? r['title'] as String
        : (r['name'] as String?)?.trim().isNotEmpty == true
            ? r['name'] as String
            : 'Untitled';
    final String releaseDate = (r['release_date'] as String?)?.trim().isNotEmpty == true
        ? r['release_date'] as String
        : (r['first_air_date'] as String?)?.trim().isNotEmpty == true
            ? r['first_air_date'] as String
            : 'Unknown';
    final String? backdropPath = r['backdrop_path'] as String?;
    final String? posterPath = r['poster_path'] as String?;
    final String imageUrl = (backdropPath?.isNotEmpty == true)
        ? '$imageBase$backdropPath'
        : (posterPath?.isNotEmpty == true)
            ? '$imageBase$posterPath'
            : 'https://via.placeholder.com/342x513';
    final List<int> genres = (r['genre_ids'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList() ?? <int>[];
    final double rating = (r['vote_average'] != null) ? double.tryParse(r['vote_average'].toString()) ?? 0.0 : 0.0;
    final num popularity = (r['popularity'] as num?) ?? 0;

    return <String, dynamic>{
      'id': r['id'],
      'title': title,
      'releaseDate': releaseDate,
      'imageUrl': imageUrl,
      'genres': genres,
      'rating': rating,
      'popularity': popularity,
      'original': r,
    };
  }).toList();

  // Sort by popularity descending (stable)
  mapped.sort((a, b) => (b['popularity'] as num).compareTo(a['popularity'] as num));

  if (limit > 0 && mapped.length > limit) {
    return mapped.take(limit).toList();
  }
  return mapped;
}

/// ---------------------------------------------------------------------------
/// UI: optimized categories + category content screen (sleeker layout)
/// ---------------------------------------------------------------------------

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

/// Reusable frosted container: faux frosted glass without real-time blur.
class FrostedContainer extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final Color accentColor;
  final EdgeInsetsGeometry? padding;

  const FrostedContainer({
    required this.child,
    required this.borderRadius,
    required this.accentColor,
    this.padding,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: RepaintBoundary(
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.035),
                Colors.white.withOpacity(0.02),
              ],
            ),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.45),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: accentColor.withOpacity(0.03),
                blurRadius: 22,
                spreadRadius: 2,
              ),
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
                        colors: [
                          Colors.white.withOpacity(0.012),
                          Colors.transparent,
                          Colors.white.withOpacity(0.008),
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  CategoriesScreenState createState() => CategoriesScreenState();
}

class CategoriesScreenState extends State<CategoriesScreen> {
  final List<Map<String, dynamic>> categories = const [
    {'name': 'Action', 'icon': Icons.local_fire_department},
    {'name': 'Comedy', 'icon': Icons.emoji_emotions},
    {'name': 'Drama', 'icon': Icons.theater_comedy},
    {'name': 'Horror', 'icon': Icons.warning},
    {'name': 'Sci-Fi', 'icon': Icons.science},
    {'name': 'Romance', 'icon': Icons.favorite},
    {'name': 'Animation', 'icon': Icons.animation},
    {'name': 'Thriller', 'icon': Icons.flash_on},
    {'name': 'Documentary', 'icon': Icons.book},
  ];

  void _onCategoryTap(BuildContext context, Map<String, dynamic> category) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.black.withOpacity(0.55),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.white.withOpacity(0.125)),
          ),
          title: Text(
            "Select Content Type",
            style: TextStyle(color: settings.accentColor, fontWeight: FontWeight.bold),
          ),
          content: const Text(
            "Choose whether to see Movies or TV Shows.",
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => CategoryContentScreen(
                      categoryName: category['name'],
                      contentType: "Movies",
                    ),
                  ),
                );
              },
              child: Text("Movies", style: TextStyle(color: settings.accentColor)),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => CategoryContentScreen(
                      categoryName: category['name'],
                      contentType: "TV Shows",
                    ),
                  ),
                );
              },
              child: Text("TV Shows", style: TextStyle(color: settings.accentColor)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Use Selector so we only rebuild when accentColor changes
    return Selector<SettingsProvider, Color>(
      selector: (_, s) => s.accentColor,
      builder: (context, accentColor, child) {
        final screenHeight = MediaQuery.of(context).size.height;
        return Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            automaticallyImplyLeading: false,
            backgroundColor: Colors.transparent,
            elevation: 0,
            centerTitle: true,
            // KEEP THE SAME APP BAR CONTENT (title "Categories")
            title: Text(
              'Categories',
              style: TextStyle(fontWeight: FontWeight.bold, color: accentColor),
            ),
          ),
          body: Stack(
            children: [
              // background
              const AnimatedBackground(),
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-0.06, -0.34),
                      radius: 1.0,
                      colors: [accentColor.withOpacity(0.5), const Color(0xFF000000)],
                      stops: const [0.0, 0.59],
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0.64, 0.3),
                      radius: 1.0,
                      colors: [accentColor.withOpacity(0.28), Colors.transparent],
                      stops: const [0.0, 0.55],
                    ),
                  ),
                ),
              ),

              // Sleek foreground card positioned under AppBar
              Positioned.fill(
                top: kToolbarHeight + MediaQuery.of(context).padding.top,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.all(Radius.circular(18)),
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 1.6,
                        colors: [accentColor.withOpacity(0.12), Colors.transparent],
                        stops: const [0.0, 1.0],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.6),
                          blurRadius: 18,
                          spreadRadius: 2,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: FrostedContainer(
                      borderRadius: BorderRadius.circular(18),
                      accentColor: accentColor,
                      padding: const EdgeInsets.all(0),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: screenHeight),
                        // content area with subtle padding and a sleek grid
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 14.0),
                          child: GridView.builder(
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.only(top: 4, bottom: 12),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              crossAxisSpacing: 14.0,
                              mainAxisSpacing: 14.0,
                              childAspectRatio: 3 / 2,
                            ),
                            itemCount: categories.length,
                            itemBuilder: (context, index) {
                              final category = categories[index];
                              return InkWell(
                                onTap: () => _onCategoryTap(context, category),
                                borderRadius: BorderRadius.circular(14.0),
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14.0),
                                    gradient: LinearGradient(
                                      colors: [accentColor.withOpacity(0.14), accentColor.withOpacity(0.26)],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    border: Border.all(color: Colors.white.withOpacity(0.04)),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.25),
                                        blurRadius: 8,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Container(
                                        width: 56,
                                        height: 56,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.white.withOpacity(0.04),
                                          border: Border.all(color: Colors.white10),
                                        ),
                                        child: Icon(category['icon'], size: 28.0, color: accentColor),
                                      ),
                                      const SizedBox(height: 10.0),
                                      Text(
                                        category['name'],
                                        style: const TextStyle(fontSize: 15.0, fontWeight: FontWeight.w700, color: Colors.white),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class CategoryContentScreen extends StatefulWidget {
  final String categoryName;
  final String contentType;

  const CategoryContentScreen({
    super.key,
    required this.categoryName,
    required this.contentType,
  });

  @override
  State<CategoryContentScreen> createState() => _CategoryContentScreenState();
}

class _CategoryContentScreenState extends State<CategoryContentScreen> {
  static final Map<String, List<Map<String, dynamic>>> _categoryCache = {};
  bool _loading = false;

  Future<List<Map<String, dynamic>>> _fetchAndProcess() async {
    final cacheKey = '${widget.contentType}_${widget.categoryName}';
    if (_categoryCache.containsKey(cacheKey)) {
      return _categoryCache[cacheKey]!;
    }

    if (mounted) setState(() => _loading = true);
    try {
      final raw = (widget.contentType == "Movies")
          ? await tmdb.TMDBApi.fetchCategoryMovies(widget.categoryName)
          : await tmdb.TMDBApi.fetchCategoryTVShows(widget.categoryName);

      // Offload mapping & sorting to compute (keeps UI thread snappy)
      final processed = await compute(_processCategoryItems, {'items': raw, 'limit': 0});

      // Precompute genresText for first N items (cheap, but done off main thread too if needed).
      final List<Map<String, dynamic>> withGenresText = [];
      for (final item in processed) {
        final genres = item['genres'] as List<dynamic>? ?? <dynamic>[];
        // Use compute for genre->text conversion (fast)
        final genresText = await compute(_genresToTextCompute, {'genreIds': genres});
        final mapped = Map<String, dynamic>.from(item);
        mapped['genresText'] = genresText;
        withGenresText.add(mapped);
      }

      _categoryCache[cacheKey] = withGenresText;
      return withGenresText;
    } catch (e) {
      debugPrint('Category fetch/process error: $e');
      return [];
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget buildMovieCardPlaceholder() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: Container(
        margin: const EdgeInsets.all(8.0),
        decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(12)),
        child: Column(
          children: [
            Expanded(
              child: Container(decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(12))),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                children: [
                  Container(width: 80, height: 10, color: Colors.grey[400]),
                  const SizedBox(height: 4),
                  Container(width: 40, height: 10, color: Colors.grey[400]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = Provider.of<SettingsProvider>(context).accentColor;
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        automaticallyImplyLeading: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        // KEEP THE SAME APP BAR CONTENT (title shows category & type)
        title: Text('${widget.categoryName} - ${widget.contentType}', style: TextStyle(fontWeight: FontWeight.bold, color: accentColor)),
      ),
      body: Stack(
        children: [
          const AnimatedBackground(),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.06, -0.34),
                  radius: 1.0,
                  colors: [accentColor.withOpacity(0.5), const Color(0xFF000000)],
                  stops: const [0.0, 0.59],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.64, 0.3),
                  radius: 1.0,
                  colors: [accentColor.withOpacity(0.28), Colors.transparent],
                  stops: const [0.0, 0.55],
                ),
              ),
            ),
          ),
          Positioned.fill(
            top: kToolbarHeight + MediaQuery.of(context).padding.top,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(18)),
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.6,
                    colors: [accentColor.withOpacity(0.12), Colors.transparent],
                    stops: const [0.0, 1.0],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.6),
                      blurRadius: 18,
                      spreadRadius: 2,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: FrostedContainer(
                  borderRadius: BorderRadius.circular(18),
                  accentColor: accentColor,
                  padding: const EdgeInsets.all(0),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: screenHeight),
                    child: FutureBuilder<List<Map<String, dynamic>>>(
                      future: _fetchAndProcess(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting || _loading) {
                          // show placeholders
                          return GridView.builder(
                            padding: const EdgeInsets.all(16.0),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 0.7,
                            ),
                            itemCount: 6,
                            itemBuilder: (context, index) => buildMovieCardPlaceholder(),
                          );
                        }

                        if (snapshot.hasError) {
                          return Center(child: Text('Error: ${snapshot.error}', style: const TextStyle(color: Colors.white)));
                        }

                        final items = snapshot.data ?? [];
                        if (items.isEmpty) {
                          return const Center(child: Text('No content available.', style: TextStyle(color: Colors.white70)));
                        }

                        // Precache first few images (non-blocking)
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          final toPrecache = items.take(6).map((e) => e['imageUrl'] as String? ?? '').where((u) => u.isNotEmpty);
                          for (final url in toPrecache) {
                            try {
                              precacheImage(CachedNetworkImageProvider(url), context);
                            } catch (_) {}
                          }
                        });

                        return GridView.builder(
                          padding: const EdgeInsets.all(16.0),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.7,
                          ),
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final item = items[index];
                            // MovieCard expects original payload; pass it along.
                            final original = item['original'] as Map<String, dynamic>? ?? item;
                            return MovieCard.fromJson(
                              original,
                              onTap: () {
                                Navigator.push(context, MaterialPageRoute(builder: (context) => MovieDetailScreen(movie: original)));
                              },
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/tmdb_api.dart' as tmdb;
import 'package:movie_app/movie_detail_screen.dart';
import 'package:movie_app/components/movie_card.dart';
import 'recommended_movies_screen.dart';

/// SubHomeScreen widget: mixes movies + TV shows in Recommended,
/// resilient to multiple TMDB wrapper response shapes.
/// Adds provider rows: Netflix, HBO, Amazon (each provider's items only).
///
/// Performance-minded:
/// - Load trending + recommended first (blocking),
/// - Kick off provider fetches after first frame so initial render is snappy,
/// - Limit provider previews to a small number (previewLimit).
class SubHomeScreen extends StatefulWidget {
  const SubHomeScreen({super.key});

  @override
  SubHomeScreenState createState() => SubHomeScreenState();
}

class SubHomeScreenState extends State<SubHomeScreen>
    with AutomaticKeepAliveClientMixin {
  final ScrollController trendingController = ScrollController();

  // Trending contains trending items (movies/tv)
  final List<dynamic> trendingMovies = [];

  // Provider rows (each contains items from that provider only)
  final List<dynamic> netflixItems = [];
  final List<dynamic> hbomaxItems = [];
  final List<dynamic> amazonItems = [];

  // Recommended contains mixed media (movies + tv shows)
  final List<dynamic> recommendedItems = [];

  bool isLoadingTrending = false;
  bool isLoadingNetflix = false;
  bool isLoadingHbo = false;
  bool isLoadingAmazon = false;
  bool isLoadingRecommended = false;

  Timer? _debounceTimer;

  // pagination for recommended results
  int recommendedPage = 1;

  // how many preview items to show per provider row (keeps UI light)
  static const int previewLimit = 10;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Fetch minimal blocking data first (trending + recommended),
    // provider rows will be fetched after first frame to avoid jank.
    fetchInitialData();
    // Kick provider fetches after first frame (non-blocking).
    SchedulerBinding.instance.addPostFrameCallback((_) {
      // do not await — fire & forget so UI stays responsive
      fetchProviderRows();
    });
    trendingController.addListener(onScrollTrending);
  }

  Future<void> fetchInitialData() async {
    // Only wait for the essentials so the first frame isn't delayed.
    await Future.wait([
      fetchTrendingMovies(),
      fetchRecommendedItems(page: 1),
    ]);
  }

  /// Helper: safely extracts a List from many possible response shapes.
  List<dynamic> _extractList(dynamic response) {
    if (response == null) return <dynamic>[];

    // If it's already a list
    if (response is List) {
      return List<dynamic>.from(response);
    }

    // If it's a map, try known keys
    if (response is Map) {
      // Common TMDB wrappers
      if (response['results'] is List) {
        return List<dynamic>.from(response['results'] as List);
      }

      // If the wrapper returns separate 'movies' and 'tv'
      final List<dynamic> out = [];
      if (response['movies'] is List) {
        out.addAll(List<dynamic>.from(response['movies'] as List));
      }
      if (response['tv'] is List) {
        out.addAll(List<dynamic>.from(response['tv'] as List));
      }
      if (out.isNotEmpty) return out;

      // nested shapes: { data: { results: [...] } }
      if (response['data'] is Map && response['data']['results'] is List) {
        return List<dynamic>.from(response['data']['results'] as List);
      }

      // fallback: return the first List value found in the map
      for (final val in response.values) {
        if (val is List) return List<dynamic>.from(val);
      }
    }

    // otherwise return empty
    return <dynamic>[];
  }

  Future<void> fetchTrendingMovies() async {
    if (isLoadingTrending) return;
    setState(() => isLoadingTrending = true);
    try {
      final dynamic resp = await tmdb.TMDBApi.fetchTrendingMovies();
      final List<dynamic> items = _extractList(resp);

      if (items.isNotEmpty) {
        // only update once
        setState(() {
          trendingMovies.addAll(items);
        });
      }
    } catch (e, st) {
      debugPrint('fetchTrendingMovies error: $e\n$st');
    } finally {
      setState(() => isLoadingTrending = false);
    }
  }

  /// Fetch provider rows (Netflix, HBO, Amazon). Each provider is NOT mixed with others.
  /// Runs in background after initial render to reduce jank.
  Future<void> fetchProviderRows() async {
    // Run each provider fetch in parallel but do not block the UI thread.
    // We await them so errors are caught, but the call was scheduled post-frame.
    try {
      await Future.wait([
        fetchNetflixRow(),
        fetchHbomaxRow(),
        fetchAmazonRow(),
      ]);
    } catch (e) {
      // swallow to avoid unhandled exceptions in post-frame
      debugPrint('fetchProviderRows error: $e');
    }
  }

  Future<void> fetchNetflixRow({int page = 1}) async {
    if (isLoadingNetflix) return;
    setState(() => isLoadingNetflix = true);

    try {
      final movieResp =
          await tmdb.TMDBApi.fetchNetflixMovies(region: 'US', page: page);
      final tvResp =
          await tmdb.TMDBApi.fetchNetflixTVShows(region: 'US', page: page);

      final movies = _extractList(movieResp);
      final tvs = _extractList(tvResp);

      // combine but only keep up to previewLimit to reduce memory & UI work
      final combined = [...movies, ...tvs];
      final deduped = _dedupeAndLimit(combined, previewLimit);

      // single setState update
      setState(() {
        netflixItems
          ..clear()
          ..addAll(deduped);
      });
    } catch (e, st) {
      debugPrint('fetchNetflixRow error: $e\n$st');
    } finally {
      setState(() => isLoadingNetflix = false);
    }
  }

  Future<void> fetchHbomaxRow({int page = 1}) async {
    if (isLoadingHbo) return;
    setState(() => isLoadingHbo = true);

    try {
      final movieResp =
          await tmdb.TMDBApi.fetchHbomaxMovies(region: 'US', page: page);
      final tvResp =
          await tmdb.TMDBApi.fetchHbomaxTVShows(region: 'US', page: page);

      final movies = _extractList(movieResp);
      final tvs = _extractList(tvResp);
      final combined = [...movies, ...tvs];
      final deduped = _dedupeAndLimit(combined, previewLimit);

      setState(() {
        hbomaxItems
          ..clear()
          ..addAll(deduped);
      });
    } catch (e, st) {
      debugPrint('fetchHbomaxRow error: $e\n$st');
    } finally {
      setState(() => isLoadingHbo = false);
    }
  }

  Future<void> fetchAmazonRow({int page = 1}) async {
    if (isLoadingAmazon) return;
    setState(() => isLoadingAmazon = true);

    try {
      final movieResp =
          await tmdb.TMDBApi.fetchAmazonMovies(region: 'US', page: page);
      final tvResp =
          await tmdb.TMDBApi.fetchAmazonTVShows(region: 'US', page: page);

      final movies = _extractList(movieResp);
      final tvs = _extractList(tvResp);
      final combined = [...movies, ...tvs];
      final deduped = _dedupeAndLimit(combined, previewLimit);

      setState(() {
        amazonItems
          ..clear()
          ..addAll(deduped);
      });
    } catch (e, st) {
      debugPrint('fetchAmazonRow error: $e\n$st');
    } finally {
      setState(() => isLoadingAmazon = false);
    }
  }

  /// small helper to dedupe by id and limit results to [limit]
  List<dynamic> _dedupeAndLimit(List<dynamic> source, int limit) {
    final seen = <dynamic>{};
    final out = <dynamic>[];
    for (final it in source) {
      if (out.length >= limit) break;
      if (it is Map && it.containsKey('id')) {
        final id = it['id'];
        if (id != null && !seen.contains(id)) {
          seen.add(id);
          out.add(it);
        }
      } else if (it != null) {
        out.add(it);
      }
    }
    return out;
  }

  /// Fetch recommended (mixed movies + tv). Uses the TMDBApi.fetchRecommendedMixed function.
  Future<void> fetchRecommendedItems({int page = 1}) async {
    if (isLoadingRecommended) return;
    setState(() => isLoadingRecommended = true);
    try {
      final dynamic resp = await tmdb.TMDBApi.fetchRecommendedMixed(page: page);
      // TMDBApi.fetchRecommendedMixed returns {'results': [...], 'total_pages': N}
      final List<dynamic> items = _extractList(resp);

      // dedupe by id when possible (extra safety)
      final List<dynamic> deduped = <dynamic>[];
      final Set<dynamic> seenIds = <dynamic>{};

      for (final entry in items) {
        if (entry is Map && entry.containsKey('id')) {
          final id = entry['id'];
          if (id != null && !seenIds.contains(id)) {
            seenIds.add(id);
            deduped.add(entry);
          }
        } else {
          deduped.add(entry);
        }
      }

      setState(() {
        if (page <= 1) {
          recommendedItems
            ..clear()
            ..addAll(deduped);
        } else {
          recommendedItems.addAll(deduped);
        }
        recommendedPage = page;
      });
    } catch (e, st) {
      debugPrint('fetchRecommendedItems error: $e\n$st');
    } finally {
      setState(() => isLoadingRecommended = false);
    }
  }

  void onScrollTrending() {
    // debounce to avoid spamming requests while scrolling
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      if (!trendingController.hasClients) return;
      final pos = trendingController.position;
      if (pos.extentAfter < 200 && !isLoadingTrending) {
        fetchTrendingMovies();
      }
    });
  }

  Future<void> refreshData() async {
    setState(() {
      trendingMovies.clear();
      netflixItems.clear();
      hbomaxItems.clear();
      amazonItems.clear();
      recommendedItems.clear();
      recommendedPage = 1;
    });
    await fetchInitialData();
    // schedule provider fetches again after refresh
    SchedulerBinding.instance.addPostFrameCallback((_) {
      fetchProviderRows();
    });
  }

  Widget buildMovieCardPlaceholder({double width = 120}) {
    return Container(
      width: width,
      margin: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Colors.grey[800]!,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Column(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey[900]!,
                borderRadius: const BorderRadius.all(Radius.circular(12)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                Container(width: 80, height: 10, color: Colors.grey[900]!),
                const SizedBox(height: 4),
                Container(width: 40, height: 10, color: Colors.grey[900]!),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Horizontal provider row. Title color is passed so we can use app accentColor.
  Widget _buildHorizontalRow(String title, List<dynamic> items, bool isLoading, Color titleColor) {
    final int displayCount = min(items.length, previewLimit);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Text(
            title,
            style: TextStyle(
              color: titleColor,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (isLoading && items.isEmpty)
          SizedBox(
            height: 160,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: 5,
              itemBuilder: (context, index) => buildMovieCardPlaceholder(),
            ),
          )
        else
          SizedBox(
            height: 160,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemExtent: 136,
              itemCount: displayCount,
              itemBuilder: (context, index) {
                final dynamic item = items[index];
                if (item == null || item is! Map) return const SizedBox();
                final posterPath = item['poster_path'] as String?;
                final posterUrl = (posterPath != null && posterPath.isNotEmpty)
                    ? 'https://image.tmdb.org/t/p/w342$posterPath'
                    : '';
                final titleText = (item['title'] ?? item['name'])?.toString() ?? 'No Title';
                final vote = item['vote_average'];
                final rating = vote != null ? double.tryParse(vote.toString()) : null;

                return RepaintBoundary(
                  child: MovieCard(
                    imageUrl: posterUrl,
                    title: titleText,
                    rating: rating,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => MovieDetailScreen(
                            movie: Map<String, dynamic>.from(item),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget buildTrendingMovies() {
    if (trendingMovies.isEmpty && isLoadingTrending) {
      return SizedBox(
        height: 240,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: 5,
          itemBuilder: (context, index) => buildMovieCardPlaceholder(),
        ),
      );
    }

    return SizedBox(
      height: 240,
      child: ListView.builder(
        controller: trendingController,
        scrollDirection: Axis.horizontal,
        itemExtent: 136,
        itemCount: trendingMovies.length + (isLoadingTrending ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == trendingMovies.length) return buildMovieCardPlaceholder();

          final dynamic movie = trendingMovies[index];
          if (movie == null || movie is! Map) return const SizedBox();

          final posterPath = movie['poster_path'] as String?;
          final posterUrl = (posterPath != null && posterPath.isNotEmpty)
              ? 'https://image.tmdb.org/t/p/w342$posterPath'
              : '';

          final title = (movie['title'] ?? movie['name'])?.toString() ?? 'No Title';
          final vote = movie['vote_average'];
          final rating = vote != null ? double.tryParse(vote.toString()) : null;

          return RepaintBoundary(
            child: MovieCard(
              imageUrl: posterUrl,
              title: title,
              rating: rating,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => MovieDetailScreen(
                      movie: Map<String, dynamic>.from(movie),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget buildRecommendedMovies() {
    if (recommendedItems.isEmpty && isLoadingRecommended) {
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.67,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        itemCount: 6,
        itemBuilder: (context, index) => buildMovieCardPlaceholder(),
      );
    }

    final int previewCount = min(recommendedItems.length, 6);

    return Column(
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 0.67,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
          ),
          itemCount: previewCount,
          itemBuilder: (context, index) {
            final dynamic item = recommendedItems[index];
            if (item == null || item is! Map) return const SizedBox();

            final posterPath = item['poster_path'] as String?;
            final posterUrl = (posterPath != null && posterPath.isNotEmpty)
                ? 'https://image.tmdb.org/t/p/w342$posterPath'
                : '';

            final title = (item['title'] ?? item['name'])?.toString() ?? 'No Title';
            final vote = item['vote_average'];
            final rating = vote != null ? double.tryParse(vote.toString()) : null;

            return RepaintBoundary(
              child: MovieCard(
                imageUrl: posterUrl,
                title: title,
                rating: rating,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => MovieDetailScreen(
                        movie: Map<String, dynamic>.from(item),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
        TextButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const RecommendedMoviesScreen()),
            );
          },
          child: const Text('See All'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Consumer<SettingsProvider>(
      builder: (context, settings, child) {
        final accent = settings.accentColor;
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Trending
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(
                  'Trending',
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              buildTrendingMovies(),
              const SizedBox(height: 16),

              // Provider rows: Netflix, HBO, Amazon (titles use accent color)
              _buildHorizontalRow('Netflix', netflixItems, isLoadingNetflix, accent),
              _buildHorizontalRow('HBO / HBOMax', hbomaxItems, isLoadingHbo, accent),
              _buildHorizontalRow('Amazon Prime', amazonItems, isLoadingAmazon, accent),

              const SizedBox(height: 16),

              // Recommended (mixed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(
                  'Recommended',
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              buildRecommendedMovies(),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    trendingController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }
}
 
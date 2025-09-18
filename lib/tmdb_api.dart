import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart'; // for compute
import 'package:http/http.dart' as http;

/// NOTE:
/// This file was updated to offload JSON decoding to a background isolate
/// using `compute()` to avoid blocking the main isolate / UI thread.
///
/// Additions:
/// - fetchRecommendedTVShows(...)         -> returns {'tv': [...], 'total_pages': N}
/// - fetchRecommendedMixed(...)           -> combines movie + tv recommended results (paged)
/// - _getProviderIdByName(...)            -> helper: resolves provider id by name (uses TMDB watch/providers)
/// - fetchNetflixMovies/TVShows(...)      -> provider-specific discover calls
/// - fetchHbomaxMovies/TVShows(...)
/// - fetchAmazonMovies/TVShows(...)

class TMDBApi {
  static const String apiKey = '1ba41bda48d0f1c90954f4811637b6d6';
  static const String baseUrl = 'https://api.themoviedb.org/3';

  // -----------------------
  // Top-level parser helpers
  // -----------------------
  // These must be top-level or static functions to be usable with compute().

  static Map<String, dynamic> _parseBodyToMap(String body) {
    return jsonDecode(body) as Map<String, dynamic>;
  }

  // Returns the 'results' list if available; otherwise returns parsed object as list if it is a list.
  static List<dynamic> _extractResultsFromBody(String body) {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded.containsKey('results')) {
      return decoded['results'] as List<dynamic>;
    } else if (decoded is List) {
      return decoded;
    } else {
      return <dynamic>[];
    }
  }

  // -----------------------
  // API methods (existing)
  // -----------------------

  /// (Legacy) Fetches one featured movie (the first popular movie).
  static Future<Map<String, dynamic>> fetchFeaturedMovie() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/movie/popular?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data =
            await compute(_parseBodyToMap, response.body);
        final List results = (data['results'] is List)
            ? data['results'] as List
            : <dynamic>[];
        if (results.isNotEmpty) {
          return Map<String, dynamic>.from(results[0] as Map);
        } else {
          throw Exception("No movies found");
        }
      } else {
        throw Exception(
            'Failed to load featured movie: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching featured movie: $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching featured movie: $e');
    }
  }

  /// Fetches upcoming movies.
  static Future<List<dynamic>> fetchUpcomingMovies() async {
    final uri = Uri.parse('$baseUrl/movie/upcoming?api_key=$apiKey');
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to load upcoming: ${response.statusCode} ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching upcoming movies: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching upcoming movies: $e');
    }
  }

  /// Fetches trending movies or TV shows.
  static Future<List<dynamic>> fetchTrendingMovies() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/trending/all/day?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to load trending movies: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching trending: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching trending movies: $e');
    }
  }

  /// Fetches trending TV shows.
  static Future<List<dynamic>> fetchTrendingTVShows() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/trending/tv/day?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to load trending TV shows: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching trending TV shows: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching trending TV shows: $e');
    }
  }

  /// Fetches recommendations (legacy).
  static Future<List<dynamic>> fetchRecommendations() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/movie/popular?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to load recommendations: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching recommendations: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching recommendations: $e');
    }
  }

  /// Fetches recommended movies with pagination, returning movies and total pages.
  static Future<Map<String, dynamic>> fetchRecommendedMovies(
      {int page = 1}) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/movie/popular?api_key=$apiKey&page=$page'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data =
            await compute(_parseBodyToMap, response.body);
        return {
          'movies': (data['results'] is List)
              ? data['results'] as List<dynamic>
              : <dynamic>[],
          'total_pages': data['total_pages'] ?? 1,
        };
      } else {
        throw Exception(
            'Failed to load recommended movies: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching recommended movies: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching recommended movies: $e');
    }
  }

  /// Fetches recommended movies as a list (legacy support for non-paginated use cases).
  static Future<List<dynamic>> fetchRecommendedMoviesList() async {
    final result = await fetchRecommendedMovies(page: 1);
    return result['movies'] as List<dynamic>;
  }

  /// Fetches the list of movie genres.
  static Future<List<dynamic>> fetchCategories() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/genre/movie/list?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data =
            await compute(_parseBodyToMap, response.body);
        return (data['genres'] is List)
            ? data['genres'] as List<dynamic>
            : <dynamic>[];
      } else {
        throw Exception(
            'Failed to load categories: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching categories: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching categories: $e');
    }
  }

  /// A map for converting category names to TMDB genre IDs.
  static Map<String, int> genreMap = {
    'Action': 28,
    'Comedy': 35,
    'Drama': 18,
    'Horror': 27,
    'Sci-Fi': 878,
    'Romance': 10749,
    'Animation': 16,
    'Thriller': 53,
    'Documentary': 99,
  };

  /// Fetches movies for the given [categoryName] using the Discover endpoint.
  static Future<List<dynamic>> fetchCategoryMovies(String categoryName) async {
    final genreId = genreMap[categoryName];
    if (genreId == null) {
      throw Exception("Genre not found for $categoryName");
    }
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/discover/movie?api_key=$apiKey&with_genres=$genreId'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to load category movies: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching category movies: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching category movies: $e');
    }
  }

  /// Fetches TV shows for the given [categoryName] using the Discover endpoint.
  static Future<List<dynamic>> fetchCategoryTVShows(String categoryName) async {
    final genreId = genreMap[categoryName];
    if (genreId == null) {
      throw Exception("Genre not found for $categoryName");
    }
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/discover/tv?api_key=$apiKey&with_genres=$genreId'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to load category TV shows: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching category TV shows: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching category TV shows: $e');
    }
  }

  /// Fetches similar movies for a given movie ID.
  static Future<List<dynamic>> fetchSimilarMovies(int movieId) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/movie/$movieId/similar?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to load similar movies: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching similar movies: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching similar movies: $e');
    }
  }

  /// Fetches similar TV shows for a given TV show ID.
  static Future<List<dynamic>> fetchSimilarTVShows(int tvId) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/tv/$tvId/similar?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to load similar TV shows: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching similar TV shows: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching similar TV shows: $e');
    }
  }

  /// Fetches trailers (videos) for a given movie or TV show ID.
  static Future<List<dynamic>> fetchTrailers(int id,
      {bool isTVShow = false}) async {
    final String endpoint = isTVShow ? 'tv/$id' : 'movie/$id';
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/$endpoint/videos?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to load trailers: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching trailers: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching trailers: $e');
    }
  }

  /// Fetches detailed TV show information, including seasons.
  static Future<Map<String, dynamic>> fetchTVShowDetails(int tvId) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/tv/$tvId?api_key=$apiKey'))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data =
            await compute(_parseBodyToMap, response.body);
        return data;
      } else {
        throw Exception(
            'Failed to load TV show details: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching TV show details: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching TV show details: $e');
    }
  }

  /// Fetches detailed TV season information, including episodes.
  static Future<Map<String, dynamic>> fetchTVSeasonDetails(
      int tvId, int seasonNumber) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/tv/$tvId/season/$seasonNumber?api_key=$apiKey'))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data =
            await compute(_parseBodyToMap, response.body);
        return data;
      } else {
        throw Exception(
            'Failed to load TV season details: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching TV season details: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching TV season details: $e');
    }
  }

  /// Fetches all episodes for all seasons of a TV show.
  static Future<Map<String, dynamic>> fetchAllEpisodesForTVShow(int tvId) async {
    try {
      // Fetch basic TV show details, which includes the list of seasons.
      final tvDetails = await fetchTVShowDetails(tvId);
      final seasons = (tvDetails['seasons'] is List)
          ? tvDetails['seasons'] as List<dynamic>
          : <dynamic>[];

      // For each season, fetch its episode details.
      for (var season in seasons) {
        final seasonNumber = season['season_number'] as int;
        final seasonDetails = await fetchTVSeasonDetails(tvId, seasonNumber);
        season['episodes'] = seasonDetails['episodes']; // Add episodes to the season map.
      }

      return tvDetails; // Return the updated TV show details with episodes.
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching all episodes for TV show: $e');
    }
  }

  /// Fetches movies matching the search [query].
  static Future<List<dynamic>> fetchSearchMovies(String query) async {
    try {
      final cleanedQuery = _cleanQuery(query);
      final response = await http
          .get(Uri.parse('$baseUrl/search/movie?api_key=$apiKey&query=${Uri.encodeQueryComponent(cleanedQuery)}'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to search movies: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while searching movies: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while searching movies: $e');
    }
  }

  /// Fetches movies, TV shows, and people matching the search [query].
  static Future<List<dynamic>> fetchSearchMulti(String query) async {
    try {
      final cleanedQuery = _cleanQuery(query);
      final response = await http
          .get(Uri.parse('$baseUrl/search/multi?api_key=$apiKey&query=${Uri.encodeQueryComponent(cleanedQuery)}'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to search: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while searching multi: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while searching multi: $e');
    }
  }

  /// Cleans search query by removing special characters (except spaces).
  static String _cleanQuery(String query) {
    return query.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), '').trim();
  }

  /// Fetches featured movies (popular movies).
  static Future<List<dynamic>> fetchFeaturedMovies() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/movie/popular?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to load featured movies: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching featured movies: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching featured movies: $e');
    }
  }

  /// Fetches featured TV shows (popular TV shows).
  static Future<List<dynamic>> fetchFeaturedTVShows() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/tv/popular?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> results =
            await compute(_extractResultsFromBody, response.body);
        return results;
      } else {
        throw Exception(
            'Failed to load featured TV shows: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching featured TV shows: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching featured TV shows: $e');
    }
  }

  /// Fetches featured content by combining featured movies and TV shows.
  /// The results are merged, sorted by popularity, and limited to 20 items.
  static Future<List<dynamic>> fetchFeaturedContent() async {
    try {
      final movies = await fetchFeaturedMovies();
      final tvShows = await fetchFeaturedTVShows();

      // Combine movies and tv shows into one list.
      List<dynamic> combined = [...movies, ...tvShows];

      // Sort the combined list by popularity (descending).
      combined.sort((a, b) =>
          (b['popularity'] as num).compareTo(a['popularity'] as num));

      // Limit to 20 items.
      if (combined.length > 20) {
        combined = combined.sublist(0, 20);
      }
      return combined;
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching featured content: $e');
    }
  }

  /// Fetches dynamic reels.
  static Future<List<dynamic>> fetchReels() async {
    try {
      final trendingResponse = await http
          .get(Uri.parse('$baseUrl/trending/movie/day?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));
      if (trendingResponse.statusCode != 200) {
        throw Exception(
            'Failed to load trending movies for reels: ${trendingResponse.statusCode} - ${trendingResponse.reasonPhrase}');
      }

      final trendingData =
          await compute(_parseBodyToMap, trendingResponse.body);
      final List trendingMovies = (trendingData['results'] is List)
          ? trendingData['results'] as List<dynamic>
          : <dynamic>[];

      List<dynamic> reels = [];

      for (var movie in trendingMovies) {
        try {
          final int movieId = movie['id'] as int;
          final trailerResponse = await http
              .get(Uri.parse('$baseUrl/movie/$movieId/videos?api_key=$apiKey'))
              .timeout(const Duration(seconds: 15));

          if (trailerResponse.statusCode == 200) {
            final trailerData =
                await compute(_parseBodyToMap, trailerResponse.body);
            final List trailers = (trailerData['results'] is List)
                ? trailerData['results'] as List<dynamic>
                : <dynamic>[];
            if (trailers.isNotEmpty) {
              var trailer = trailers.firstWhere(
                (t) => t['type'] == 'Trailer' || t['type'] == 'Teaser',
                orElse: () => trailers[0],
              );
              reels.add({
                'title': movie['title'] ?? movie['name'] ?? 'Reel',
                'videoUrl': 'https://www.youtube.com/watch?v=${trailer['key']}',
                'thumbnail_url': movie['backdrop_path'] != null
                    ? 'https://image.tmdb.org/t/p/w500${movie['backdrop_path']}'
                    : '',
              });
            }
          } else {
            debugPrint(
                'Failed to load trailers for movie $movieId: ${trailerResponse.statusCode}');
          }
        } catch (e) {
          debugPrint('Error fetching trailer for movie: $e');
          // continue with other movies
        }
      }

      return reels;
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching reels: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching reels: $e');
    }
  }

  /// Fetches dynamic stories.
  static Future<List<dynamic>> fetchStories() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/trending/tv/day?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data =
            await compute(_parseBodyToMap, response.body);
        List results = (data['results'] is List)
            ? data['results'] as List<dynamic>
            : <dynamic>[];
        return results.map((tv) {
          return {
            'name': tv['name'] ?? 'Story',
            'imageUrl': tv['poster_path'] != null
                ? 'https://image.tmdb.org/t/p/w200${tv['poster_path']}'
                : 'https://source.unsplash.com/random/100x100/?face',
          };
        }).toList();
      } else {
        throw Exception(
            'Failed to load stories: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching stories: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching stories: $e');
    }
  }

  // -----------------------
  // New: Recommended TV + Mixed
  // -----------------------

  /// Fetches recommended TV shows with pagination, returning tv and total pages.
  static Future<Map<String, dynamic>> fetchRecommendedTVShows(
      {int page = 1}) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/tv/popular?api_key=$apiKey&page=$page'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data =
            await compute(_parseBodyToMap, response.body);
        return {
          'tv': (data['results'] is List)
              ? data['results'] as List<dynamic>
              : <dynamic>[],
          'total_pages': data['total_pages'] ?? 1,
        };
      } else {
        throw Exception(
            'Failed to load recommended tv: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while fetching recommended tv: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error: Failed to connect to TMDB API - $e');
    } catch (e) {
      throw Exception('Unexpected error while fetching recommended tv: $e');
    }
  }

  /// Fetches recommended mixed content (movies + tv) and returns combined 'results' list
  /// as well as total_pages (max of both). This does not alter existing movie/tv functions.
  static Future<Map<String, dynamic>> fetchRecommendedMixed({int page = 1}) async {
    try {
      final movieResp = await fetchRecommendedMovies(page: page);
      final tvResp = await fetchRecommendedTVShows(page: page);

      final List<dynamic> movies =
          (movieResp['movies'] is List) ? movieResp['movies'] as List<dynamic> : <dynamic>[];
      final List<dynamic> tvs = (tvResp['tv'] is List) ? tvResp['tv'] as List<dynamic> : <dynamic>[];

      final List<dynamic> combined = [...movies, ...tvs];

      // dedupe by id if present
      final seenIds = <dynamic>{};
      final deduped = <dynamic>[];
      for (final item in combined) {
        if (item is Map && item.containsKey('id')) {
          final id = item['id'];
          if (id != null && !seenIds.contains(id)) {
            seenIds.add(id);
            deduped.add(item);
          }
        } else {
          deduped.add(item);
        }
      }

      // determine total_pages (best-effort): take max of both
      final int moviePages = (movieResp['total_pages'] is int) ? movieResp['total_pages'] as int : 1;
      final int tvPages = (tvResp['total_pages'] is int) ? tvResp['total_pages'] as int : 1;
      final int totalPages = moviePages > tvPages ? moviePages : tvPages;

      return {
        'results': deduped,
        'total_pages': totalPages,
      };
    } catch (e) {
      throw Exception('Unexpected error while fetching mixed recommendations: $e');
    }
  }

  // -----------------------
  // New: Watch provider helper + provider-specific fetches
  // -----------------------

  /// Helper: get provider id by provider name (case-insensitive).
  /// type = 'movie' or 'tv' (affects which provider list is fetched)
  /// If not found, returns null. You may use a fallback map if needed.
  static Future<int?> _getProviderIdByName(String providerName,
      {String type = 'movie'}) async {
    // fetch providers list from TMDB
    final endpoint = (type == 'tv') ? 'watch/providers/tv' : 'watch/providers/movie';
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/$endpoint?api_key=$apiKey'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data =
            await compute(_parseBodyToMap, response.body);
        if (data['results'] is List) {
          final List results = data['results'] as List<dynamic>;
          for (final p in results) {
            try {
              final name = (p['provider_name'] ?? '').toString().toLowerCase();
              if (name.isNotEmpty &&
                  providerName.toLowerCase().contains(name) ||
                  name.contains(providerName.toLowerCase())) {
                return p['provider_id'] as int?;
              }

              // direct equality check (case-insensitive)
              if (p['provider_name'] != null &&
                  p['provider_name'].toString().toLowerCase() ==
                      providerName.toLowerCase()) {
                return p['provider_id'] as int?;
              }
            } catch (_) {
              // ignore single entry errors & continue
            }
          }
        }
      } else {
        debugPrint(
            'Failed to fetch providers list: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } catch (e) {
      debugPrint('Error fetching providers list: $e');
    }

    // fallback mapping (common IDs, may change over time). We return null if not found.
    final fallback = <String, int>{
      'netflix': 8, // commonly used id for Netflix
      'hbo': 384, // best-effort fallback for HBO / HBO Max (may vary)
      'hbo max': 384,
      'hbomax': 384,
      'amazon': 119, // best-effort fallback for Amazon Prime Video (may vary)
      'amazon prime': 119,
      'prime video': 119,
      'primevideo': 119,
    };

    final key = providerName.toLowerCase();
    if (fallback.containsKey(key)) {
      return fallback[key];
    }

    return null;
  }

  /// Generic discover helper for a single provider (movies or tv).
  static Future<Map<String, dynamic>> _discoverByProvider({
    required bool isMovie,
    required int providerId,
    String region = 'US',
    int page = 1,
    String? monetizationType, // e.g., 'flatrate' (optional)
  }) async {
    final typePath = isMovie ? 'discover/movie' : 'discover/tv';
    final buffer = StringBuffer('$baseUrl/$typePath?api_key=$apiKey&page=$page&with_watch_providers=$providerId&watch_region=${Uri.encodeComponent(region)}');
    if (monetizationType != null && monetizationType.isNotEmpty) {
      buffer.write('&with_watch_monetization_types=${Uri.encodeComponent(monetizationType)}');
    }

    try {
      final response = await http.get(Uri.parse(buffer.toString())).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = await compute(_parseBodyToMap, response.body);
        final List<dynamic> results = (data['results'] is List) ? data['results'] as List<dynamic> : <dynamic>[];
        return {
          'results': results,
          'total_pages': data['total_pages'] ?? 1,
        };
      } else {
        throw Exception('Failed to discover by provider: ${response.statusCode} - ${response.reasonPhrase}');
      }
    } on TimeoutException catch (e) {
      throw Exception('Request timed out while discovering by provider: $e');
    } on http.ClientException catch (e) {
      throw Exception('Network error while discovering by provider: $e');
    } catch (e) {
      throw Exception('Unexpected error while discovering by provider: $e');
    }
  }

  // -----------------------
  // Netflix (provider-specific)
  // -----------------------

  /// Fetches Netflix movies only (does not mix other providers).
  /// region defaults to 'US' but you may pass another ISO country code (e.g. 'GB').
  static Future<Map<String, dynamic>> fetchNetflixMovies({String region = 'US', int page = 1}) async {
    final providerId = await _getProviderIdByName('netflix', type: 'movie');
    if (providerId == null) {
      throw Exception('Could not resolve Netflix provider id from TMDB.');
    }
    return await _discoverByProvider(isMovie: true, providerId: providerId, region: region, page: page, monetizationType: 'flatrate');
  }

  /// Fetches Netflix TV shows only (does not mix other providers).
  static Future<Map<String, dynamic>> fetchNetflixTVShows({String region = 'US', int page = 1}) async {
    final providerId = await _getProviderIdByName('netflix', type: 'tv');
    if (providerId == null) {
      throw Exception('Could not resolve Netflix provider id from TMDB.');
    }
    return await _discoverByProvider(isMovie: false, providerId: providerId, region: region, page: page, monetizationType: 'flatrate');
  }

  // -----------------------
  // HBO (provider-specific)
  // -----------------------

  /// Fetches HBO (HBO Max) movies only.
  static Future<Map<String, dynamic>> fetchHbomaxMovies({String region = 'US', int page = 1}) async {
    final providerId = await _getProviderIdByName('hbo max', type: 'movie') ?? await _getProviderIdByName('hbo', type: 'movie');
    if (providerId == null) {
      throw Exception('Could not resolve HBO provider id from TMDB.');
    }
    return await _discoverByProvider(isMovie: true, providerId: providerId, region: region, page: page, monetizationType: 'flatrate');
  }

  /// Fetches HBO (HBO Max) TV shows only.
  static Future<Map<String, dynamic>> fetchHbomaxTVShows({String region = 'US', int page = 1}) async {
    final providerId = await _getProviderIdByName('hbo max', type: 'tv') ?? await _getProviderIdByName('hbo', type: 'tv');
    if (providerId == null) {
      throw Exception('Could not resolve HBO provider id from TMDB.');
    }
    return await _discoverByProvider(isMovie: false, providerId: providerId, region: region, page: page, monetizationType: 'flatrate');
  }

  // -----------------------
  // Amazon Prime Video (provider-specific)
  // -----------------------

  /// Fetches Amazon Prime Video movies only.
  static Future<Map<String, dynamic>> fetchAmazonMovies({String region = 'US', int page = 1}) async {
    // try multiple name variants
    final providerId = await _getProviderIdByName('amazon prime', type: 'movie') ??
        await _getProviderIdByName('prime video', type: 'movie') ??
        await _getProviderIdByName('amazon', type: 'movie');
    if (providerId == null) {
      throw Exception('Could not resolve Amazon provider id from TMDB.');
    }
    return await _discoverByProvider(isMovie: true, providerId: providerId, region: region, page: page, monetizationType: 'flatrate');
  }

  /// Fetches Amazon Prime Video TV shows only.
  static Future<Map<String, dynamic>> fetchAmazonTVShows({String region = 'US', int page = 1}) async {
    final providerId = await _getProviderIdByName('amazon prime', type: 'tv') ??
        await _getProviderIdByName('prime video', type: 'tv') ??
        await _getProviderIdByName('amazon', type: 'tv');
    if (providerId == null) {
      throw Exception('Could not resolve Amazon provider id from TMDB.');
    }
    return await _discoverByProvider(isMovie: false, providerId: providerId, region: region, page: page, monetizationType: 'flatrate');
  }
}

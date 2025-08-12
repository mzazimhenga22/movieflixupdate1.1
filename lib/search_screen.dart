// Replace your current SearchScreen with this refactored one

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/tmdb_api.dart' as tmdb;
import 'package:movie_app/movie_detail_screen.dart';
import 'package:movie_app/components/movie_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  Future<List<dynamic>>? _searchResults;
  final ScrollController _scrollController = ScrollController();
  List<String> _previousSearches = [];

  @override
  void initState() {
    super.initState();
    _loadPreviousSearches();
  }

  Future<void> _loadPreviousSearches() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _previousSearches = prefs.getStringList('previousSearches') ?? [];
    });
  }

  Future<void> _savePreviousSearch(String query) async {
    if (!_previousSearches.contains(query)) {
      _previousSearches.insert(0, query);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('previousSearches', _previousSearches);
    }
  }

  void _performSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    _savePreviousSearch(trimmed);
    setState(() {
      _searchResults = tmdb.TMDBApi.fetchSearchMulti(trimmed);
    });

    // Scroll to top when search happens
    Future.delayed(const Duration(milliseconds: 300), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  Widget _buildSearchBar(Color accentColor) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accentColor.withOpacity(0.3)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: TextField(
          controller: _controller,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Search movies & TV shows...',
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
            border: InputBorder.none,
            suffixIcon: _controller.text.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.clear, color: Colors.white.withOpacity(0.5)),
                    onPressed: () {
                      _controller.clear();
                      setState(() => _searchResults = null);
                    },
                  )
                : null,
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: _performSearch,
          onChanged: (value) {
            if (value.trim().isEmpty && _searchResults != null) {
              setState(() => _searchResults = null);
            }
          },
        ),
      ),
    );
  }

  Widget _buildCategorySection(String title, List<dynamic> items, Color accentColor) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      sliver: SliverToBoxAdapter(
        child: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(List<dynamic> items, Color accentColor) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final item = items[index];
            return GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MovieDetailScreen(movie: item),
                  ),
                );
              },
              child: MovieCard.fromJson(
                item,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MovieDetailScreen(movie: item),
                    ),
                  );
                },
              ),
            );
          },
          childCount: items.length,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.7,
        ),
      ),
    );
  }

  Widget _buildResultsList(List<dynamic> results, Color accentColor) {
    final movies = results.where((e) => e['media_type'] == 'movie').toList();
    final tvShows = results.where((e) => e['media_type'] == 'tv').toList();

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        if (movies.isNotEmpty) ...[
          _buildCategorySection('Movies', movies, accentColor),
          _buildGrid(movies, accentColor),
        ],
        if (tvShows.isNotEmpty) ...[
          _buildCategorySection('TV Shows', tvShows, accentColor),
          _buildGrid(tvShows, accentColor),
        ],
      ],
    );
  }

  Widget _buildPreviousSearches(Color accentColor) {
    if (_previousSearches.isEmpty) {
      return const Center(
        child: Text(
          'Search for a movie or TV show above',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: _previousSearches.length,
      itemBuilder: (context, index) {
        final query = _previousSearches[index];
        return ListTile(
          leading: Icon(Icons.history, color: accentColor),
          title: Text(query, style: const TextStyle(color: Colors.white)),
          onTap: () {
            _controller.text = query;
            _performSearch(query);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Selector<SettingsProvider, Color>(
      selector: (_, s) => s.accentColor,
      builder: (context, accentColor, child) {
        return Scaffold(
          backgroundColor: const Color(0xFF111927),
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: _buildSearchBar(accentColor),
            actions: [
              IconButton(
                icon: Icon(Icons.search, color: accentColor),
                onPressed: () => _performSearch(_controller.text),
              ),
            ],
          ),
          body: FocusTraversalGroup(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    accentColor.withOpacity(0.1),
                    Colors.transparent,
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: _searchResults == null
                  ? _buildPreviousSearches(accentColor)
                  : FutureBuilder<List<dynamic>>(
                      future: _searchResults,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return Center(child: CircularProgressIndicator(color: accentColor));
                        }
                        if (snapshot.hasError) {
                          return Center(
                            child: Text(
                              'Error: ${snapshot.error}',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          );
                        }
                        final results = snapshot.data!;
                        if (results.isEmpty) {
                          return const Center(
                            child: Text(
                              'No results found',
                              style: TextStyle(color: Colors.white70),
                            ),
                          );
                        }
                        return _buildResultsList(results, accentColor);
                      },
                    ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

// search_screen_adaptive.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
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

  // For TV horizontal rows we need two controllers (movies, tv)
  final ScrollController _moviesRowController = ScrollController();
  final ScrollController _tvRowController = ScrollController();

  // For on-screen keyboard focus management on TV:
  FocusNode? _searchFieldFocusNode;

  List<String> _previousSearches = [];

  // whether TV on-screen keyboard is visible (driven by focus)
  bool _tvKeyboardVisible = false;

  @override
  void initState() {
    super.initState();
    _loadPreviousSearches();
    _searchFieldFocusNode = FocusNode();
    // Listen for focus changes to show/hide the on-screen keyboard
    _searchFieldFocusNode?.addListener(_handleSearchFocusChange);

    // Attempt to auto-focus the search field on TV/large screens after first build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isLargeScreen(context)) {
        // Request focus so the keyboard appears automatically on TV
        _searchFieldFocusNode?.requestFocus();
      }
    });
  }

  void _handleSearchFocusChange() {
    final hasFocus = _searchFieldFocusNode?.hasFocus ?? false;
    if (mounted) setState(() => _tvKeyboardVisible = hasFocus);
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

  bool _isLargeScreen(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Consider it TV mode when width >= 900 or diagonal/short side is large
    if (mq.size.width >= 900 || mq.size.shortestSide >= 600) return true;
    return false;
  }

  // Helper to determine whether we should show the on-screen keyboard
  bool _shouldShowOnScreenKeyboard(BuildContext context) {
    return _isLargeScreen(context);
  }

  Widget _buildSearchBar(Color accentColor, bool useOnScreenKeyboard) {
    // If useOnScreenKeyboard is true (TV), we show a read-only field and manage input via the on-screen keyboard
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Container(
        decoration: BoxDecoration(
          color: const Color.fromRGBO(0, 0, 0, 0.45),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accentColor.withOpacity(0.28)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _searchFieldFocusNode,
                readOnly: useOnScreenKeyboard,
                onTap: useOnScreenKeyboard
                    ? () {
                        // When user taps with remote on the read-only field, request focus so keyboard shows.
                        _searchFieldFocusNode?.requestFocus();
                      }
                    : null,
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
            IconButton(
              icon: Icon(Icons.search, color: accentColor),
              onPressed: () => _performSearch(_controller.text),
            )
          ],
        ),
      ),
    );
  }

  // Build results for mobile: the same 2-column grid you had before
  Widget _buildMobileResults(List<dynamic> results, Color accentColor) {
    final movies = results.where((e) => e['media_type'] == 'movie').toList();
    final tvShows = results.where((e) => e['media_type'] == 'tv').toList();

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        if (movies.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Movies',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = movies[index];
                  return GestureDetector(
                    onTap: () => _openDetail(item),
                    child: MovieCard.fromJson(
                      item,
                      onTap: () => _openDetail(item),
                    ),
                  );
                },
                childCount: movies.length,
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.7,
              ),
            ),
          ),
        ],
        if (tvShows.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            sliver: SliverToBoxAdapter(
              child: Text(
                'TV Shows',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = tvShows[index];
                  return GestureDetector(
                    onTap: () => _openDetail(item),
                    child: MovieCard.fromJson(
                      item,
                      onTap: () => _openDetail(item),
                    ),
                  );
                },
                childCount: tvShows.length,
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.7,
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  // Open detail helper
  void _openDetail(dynamic item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MovieDetailScreen(movie: item)),
    );
  }

  // TV layout: two horizontal rows (Movies and TV Shows) with focusable poster items
  Widget _buildTvResults(List<dynamic> results, Color accentColor) {
    final movies = results.where((e) => e['media_type'] == 'movie').toList();
    final tvShows = results.where((e) => e['media_type'] == 'tv').toList();

    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (movies.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 16, 8),
              child: Text('Movies', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            ),
            SizedBox(
              height: 360,
              child: _HorizontalFocusableRow(
                items: movies,
                scrollController: _moviesRowController,
                onItemTap: _openDetail,
                accentColor: accentColor,
              ),
            ),
          ],
          if (tvShows.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 16, 8),
              child: Text('TV Shows', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            ),
            SizedBox(
              height: 360,
              child: _HorizontalFocusableRow(
                items: tvShows,
                scrollController: _tvRowController,
                onItemTap: _openDetail,
                accentColor: accentColor,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPreviousSearches(Color accentColor, bool isTv) {
    if (_previousSearches.isEmpty) {
      return Center(
        child: Text(
          'Search for a movie or TV show above',
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }

    if (isTv) {
      // On TV show previous searches as a simple vertical list navigable by remote
      return ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(16),
        itemCount: _previousSearches.length,
        itemBuilder: (context, index) {
          final query = _previousSearches[index];
          return FocusableActionDetector(
            actions: {
              ActivateIntent: CallbackAction(onInvoke: (_) {
                _controller.text = query;
                _performSearch(query);
                return null;
              })
            },
            child: ListTile(
              leading: Icon(Icons.history, color: accentColor),
              title: Text(query, style: const TextStyle(color: Colors.white)),
              onTap: () {
                _controller.text = query;
                _performSearch(query);
              },
            ),
          );
        },
      );
    }

    // Mobile previous searches: as before
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

  // Build the UI and toggle between mobile/tv behaviors
  @override
  Widget build(BuildContext context) {
    final isTv = _isLargeScreen(context);

    return Selector<SettingsProvider, Color>(
      selector: (_, s) => s.accentColor,
      builder: (context, accentColor, child) {
        return Scaffold(
          backgroundColor: const Color(0xFF111927),
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: _buildSearchBar(accentColor, _shouldShowOnScreenKeyboard(context)),
            automaticallyImplyLeading: !isTv,
            actions: isTv
                ? null
                : [
                    IconButton(
                      icon: Icon(Icons.search, color: accentColor),
                      onPressed: () => _performSearch(_controller.text),
                    ),
                  ],
          ),
          body: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  accentColor.withOpacity(0.08),
                  Colors.transparent,
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: _searchResults == null
                ? _buildPreviousSearches(accentColor, isTv)
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

                      // If TV -> show horizontal rows + on-screen keyboard anchored below (if focused).
                      if (isTv) {
                        return Column(
                          children: [
                            // make sure results area is scrollable and flexible
                            Expanded(
                              child: SingleChildScrollView(
                                child: _buildTvResults(results, accentColor),
                              ),
                            ),

                            // Animated cross-fade between hidden and visible keyboard
                            AnimatedCrossFade(
                              firstChild: const SizedBox.shrink(),
                              secondChild: OnScreenKeyboard(
                                controller: _controller,
                                onSubmit: () => _performSearch(_controller.text),
                                onClose: () {
                                  // hide the keyboard and unfocus the field
                                  _searchFieldFocusNode?.unfocus();
                                },
                              ),
                              crossFadeState: _tvKeyboardVisible ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                              duration: const Duration(milliseconds: 220),
                            ),
                          ],
                        );
                      }

                      // Mobile: original grid layout
                      return _buildMobileResults(results, accentColor);
                    },
                  ),
          ),
          // Give a floating button on TV for focusing the search field (remote users)
          floatingActionButton: isTv
              ? FloatingActionButton(
                  mini: true,
                  backgroundColor: accentColor,
                  onPressed: () {
                    _searchFieldFocusNode?.requestFocus();
                  },
                  child: const Icon(Icons.keyboard, color: Colors.white),
                )
              : null,
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _moviesRowController.dispose();
    _tvRowController.dispose();
    _searchFieldFocusNode?.removeListener(_handleSearchFocusChange);
    _searchFieldFocusNode?.dispose();
    super.dispose();
  }
}

/// Horizontal focusable row used in TV mode.
/// Items is a list of TMDB JSON maps. It displays focusable posters, and automatically scrolls the underlying controller
/// so focused items remain visible.
class _HorizontalFocusableRow extends StatefulWidget {
  final List<dynamic> items;
  final ScrollController scrollController;
  final void Function(dynamic item) onItemTap;
  final Color accentColor;

  const _HorizontalFocusableRow({
    required this.items,
    required this.scrollController,
    required this.onItemTap,
    required this.accentColor,
    super.key,
  });

  @override
  State<_HorizontalFocusableRow> createState() => _HorizontalFocusableRowState();
}

class _HorizontalFocusableRowState extends State<_HorizontalFocusableRow> {
  // Keep a focus node per item so D-pad navigation works naturally
  late final List<FocusNode> _nodes;
  @override
  void initState() {
    super.initState();
    _nodes = List.generate(widget.items.length, (_) => FocusNode());
    // Listen focus changes to auto scroll
    for (var i = 0; i < _nodes.length; i++) {
      _nodes[i].addListener(() {
        if (_nodes[i].hasFocus) {
          _ensureVisible(i);
        }
      });
    }
  }

  Future<void> _ensureVisible(int index) async {
    final itemWidth = 260.0; // width + margin approx
    final offset = (index * itemWidth) - (MediaQuery.of(context).size.width / 2) + (itemWidth / 2);
    if (offset < 0) {
      widget.scrollController.animateTo(0, duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    } else {
      widget.scrollController.animateTo(offset.clamp(0.0, widget.scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: widget.scrollController,
      scrollDirection: Axis.horizontal,
      itemCount: widget.items.length,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemBuilder: (context, index) {
        final item = widget.items[index];
        final poster = (item['poster_path'] as String?) ?? '';
        final imageUrl = poster.isNotEmpty ? 'https://image.tmdb.org/t/p/w500$poster' : 'https://via.placeholder.com/300x450';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12),
          child: FocusableActionDetector(
            focusNode: _nodes[index],
            actions: {
              ActivateIntent: CallbackAction(onInvoke: (_) {
                widget.onItemTap(item);
                return null;
              }),
            },
            child: Builder(builder: (ctx) {
              final focused = Focus.of(ctx).hasFocus;
              return AnimatedScale(
                scale: focused ? 1.12 : 1.0,
                duration: const Duration(milliseconds: 150),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 240,
                      height: 340,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: focused ? widget.accentColor.withOpacity(0.18) : Colors.black45,
                            blurRadius: focused ? 28 : 8,
                            offset: const Offset(0, 6),
                          )
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(color: Colors.grey[900]),
                          errorWidget: (_, __, ___) => Container(color: Colors.grey),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: 240,
                      child: Text(
                        item['title'] ?? item['name'] ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: focused ? Colors.white : Colors.white70, fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        );
      },
    );
  }
}

/// Simple YouTube-like on-screen keyboard.
/// Keys are focusable and navigable via D-pad; pressing a key updates the provided text controller.
/// Includes BACKSPACE, SPACE and ENTER.
class OnScreenKeyboard extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback? onSubmit;
  final VoidCallback? onClose;

  const OnScreenKeyboard({required this.controller, this.onSubmit, this.onClose, super.key});

  @override
  State<OnScreenKeyboard> createState() => _OnScreenKeyboardState();
}

class _OnScreenKeyboardState extends State<OnScreenKeyboard> {
  // keyboard layout rows (letters only for simplicity)
  final List<String> _rows = [
    'QWERTYUIOP',
    'ASDFGHJKL',
    'ZXCVBNM⌫', // last key replaced visually with backspace symbol
  ];

  // dynamic focus nodes for each key
  final List<FocusNode> _keys = [];

  @override
  void initState() {
    super.initState();
    // create focus nodes for all keys + special keys row (space + clear + enter)
    final totalKeys = _rows.fold<int>(0, (p, r) => p + r.length) + 3; // +3 for space, clear, enter
    for (var i = 0; i < totalKeys; i++) {
      _keys.add(FocusNode());
    }
    // Request initial focus on first key shortly after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_keys.isNotEmpty && mounted) FocusScope.of(context).requestFocus(_keys[0]);
    });
  }

  @override
  void dispose() {
    for (final k in _keys) {
      k.dispose();
    }
    super.dispose();
  }

  // Helper to find index offset for a key at row/col
  int _indexFor(int row, int col) {
    var idx = 0;
    for (var r = 0; r < row; r++) {
      idx += _rows[r].length;
    }
    return idx + col;
  }

  // Submit / backspace handlers
  void _pressKey(String value) {
    if (value == '⌫') {
      final text = widget.controller.text;
      if (text.isNotEmpty) {
        widget.controller.text = text.substring(0, text.length - 1);
        widget.controller.selection = TextSelection.collapsed(offset: widget.controller.text.length);
      }
      return;
    }
    // normal char
    widget.controller.text = widget.controller.text + value;
    widget.controller.selection = TextSelection.collapsed(offset: widget.controller.text.length);
  }

  void _pressSpace() {
    widget.controller.text = widget.controller.text + ' ';
    widget.controller.selection = TextSelection.collapsed(offset: widget.controller.text.length);
  }

  void _pressClear() {
    widget.controller.clear();
  }

  void _pressEnter() {
    widget.onSubmit?.call();
  }

  @override
  Widget build(BuildContext context) {
    final keyWidgets = <Widget>[];
    // letter keys
    for (var r = 0; r < _rows.length; r++) {
      final row = _rows[r];
      final children = <Widget>[];
      for (var c = 0; c < row.length; c++) {
        final ch = row[c];
        final idx = _indexFor(r, c);
        children.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: FocusableActionDetector(
            focusNode: _keys[idx],
            actions: {
              ActivateIntent: CallbackAction(onInvoke: (_) {
                _pressKey(ch == '⌫' ? '⌫' : ch);
                return null;
              }),
            },
            child: Builder(builder: (ctx) {
              final focused = Focus.of(ctx).hasFocus;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: focused ? Colors.white10 : const Color.fromRGBO(255, 255, 255, 0.04),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  ch,
                  style: TextStyle(color: focused ? Colors.white : Colors.white70, fontSize: 18, fontWeight: FontWeight.w600),
                ),
              );
            }),
          ),
        ));
      }
      keyWidgets.add(Row(mainAxisSize: MainAxisSize.min, children: children));
    }

    // special keys indices start at total letters
    final specialStart = _rows.fold<int>(0, (p, r) => p + r.length);

    final spaceKey = FocusableActionDetector(
      focusNode: _keys[specialStart],
      actions: {
        ActivateIntent: CallbackAction(onInvoke: (_) {
          _pressSpace();
          return null;
        }),
      },
      child: Builder(builder: (ctx) {
        final focused = Focus.of(ctx).hasFocus;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          decoration: BoxDecoration(
            color: focused ? Colors.white10 : const Color.fromRGBO(255, 255, 255, 0.04),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('SPACE', style: TextStyle(color: focused ? Colors.white : Colors.white70, fontWeight: FontWeight.w700)),
        );
      }),
    );

    final clearKey = FocusableActionDetector(
      focusNode: _keys[specialStart + 1],
      actions: {
        ActivateIntent: CallbackAction(onInvoke: (_) {
          _pressClear();
          return null;
        }),
      },
      child: Builder(builder: (ctx) {
        final focused = Focus.of(ctx).hasFocus;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: focused ? Colors.white10 : const Color.fromRGBO(255, 255, 255, 0.04),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('CLEAR', style: TextStyle(color: focused ? Colors.white : Colors.white70, fontWeight: FontWeight.w700)),
        );
      }),
    );

    final enterKey = FocusableActionDetector(
      focusNode: _keys[specialStart + 2],
      actions: {
        ActivateIntent: CallbackAction(onInvoke: (_) {
          _pressEnter();
          return null;
        }),
      },
      child: Builder(builder: (ctx) {
        final focused = Focus.of(ctx).hasFocus;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: focused ? Colors.white10 : const Color.fromRGBO(255, 255, 255, 0.04),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('ENTER', style: TextStyle(color: focused ? Colors.white : Colors.white70, fontWeight: FontWeight.w700)),
        );
      }),
    );

    return Container(
      color: const Color(0xFF0D1117),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // the letter rows
          ...keyWidgets.map((r) => Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Center(child: r))),
          const SizedBox(height: 10),
          // special row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              spaceKey,
              const SizedBox(width: 18),
              clearKey,
              const SizedBox(width: 18),
              enterKey,
            ],
          ),
          const SizedBox(height: 8),
          // close button
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                widget.onClose?.call();
              },
              child: const Text('Close', style: TextStyle(color: Colors.white70)),
            ),
          )
        ],
      ),
    );
  }
}

// interactive_features_optimized_gradient_icons.dart
// Updated: icons are now rendered with a gradient shader while keeping everything else unchanged.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import 'package:movie_app/settings_provider.dart';
import 'components/feature_card.dart';
import 'components/storage_settings_screen.dart';
import 'components/watch_party_screen.dart';
import 'components/in_playback_trivia_screen.dart';
import 'components/ar_mode_screen.dart';
import 'components/recommendations_screen.dart';
import 'components/behind_the_scenes_screen.dart';
import 'components/theme_settings_screen.dart';
import 'components/voice_command_screen.dart';
import 'components/common_widgets.dart';
import '../components/socialsection/social_reactions_screen.dart' hide WatchPartyScreen;

/// ----------------------
/// Compute helpers (top-level)
/// ----------------------

Future<Map<String, dynamic>> _computeDirStats(String dirPath) async {
  final dir = Directory(dirPath);
  int totalBytes = 0;
  int fileCount = 0;
  try {
    if (!await dir.exists()) return {'bytes': 0, 'files': 0};
    final stream = dir.list(recursive: true, followLinks: false);
    await for (final entity in stream) {
      if (entity is File) {
        try {
          final len = await entity.length();
          totalBytes += len;
          fileCount++;
        } catch (_) {}
      }
    }
  } catch (_) {}
  return {'bytes': totalBytes, 'files': fileCount};
}

Future<bool> _computeAllocateFile(Map<String, dynamic> args) async {
  final String path = args['path'] as String;
  final int bytes = args['bytes'] as int;
  try {
    final file = File(path);
    if (await file.exists()) return true;
    final raf = await file.open(mode: FileMode.write);
    await raf.setPosition(bytes > 0 ? bytes - 1 : 0);
    await raf.writeByte(0);
    await raf.close();
    return true;
  } catch (_) {
    return false;
  }
}

/// ----------------------
/// Gradient Icon helper
/// ----------------------

/// A small helper widget that paints an icon with a gradient using ShaderMask.
class GradientIcon extends StatelessWidget {
  final IconData icon;
  final double size;
  final Gradient gradient;

  const GradientIcon({
    required this.icon,
    this.size = 24.0,
    required this.gradient,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => gradient.createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height)),
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(icon, size: size, color: Colors.white),
      ),
    );
  }
}

/// Convenience to create a pleasant two-stop gradient from the accent color.
LinearGradient _iconGradient(Color base) {
  // lighter variant by increasing lightness via HSL for a nicer contrast
  final hsl = HSLColor.fromColor(base);
  final light = hsl.withLightness((hsl.lightness + 0.22).clamp(0.0, 1.0)).toColor();
  return LinearGradient(
    colors: [base, light],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

/// ----------------------
/// Local UI helpers
/// ----------------------

class _AnimatedBackground extends StatelessWidget {
  const _AnimatedBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SizedBox.expand(),
      ),
    );
  }
}

/// FrostedContainer (tweakable intensity)
class FrostedContainer extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final Color accentColor;
  final EdgeInsetsGeometry? padding;
  final double intensity;

  const FrostedContainer({
    required this.child,
    required this.borderRadius,
    required this.accentColor,
    this.padding,
    this.intensity = 0.5,
    super.key,
  }) : assert(intensity >= 0.0 && intensity <= 1.0, 'intensity must be 0..1');

  @override
  Widget build(BuildContext context) {
    final double baseTint = 0.04 * intensity;
    final double borderOpacity = 0.06 * intensity;
    final double shadowOpacity = 0.45 * intensity;
    final double accentGlow = 0.03 * intensity;
    final double sheenOpacity = 0.012 + 0.02 * intensity;

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
                Colors.white.withOpacity(baseTint),
                Colors.white.withOpacity(baseTint * 0.5),
              ],
            ),
            border: Border.all(color: Colors.white.withOpacity(borderOpacity)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(shadowOpacity),
                blurRadius: 12 + 10 * intensity,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: accentColor.withOpacity(accentGlow),
                blurRadius: 20 * intensity,
                spreadRadius: 2 * intensity,
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
                          Colors.white.withOpacity(sheenOpacity),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.6],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: borderRadius,
                      color: Colors.black.withOpacity(0.02 * intensity),
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

/// ----------------------
/// Main screen (optimized)
/// ----------------------

class InteractiveFeaturesScreen extends StatefulWidget {
  final bool isDarkMode;
  final Function(bool)? onThemeChanged;

  const InteractiveFeaturesScreen({
    super.key,
    required this.isDarkMode,
    this.onThemeChanged,
  });

  @override
  _InteractiveFeaturesScreenState createState() =>
      _InteractiveFeaturesScreenState();
}

class _InteractiveFeaturesScreenState extends State<InteractiveFeaturesScreen>
    with SingleTickerProviderStateMixin {
  bool _loadingStats = true;
  bool _isAllocating = false;
  int _storageBytes = 0;
  int _storageFiles = 0;
  double _storagePercent = 0.0;
  late AnimationController _pulseController;
  static const int _softCapBytes = 1024 * 1024 * 1024; // 1 GB cap

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    // Start stats computation but do NOT block feature display.
    _refreshStorageStats();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _refreshStorageStats() async {
    // Keep UI responsive: show spinner inside storage card while compute is running.
    setState(() => _loadingStats = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final result = await compute(_computeDirStats, dir.path);
      final bytes = (result['bytes'] as int?) ?? 0;
      final files = (result['files'] as int?) ?? 0;
      if (!mounted) return;
      setState(() {
        _storageBytes = bytes;
        _storageFiles = files;
        _storagePercent = (_softCapBytes > 0) ? (bytes / _softCapBytes).clamp(0.0, 1.0) : 0.0;
      });
    } catch (e) {
      debugPrint('Failed to compute storage stats: $e');
    } finally {
      if (mounted) setState(() => _loadingStats = false);
    }
  }

  Future<void> _allocateStorageSample() async {
    if (_isAllocating) return;
    setState(() => _isAllocating = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final filePath = '${dir.path}${Platform.pathSeparator}allocated_test.bin';
      final bytes = 2 * 1024 * 1024; // 2 MB
      final success =
          await compute(_computeAllocateFile, {'path': filePath, 'bytes': bytes});
      if (!mounted) return;
      if (success) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('allocatedSample', bytes);
        await _refreshStorageStats();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Allocated sample storage (2 MB)')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Allocation failed')));
      }
    } catch (e) {
      debugPrint('Allocation error: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Allocation error: $e')));
    } finally {
      if (mounted) setState(() => _isAllocating = false);
    }
  }

  Widget _buildStorageCard(Color accentColor) {
    final human = _humanFileSize(_storageBytes);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            colors: [accentColor.withOpacity(0.14), accentColor.withOpacity(0.06)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: accentColor.withOpacity(0.08)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 72,
              height: 72,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: _loadingStats ? null : _storagePercent,
                    strokeWidth: 8,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                  ),
                  ScaleTransition(
                    scale: Tween<double>(begin: 0.9, end: 1.05).animate(_pulseController),
                    child: GradientIcon(
                      icon: Icons.sd_storage,
                      size: 28,
                      gradient: _iconGradient(accentColor),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Local Storage Usage', style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                _loadingStats
                    ? Text('Calculating…', style: TextStyle(color: accentColor.withOpacity(0.8)))
                    : Text('$human • $_storageFiles files', style: TextStyle(color: accentColor.withOpacity(0.85))),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: _loadingStats ? null : _storagePercent,
                      minHeight: 6,
                      backgroundColor: Colors.white10,
                      valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isAllocating ? null : _allocateStorageSample,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accentColor,
                      elevation: 4,
                      minimumSize: const Size(88, 36),
                    ),
                    child: _isAllocating
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Allocate', style: TextStyle(color: Colors.white)),
                  ),
                ]),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShimmerPlaceholder(Color accentColor) {
    return Shimmer.fromColors(
      baseColor: const Color.fromARGB(255, 30, 30, 30),
      highlightColor: const Color.fromARGB(255, 60, 60, 60),
      child: ListView.builder(
        padding: const EdgeInsets.all(16.0),
        itemCount: 6,
        itemBuilder: (context, index) {
          return Container(
            margin: const EdgeInsets.symmetric(vertical: 10.0),
            height: 88,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  accentColor.withOpacity(0.18),
                  accentColor.withOpacity(0.04),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accentColor.withOpacity(0.05)),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final accentColor = settings.accentColor;

    // Data-driven features (iconColor replaced with accentColor for consistent theme)
    final List<Map<String, dynamic>> features = [
      {
        'icon': Icons.group,
        'title': "Watch Party",
        'subtitle': "Host live watch parties with synchronized playback and in-app chat.",
        'route': (BuildContext ctx) => const WatchPartyScreen(),
      },
      {
        'icon': Icons.quiz,
        'title': "In-Playback Trivia",
        'subtitle': "Engage with trivia and challenges during key moments.",
        'route': (BuildContext ctx) => const InPlaybackTriviaScreen(),
      },
      {
        'icon': Icons.view_in_ar,
        'title': "Augmented Reality Mode",
        'subtitle': "Experience AR with movie posters and interactive objects.",
        'route': (BuildContext ctx) => const ARModeScreen(),
      },
      {
        'icon': Icons.playlist_add_check,
        'title': "Personalized Watchlists",
        'subtitle': "Get personalized movie journeys based on your viewing history.",
        'route': (BuildContext ctx) => const RecommendationsScreen(),
      },
      {
        'icon': Icons.movie_filter,
        'title': "Behind-the-Scenes",
        'subtitle': "Discover exclusive content and interactive Easter egg hunts.",
        'route': (BuildContext ctx) => const BehindTheScenesScreen(),
      },
      {
        'icon': Icons.color_lens,
        'title': "Customizable UI Themes",
        'subtitle': "Switch between dark mode, cinema mode, and more.",
        'route': (BuildContext ctx) => ThemeSettingsScreen(
              currentTheme: widget.isDarkMode ? "Dark" : "Light",
              onThemeChanged: (newTheme) {
                widget.onThemeChanged?.call(newTheme == "Dark");
              },
            ),
      },
      {
        'icon': Icons.mic,
        'title': "Voice Command",
        'subtitle': "Control the app hands-free with voice commands.",
        'route': (BuildContext ctx) => const VoiceCommandScreen(),
      },
      {
        'icon': Icons.emoji_emotions,
        'title': "Social Reactions",
        'subtitle': "Share live reactions during movies with your community.",
        'route': (BuildContext ctx) => SocialReactionsScreen(accentColor: accentColor),
      },
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text("Interactive Features", style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: GradientIcon(icon: Icons.settings, size: 20, gradient: _iconGradient(accentColor)),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const StorageSettingsScreen()));
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          const _AnimatedBackground(),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.2, -0.6),
                  radius: 1.0,
                  colors: [accentColor.withOpacity(0.14), Colors.transparent],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.6, 0.3),
                  radius: 1.0,
                  colors: [accentColor.withOpacity(0.08), Colors.transparent],
                ),
              ),
            ),
          ),

          // Foreground frosted content area.
          Positioned.fill(
            top: kToolbarHeight + MediaQuery.of(context).padding.top,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
              child: FrostedContainer(
                borderRadius: BorderRadius.circular(18),
                accentColor: accentColor,
                intensity: 0.65,
                padding: const EdgeInsets.all(12),
                // IMPORTANT: always show features immediately. Storage card will show a loading state while compute runs.
                child: RefreshIndicator(
                  onRefresh: _refreshStorageStats,
                  color: accentColor,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(child: const SizedBox(height: 6)),
                      SliverToBoxAdapter(child: _buildStorageCard(accentColor)),
                      SliverToBoxAdapter(child: const SizedBox(height: 18)),
                      // Features grid (renders immediately)
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        sliver: SliverGrid(
                          delegate: SliverChildBuilderDelegate((context, index) {
                            final item = features[index];
                            return _FeatureTile(
                              icon: item['icon'] as IconData,
                              title: item['title'] as String,
                              subtitle: item['subtitle'] as String,
                              accentColor: accentColor,
                              onTap: () {
                                final built = (item['route'] as Function)(context) as Widget;
                                Navigator.push(context, MaterialPageRoute(builder: (_) => built));
                              },
                            );
                          }, childCount: features.length),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 1.05,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(child: const SizedBox(height: 24)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _humanFileSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(size >= 100 ? 0 : (size >= 10 ? 1 : 2))} ${suffixes[i]}';
  }
}

/// ----------------------
/// Feature tile (uses accentColor everywhere)
/// ----------------------

class _FeatureTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color accentColor;
  final VoidCallback onTap;

  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accentColor,
    required this.onTap,
    super.key,
  });

  @override
  State<_FeatureTile> createState() => _FeatureTileState();
}

class _FeatureTileState extends State<_FeatureTile> with SingleTickerProviderStateMixin {
  double _elevation = 6.0;
  double _scale = 1.0;
  late AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _onTapDown(_) {
    setState(() {
      _scale = 0.98;
      _elevation = 2.0;
    });
    _anim.forward();
  }

  void _onTapUp(_) {
    setState(() {
      _scale = 1.0;
      _elevation = 6.0;
    });
    _anim.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accentColor;
    return GestureDetector(
      onTapDown: _onTapDown,
      onTapCancel: () {
        setState(() {
          _scale = 1.0;
          _elevation = 6.0;
        });
        _anim.reverse();
      },
      onTapUp: (details) {
        _onTapUp(details);
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 120),
        child: Material(
          color: Colors.transparent,
          elevation: _elevation,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(
                colors: [accent.withOpacity(0.14), Colors.transparent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(color: accent.withOpacity(0.06)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.165),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: GradientIcon(icon: widget.icon, size: 28, gradient: _iconGradient(accent)),
                ),
                const SizedBox(height: 12),
                Text(widget.title, style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Expanded(
                  child: Text(widget.subtitle, style: TextStyle(color: accent.withOpacity(0.9), fontSize: 12), maxLines: 3, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

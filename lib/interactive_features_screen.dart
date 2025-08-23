import 'dart:io';
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

class _InteractiveFeaturesScreenState extends State<InteractiveFeaturesScreen> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _allocateStorage();
  }

  Future<void> _allocateStorage() async {
    setState(() => _isLoading = true);
    try {
      final directory = await getApplicationDocumentsDirectory();
      final filePath = '${directory.path}/allocated_storage.bin';
      final file = File(filePath);

      final dir = Directory(directory.path);
      final stats = await dir.stat();
      if (stats.size < 1024 * 1024 * 1024) {
        debugPrint("Insufficient storage for 1GB allocation. Skipping...");
        return;
      }

      if (!await file.exists()) {
        int sizeInBytes = 1024 * 1024; // 1MB for testing
        debugPrint("Allocating storage: $sizeInBytes bytes");
        RandomAccessFile raf = await file.open(mode: FileMode.write);
        await raf.setPosition(sizeInBytes - 1);
        await raf.writeByte(0);
        await raf.close();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('allocatedStorage', sizeInBytes);
        debugPrint("Storage allocation successful");
      } else {
        debugPrint("Storage file already exists");
      }
    } catch (e, stackTrace) {
      debugPrint("Error during storage allocation: $e\n$stackTrace");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Widget _buildShimmerPlaceholder() {
    final settings = Provider.of<SettingsProvider>(context);
    return Shimmer.fromColors(
      baseColor: const Color.fromARGB(255, 40, 40, 40),
      highlightColor: const Color.fromARGB(255, 60, 60, 60),
      child: ListView.builder(
        padding: const EdgeInsets.all(16.0),
        itemCount: 8,
        itemBuilder: (context, index) {
          return Container(
            margin: const EdgeInsets.symmetric(vertical: 8.0),
            height: 80,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  settings.accentColor.withOpacity(0.2),
                  settings.accentColor.withOpacity(0.4),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: settings.accentColor.withOpacity(0.5), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: settings.accentColor.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  margin: const EdgeInsets.all(8.0),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        settings.accentColor.withOpacity(0.3),
                        settings.accentColor.withOpacity(0.5),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 150,
                        height: 16,
                        color: Colors.white,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: 200,
                        height: 12,
                        color: Colors.white,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: settings.accentColor.withOpacity(0.1),
        elevation: 0,
        title: Text(
          "Interactive Features",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: settings.accentColor,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.settings, color: settings.accentColor),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const StorageSettingsScreen()),
              );
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
                  center: const Alignment(-0.06, -0.34),
                  radius: 1.0,
                  colors: [
                    settings.accentColor.withOpacity(0.5),
                    Colors.black,
                  ],
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
                  colors: [
                    settings.accentColor.withOpacity(0.3),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.55],
                ),
              ),
            ),
          ),

          // Main content area — replaced BackdropFilter with FrostedContainer (gpu-friendly)
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.5,
                    colors: [
                      settings.accentColor.withOpacity(0.3),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 1.0],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: settings.accentColor.withOpacity(0.5),
                      blurRadius: 12,
                      spreadRadius: 2,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: FrostedContainer(
                  // tweak intensity between 0.0 and 1.0 (0 = no frost, 1 = strong frost)
                  intensity: 0.56,
                  borderRadius: BorderRadius.circular(12),
                  accentColor: settings.accentColor,
                  padding: const EdgeInsets.all(0),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: screenHeight),
                    child: _isLoading
                        ? _buildShimmerPlaceholder()
                        : ListView(
                            padding: const EdgeInsets.all(16.0),
                            children: [
                              FeatureCard(
                                icon: Icons.group,
                                iconColor: Colors.blue,
                                title: "Watch Party",
                                subtitle:
                                    "Host live watch parties with synchronized playback and in-app chat.",
                                backgroundGradient: LinearGradient(
                                  colors: [
                                    settings.accentColor.withOpacity(0.2),
                                    settings.accentColor.withOpacity(0.4),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderColor:
                                    settings.accentColor.withOpacity(0.5),
                                titleStyle: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                                subtitleStyle: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 1,
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (context) => const WatchPartyScreen()),
                                  );
                                },
                              ),

                              FeatureCard(
                                icon: Icons.quiz,
                                iconColor: Colors.green,
                                title: "In-Playback Trivia",
                                subtitle:
                                    "Engage with trivia and challenges during key moments.",
                                backgroundGradient: LinearGradient(
                                  colors: [
                                    settings.accentColor.withOpacity(0.2),
                                    settings.accentColor.withOpacity(0.4),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderColor:
                                    settings.accentColor.withOpacity(0.5),
                                titleStyle: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                                subtitleStyle: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 1,
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (context) => const InPlaybackTriviaScreen()),
                                  );
                                },
                              ),

                              FeatureCard(
                                icon: Icons.view_in_ar,
                                iconColor: Colors.orange,
                                title: "Augmented Reality Mode",
                                subtitle:
                                    "Experience AR with movie posters and interactive virtual objects.",
                                backgroundGradient: LinearGradient(
                                  colors: [
                                    settings.accentColor.withOpacity(0.2),
                                    settings.accentColor.withOpacity(0.4),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderColor:
                                    settings.accentColor.withOpacity(0.5),
                                titleStyle: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                                subtitleStyle: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 1,
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (context) => const ARModeScreen()),
                                  );
                                },
                              ),

                              FeatureCard(
                                icon: Icons.playlist_add_check,
                                iconColor: Colors.purple,
                                title:
                                    "Personalized Watchlists & AI Recommendations",
                                subtitle:
                                    "Get personalized movie journeys based on your viewing history.",
                                backgroundGradient: LinearGradient(
                                  colors: [
                                    settings.accentColor.withOpacity(0.2),
                                    settings.accentColor.withOpacity(0.4),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderColor:
                                    settings.accentColor.withOpacity(0.5),
                                titleStyle: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                                subtitleStyle: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 1,
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (context) => const RecommendationsScreen()),
                                  );
                                },
                              ),

                              FeatureCard(
                                icon: Icons.movie_filter,
                                iconColor: Colors.red,
                                title: "Behind-the-Scenes & Easter Eggs",
                                subtitle:
                                    "Discover exclusive content and interactive Easter egg hunts.",
                                backgroundGradient: LinearGradient(
                                  colors: [
                                    settings.accentColor.withOpacity(0.2),
                                    settings.accentColor.withOpacity(0.4),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderColor:
                                    settings.accentColor.withOpacity(0.5),
                                titleStyle: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                                subtitleStyle: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 1,
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (context) => const BehindTheScenesScreen()),
                                  );
                                },
                              ),

                              FeatureCard(
                                icon: Icons.color_lens,
                                iconColor: Colors.teal,
                                title: "Customizable UI Themes",
                                subtitle:
                                    "Switch between dark mode, cinema mode, and more.",
                                backgroundGradient: LinearGradient(
                                  colors: [
                                    settings.accentColor.withOpacity(0.2),
                                    settings.accentColor.withOpacity(0.4),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderColor:
                                    settings.accentColor.withOpacity(0.5),
                                titleStyle: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                                subtitleStyle: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 1,
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => ThemeSettingsScreen(
                                        currentTheme: widget.isDarkMode
                                            ? "Dark"
                                            : "Light",
                                        onThemeChanged: (newTheme) {
                                          widget.onThemeChanged
                                              ?.call(newTheme == "Dark");
                                        },
                                      ),
                                    ),
                                  );
                                },
                              ),

                              FeatureCard(
                                icon: Icons.mic,
                                iconColor: Colors.indigo,
                                title: "Voice Command Integration",
                                subtitle:
                                    "Control the app hands-free with voice commands.",
                                backgroundGradient: LinearGradient(
                                  colors: [
                                    settings.accentColor.withOpacity(0.2),
                                    settings.accentColor.withOpacity(0.4),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderColor:
                                    settings.accentColor.withOpacity(0.5),
                                titleStyle: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                                subtitleStyle: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 1,
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (context) => const VoiceCommandScreen()),
                                  );
                                },
                              ),

                              FeatureCard(
                                icon: Icons.emoji_emotions,
                                iconColor: Colors.pink,
                                title: "Real-Time Social Reactions",
                                subtitle:
                                    "Share live reactions during movies with your community.",
                                backgroundGradient: LinearGradient(
                                  colors: [
                                    settings.accentColor.withOpacity(0.2),
                                    settings.accentColor.withOpacity(0.4),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderColor:
                                    settings.accentColor.withOpacity(0.5),
                                titleStyle: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                                subtitleStyle: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      offset: Offset(1, 1),
                                      blurRadius: 1,
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => SocialReactionsScreen(
                                          accentColor: settings.accentColor),
                                    ),
                                  );
                                },
                              ),
                            ],
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

/// Small reusable animated background used by many screens.
class _AnimatedBackground extends StatelessWidget {
  const _AnimatedBackground();

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

/// FrostedContainer: fake frosted-glass look without expensive blur.
/// intensity: 0.0..1.0 — controls strength of tint, border and sheen.
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
    // Map intensity to practical opacities
    final double baseTint = 0.04 * intensity; // overlay white tint
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
            // faint white tint for frosted effect
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
              // subtle sheen
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

              // Content area gets slight inner tint for depth
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

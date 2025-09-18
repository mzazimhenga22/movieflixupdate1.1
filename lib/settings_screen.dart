// settings_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/l10n/app_localizations.dart';
import 'settings_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  // keep your available color map; this shows friendly names
  static const Map<String, Color> availableBackgroundColors = {
    'Default (Purple)': Colors.purple,
    'BlueAccent': Colors.blueAccent,
    'RedAccent': Colors.redAccent,
    'GreenAccent': Colors.greenAccent,
    'PurpleAccent': Colors.purpleAccent,
    'OrangeAccent': Colors.deepOrangeAccent,
    'PinkAccent': Colors.pinkAccent,
    'TealAccent': Colors.tealAccent,
    'CyanAccent': Colors.cyanAccent,
    'AmberAccent': Colors.amberAccent,
    // Example gradient base colors (we pick a single representative color)
    'SunsetGradient': Color(0xFFFF5F6D),
    'OceanGradient': Color(0xFF2193B0),
    'LushGradient': Color(0xFF56AB2F),
    'FireGradient': Color(0xFFFF512F),
    'SkyGradient': Color(0xFF00C9FF),
    'PeachGradient': Color(0xFFFF7E5F),
  };

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // hue in degrees 0..360 (for draggable picker)
  double _hue = 260; // start near purple
  // brightness & saturation fixed for pleasing accent — could expose later
  final double _saturation = 0.8;
  final double _value = 0.85;

  @override
  void initState() {
    super.initState();
    // sync initial hue with provider accentColor (if possible)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final settings = Provider.of<SettingsProvider>(context, listen: false);
      final accent = settings.accentColor;
      final hsv = HSVColor.fromColor(accent);
      setState(() {
        _hue = hsv.hue;
      });
    });
  }

  void _onHueChanged(double hue) {
    setState(() => _hue = hue);
    final color = HSVColor.fromAHSV(1.0, hue, _saturation, _value).toColor();
    Provider.of<SettingsProvider>(context, listen: false).setAccentColor(color);
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final settings = Provider.of<SettingsProvider>(context);

    // Attempt to find friendly name for current accent color
    final matchEntry = SettingsScreen.availableBackgroundColors.entries.firstWhere(
      (e) => e.value.value == settings.accentColor.value,
      orElse: () => const MapEntry('Custom', Colors.purple),
    );

    // If the matched key exists in the predefined map, we use it; otherwise null (Custom)
    final availableKeys = SettingsScreen.availableBackgroundColors.keys.toList();
    final String? selectedColorKey = availableKeys.contains(matchEntry.key) ? matchEntry.key : null;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: settings.accentColor.withOpacity(0.08),
        elevation: 0,
        title: Text(localizations.settings),
        iconTheme: IconThemeData(color: settings.accentColor),
      ),
      body: Stack(
        children: [
          // background layers (same "look" as other screens)
          const _AnimatedBackground(),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.06, -0.34),
                  radius: 1.0,
                  colors: [
                    settings.accentColor.withOpacity(0.45),
                    Colors.black,
                  ],
                  stops: const [0.0, 0.6],
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

          // Main frosted content area
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(10.0),
              child: FrostedContainer(
                borderRadius: BorderRadius.circular(12),
                accentColor: settings.accentColor,
                intensity: 0.56, // tweak this to taste
                padding: const EdgeInsets.all(0),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: MediaQuery.of(context).size.height),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Section: Basic settings (reuse your original items)
                          _buildDropdownTile(
                            title: localizations.homeScreenType,
                            trailing: DropdownButton<String>(
                              value: settings.homeScreenType,
                              items: const [
                                DropdownMenuItem(value: 'standard', child: Text('Standard (Rich UI)')),
                                DropdownMenuItem(value: 'performance', child: Text('Performance (Lightweight)')),
                              ],
                              onChanged: (val) {
                                if (val != null) settings.setHomeScreenType(val);
                              },
                            ),
                          ),
                          _buildDropdownTile(
                            title: localizations.downloadQuality,
                            trailing: DropdownButton<String>(
                              value: settings.downloadQuality,
                              items: const [
                                DropdownMenuItem(value: 'Low', child: Text('Low')),
                                DropdownMenuItem(value: 'Medium', child: Text('Medium')),
                                DropdownMenuItem(value: 'High', child: Text('High')),
                              ],
                              onChanged: (val) {
                                if (val != null) settings.setDownloadQuality(val);
                              },
                            ),
                          ),
                          SwitchListTile(
                            title: Text(localizations.wifiOnlyDownloads),
                            value: settings.wifiOnlyDownloads,
                            onChanged: settings.setWifiOnlyDownloads,
                          ),
                          _buildDropdownTile(
                            title: localizations.playbackQuality,
                            trailing: DropdownButton<String>(
                              value: settings.playbackQuality,
                              items: const [
                                DropdownMenuItem(value: '480p', child: Text('480p')),
                                DropdownMenuItem(value: '720p', child: Text('720p')),
                                DropdownMenuItem(value: '1080p', child: Text('1080p')),
                                DropdownMenuItem(value: '4K', child: Text('4K')),
                              ],
                              onChanged: (val) {
                                if (val != null) settings.setPlaybackQuality(val);
                              },
                            ),
                          ),
                          SwitchListTile(
                            title: Text(localizations.subtitles),
                            value: settings.subtitlesEnabled,
                            onChanged: settings.setSubtitlesEnabled,
                          ),
                          _buildDropdownTile(
                            title: localizations.language,
                            trailing: DropdownButton<String>(
                              value: settings.language,
                              items: const [
                                DropdownMenuItem(value: 'English', child: Text('English')),
                                DropdownMenuItem(value: 'Spanish', child: Text('Spanish')),
                                DropdownMenuItem(value: 'French', child: Text('French')),
                                DropdownMenuItem(value: 'German', child: Text('German')),
                              ],
                              onChanged: (val) {
                                if (val != null) settings.setLanguage(val);
                              },
                            ),
                          ),
                          SwitchListTile(
                            title: Text(localizations.autoPlayTrailers),
                            value: settings.autoPlayTrailers,
                            onChanged: settings.setAutoPlayTrailers,
                          ),
                          SwitchListTile(
                            title: Text(localizations.notifications),
                            value: settings.notificationsEnabled,
                            onChanged: settings.setNotificationsEnabled,
                          ),
                          SwitchListTile(
                            title: Text(localizations.parentalControl),
                            value: settings.parentalControl,
                            onChanged: settings.setParentalControl,
                          ),
                          SwitchListTile(
                            title: Text(localizations.dataSaverMode),
                            value: settings.dataSaverMode,
                            onChanged: settings.setDataSaverMode,
                          ),
                          ListTile(
                            title: Text(localizations.clearCache),
                            subtitle: Text("${localizations.cacheSize}: ${settings.cacheSize.toStringAsFixed(1)} MB"),
                            trailing: ElevatedButton(
                              onPressed: () {
                                settings.clearCache();
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(localizations.cacheCleared)));
                              },
                              child: const Text("Clear"),
                            ),
                          ),

                          const SizedBox(height: 12),
                          // Color selection section
                          Text("Accent color", style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white)),
                          const SizedBox(height: 8),

                          // Predefined color dropdown (friendly named options)
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButton<String?>(
                                  value: selectedColorKey, // nullable now; null means 'Custom'
                                  isExpanded: true,
                                  hint: const Text("Custom", style: TextStyle(color: Colors.white70)),
                                  items: SettingsScreen.availableBackgroundColors.entries.map((entry) {
                                    return DropdownMenuItem<String?>(
                                      value: entry.key,
                                      child: Row(
                                        children: [
                                          Container(width: 18, height: 18, decoration: BoxDecoration(color: entry.value, borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.white24))),
                                          const SizedBox(width: 8),
                                          Text(entry.key, style: const TextStyle(color: Colors.white)),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (String? newValue) {
                                    if (newValue == null) return;
                                    final newColor = SettingsScreen.availableBackgroundColors[newValue]!;
                                    Provider.of<SettingsProvider>(context, listen: false).setAccentColor(newColor);
                                    final hsv = HSVColor.fromColor(newColor);
                                    setState(() => _hue = hsv.hue);
                                  },
                                  dropdownColor: Colors.black.withOpacity(0.8),
                                ),
                              ),
                              const SizedBox(width: 12),
                              // preview swatch
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: settings.accentColor,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.white24),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 16),

                          // Draggable hue slider (the thing you "drag")
                          Text("Pick any color (drag the knob)", style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white70)),
                          const SizedBox(height: 8),
                          HueSlider(
                            hue: _hue,
                            onChanged: _onHueChanged,
                            height: 44,
                            knobRadius: 14,
                          ),

                          const SizedBox(height: 10),
                          // advanced color controls (brightness/sat preview)
                          Row(
                            children: [
                              Expanded(
                                child: Text("Saturation: ${(_saturation * 100).round()}%", style: const TextStyle(color: Colors.white70)),
                              ),
                              Expanded(
                                child: Text("Brightness: ${(_value * 100).round()}%", style: const TextStyle(color: Colors.white70)),
                              ),
                            ],
                          ),

                          const SizedBox(height: 24),

                          // Demonstrate the accent color against UI elements
                          Text("Preview", style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white)),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(backgroundColor: settings.accentColor),
                                  onPressed: () {},
                                  child: const Text("Primary", style: TextStyle(color: Colors.black)),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(side: BorderSide(color: settings.accentColor)),
                                  onPressed: () {},
                                  child: Text("Outline", style: TextStyle(color: settings.accentColor)),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 28),
                        ],
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
  }

  Widget _buildDropdownTile({required String title, required Widget trailing}) {
    return ListTile(
      title: Text(title),
      trailing: trailing,
    );
  }
}

/// Small reusable animated background used in other screens
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

/// FrostedContainer: GPU-friendly frosted glass look (no BackdropFilter).
/// intensity: 0..1 controls tint/shine strength.
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
  }) : assert(intensity >= 0.0 && intensity <= 1.0);

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
                Colors.white.withOpacity(baseTint * 0.6),
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

/// HueSlider: a draggable gradient slider returning hue 0..360
class HueSlider extends StatefulWidget {
  final double hue;
  final ValueChanged<double> onChanged;
  final double height;
  final double knobRadius;

  const HueSlider({
    required this.hue,
    required this.onChanged,
    this.height = 40,
    this.knobRadius = 12,
    super.key,
  });

  @override
  State<HueSlider> createState() => _HueSliderState();
}

class _HueSliderState extends State<HueSlider> {
  late double _localHue;

  @override
  void initState() {
    super.initState();
    _localHue = widget.hue;
  }

  @override
  void didUpdateWidget(covariant HueSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.hue - _localHue).abs() > 0.5) {
      _localHue = widget.hue;
    }
  }

  void _handlePan(Offset localPosition, RenderBox box) {
    final width = box.size.width;
    double dx = localPosition.dx.clamp(0.0, width);
    double ratio = dx / width;
    double hue = ratio * 360.0;
    setState(() => _localHue = hue);
    widget.onChanged(hue);
  }

  @override
  Widget build(BuildContext context) {
    final knobColor = HSVColor.fromAHSV(1, _localHue, 0.8, 0.85).toColor();

    return GestureDetector(
      onPanDown: (details) {
        final box = context.findRenderObject() as RenderBox;
        _handlePan(details.localPosition, box);
      },
      onPanUpdate: (details) {
        final box = context.findRenderObject() as RenderBox;
        _handlePan(details.localPosition, box);
      },
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(builder: (context, constraints) {
          return Stack(
            alignment: Alignment.centerLeft,
            children: [
              // Hue gradient background
              Container(
                height: widget.height * 0.46,
                margin: EdgeInsets.symmetric(vertical: (widget.height - widget.height * 0.46) / 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  gradient: LinearGradient(
                    colors: List.generate(13, (i) {
                      final h = i * 30.0;
                      return HSVColor.fromAHSV(1, h, 1.0, 1.0).toColor();
                    }),
                    stops: List.generate(13, (i) => i / 12),
                  ),
                ),
              ),

              // knob (positioned by hue)
              Positioned(
                left: (_localHue / 360.0) * (constraints.maxWidth - widget.knobRadius * 2),
                child: Container(
                  width: widget.knobRadius * 2,
                  height: widget.knobRadius * 2,
                  alignment: Alignment.center,
                  child: Container(
                    width: widget.knobRadius * 2,
                    height: widget.knobRadius * 2,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: knobColor,
                      border: Border.all(color: Colors.white.withOpacity(0.85), width: 2),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 4, offset: const Offset(0, 2))],
                    ),
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

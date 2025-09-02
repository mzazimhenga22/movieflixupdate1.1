// main_tab_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/home_screen_main.dart';
import 'package:movie_app/home_screen_lite.dart';
import 'package:movie_app/categories_screen.dart';
import 'package:movie_app/downloads_screen.dart';
import 'package:movie_app/interactive_features_screen.dart';
import 'package:movie_app/components/common_widgets.dart';
import 'package:movie_app/tv_homescreen.dart'; // <-- TV home screen

/// Selects between HomeScreenMain and HomeScreenLite based on settings
class HomeContainer extends StatelessWidget {
  final String? profileName;

  const HomeContainer({super.key, this.profileName});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    return settings.homeScreenType == 'standard'
        ? HomeScreenMain(profileName: profileName)
        : HomeScreenLite(profileName: profileName);
  }
}

/// Main screen with bottom navigation tabs
class MainTabScreen extends StatefulWidget {
  final String? profileName;
  const MainTabScreen({super.key, this.profileName});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  int _selectedIndex = 0;

  /// Returns the list of tab pages (mobile/tablet)
  List<Widget> _getPages(SettingsProvider settings) {
    return [
      HomeContainer(profileName: widget.profileName),
      const CategoriesScreen(),
      const DownloadsScreen(),
      InteractiveFeaturesScreen(
        isDarkMode: settings.isDarkMode,
        onThemeChanged: (bool value) {
          settings.setDarkMode(value);
        },
      ),
    ];
  }

  // Simple TV detection helper — tweak thresholds as needed
  bool _isTelevision(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Treat as TV if width is large OR shortest side (useful for tablets/large screens)
    if (mq.size.width >= 900) return true;
    if (mq.size.shortestSide >= 600) return true;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final accentColor = settings.accentColor;

    // If device is TV, immediately navigate / show TVHomeScreen instead of tab UI.
    // Returning the TV screen directly avoids showing bottom navigation which is not ideal on TV.
    if (_isTelevision(context)) {
      return const TVHomeScreen();
    }

    // Mobile / normal behavior (tabs)
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _getPages(settings),
      ),
      bottomNavigationBar: BottomNavBar(
        accentColor: accentColor,
        selectedIndex: _selectedIndex,
        useBlurEffect: true,
        onItemTapped: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
      ),
    );
  }
}

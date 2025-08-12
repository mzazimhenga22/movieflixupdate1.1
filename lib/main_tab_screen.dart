import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/home_screen_main.dart';
import 'package:movie_app/home_screen_lite.dart';
import 'package:movie_app/categories_screen.dart';
import 'package:movie_app/downloads_screen.dart';
import 'package:movie_app/interactive_features_screen.dart';
import 'package:movie_app/components/common_widgets.dart';

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

  /// Returns the list of tab pages
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

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final accentColor = settings.accentColor;

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
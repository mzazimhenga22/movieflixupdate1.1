import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

class SettingsProvider with ChangeNotifier {
  String _downloadQuality = 'Medium';
  bool _wifiOnlyDownloads = true;
  String _playbackQuality = '720p';
  bool _subtitlesEnabled = true;
  String _language = 'English';
  bool _autoPlayTrailers = true;
  bool _notificationsEnabled = true;
  bool _parentalControl = false;
  bool _dataSaverMode = false;
  bool _isDarkMode = false;
  double _cacheSize = 0.0;
  Color _accentColor = Colors.red;
  String _homeScreenType = 'standard';

  SettingsProvider() {
    _loadSettings();
  }

  String get downloadQuality => _downloadQuality;
  bool get wifiOnlyDownloads => _wifiOnlyDownloads;
  String get playbackQuality => _playbackQuality;
  bool get subtitlesEnabled => _subtitlesEnabled;
  String get language => _language;
  bool get autoPlayTrailers => _autoPlayTrailers;
  bool get notificationsEnabled => _notificationsEnabled;
  bool get parentalControl => _parentalControl;
  bool get dataSaverMode => _dataSaverMode;
  double get cacheSize => _cacheSize;
  bool get isDarkMode => _isDarkMode;
  Color get accentColor => _accentColor;
  String get homeScreenType => _homeScreenType;

  List<Color> get accentGradientColors => [
        _accentColor.withOpacity(0.5),
        _accentColor.withOpacity(0.3),
      ];

  Future<void> setDownloadQuality(String quality) async {
    _downloadQuality = quality;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('downloadQuality', quality);
    notifyListeners();
  }

  Future<void> setWifiOnlyDownloads(bool value) async {
    _wifiOnlyDownloads = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wifiOnlyDownloads', value);
    notifyListeners();
  }

  Future<void> setPlaybackQuality(String quality) async {
    _playbackQuality = quality;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('playbackQuality', quality);
    notifyListeners();
  }

  Future<void> setSubtitlesEnabled(bool value) async {
    _subtitlesEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('subtitlesEnabled', value);
    notifyListeners();
  }

  Future<void> setLanguage(String lang) async {
    _language = lang;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language', lang);
    notifyListeners();
  }

  Future<void> setAutoPlayTrailers(bool value) async {
    _autoPlayTrailers = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoPlayTrailers', value);
    notifyListeners();
  }

  Future<void> setNotificationsEnabled(bool value) async {
    _notificationsEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notificationsEnabled', value);
    notifyListeners();
  }

  Future<void> setParentalControl(bool value) async {
    _parentalControl = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('parentalControl', value);
    notifyListeners();
  }

  Future<void> setDataSaverMode(bool value) async {
    _dataSaverMode = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dataSaverMode', value);
    notifyListeners();
  }

  Future<void> setAccentColor(Color color) async {
    _accentColor = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('accentColor', color.value);
    notifyListeners();
  }

  Future<void> setHomeScreenType(String type) async {
    _homeScreenType = type;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('homeScreenType', type);
    notifyListeners();
  }

Future<void> setDarkMode(bool value) async {
  _isDarkMode = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('isDarkMode', value);
  notifyListeners();
}


Future<void> _loadSettings() async {
  final prefs = await SharedPreferences.getInstance();
  _downloadQuality = prefs.getString('downloadQuality') ?? 'Medium';
  _wifiOnlyDownloads = prefs.getBool('wifiOnlyDownloads') ?? true;
  _playbackQuality = prefs.getString('playbackQuality') ?? '720p';
  _subtitlesEnabled = prefs.getBool('subtitlesEnabled') ?? true;
  _language = prefs.getString('language') ?? 'English';
  _autoPlayTrailers = prefs.getBool('autoPlayTrailers') ?? true;
  _notificationsEnabled = prefs.getBool('notificationsEnabled') ?? true;
  _parentalControl = prefs.getBool('parentalControl') ?? false;
  _isDarkMode = prefs.getBool('isDarkMode') ?? false;
  _dataSaverMode = prefs.getBool('dataSaverMode') ?? false;
  _accentColor = Color(prefs.getInt('accentColor') ?? Colors.red.value);
  _homeScreenType = prefs.getString('homeScreenType') ?? 'standard';
  await _loadCacheSize();
  notifyListeners();
}

  Future<void> _loadCacheSize() async {
    final tempDir = await getTemporaryDirectory();
    double sizeInMB = 0.0;
    if (tempDir.existsSync()) {
      await for (var entity in tempDir.list(recursive: true)) {
        if (entity is File) {
          final sizeInBytes = await entity.length();
          sizeInMB += sizeInBytes / (1024 * 1024);
        }
      }
    }
    _cacheSize = sizeInMB;
    notifyListeners();
  }

  Future<void> clearCache() async {
    final tempDir = await getTemporaryDirectory();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
      await tempDir.create(recursive: true);
    }
    _cacheSize = 0.0;
    notifyListeners();
  }

  Locale getLocale() {
    switch (_language) {
      case 'Spanish':
        return const Locale('es');
      case 'French':
        return const Locale('fr');
      case 'German':
        return const Locale('de');
      case 'English':
      default:
        return const Locale('en');
    }
  }
}
// profile_selection_screen.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database/auth_database.dart';
import 'main_tab_screen.dart';
import 'signin_screen.dart';
import 'user_manager.dart';
import 'session_manager.dart';
import 'settings_provider.dart';
import 'package:flutter/painting.dart'; // for imageCache access

/// Lightweight defaults
const List<String> _kDefaultAvatars = [
  "assets/profile1.jpg",
  "assets/profile2.jpg",
  "assets/profile3.webp",
  "assets/profile4.jpg",
  "assets/profile5.jpg",
];

const List<String> _kDefaultBackgroundS = [
  "assets/background1.jpg",
  "assets/background2.jpg",
  "assets/background3.webp",
  "assets/background4.jpg",
  "assets/background5.jpg",
];

const List<String> _kDefaultBackgrounds = _kDefaultBackgroundS;

/// Serializers (kept simple)
Map<String, dynamic> _makeSerializableMap(Map m) {
  final out = <String, dynamic>{};
  m.forEach((k, v) {
    out[k.toString()] = _makeSerializableValue(v);
  });
  return out;
}

List _makeSerializableList(List l) => l.map(_makeSerializableValue).toList();

dynamic _makeSerializableValue(dynamic v) {
  if (v == null) return null;
  if (v is Timestamp) return v.toDate().toIso8601String();
  if (v is DateTime) return v.toIso8601String();
  if (v is Map) return _makeSerializableMap(v as Map);
  if (v is List) return _makeSerializableList(v as List);
  if (v is num || v is String || v is bool) return v;
  try {
    if (v is GeoPoint) return "${v.latitude},${v.longitude}";
  } catch (_) {}
  return v.toString();
}

/// Synchronous normalizer (avoids isolate overhead)
List<Map<String, dynamic>> _normalizeProfilesListSync(dynamic inData) {
  final raw = List<Map<String, dynamic>>.from(inData as List);
  final result = <Map<String, dynamic>>[];
  for (var item in raw) {
    final map = <String, dynamic>{};
    map['id'] = (item['id'] ?? '').toString();
    map['user_id'] = (item['user_id'] ?? '').toString();
    map['name'] = (item['name'] ?? 'Unknown Profile').toString().trim();
    var avatar = (item['avatar'] ?? '').toString().trim();
    var background = (item['backgroundImage'] ?? '').toString().trim();
    if (avatar.isEmpty) {
      avatar = _kDefaultAvatars.first;
    } else if (!avatar.startsWith('http') && !avatar.startsWith('assets/')) {
      avatar = 'https://$avatar';
    }
    if (background.isEmpty) {
      background = _kDefaultBackgrounds.first;
    } else if (!background.startsWith('http') && !background.startsWith('assets/')) {
      background = 'https://$background';
    }
    map['avatar'] = avatar;
    map['backgroundImage'] = background;
    map['locked'] = (item['locked'] ?? 0);
    map['pin'] = (item['pin'] ?? null);
    map['created_at'] = item['created_at']?.toString();
    map['updated_at'] = item['updated_at']?.toString();
    result.add(map);
  }
  return result;
}

/// Lightweight border animation widget (cheap)
class SimpleAnimatedBorder extends StatelessWidget {
  const SimpleAnimatedBorder({
    super.key,
    required this.child,
    required this.color,
    required this.opacityAnimation,
    this.borderWidth = 2.0,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  final Widget child;
  final Color color;
  final Animation<double> opacityAnimation;
  final double borderWidth;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: opacityAnimation,
      builder: (context, _) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            border: Border.all(
              color: color.withOpacity((0.35 + 0.65 * opacityAnimation.value).clamp(0.1, 1.0)),
              width: borderWidth,
            ),
          ),
          child: child,
        );
      },
      child: child,
    );
  }
}

class AnimatedBorderBox extends StatelessWidget {
  const AnimatedBorderBox({
    super.key,
    required this.index,
    required this.child,
    required this.animation,
    required this.accent,
  });

  final int index;
  final Widget child;
  final Animation<double> animation;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return SimpleAnimatedBorder(
      color: accent,
      opacityAnimation: animation,
      borderWidth: 2,
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: child,
    );
  }
}

class ProfileSelectionScreen extends StatefulWidget {
  const ProfileSelectionScreen({super.key});

  @override
  State<ProfileSelectionScreen> createState() => _ProfileSelectionScreenState();
}

class _ProfileSelectionScreenState extends State<ProfileSelectionScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool isEditing = false;

  // Use ValueNotifier (lighter than StreamController)
  final ValueNotifier<List<Map<String, dynamic>>> _profilesNotifier =
      ValueNotifier<List<Map<String, dynamic>>>([]);

  List<Map<String, dynamic>> _profiles = [];
  int get maxProfiles => 5;
  static const List<String> defaultAvatars = _kDefaultAvatars;
  static const List<String> defaultBackgrounds = _kDefaultBackgrounds;

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseMessaging _fcm = FirebaseMessaging.instance;

  StreamSubscription<String>? _fcmTokenRefreshSub;
  String? _fcmSavedForUserId;

  late final AnimationController _sharedBorderController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // reduce flutter image cache to mitigate OOM on low-memory emulators
    try {
      PaintingBinding.instance.imageCache.maximumSize = 30; // slightly lower
      PaintingBinding.instance.imageCache.maximumSizeBytes = 6 * 1024 * 1024; // 6MB
      debugPrint('⚙️ imageCache limits set: maxSize=30, maxBytes=6MB');
    } catch (e) {
      debugPrint('⚠️ failed to set imageCache limits: $e');
    }

    _sharedBorderController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Future.delayed(const Duration(milliseconds: 250), () {
        if (mounted && !_sharedBorderController.isAnimating) {
          try {
            _sharedBorderController.repeat(reverse: true);
          } catch (_) {}
        }
      });
    });

    try {
      _firestore.settings = const Settings(persistenceEnabled: true);
    } catch (e) {
      debugPrint('❌ firestore settings error: $e');
    }

    _loadCurrentUserAndProfiles();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _profilesNotifier.dispose();
    _fcmTokenRefreshSub?.cancel();
    try {
      // clear caches to free memory aggressively on dispose
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}
    _sharedBorderController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      try {
        _sharedBorderController.stop(canceled: false);
      } catch (_) {}
    } else if (state == AppLifecycleState.resumed) {
      try {
        if (!_sharedBorderController.isAnimating) {
          _sharedBorderController.repeat(reverse: true);
        }
      } catch (_) {}
    }
  }

  Future<void> _ensureFcmTokenSavedForUser(String userId) async {
    try {
      if (_fcmSavedForUserId == userId) return;
      final token = await _fcm.getToken();
      if (token != null && token.isNotEmpty) {
        try {
          await _firestore.collection('users').doc(userId).set({'fcmToken': token}, SetOptions(merge: true));
        } catch (e) {
          debugPrint('[FCM] failed saving token to firestore: $e');
        }
      }
      await _fcmTokenRefreshSub?.cancel();
      _fcmTokenRefreshSub = _fcm.onTokenRefresh.listen((newToken) async {
        try {
          if (newToken != null && newToken.isNotEmpty) {
            await _firestore.collection('users').doc(userId).set({'fcmToken': newToken}, SetOptions(merge: true));
          }
        } catch (e) {
          debugPrint('[FCM] failed saving refreshed token: $e');
        }
      });
      _fcmSavedForUserId = userId;
    } catch (e) {
      debugPrint('[FCM] _ensureFcmTokenSavedForUser error: $e');
    }
  }

  Future<void> _loadCurrentUserAndProfiles() async {
    try {
      await AuthDatabase.instance.initialize();
      final user = _auth.currentUser;
      if (user == null) {
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SignInScreen()));
          });
        }
        return;
      }

      final sessionDoc = await _firestore.collection('sessions').doc(user.uid).get();
      if (!sessionDoc.exists) {
        final token = await user.getIdToken();
        if (token == null) {
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SignInScreen()));
            });
          }
          return;
        }
        await _firestore.collection('sessions').doc(user.uid).set({
          'userId': user.uid,
          'token': token,
          'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(days: 5))),
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        await SessionManager.saveAuthToken(token);
        await SessionManager.saveSessionUserId(user.uid);
      } else {
        final sessionData = sessionDoc.data();
        final expiresAt = sessionData?['expiresAt'] as Timestamp?;
        if (expiresAt == null || DateTime.now().isAfter(expiresAt.toDate())) {
          if (!mounted) return;
          await SessionManager.clearAuthToken();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SignInScreen()));
          });
          return;
        }
      }

      await _ensureFcmTokenSavedForUser(user.uid);
      await _refreshProfiles();
    } catch (e) {
      debugPrint('❌ Error in _loadCurrentUserAndProfiles: $e');
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error loading profiles')));
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SignInScreen()));
        });
      }
    }
  }

  Future<void> _refreshProfiles() async {
    final user = UserManager.instance.currentUser.value;
    if (user == null) {
      _profiles = [];
      _profilesNotifier.value = _profiles;
      if (mounted) setState(() {});
      return;
    }
    final userId = user['id']?.toString() ?? '';
    if (userId.isEmpty) {
      _profiles = [];
      _profilesNotifier.value = _profiles;
      if (mounted) setState(() {});
      return;
    }

    await _ensureFcmTokenSavedForUser(userId);

    try {
      // Try cache first (light)
      final snapshot = await _firestore
          .collection('profiles')
          .where('user_id', isEqualTo: userId)
          .where('locked', isEqualTo: 0)
          .orderBy('created_at')
          .get(const GetOptions(source: Source.cache));

      List<Map<String, dynamic>> rawProfiles = [];

      if (snapshot.docs.isNotEmpty) {
        rawProfiles = snapshot.docs.map((d) {
          final data = Map<String, dynamic>.from(d.data());
          data['id'] = d.id;
          return data;
        }).toList();
      } else {
        final serverSnapshot = await _firestore
            .collection('profiles')
            .where('user_id', isEqualTo: userId)
            .where('locked', isEqualTo: 0)
            .orderBy('created_at')
            .get(const GetOptions(source: Source.serverAndCache));
        if (serverSnapshot.docs.isNotEmpty) {
          rawProfiles = serverSnapshot.docs.map((d) {
            final data = Map<String, dynamic>.from(d.data());
            data['id'] = d.id;
            return data;
          }).toList();
        } else {
          final local = await AuthDatabase.instance.getProfilesByUserId(userId);
          rawProfiles = List<Map<String, dynamic>>.from(local);
        }
      }

      final serializable = rawProfiles.map((m) => _makeSerializableMap(m)).toList();

      // Normalize synchronously to avoid isolate overhead
      List<Map<String, dynamic>> normalized = [];
      try {
        normalized = _normalizeProfilesListSync(serializable);
      } catch (e) {
        debugPrint('⚠️ normalization failed (fallback): $e');
        normalized = List<Map<String, dynamic>>.from(rawProfiles);
      }

      _profiles = List<Map<String, dynamic>>.from(normalized);
      _profilesNotifier.value = _profiles;

      if (mounted) setState(() {});
      // Update local DB asynchronously without awaiting UI-blocking operations
      _updateLocalProfilesAsync(rawProfiles);
    } catch (e) {
      debugPrint('❌ Error refreshing profiles: $e');
      try {
        final profiles = await AuthDatabase.instance.getProfilesByUserId(userId);
        _profiles = List<Map<String, dynamic>>.from(profiles);
        _profilesNotifier.value = _profiles;
        if (mounted) setState(() {});
      } catch (localError) {
        debugPrint('❌ Error fetching from local database: $localError');
        _profiles = [];
        _profilesNotifier.value = _profiles;
        if (mounted) setState(() {});
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error refreshing profiles')));
          });
        }
      }
    }
  }

  void _updateLocalProfilesAsync(List<Map<String, dynamic>> profiles) {
    // Fire-and-forget local updates
    Future(() async {
      try {
        for (var profileData in profiles) {
          await AuthDatabase.instance.updateProfile(profileData);
        }
      } catch (e) {
        debugPrint('❌ local DB update failed: $e');
      }
    });
  }

  String _processUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return u;
    if (!u.startsWith('http://') && !u.startsWith('https://') && !u.startsWith('assets/')) {
      u = 'https://$u';
    }
    return u;
  }

  void _showAddProfileDialog() {
    final user = UserManager.instance.currentUser.value;
    if (user == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No user logged in.")));
      }
      return;
    }
    final userId = user['id']?.toString() ?? '';
    if (userId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Invalid user ID.")));
      }
      return;
    }
    if (_profiles.length >= maxProfiles) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Maximum 5 profiles allowed.")));
      }
      return;
    }

    final nameController = TextEditingController();
    final avatarController = TextEditingController();
    final pinController = TextEditingController();

    if (mounted) {
      showDialog<void>(
        context: context,
        builder: (context) {
          final accent = Provider.of<SettingsProvider>(context).accentColor;
          return AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text("Add Profile", style: TextStyle(color: Colors.white)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: "Name",
                      labelStyle: const TextStyle(color: Colors.white70),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.03),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: avatarController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: "Avatar URL (optional)",
                      labelStyle: const TextStyle(color: Colors.white70),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.03),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: pinController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: "PIN (optional)",
                      labelStyle: const TextStyle(color: Colors.white70),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.03),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                    ),
                    keyboardType: TextInputType.number,
                    obscureText: true,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                child: Text("Cancel", style: TextStyle(color: accent.withOpacity(0.9))),
                onPressed: () => Navigator.pop(context),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: accent),
                child: const Text("Add"),
                onPressed: () async {
                  if (!mounted) return;
                  final scaffoldMessenger = ScaffoldMessenger.of(context);
                  if (nameController.text.trim().isEmpty) {
                    scaffoldMessenger.showSnackBar(const SnackBar(content: Text("Profile name is required.")));
                    return;
                  }
                  try {
                    String avatarUrl = avatarController.text.trim();
                    String backgroundUrl;
                    if (avatarUrl.isEmpty) {
                      final usedAvatars = _profiles.map((p) => p['avatar'] as String).where((a) => defaultAvatars.contains(a)).toList();
                      final availableAvatars = defaultAvatars.where((a) => !usedAvatars.contains(a)).toList();
                      avatarUrl = availableAvatars.isNotEmpty ? availableAvatars.first : defaultAvatars.first;
                      backgroundUrl = defaultBackgrounds.first;
                    } else {
                      avatarUrl = _processUrl(avatarUrl);
                      backgroundUrl = defaultBackgrounds.first;
                    }
                    final newProfile = {
                      'id': DateTime.now().millisecondsSinceEpoch.toString(),
                      'user_id': userId,
                      'name': nameController.text.trim(),
                      'avatar': avatarUrl,
                      'backgroundImage': backgroundUrl,
                      'pin': pinController.text.trim().isEmpty ? null : pinController.text.trim(),
                      'locked': pinController.text.trim().isEmpty ? 0 : 1,
                      'created_at': DateTime.now().toIso8601String(),
                      'updated_at': DateTime.now().toIso8601String(),
                    };
                    await AuthDatabase.instance.createProfile(newProfile);
                    await _firestore.collection('profiles').doc(newProfile['id'] as String).set(newProfile, SetOptions(merge: true));
                    Navigator.pop(context);
                    await _refreshProfiles();
                    scaffoldMessenger.showSnackBar(SnackBar(content: Text("Profile '${newProfile['name']}' created.")));
                  } catch (e) {
                    debugPrint('❌ Error creating profile: $e');
                    scaffoldMessenger.showSnackBar(const SnackBar(content: Text('Error creating profile')));
                  }
                },
              ),
            ],
          );
        },
      );
    }
  }

  Future<void> _updateAvatar(Map<String, dynamic> profile) async {
    final currentAvatar = profile['avatar'] as String? ?? "";
    final avatarController = TextEditingController(text: currentAvatar);

    if (mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) {
          final accent = Provider.of<SettingsProvider>(context).accentColor;
          return AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text("Update Avatar URL", style: TextStyle(color: Colors.white)),
            content: SingleChildScrollView(
              child: TextField(
                controller: avatarController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: "New Avatar URL",
                  labelStyle: const TextStyle(color: Colors.white70),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.03),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                ),
              ),
            ),
            actions: [
              TextButton(
                child: Text("Cancel", style: TextStyle(color: accent.withOpacity(0.9))),
                onPressed: () => Navigator.pop(context),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: accent),
                child: const Text("Update"),
                onPressed: () async {
                  if (!mounted) return;
                  final scaffoldMessenger = ScaffoldMessenger.of(context);
                  final newUrl = _processUrl(avatarController.text.trim());
                  if (newUrl.isEmpty) {
                    scaffoldMessenger.showSnackBar(const SnackBar(content: Text("Avatar URL cannot be empty.")));
                    return;
                  }
                  if (newUrl == currentAvatar) {
                    Navigator.pop(context);
                    return;
                  }
                  profile['avatar'] = newUrl;
                  try {
                    await AuthDatabase.instance.updateProfile(profile);
                    await _firestore.collection('profiles').doc(profile['id'] as String).update({'avatar': newUrl});
                    Navigator.pop(context);
                    await _refreshProfiles();
                    scaffoldMessenger.showSnackBar(const SnackBar(content: Text("Avatar updated.")));
                  } catch (e) {
                    debugPrint('❌ Error updating avatar: $e');
                    scaffoldMessenger.showSnackBar(const SnackBar(content: Text('Error updating avatar')));
                  }
                },
              ),
            ],
          );
        },
      );
    }
  }

  Future<void> _deleteProfile(Map<String, dynamic> profile) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        final accent = Provider.of<SettingsProvider>(context).accentColor;
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text("Confirm Deletion", style: TextStyle(color: Colors.white)),
          content: Text(
            "Are you sure you want to delete profile '${profile['name']}'?",
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              child: Text("Cancel", style: TextStyle(color: accent.withOpacity(0.9))),
              onPressed: () => Navigator.pop(context, false),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: accent),
              child: const Text("Delete"),
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) return;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final profileId = profile['id']?.toString() ?? '';
    if (profileId.isEmpty) {
      scaffoldMessenger.showSnackBar(const SnackBar(content: Text("Invalid profile ID.")));
      return;
    }
    try {
      await AuthDatabase.instance.deleteProfile(profileId);
      await _firestore.collection('profiles').doc(profileId).delete();
      await _refreshProfiles();
      scaffoldMessenger.showSnackBar(SnackBar(content: Text("Profile '${profile['name']}' deleted.")));
    } catch (e) {
      debugPrint('❌ Error deleting profile: $e');
      scaffoldMessenger.showSnackBar(const SnackBar(content: Text('Error deleting profile')));
    }
  }

  void _onProfileTapped(Map<String, dynamic> profile) {
    if (isEditing) return;
    if ((profile['pin'] as String?)?.isNotEmpty ?? false) {
      _showPinDialog(profile);
    } else {
      _selectProfile(profile);
    }
  }

  void _showPinDialog(Map<String, dynamic> profile) {
    final pinController = TextEditingController();
    if (mounted) {
      showDialog<void>(
        context: context,
        builder: (context) {
          final accent = Provider.of<SettingsProvider>(context).accentColor;
          return AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text("Enter PIN", style: TextStyle(color: Colors.white)),
            content: SingleChildScrollView(
              child: TextField(
                controller: pinController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: "PIN",
                  labelStyle: const TextStyle(color: Colors.white70),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.03),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                ),
                keyboardType: TextInputType.number,
                obscureText: true,
              ),
            ),
            actions: [
              TextButton(
                child: Text("Cancel", style: TextStyle(color: accent.withOpacity(0.9))),
                onPressed: () => Navigator.pop(context),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: accent),
                child: const Text("Submit"),
                onPressed: () {
                  if (!mounted) return;
                  if (pinController.text.trim() == profile['pin']) {
                    Navigator.pop(context);
                    _selectProfile(profile);
                  } else {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Incorrect PIN for profile '${profile['name']}'.")));
                  }
                },
              ),
            ],
          );
        },
      );
    }
  }

  Future<void> _rememberLastSelectedProfileLocally(String profileId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_selected_profile', profileId);
    } catch (e) {
      debugPrint('❌ failed to save last_selected_profile locally: $e');
    }
  }

  void _selectProfile(Map<String, dynamic> profile) async {
    UserManager.instance.updateProfile(profile);

    final currentUser = UserManager.instance.currentUser.value;
    final userId = currentUser?['id']?.toString() ?? _auth.currentUser?.uid;
    if (userId != null && userId.isNotEmpty) {
      try {
        await _firestore.collection('users').doc(userId).update({
          'last_selected_profile': profile['id'],
          'last_selected_profile_name': profile['name'],
          'updated_at': FieldValue.serverTimestamp(),
        });
        await _rememberLastSelectedProfileLocally(profile['id']?.toString() ?? '');
      } catch (e) {
        debugPrint('❌ failed saving last_selected_profile: $e');
      }
      await _ensureFcmTokenSavedForUser(userId);
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (context, animation, secondaryAnimation) => MainTabScreen(profileName: profile['name'] as String),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final fadeTween = Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeInOut));
          return FadeTransition(opacity: animation.drive(fadeTween), child: child);
        },
      ),
    );
  }

  Widget _frostedTile({
    required Widget child,
    required double radius,
    required Color accent,
    EdgeInsetsGeometry? padding,
    BoxConstraints? constraints,
  }) {
    // simplified "frost" effect
    return Container(
      padding: padding ?? const EdgeInsets.all(8),
      constraints: constraints,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: Colors.black.withOpacity(0.35),
        border: Border.all(color: accent.withOpacity(0.12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 6,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildAddProfileTile(Color accent) {
    return GestureDetector(
      onTap: _showAddProfileDialog,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: _frostedTile(
          radius: 12,
          accent: accent,
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: const Center(child: Icon(Icons.add, color: Colors.white, size: 34)),
        ),
      ),
    );
  }

  Widget _buildProfileTile(Map<String, dynamic> profile, int index, Color accent) {
    final name = profile['name'] as String? ?? "Unknown Profile";
    var avatar = profile['avatar'] as String? ?? "";
    var background = profile['backgroundImage'] as String? ?? "";
    final locked = (profile['locked'] as int?) == 1;

    if (avatar.isEmpty) avatar = defaultAvatars.first;
    if (background.isEmpty) background = defaultBackgrounds.first;

    const double avatarRadius = 36.0;
    const double avatarImageSize = 64.0;

    final tile = GestureDetector(
      onTap: () => _onProfileTapped(profile),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: LayoutBuilder(builder: (context, constraints) {
                final dpr = MediaQuery.of(context).devicePixelRatio;
                final targetWidth = (constraints.maxWidth * dpr).clamp(64, 800).toInt();
                final targetHeight = (constraints.maxHeight * dpr).clamp(64, 800).toInt();

                if (background.startsWith('assets/')) {
                  return Image.asset(
                    background,
                    fit: BoxFit.cover,
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    errorBuilder: (c, e, st) => Container(color: Colors.grey[900]),
                  );
                } else {
                  return Image.network(
                    background,
                    fit: BoxFit.cover,
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    cacheWidth: targetWidth,
                    cacheHeight: targetHeight,
                    filterQuality: FilterQuality.low,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Container(color: Colors.grey[900]);
                    },
                    errorBuilder: (c, e, st) => Container(color: Colors.grey[900]),
                  );
                }
              }),
            ),

            // simplified frosted overlay
            Positioned.fill(
              child: _frostedTile(
                radius: 12,
                accent: accent,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.expand(),
                child: const SizedBox.shrink(),
              ),
            ),

            Positioned.fill(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Avatar
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.grey[850],
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.18),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        )
                      ],
                    ),
                    child: CircleAvatar(
                      radius: avatarRadius,
                      backgroundColor: Colors.grey[850],
                      child: ClipOval(
                        child: LayoutBuilder(builder: (context, avatarConstraints) {
                          final dpr = MediaQuery.of(context).devicePixelRatio;
                          final avatarPx = (avatarRadius * 2 * dpr).clamp(32, 256).toInt();

                          if (avatar.startsWith('assets/')) {
                            return Image.asset(
                              avatar,
                              width: avatarImageSize,
                              height: avatarImageSize,
                              fit: BoxFit.cover,
                              errorBuilder: (c, e, st) => Container(
                                width: avatarImageSize,
                                height: avatarImageSize,
                                color: Colors.grey[700],
                                child: const Icon(Icons.person, color: Colors.white30),
                              ),
                            );
                          } else {
                            return Image.network(
                              avatar,
                              width: avatarImageSize,
                              height: avatarImageSize,
                              fit: BoxFit.cover,
                              cacheWidth: avatarPx,
                              cacheHeight: avatarPx,
                              filterQuality: FilterQuality.low,
                              loadingBuilder: (c, child, progress) {
                                if (progress == null) return child;
                                return Container(
                                  width: avatarImageSize,
                                  height: avatarImageSize,
                                  color: Colors.grey[700],
                                  child: const Icon(Icons.person, color: Colors.white30),
                                );
                              },
                              errorBuilder: (c, e, st) => Container(
                                width: avatarImageSize,
                                height: avatarImageSize,
                                color: Colors.grey[700],
                                child: const Icon(Icons.person, color: Colors.white30),
                              ),
                            );
                          }
                        }),
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6.0),
                    child: Text(
                      name,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (locked) const Icon(Icons.lock, color: Colors.white70, size: 16),
                  if (isEditing)
                    Padding(
                      padding: const EdgeInsets.only(top: 6.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: Icon(Icons.edit, color: accent.withOpacity(0.95), size: 20),
                            onPressed: () => _updateAvatar(profile),
                            tooltip: "Edit avatar",
                          ),
                          IconButton(
                            icon: Icon(Icons.delete, color: accent.withOpacity(0.95), size: 20),
                            onPressed: () => _deleteProfile(profile),
                            tooltip: "Delete profile",
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return AnimatedBorderBox(index: index, animation: _sharedBorderController, accent: accent, child: tile);
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final accent = settings.accentColor;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Select Your Profile", style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: _refreshProfiles,
            icon: Icon(Icons.refresh, color: accent),
            tooltip: "Refresh profiles",
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.2, -0.6),
                radius: 1.1,
                colors: [accent.withOpacity(0.16), accent.withOpacity(0.04), Colors.black],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [accent.withOpacity(0.02), Colors.transparent]),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: Text(
                    "Choose a profile to continue",
                    style: TextStyle(color: Colors.white.withOpacity(0.92), fontSize: 18, fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                    valueListenable: _profilesNotifier,
                    builder: (context, profiles, _) {
                      if (profiles.isEmpty) {
                        // show spinner while initial load
                        return const Center(child: CircularProgressIndicator());
                      }

                      final itemCount = profiles.length < maxProfiles ? profiles.length + 1 : profiles.length;

                      final width = MediaQuery.of(context).size.width;
                      int crossAxisCount = 2;
                      double childAspect = 0.95;
                      if (width > 1200) {
                        crossAxisCount = 4;
                        childAspect = 1.0;
                      } else if (width > 900) {
                        crossAxisCount = 3;
                        childAspect = 0.98;
                      } else if (width > 600) {
                        crossAxisCount = 2;
                        childAspect = 0.95;
                      } else {
                        crossAxisCount = 2;
                        childAspect = 0.95;
                      }

                      return GridView.builder(
                        padding: const EdgeInsets.all(18),
                        addAutomaticKeepAlives: false,
                        addRepaintBoundaries: false,
                        cacheExtent: 200,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: childAspect,
                        ),
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          if (index == profiles.length && profiles.length < maxProfiles) {
                            return _buildAddProfileTile(accent);
                          }
                          final p = profiles[index];
                          return _buildProfileTile(p, index, accent);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            isEditing = !isEditing;
          });
        },
        backgroundColor: accent,
        child: Icon(isEditing ? Icons.check : Icons.edit, color: Colors.white),
      ),
    );
  }
}

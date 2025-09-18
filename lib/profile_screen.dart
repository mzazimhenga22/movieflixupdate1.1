import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/signin_screen.dart';
import 'package:movie_app/account_screen.dart';
import 'package:movie_app/settings_screen.dart';
import 'package:movie_app/watch_history_screen.dart';
import 'package:movie_app/marketplace/marketplace_home.dart';
import 'package:shimmer/shimmer.dart';
import 'package:movie_app/database/auth_database.dart';
import 'package:movie_app/user_manager.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:movie_app/session_manager.dart';
import 'dart:math';

class AnimatedBackground extends StatelessWidget {
  const AnimatedBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.redAccent, Colors.blueAccent],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final Map<String, dynamic> _defaultProfile = {
    'name': 'Guest',
    'avatar': null,
    'backgroundImage': null,
    'email': '',
    'bio': '',
  };

  late Future<Map<String, dynamic>> _profileFuture;

  @override
  void initState() {
    super.initState();
    _profileFuture = _fetchProfile();
  }

  Future<Map<String, dynamic>> _fetchProfile() async {
    try {
      debugPrint('Fetching profile data...');
      final Map<String, dynamic>? profile = UserManager.instance.currentProfile.value;
      final Map<String, dynamic>? user = UserManager.instance.currentUser.value;
      debugPrint('User: $user');
      debugPrint('Profile: $profile');

      if (user == null) {
        debugPrint('No user logged in, returning default profile');
        return _defaultProfile;
      }

      final Map<String, dynamic>? userFromDB = await AuthDatabase.instance.getUserById(user['id']);
      final Map<String, dynamic> userData = userFromDB ?? user;
      debugPrint('User from DB: $userFromDB');

      if (profile != null && profile['id'] != null) {
        final Map<String, dynamic>? profileFromDB = await AuthDatabase.instance.getProfileById(profile['id']);
        debugPrint('Profile from DB: $profileFromDB');
        if (profileFromDB != null) {
          final Map<String, dynamic> combinedData = {
            'id': profileFromDB['id'],
            'name': profileFromDB['name'] ?? 'Unnamed',
            'avatar': profileFromDB['avatar'],
            'backgroundImage': profileFromDB['backgroundImage'],
            'email': userData['email'] ?? '',
            'bio': userData['bio'] ?? '',
          };
          UserManager.instance.updateProfile(combinedData);
          return combinedData;
        }
        final Map<String, dynamic> fallbackProfile = {
          'id': profile['id'],
          'name': profile['name'] ?? 'Unnamed',
          'avatar': profile['avatar'],
          'backgroundImage': profile['backgroundImage'],
          'email': userData['email'] ?? '',
          'bio': userData['bio'] ?? '',
        };
        return fallbackProfile;
      } else {
        final int userId = userData['id'] as int? ?? 0;
        final String userName = userData['username'] as String? ?? 'User $userId';
        final Map<String, dynamic> profileData = {
          'id': userId,
          'name': userName,
          'avatar': userData['avatar'],
          'backgroundImage': null,
          'email': userData['email'] ?? '',
          'bio': userData['bio'] ?? '',
        };
        UserManager.instance.updateProfile(profileData);
        return profileData;
      }
    } catch (e, stackTrace) {
      debugPrint('Error fetching profile: $e\n$stackTrace');
      final Map<String, dynamic>? user = UserManager.instance.currentUser.value;
      final Map<String, dynamic>? profile = UserManager.instance.currentProfile.value;
      final Map<String, dynamic> fallbackProfile = profile ?? {};
      final int fallbackId = fallbackProfile['id'] as int? ?? user?['id'] as int? ?? 0;
      final String fallbackName = fallbackProfile['name'] as String? ?? user?['username'] as String? ?? 'User $fallbackId';
      return {
        'id': fallbackId,
        'name': fallbackName,
        'avatar': fallbackProfile['avatar'],
        'backgroundImage': null,
        'email': user?['email'] ?? '',
        'bio': user?['bio'] ?? '',
      };
    }
  }

  Future<void> _onRefresh() async {
    setState(() {
      _profileFuture = _fetchProfile();
    });
  }

  Widget _buildShimmerPlaceholder() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          children: [
            Container(
              height: 250,
              color: Colors.grey[300],
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 50,
                    backgroundColor: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: 150,
                    height: 24,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 200,
                    height: 16,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 250,
                    height: 16,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 24),
                  Container(
                    height: 60,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: List.generate(
                          4,
                          (index) => [
                                ListTile(
                                  leading: Container(
                                    width: 24,
                                    height: 24,
                                    color: Colors.grey[400],
                                  ),
                                  title: Container(
                                    width: 100,
                                    height: 16,
                                    color: Colors.grey[400],
                                  ),
                                  trailing: Container(
                                    width: 16,
                                    height: 16,
                                    color: Colors.grey[400],
                                  ),
                                ),
                                if (index < 3)
                                  Divider(color: Colors.grey[400], height: 1),
                              ]).expand((element) => element).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final SettingsProvider settings = Provider.of<SettingsProvider>(context);
    final double screenHeight = MediaQuery.of(context).size.height;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const AnimatedBackground(),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.06, -0.34),
                  radius: 1.0,
                  colors: [
                    settings.accentColor.withOpacity(0.5),
                    const Color.fromARGB(255, 0, 0, 0),
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
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color.fromARGB(160, 17, 19, 40),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withOpacity(0.125)),
                      ),
                      child: RefreshIndicator(
                        onRefresh: _onRefresh,
                        child: FutureBuilder<Map<String, dynamic>>(
                          future: _profileFuture,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return ConstrainedBox(
                                constraints: BoxConstraints(minHeight: screenHeight),
                                child: _buildShimmerPlaceholder(),
                              );
                            }
                            if (snapshot.hasError) {
                              debugPrint('Profile fetch error: ${snapshot.error}');
                              return Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text('Error loading profile: ${snapshot.error}'),
                                    ElevatedButton(
                                      onPressed: _onRefresh,
                                      child: const Text('Retry'),
                                    ),
                                  ],
                                ),
                              );
                            }
                            final Map<String, dynamic> profile = snapshot.data ?? _defaultProfile;
                            debugPrint('Building profile UI with data: $profile');
                            return CustomScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              slivers: [
                                SliverAppBar(
                                  expandedHeight: 250,
                                  pinned: true,
                                  backgroundColor: Colors.transparent,
                                  flexibleSpace: FlexibleSpaceBar(
                                    title: Text(
                                      profile['name'] as String? ?? 'Unnamed',
                                      style: TextStyle(
                                        color: settings.accentColor,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    background: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        _buildBackgroundImage(profile['backgroundImage'] as String?),
                                        DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              colors: [
                                                Colors.black.withOpacity(0.8),
                                                Colors.transparent,
                                              ],
                                              begin: Alignment.bottomCenter,
                                              end: Alignment.topCenter,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Column(
                                      children: [
                                        _buildAvatar(profile['avatar'] as String?),
                                        const SizedBox(height: 16),
                                        Text(
                                          profile['name'] as String? ?? 'Unnamed',
                                          style: TextStyle(
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                            color: settings.accentColor,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          (profile['email'] as String?)?.isNotEmpty ?? false
                                              ? profile['email'] as String
                                              : "No email provided",
                                          style: const TextStyle(
                                            fontSize: 16,
                                            color: Colors.white70,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          (profile['bio'] as String?)?.isNotEmpty ?? false
                                              ? profile['bio'] as String
                                              : "No bio available",
                                          style: const TextStyle(
                                            fontSize: 16,
                                            color: Colors.white70,
                                          ),
                                        ),
                                        const SizedBox(height: 24),
                                        GestureDetector(
                                          onTap: () {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) => MarketplaceHomeScreen(
                                                  userName: profile['name'] as String? ?? 'Unnamed',
                                                  userEmail: profile['email'] as String? ?? 'No email provided',
                                                  userAvatar: profile['avatar'] as String?,
                                                ),
                                              ),
                                            );
                                          },
                                          child: Card(
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            elevation: 4,
                                            child: Container(
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
                                                  color: settings.accentColor.withOpacity(0.5),
                                                  width: 1.5,
                                                ),
                                              ),
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      Icons.storefront,
                                                      color: settings.accentColor,
                                                    ),
                                                    const SizedBox(width: 16),
                                                    const Text(
                                                      'Marketplace',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 18,
                                                        fontWeight: FontWeight.bold,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 24),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(12),
                                          child: BackdropFilter(
                                            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                                            child: Container(
                                              decoration: BoxDecoration(
                                                gradient: LinearGradient(
                                                  colors: [
                                                    settings.accentColor.withOpacity(0.2),
                                                    Colors.black.withAlpha(128),
                                                  ],
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                ),
                                                borderRadius: BorderRadius.circular(12),
                                                border: Border.all(color: Colors.white24),
                                              ),
                                              child: Column(
                                                children: [
                                                  _buildOptionTile(
                                                    icon: Icons.person,
                                                    title: 'Account',
                                                    onTap: () => Navigator.push(
                                                      context,
                                                      MaterialPageRoute(
                                                        builder: (context) => const AccountScreen(),
                                                      ),
                                                    ),
                                                  ),
                                                  const Divider(color: Colors.white24, height: 1),
                                                  _buildOptionTile(
                                                    icon: Icons.settings,
                                                    title: 'Settings',
                                                    onTap: () => Navigator.push(
                                                      context,
                                                      MaterialPageRoute(
                                                        builder: (context) => const SettingsScreen(),
                                                      ),
                                                    ),
                                                  ),
                                                  const Divider(color: Colors.white24, height: 1),
                                                  _buildOptionTile(
                                                    icon: Icons.history,
                                                    title: 'Watch History',
                                                    onTap: () => Navigator.push(
                                                      context,
                                                      MaterialPageRoute(
                                                        builder: (context) => const WatchHistoryScreen(),
                                                      ),
                                                    ),
                                                  ),
                                                  const Divider(color: Colors.white24, height: 1),
                                                  _buildOptionTile(
                                                    icon: Icons.logout,
                                                    title: 'Logout',
                                                    onTap: () async {
                                                      await FirebaseAuth.instance.signOut();
                                                      await SessionManager.clearAuthToken();
                                                      UserManager.instance.clearUser();
                                                      Navigator.pushReplacement(
                                                        context,
                                                        MaterialPageRoute(
                                                          builder: (context) => const SignInScreen(),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
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

  Widget _buildBackgroundImage(String? imageUrl) {
    if (imageUrl != null && imageUrl.isNotEmpty) {
      if (imageUrl.startsWith('assets/')) {
        return Image(
          image: AssetImage(imageUrl),
          fit: BoxFit.cover,
        );
      } else if (Uri.tryParse(imageUrl)?.hasAbsolutePath == true) {
        return Image(
          image: CachedNetworkImageProvider(imageUrl),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            debugPrint('Background image load error: $error');
            return const AnimatedPlaceholderImage();
          },
        );
      }
    }
    return const AnimatedPlaceholderImage();
  }

  Widget _buildAvatar(String? avatar) {
    if (avatar != null && avatar.isNotEmpty) {
      if (avatar.startsWith('assets/')) {
        return CircleAvatar(
          radius: 50,
          backgroundImage: AssetImage(avatar),
          backgroundColor: Colors.grey[900],
        );
      } else if (Uri.tryParse(avatar)?.hasAbsolutePath == true) {
        return CircleAvatar(
          radius: 50,
          backgroundImage: CachedNetworkImageProvider(avatar),
          backgroundColor: Colors.grey[900],
          onBackgroundImageError: (error, stackTrace) {
            debugPrint('Avatar image load error: $error');
          },
        );
      }
    }
    return CircleAvatar(
      radius: 50,
      backgroundImage: const CachedNetworkImageProvider('https://via.placeholder.com/150'),
      backgroundColor: Colors.grey[900],
    );
  }

  Widget _buildOptionTile({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: Provider.of<SettingsProvider>(context).accentColor),
      title: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
      trailing: Icon(
        Icons.arrow_forward_ios,
        color: Provider.of<SettingsProvider>(context).accentColor.withOpacity(0.7),
        size: 16,
      ),
      onTap: onTap,
    );
  }
}

class AnimatedPlaceholderAvatar extends StatefulWidget {
  final double size;

  const AnimatedPlaceholderAvatar({super.key, required this.size});

  @override
  State<AnimatedPlaceholderAvatar> createState() => _AnimatedPlaceholderAvatarState();
}

class _AnimatedPlaceholderAvatarState extends State<AnimatedPlaceholderAvatar> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              startAngle: 0.0,
              endAngle: 2 * pi,
              colors: [
                Provider.of<SettingsProvider>(context).accentColor,
                Colors.red,
                Provider.of<SettingsProvider>(context).accentColor,
              ],
              transform: GradientRotation(_controller.value * 2 * pi),
            ),
          ),
        );
      },
    );
  }
}

class AnimatedPlaceholderImage extends StatefulWidget {
  const AnimatedPlaceholderImage({super.key});

  @override
  State<AnimatedPlaceholderImage> createState() => _AnimatedPlaceholderImageState();
}

class _AnimatedPlaceholderImageState extends State<AnimatedPlaceholderImage> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            image: const DecorationImage(
              image: CachedNetworkImageProvider('https://via.placeholder.com/150'),
              fit: BoxFit.cover,
            ),
            gradient: SweepGradient(
              startAngle: 0.0,
              endAngle: 2 * pi,
              colors: [
                Provider.of<SettingsProvider>(context).accentColor.withOpacity(0.5),
                Colors.red.withOpacity(0.5),
                Provider.of<SettingsProvider>(context).accentColor.withOpacity(0.5),
              ],
              transform: GradientRotation(_controller.value * 2 * pi),
            ),
          ),
        );
      },
    );
  }
}
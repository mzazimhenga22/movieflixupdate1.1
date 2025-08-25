import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io' show File;
import 'stories.dart';
import 'edit_profile_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'followers_following_screens.dart';
import '../../utils/extensions.dart';
import 'chat_screen.dart';
import 'package:movie_app/marketplace/marketplace_home.dart';

class UserProfileScreen extends StatefulWidget {
  final Map<String, dynamic> user;
  final bool showAppBar;
  final Color accentColor;
  @override
  final Key key;

  const UserProfileScreen({
    required this.key,
    required this.user,
    this.showAppBar = true,
    required this.accentColor,
  }) : super(key: key);

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

/// ----------------- Reusable frosted decoration helper -----------------
/// Lightweight "frosted glass" look without using BackdropFilter.
/// Use this for main panels and cards for consistent UI & performance.
BoxDecoration frostedPanelDecoration(Color accentColor, {double radius = 16}) {
  return BoxDecoration(
    color: Colors.white.withOpacity(0.03), // subtle glass tint
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: accentColor.withOpacity(0.06)),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.32),
        blurRadius: 12,
        offset: const Offset(0, 6),
      )
    ],
  );
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  late Map<String, dynamic> _user;
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _stories = [];
  List<Map<String, dynamic>> _allUsers = [];
  List<String> _hiddenUserIds = [];
  bool _isLoadingUsers = true;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _user = _sanitizeUserData(widget.user);
    _loadStories();
    _loadHiddenUsers();
    _loadAllUsers().then((_) {
      setState(() {
        _isLoadingUsers = false;
      });
    });
    _searchController.addListener(_onSearchChanged);
    _checkAndShowReminder();
  }

  Future<void> _loadStories() async {
    try {
      final snapshot =
          await FirebaseFirestore.instance.collection('stories').get();
      setState(() {
        _stories = snapshot.docs
            .map((doc) {
              final data = doc.data();
              return <String, dynamic>{...data, 'id': doc.id};
            })
            .where((story) =>
                DateTime.now().difference(DateTime.parse(
                    story['timestamp'] ?? DateTime.now().toIso8601String())) <
                const Duration(hours: 24))
            .toList();
      });
    } catch (e) {
      debugPrint('load stories error: $e');
    }
  }

  Future<void> _loadHiddenUsers() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .collection('hidden_users')
          .get();
      setState(() {
        _hiddenUserIds = snapshot.docs.map((doc) => doc.id).toList();
      });
    }
  }

  Future<void> _loadAllUsers() async {
    try {
      final snapshot = await FirebaseFirestore.instance.collection('users').get();
      setState(() {
        _allUsers = snapshot.docs.map((doc) {
          final data = doc.data();
          return _sanitizeUserData({...data, 'id': doc.id});
        }).toList();
      });
    } catch (e) {
      debugPrint('load users error: $e');
      setState(() => _allUsers = []);
    }
  }

  List<Map<String, dynamic>> _searchUsers(String query) {
    final lowerQuery = query.toLowerCase();
    return _allUsers
        .where((user) =>
            (user['username'] as String).toLowerCase().startsWith(lowerQuery) &&
            !_hiddenUserIds.contains(user['id']) &&
            user['id'] != _user['id'])
        .toList();
  }

  void _onSearchChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() {});
    });
  }

  Future<void> _checkAndShowReminder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final today = DateTime.now().toIso8601String().split('T')[0];
      final lastVisitDate = prefs.getString('last_visit_date') ?? '';
      final visitCount = prefs.getInt('visit_count') ?? 0;

      if (lastVisitDate != today) {
        await prefs.setString('last_visit_date', today);
        await prefs.setInt('visit_count', 1);
      } else {
        await prefs.setInt('visit_count', visitCount + 1);
      }

      if (visitCount >= 1 && _user['username'] == 'Guest' && mounted) {
        _showNicknameReminder();
      }
    } catch (e) {
      debugPrint('reminder error: $e');
    }
  }

  void _showNicknameReminder() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color.fromARGB(255, 17, 25, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          "Personalize Your Profile",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          "Hey there! It looks like you haven't set a nickname yet. Add one to make your profile stand out!",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Later", style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => EditProfileScreen(
                    user: _user,
                    accentColor: widget.accentColor,
                    onProfileUpdated: (updatedUser) {
                      setState(() {
                        _user = _sanitizeUserData(updatedUser);
                      });
                    },
                  ),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.accentColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text("Set Nickname"),
          ),
        ],
      ),
    );
  }

  String extractFirstName(String email) {
    final parts = email.split('@').first.split('.');
    return parts.isNotEmpty ? parts.first.capitalize() : 'Guest';
  }

  Map<String, dynamic> _sanitizeUserData(Map<String, dynamic> user) {
    final email = user['email']?.toString() ?? '';
    final username = user['username']?.toString() ?? extractFirstName(email);
    return {
      'id': user['id']?.toString() ?? '',
      'username': username,
      'email': email,
      'avatar': user['avatar']?.toString() ?? '',
      'bio': user['bio']?.toString() ?? 'No bio available.',
      'followers_count': user['followers_count'] ?? 0,
      'following_count': user['following_count'] ?? 0,
    };
  }

  ImageProvider _buildAvatarImage() {
    if (_user['avatar'] != null && _user['avatar'].isNotEmpty) {
      if (kIsWeb || _user['avatar'].startsWith("http")) {
        return CachedNetworkImageProvider(_user['avatar']);
      } else {
        return FileImage(File(_user['avatar']));
      }
    }
    return const NetworkImage("https://via.placeholder.com/200");
  }

  Future<void> _followUser(String currentUserId, String targetUserId) async {
    final batch = FirebaseFirestore.instance.batch();
    batch.set(
        FirebaseFirestore.instance
            .collection('users')
            .doc(currentUserId)
            .collection('following')
            .doc(targetUserId),
        {'timestamp': DateTime.now().toIso8601String()});
    batch.set(
        FirebaseFirestore.instance
            .collection('users')
            .doc(targetUserId)
            .collection('followers')
            .doc(currentUserId),
        {'timestamp': DateTime.now().toIso8601String()});
    batch.update(
        FirebaseFirestore.instance.collection('users').doc(targetUserId),
        {'followers_count': FieldValue.increment(1)});
    batch.update(
        FirebaseFirestore.instance.collection('users').doc(currentUserId),
        {'following_count': FieldValue.increment(1)});
    await batch.commit();
    if (mounted && _user['id'] == targetUserId) {
      setState(() {
        _user['followers_count'] = (_user['followers_count'] ?? 0) + 1;
      });
    }
  }

  Future<void> _unfollowUser(String currentUserId, String targetUserId) async {
    final batch = FirebaseFirestore.instance.batch();
    batch.delete(FirebaseFirestore.instance
        .collection('users')
        .doc(currentUserId)
        .collection('following')
        .doc(targetUserId));
    batch.delete(FirebaseFirestore.instance
        .collection('users')
        .doc(targetUserId)
        .collection('followers')
        .doc(currentUserId));
    batch.update(
        FirebaseFirestore.instance.collection('users').doc(targetUserId),
        {'followers_count': FieldValue.increment(-1)});
    batch.update(
        FirebaseFirestore.instance.collection('users').doc(currentUserId),
        {'following_count': FieldValue.increment(-1)});
    await batch.commit();
    if (mounted && _user['id'] == targetUserId) {
      setState(() {
        _user['followers_count'] = (_user['followers_count'] ?? 1) - 1;
      });
    }
  }

  Future<void> _deletePost(String postId) async {
    final batch = FirebaseFirestore.instance.batch();
    batch.delete(FirebaseFirestore.instance
        .collection('users')
        .doc(_user['id'])
        .collection('posts')
        .doc(postId));
    batch.delete(FirebaseFirestore.instance.collection('feeds').doc(postId));
    await batch.commit();
  }

  Future<void> _likePost(String postId, bool isLiked, String userId) async {
    final postRef = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('posts')
        .doc(postId);
    final feedRef = FirebaseFirestore.instance.collection('feeds').doc(postId);
    final batch = FirebaseFirestore.instance.batch();
    if (isLiked) {
      batch.update(postRef, {'liked': false, 'likes_count': FieldValue.increment(-1)});
      batch.update(feedRef, {'liked': false, 'likes_count': FieldValue.increment(-1)});
    } else {
      batch.update(postRef, {'liked': true, 'likes_count': FieldValue.increment(1)});
      batch.update(feedRef, {'liked': true, 'likes_count': FieldValue.increment(1)});
    }
    await batch.commit();
  }

  Future<void> _hideUser(String userIdToHide) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .collection('hidden_users')
          .doc(userIdToHide)
          .set({});
      setState(() {
        _hiddenUserIds.add(userIdToHide);
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User hidden')));
    }
  }

  String _displayCount(dynamic count) {
    return count?.toString() ?? '0';
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayName = _user['username'];
    final currentUser = FirebaseAuth.instance.currentUser;
    final isOwnProfile = _user['id'] == currentUser?.uid;

    // Reusable decorations for this build
    final panelGradient = RadialGradient(
      center: Alignment.center,
      radius: 1.6,
      colors: [widget.accentColor.withOpacity(0.18), Colors.transparent],
      stops: const [0.0, 1.0],
    );

    final avatarBorderDecoration = BoxDecoration(
      shape: BoxShape.circle,
      color: widget.accentColor,
      boxShadow: [BoxShadow(color: widget.accentColor.withOpacity(0.12), blurRadius: 10, offset: const Offset(0, 6))],
    );

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: widget.showAppBar
          ? AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              title: Text(displayName, style: const TextStyle(color: Colors.white, fontSize: 20)),
            )
          : null,
      body: Stack(
        children: [
          // Base background
          Container(color: const Color(0xFF111927)),
          // Accent radial
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.1, -0.4),
                radius: 1.2,
                colors: [widget.accentColor.withOpacity(0.36), Colors.black],
                stops: const [0.0, 0.6],
              ),
            ),
          ),
          // Main content panel (frosted — no blur)
          Positioned.fill(
            top: widget.showAppBar ? kToolbarHeight + MediaQuery.of(context).padding.top : 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                decoration: BoxDecoration(
                  gradient: panelGradient,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.55), blurRadius: 16, offset: const Offset(0, 8))],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    // Use the frosted helper here
                    decoration: frostedPanelDecoration(widget.accentColor, radius: 16).copyWith(
                      // slightly darker center for a more dimensional panel
                      color: Colors.white.withOpacity(0.028),
                    ),
                    child: SingleChildScrollView(
                      padding: EdgeInsets.only(
                        top: widget.showAppBar ? 16 : 48,
                        left: 16,
                        right: 16,
                        bottom: 24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Avatar + ring
                          RepaintBoundary(
                            child: GestureDetector(
                              onTap: _hasActiveStory()
                                  ? () async {
                                      final snapshot = await FirebaseFirestore.instance
                                          .collection('users')
                                          .doc(_user['id'])
                                          .collection('stories')
                                          .get();
                                      final userStories = snapshot.docs
                                          .map((doc) {
                                            final data = doc.data();
                                            return <String, dynamic>{...data, 'id': doc.id};
                                          })
                                          .where((story) =>
                                              DateTime.now().difference(DateTime.parse(story['timestamp'] ?? DateTime.now().toIso8601String())) <
                                              const Duration(hours: 24))
                                          .toList();
                                      if (userStories.isNotEmpty && mounted) {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => StoryScreen(
                                              stories: userStories,
                                              initialIndex: 0,
                                              currentUserId: currentUser?.uid ?? '',
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  : null,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: _hasActiveStory()
                                    ? BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: LinearGradient(colors: [Colors.yellow.withOpacity(0.9), widget.accentColor.withOpacity(0.6)]),
                                        boxShadow: [BoxShadow(color: Colors.yellow.withOpacity(0.12), blurRadius: 12, offset: const Offset(0, 6))],
                                      )
                                    : null,
                                child: Container(
                                  decoration: avatarBorderDecoration,
                                  child: CircleAvatar(
                                    radius: 50,
                                    backgroundColor: widget.accentColor,
                                    child: ClipOval(
                                      child: Image(
                                        image: _buildAvatarImage(),
                                        width: 100,
                                        height: 100,
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) => Center(
                                          child: Text(
                                            displayName.isNotEmpty ? displayName[0].toUpperCase() : "G",
                                            style: const TextStyle(fontSize: 40, color: Colors.white, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 16),

                          // Name & counts
                          Text(displayName, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white, shadows: [Shadow(color: Colors.black45, offset: Offset(1, 1), blurRadius: 2)])),
                          const SizedBox(height: 12),
                          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            GestureDetector(
                              onTap: () {
                                Navigator.push(context, MaterialPageRoute(builder: (context) => FollowersScreen(userId: _user['id'], accentColor: widget.accentColor)));
                              },
                              child: Text('Followers: ${_displayCount(_user['followers_count'])}', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                            ),
                            const SizedBox(width: 16),
                            GestureDetector(
                              onTap: () {
                                Navigator.push(context, MaterialPageRoute(builder: (context) => FollowingScreen(userId: _user['id'], accentColor: widget.accentColor)));
                              },
                              child: Text('Following: ${_displayCount(_user['following_count'])}', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                            ),
                          ]),
                          const SizedBox(height: 12),
                          Text(_user['email'], style: const TextStyle(fontSize: 14, color: Colors.white70)),
                          const SizedBox(height: 12),
                          Text(_user['bio'], textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.9))),
                          const SizedBox(height: 16),

                          // Actions (Follow/Message/Edit)
                          if (!isOwnProfile && currentUser != null)
                            Column(children: [
                              StreamBuilder<DocumentSnapshot>(
                                stream: FirebaseFirestore.instance.collection('users').doc(currentUser.uid).collection('following').doc(_user['id']).snapshots(),
                                builder: (context, snapshot) {
                                  if (snapshot.connectionState == ConnectionState.waiting) {
                                    return const CircularProgressIndicator();
                                  }
                                  final isFollowing = snapshot.data?.exists ?? false;
                                  return ElevatedButton(
                                    onPressed: () async {
                                      if (isFollowing) {
                                        await _unfollowUser(currentUser.uid, _user['id']);
                                      } else {
                                        await _followUser(currentUser.uid, _user['id']);
                                      }
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: widget.accentColor,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
                                      minimumSize: const Size(double.infinity, 48),
                                    ),
                                    child: Text(isFollowing ? 'Unfollow' : 'Follow', style: const TextStyle(fontSize: 16)),
                                  );
                                },
                              ),
                              const SizedBox(height: 12),
                              ElevatedButton.icon(
                                onPressed: () {
                                  final chatId = currentUser!.uid.compareTo(_user['id']) < 0 ? '${currentUser.uid}_${_user['id']}' : '${_user['id']}_${currentUser.uid}';
                                  Navigator.push(context, MaterialPageRoute(builder: (context) => ChatScreen(
                                    chatId: chatId,
                                    currentUser: {'id': currentUser.uid, 'username': _user['username']},
                                    otherUser: _user,
                                    authenticatedUser: {'id': currentUser.uid, 'username': _user['username']},
                                    storyInteractions: const [],
                                  )));
                                },
                                icon: const Icon(Icons.message, size: 20),
                                label: const Text("Message", style: TextStyle(fontSize: 16)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: widget.accentColor,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
                                  minimumSize: const Size(double.infinity, 48),
                                ),
                              ),
                            ]),

                          // Edit profile
                          if (isOwnProfile && currentUser != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  Navigator.push(context, MaterialPageRoute(builder: (context) => EditProfileScreen(
                                    user: _user,
                                    accentColor: widget.accentColor,
                                    onProfileUpdated: (updatedUser) {
                                      setState(() {
                                        _user = _sanitizeUserData(updatedUser);
                                      });
                                    },
                                  )));
                                },
                                icon: const Icon(Icons.edit, size: 20),
                                label: const Text("Edit Profile", style: TextStyle(fontSize: 16)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: widget.accentColor,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
                                  minimumSize: const Size(double.infinity, 48),
                                ),
                              ),
                            ),

                          const SizedBox(height: 12),

                          // Marketplace card (accent gradient)
                          GestureDetector(
                            onTap: () {
                              Navigator.push(context, MaterialPageRoute(builder: (_) => MarketplaceHomeScreen(
                                userName: _user['username'] ?? 'Unnamed',
                                userEmail: _user['email'] ?? 'No email provided',
                                userAvatar: _user['avatar'],
                              )));
                            },
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 8),
                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [widget.accentColor.withOpacity(0.14), widget.accentColor.withOpacity(0.28)],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: widget.accentColor.withOpacity(0.18)),
                              ),
                              child: Row(children: [
                                Icon(Icons.storefront, color: widget.accentColor),
                                const SizedBox(width: 16),
                                Expanded(child: Text('Marketplace', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
                                Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.7)),
                              ]),
                            ),
                          ),

                          const Divider(color: Colors.white54, thickness: 1),
                          const SizedBox(height: 16),

                          // User's posts header
                          const Text("User's Posts", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white, shadows: [Shadow(color: Colors.black45, offset: Offset(1, 1), blurRadius: 2)])),
                          const SizedBox(height: 12),

                          // Posts list (grid)
                          StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance.collection('users').doc(_user['id']).collection('posts').orderBy('timestamp', descending: true).snapshots(),
                            builder: (context, snapshot) {
                              if (snapshot.hasError) {
                                return Text('Error: ${snapshot.error}', style: const TextStyle(color: Colors.white));
                              }
                              if (!snapshot.hasData) {
                                return const Center(child: CircularProgressIndicator());
                              }
                              final posts = snapshot.data!.docs.map((doc) {
                                final data = doc.data() as Map<String, dynamic>;
                                return <String, dynamic>{...data, 'id': doc.id};
                              }).toList();

                              if (posts.isEmpty) {
                                return Container(
                                  margin: const EdgeInsets.symmetric(vertical: 8),
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(colors: [widget.accentColor.withOpacity(0.06), widget.accentColor.withOpacity(0.12)]),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: widget.accentColor.withOpacity(0.06)),
                                  ),
                                  child: const Text("No posts available.", style: TextStyle(fontSize: 15, color: Colors.white70)),
                                );
                              }

                              return GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  childAspectRatio: 0.7,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                ),
                                itemCount: posts.length,
                                itemBuilder: (context, index) {
                                  final post = posts[index];
                                  return RepaintBoundary(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: widget.accentColor.withOpacity(0.06)),
                                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 6))],
                                        gradient: LinearGradient(colors: [widget.accentColor.withOpacity(0.06), widget.accentColor.withOpacity(0.12)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          if (post['media']?.isNotEmpty ?? false)
                                            ClipRRect(
                                              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                                              child: CachedNetworkImage(
                                                imageUrl: post['media']!,
                                                height: 120,
                                                width: double.infinity,
                                                fit: BoxFit.cover,
                                                placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
                                                errorWidget: (context, url, error) => Container(
                                                  height: 120,
                                                  color: Colors.grey[800],
                                                  child: const Center(child: Icon(Icons.error, size: 30)),
                                                ),
                                              ),
                                            ),
                                          Padding(
                                            padding: const EdgeInsets.all(8.0),
                                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                              Text(post['post'] ?? '', style: const TextStyle(fontSize: 14, color: Colors.white70), maxLines: 2, overflow: TextOverflow.ellipsis),
                                              const SizedBox(height: 4),
                                              Text("Movie: ${post['movie'] ?? 'Unknown'}", style: const TextStyle(fontSize: 12, color: Colors.white60, fontStyle: FontStyle.italic), maxLines: 1, overflow: TextOverflow.ellipsis),
                                            ]),
                                          ),
                                          const Spacer(),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                                            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                              Row(children: [
                                                IconButton(
                                                  icon: Icon(post['liked'] == true ? Icons.favorite : Icons.favorite_border, color: post['liked'] == true ? Colors.red : Colors.white70, size: 20),
                                                  onPressed: currentUser != null ? () async { await _likePost(post['id'], post['liked'] ?? false, _user['id']); } : null,
                                                ),
                                                Text('${post['likes_count'] ?? 0}', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                                              ]),
                                              if (isOwnProfile)
                                                IconButton(
                                                  icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                                                  onPressed: () async {
                                                    final confirm = await showDialog<bool>(
                                                      context: context,
                                                      builder: (context) => AlertDialog(
                                                        backgroundColor: const Color.fromARGB(255, 17, 25, 40),
                                                        title: const Text("Delete Post", style: TextStyle(color: Colors.white)),
                                                        content: const Text("Are you sure you want to delete this post?", style: TextStyle(color: Colors.white70)),
                                                        actions: [
                                                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel", style: TextStyle(color: Colors.white70))),
                                                          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white), onPressed: () => Navigator.pop(context, true), child: const Text("Delete")),
                                                        ],
                                                      ),
                                                    );
                                                    if (confirm == true) await _deletePost(post['id']);
                                                  },
                                                ),
                                            ]),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),

                          // Recent watches for own profile
                          if (isOwnProfile)
                            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const SizedBox(height: 16),
                              const Text("Recent Watches", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white, shadows: [Shadow(color: Colors.black45, offset: Offset(1, 1), blurRadius: 2)])),
                              const SizedBox(height: 12),
                              StreamBuilder<QuerySnapshot>(
                                stream: FirebaseFirestore.instance.collection('users').doc(_user['id']).collection('watch_history').orderBy('timestamp', descending: true).limit(5).snapshots(),
                                builder: (context, snapshot) {
                                  if (snapshot.hasError) return Text('Error: ${snapshot.error}', style: const TextStyle(color: Colors.white));
                                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                                  final watches = snapshot.data!.docs.map((doc) => doc.data() as Map<String, dynamic>).toList();
                                  if (watches.isEmpty) return const Text("No recent watches.", style: TextStyle(color: Colors.white70));
                                  return ListView.builder(
                                    shrinkWrap: true,
                                    physics: const NeverScrollableScrollPhysics(),
                                    itemCount: watches.length,
                                    itemBuilder: (context, index) {
                                      final watch = watches[index];
                                      return ListTile(
                                        title: Text(watch['title'] ?? 'Unknown', style: const TextStyle(color: Colors.white)),
                                        subtitle: Text('Watched on ${watch['timestamp'] ?? ''}', style: const TextStyle(color: Colors.white70)),
                                      );
                                    },
                                  );
                                },
                              ),
                            ]),

                          const SizedBox(height: 16),
                          const Divider(color: Colors.white54, thickness: 1),
                          const SizedBox(height: 16),

                          // Find users
                          const Text("Find Users", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white, shadows: [Shadow(color: Colors.black45, offset: Offset(1, 1), blurRadius: 2)])),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _searchController,
                            style: const TextStyle(color: Colors.white, fontSize: 16),
                            decoration: InputDecoration(
                              hintText: "Search by username",
                              hintStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.02),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                              prefixIcon: const Icon(Icons.search, color: Colors.white),
                            ),
                          ),
                          const SizedBox(height: 12),

                          if (_isLoadingUsers)
                            const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CircularProgressIndicator()))
                          else
                            Builder(builder: (context) {
                              final users = _searchUsers(_searchController.text.trim());
                              if (users.isEmpty) return const Text("No users found.", style: TextStyle(color: Colors.white));
                              return GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  childAspectRatio: 0.8,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                ),
                                itemCount: users.length,
                                itemBuilder: (context, index) {
                                  final otherUser = users[index];
                                  return RepaintBoundary(
                                    child: GestureDetector(
                                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => UserProfileScreen(key: ValueKey(otherUser['id']), user: otherUser, showAppBar: true, accentColor: widget.accentColor))),
                                      onLongPress: () {
                                        showDialog(context: context, builder: (context) => AlertDialog(
                                          backgroundColor: const Color.fromARGB(255, 17, 25, 40),
                                          title: Text('Hide ${otherUser['username']}', style: const TextStyle(color: Colors.white)),
                                          content: const Text('Do you want to hide this user from search results?', style: TextStyle(color: Colors.white70)),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
                                            ElevatedButton(onPressed: () { _hideUser(otherUser['id']); Navigator.pop(context); }, style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Hide', style: TextStyle(color: Colors.white))),
                                          ],
                                        ));
                                      },
                                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                                        CircleAvatar(radius: 30, backgroundColor: widget.accentColor, backgroundImage: otherUser['avatar']?.isNotEmpty == true ? CachedNetworkImageProvider(otherUser['avatar']) : null, child: otherUser['avatar']?.isNotEmpty != true ? Text(otherUser['username'].isNotEmpty ? otherUser['username'][0].toUpperCase() : "G", style: const TextStyle(color: Colors.white)) : null),
                                        const SizedBox(height: 4),
                                        Text(otherUser['username'], style: const TextStyle(color: Colors.white, fontSize: 12), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                                        if (currentUser != null)
                                          StreamBuilder<DocumentSnapshot>(
                                            stream: FirebaseFirestore.instance.collection('users').doc(currentUser.uid).collection('following').doc(otherUser['id']).snapshots(),
                                            builder: (context, snapshot) {
                                              if (snapshot.connectionState == ConnectionState.waiting) return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
                                              final isFollowing = snapshot.data?.exists ?? false;
                                              return ElevatedButton(
                                                onPressed: () async {
                                                  if (isFollowing) await _unfollowUser(currentUser.uid, otherUser['id']);
                                                  else await _followUser(currentUser.uid, otherUser['id']);
                                                },
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: isFollowing ? Colors.grey[700] : widget.accentColor,
                                                  foregroundColor: Colors.white,
                                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                                  minimumSize: const Size(60, 24),
                                                ),
                                                child: Text(isFollowing ? 'Unfollow' : 'Follow', style: const TextStyle(fontSize: 10)),
                                              );
                                            },
                                          )
                                      ]),
                                    ),
                                  );
                                },
                              );
                            }),

                          if (isOwnProfile)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: ElevatedButton(
                                onPressed: () async {
                                  await FirebaseAuth.instance.signOut();
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
                                  minimumSize: const Size(double.infinity, 48),
                                ),
                                child: const Text("Log Out", style: TextStyle(fontSize: 16)),
                              ),
                            ),
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

  bool _hasActiveStory() {
    return _stories.any((story) =>
        story['userId'] == _user['id'] &&
        DateTime.now().difference(DateTime.parse(story['timestamp'] ?? DateTime.now().toIso8601String())) < const Duration(hours: 24));
  }
}

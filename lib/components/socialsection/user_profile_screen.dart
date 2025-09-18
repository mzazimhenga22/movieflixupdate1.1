// user_profile_screen.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io' show File;
import 'stories.dart';
import 'storiecomponents.dart'; // ensures StoriesRow is available
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

/// light "frosted" box decoration used for panels
BoxDecoration frostedPanelDecoration(Color accentColor, {double radius = 16}) {
  return BoxDecoration(
    color: Colors.white.withOpacity(0.03),
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

  // simple memoization for current user id
  User? get _currentAuthUser => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    _user = _sanitizeUserData(widget.user);
    _loadStories();
    _loadHiddenUsers();
    _loadAllUsers().then((_) {
      if (mounted) setState(() => _isLoadingUsers = false);
    });
    _searchController.addListener(_onSearchChanged);
    _checkAndShowReminder();
  }

  Future<void> _loadStories() async {
    try {
      final snapshot =
          await FirebaseFirestore.instance.collection('stories').get();
      final now = DateTime.now();
      setState(() {
        _stories = snapshot.docs
            .map((doc) {
              final data = doc.data();
              return <String, dynamic>{...data, 'id': doc.id};
            })
            .where((story) {
              try {
                final ts = story['timestamp']?.toString() ?? now.toIso8601String();
                return now.difference(DateTime.parse(ts)) < const Duration(hours: 24);
              } catch (_) {
                return false;
              }
            })
            .toList();
      });
    } catch (e) {
      debugPrint('load stories error: $e');
    }
  }

  Future<void> _loadHiddenUsers() async {
    final currentUser = _currentAuthUser;
    if (currentUser != null) {
      try {
        final snapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser.uid)
            .collection('hidden_users')
            .get();
        setState(() {
          _hiddenUserIds = snapshot.docs.map((doc) => doc.id).toList();
        });
      } catch (e) {
        debugPrint('load hidden users error: $e');
      }
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
    final lower = query.toLowerCase();
    return _allUsers.where((u) {
      final name = (u['username'] ?? '').toString().toLowerCase();
      return name.startsWith(lower) &&
          !_hiddenUserIds.contains(u['id']) &&
          u['id'] != _user['id'];
    }).toList();
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

      if ((visitCount >= 1) && _user['username'] == 'Guest' && mounted) {
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
        title: Text(
          "Personalize Your Profile",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          "Hey there! It looks like you haven't set a nickname yet. Add one to make your profile stand out!",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text("Later", style: TextStyle(color: Colors.white70)),
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
                      if (mounted) setState(() => _user = _sanitizeUserData(updatedUser));
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
    final email = (user['email'] ?? '').toString();
    final username = (user['username']?.toString() ?? extractFirstName(email));
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
    final currentUser = _currentAuthUser;
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

  String _displayCount(dynamic count) => (count ?? 0).toString();

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  bool _hasActiveStory() {
    return _stories.any((story) {
      try {
        return story['userId'] == _user['id'] &&
            DateTime.now().difference(DateTime.parse(story['timestamp'] ?? DateTime.now().toIso8601String())) <
                const Duration(hours: 24);
      } catch (_) {
        return false;
      }
    });
  }

  // safe helper: first initial (or fallback)
  String _initial(String? name) {
    final s = (name ?? '').toString();
    if (s.isNotEmpty) return s[0].toUpperCase();
    return '?';
  }

  // Build a compact avatar widget that avoids remote placeholder fallbacks
  Widget buildAvatar(double radius) {
    final avatarUrl = (_user['avatar'] ?? '').toString();
    final initials = _initial(_user['username']);

    if (avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: widget.accentColor,
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: avatarUrl,
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            placeholder: (context, url) => Container(
              alignment: Alignment.center,
              color: Colors.grey.shade800,
              child: Text(initials, style: TextStyle(fontSize: radius * 0.8, color: Colors.white)),
            ),
            errorWidget: (context, url, error) => Container(
              alignment: Alignment.center,
              color: Colors.grey.shade800,
              child: Text(initials, style: TextStyle(fontSize: radius * 0.8, color: Colors.white)),
            ),
          ),
        ),
      );
    } else {
      return CircleAvatar(
        radius: radius,
        backgroundColor: widget.accentColor,
        child: Text(initials, style: TextStyle(fontSize: radius * 0.8, color: Colors.white, fontWeight: FontWeight.bold)),
      );
    }
  }

  // Header widget (keeps top area tidy)
  Widget buildHeader(BuildContext context) {
    final displayName = (_user['username'] ?? '').toString();
    final currentUser = _currentAuthUser;
    final isOwnProfile = _user['id'] == currentUser?.uid;

    // counts as compact chips to avoid overflow and wrap when necessary
    final countsWrap = Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (c) => FollowersScreen(userId: _user['id'], accentColor: widget.accentColor))),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: widget.accentColor.withOpacity(0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: widget.accentColor.withOpacity(0.12)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${_displayCount(_user['followers_count'])}', style: TextStyle(color: widget.accentColor, fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Text('Followers', style: TextStyle(color: Colors.white70, fontSize: 13)),
            ]),
          ),
        ),
        InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (c) => FollowingScreen(userId: _user['id'], accentColor: widget.accentColor))),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: widget.accentColor.withOpacity(0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: widget.accentColor.withOpacity(0.12)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${_displayCount(_user['following_count'])}', style: TextStyle(color: widget.accentColor, fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Text('Following', style: TextStyle(color: Colors.white70, fontSize: 13)),
            ]),
          ),
        ),
      ],
    );

    // Action button(s) with responsive layout to prevent overflow
    Widget actionArea() {
      if (isOwnProfile && currentUser != null) {
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: ElevatedButton.icon(
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (context) => EditProfileScreen(
                user: _user,
                accentColor: widget.accentColor,
                onProfileUpdated: (updatedUser) {
                  if (mounted) setState(() => _user = _sanitizeUserData(updatedUser));
                },
              )));
            },
            icon: Icon(Icons.edit, size: 18, color: Colors.white),
            label: const Text('Edit Profile', overflow: TextOverflow.ellipsis),
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.accentColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            ),
          ),
        );
      } else if (currentUser != null) {
        // use Wrap so buttons move to next line if space is constrained
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance.collection('users').doc(currentUser.uid).collection('following').doc(_user['id']).snapshots(),
                builder: (context, snapshot) {
                  final isFollowing = snapshot.data?.exists ?? false;
                  return ElevatedButton(
                    onPressed: () async {
                      if (isFollowing) {
                        await _unfollowUser(currentUser.uid, _user['id']);
                      } else {
                        await _followUser(currentUser.uid, _user['id']);
                      }
                    },
                    child: Text(isFollowing ? 'Unfollow' : 'Follow', overflow: TextOverflow.ellipsis),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isFollowing ? widget.accentColor.withOpacity(0.28) : widget.accentColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                      minimumSize: const Size(88, 40),
                    ),
                  );
                },
              ),
              ElevatedButton.icon(
                onPressed: () {
                  final chatId = (currentUser!.uid.compareTo(_user['id']) < 0)
                      ? '${currentUser.uid}_${_user['id']}'
                      : '${_user['id']}_${currentUser.uid}';
                  Navigator.push(context, MaterialPageRoute(builder: (c) => ChatScreen(
                    chatId: chatId,
                    currentUser: {'id': currentUser.uid, 'username': _user['username']},
                    otherUser: _user,
                    authenticatedUser: {'id': currentUser.uid, 'username': _user['username']},
                    storyInteractions: const [],
                  )));
                },
                icon: const Icon(Icons.message, size: 16),
                label: const Text('Message', overflow: TextOverflow.ellipsis),
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.accentColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  minimumSize: const Size(88, 40),
                ),
              ),
            ],
          ),
        );
      } else {
        return const SizedBox.shrink();
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14.0, horizontal: 12),
      child: Column(
        children: [
          // avatar + name + counts + actions in a responsive Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: _hasActiveStory()
                    ? () async {
                        final snapshot = await FirebaseFirestore.instance
                            .collection('users')
                            .doc(_user['id'])
                            .collection('stories')
                            .get();
                        final userStories = snapshot.docs.map((doc) {
                          final data = doc.data();
                          return <String, dynamic>{...data, 'id': doc.id};
                        }).where((story) {
                          try {
                            return DateTime.now().difference(DateTime.parse(story['timestamp'] ?? DateTime.now().toIso8601String())) < const Duration(hours: 24);
                          } catch (_) {
                            return false;
                          }
                        }).toList();
                        if (userStories.isNotEmpty && mounted) {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => StoryScreen(
                            stories: userStories,
                            initialIndex: 0,
                            currentUserId: _currentAuthUser?.uid ?? '',
                          )));
                        }
                      }
                    : null,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: _hasActiveStory()
                      ? BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(colors: [widget.accentColor.withOpacity(0.22), widget.accentColor.withOpacity(0.12)]),
                          boxShadow: [BoxShadow(color: widget.accentColor.withOpacity(0.08), blurRadius: 12, offset: const Offset(0, 6))],
                        )
                      : null,
                  child: buildAvatar(44),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(displayName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white), overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                  const SizedBox(height: 8),
                  countsWrap,
                  const SizedBox(height: 8),
                  Text(_user['email'] ?? '', style: const TextStyle(color: Colors.white70, fontSize: 13), overflow: TextOverflow.ellipsis),
                ]),
              ),
              const SizedBox(width: 12),
              // prevent button overflow by constraining
              Flexible(child: actionArea()),
            ],
          ),
          const SizedBox(height: 12),
          // bio - make sure it wraps and doesn't overflow
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _user['bio'] ?? '',
              textAlign: TextAlign.left,
              style: TextStyle(color: Colors.white.withOpacity(0.9)),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ----- Tab contents -----

  Widget buildOverviewTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        children: [
          // marketplace card
          GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MarketplaceHomeScreen(
              userName: _user['username'] ?? 'Unnamed',
              userEmail: _user['email'] ?? 'No email provided',
              userAvatar: _user['avatar'],
            ))),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [widget.accentColor.withOpacity(0.10), widget.accentColor.withOpacity(0.18)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: widget.accentColor.withOpacity(0.12)),
              ),
              child: Row(children: [
                Icon(Icons.storefront, color: widget.accentColor),
                const SizedBox(width: 12),
                Expanded(child: Text('Marketplace', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold))),
                Icon(Icons.chevron_right, color: Colors.white54),
              ]),
            ),
          ),

          const SizedBox(height: 16),

          // stories preview
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.02),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: widget.accentColor.withOpacity(0.06)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Recent Stories', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SizedBox(height: 96, child: StoriesRow(
                  stories: _stories.where((s) => s['userId'] == _user['id']).toList(),
                  height: 96,
                  currentUserAvatar: _user['avatar'],
                  currentUser: _user,
                  accentColor: widget.accentColor,
                  forceNavigateOnAdd: false,
                  onAddStory: () {},
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildPostsTab() {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      int crossAxisCount = 2;
      if (width > 1000) crossAxisCount = 3;
      else if (width > 700) crossAxisCount = 2;
      else crossAxisCount = 1;

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('users').doc(_user['id']).collection('posts').orderBy('timestamp', descending: true).snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) return Center(child: Text('Error: ${snapshot.error}', style: const TextStyle(color: Colors.white)));
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            final posts = snapshot.data!.docs.map((d) => <String, dynamic>{...((d.data() as Map<String, dynamic>?) ?? {}), 'id': d.id}).toList();
            if (posts.isEmpty) {
              return Center(child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.02),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: widget.accentColor.withOpacity(0.06)),
                ),
                child: const Text("No posts available.", style: TextStyle(color: Colors.white70)),
              ));
            }

            return GridView.builder(
              itemCount: posts.length,
              padding: const EdgeInsets.only(bottom: 12),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                childAspectRatio: crossAxisCount == 1 ? 3.2 : 0.72,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemBuilder: (context, i) {
                final post = posts[i];
                return Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: widget.accentColor.withOpacity(0.06)),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 6))],
                    gradient: LinearGradient(colors: [widget.accentColor.withOpacity(0.04), widget.accentColor.withOpacity(0.10)]),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if ((post['media'] ?? '').toString().isNotEmpty)
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                        child: CachedNetworkImage(
                          imageUrl: post['media'] ?? '',
                          height: 120, width: double.infinity, fit: BoxFit.cover,
                          placeholder: (c, url) => Container(height: 120, color: Colors.grey.shade800, child: const Center(child: CircularProgressIndicator())),
                          errorWidget: (c, url, e) => Container(height: 120, color: Colors.grey.shade800, child: const Center(child: Icon(Icons.error, size: 30))),
                        ),
                      )
                    else
                      Container(height: 120, decoration: BoxDecoration(color: Colors.grey.shade800, borderRadius: const BorderRadius.vertical(top: Radius.circular(12))), child: const Center(child: Icon(Icons.image))),
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(post['post'] ?? '', style: const TextStyle(color: Colors.white70), maxLines: 2, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 6),
                        Text("Movie: ${post['movie'] ?? 'Unknown'}", style: const TextStyle(fontSize: 12, color: Colors.white60, fontStyle: FontStyle.italic)),
                      ]),
                    ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Row(children: [
                          IconButton(
                            icon: Icon(post['liked'] == true ? Icons.favorite : Icons.favorite_border, color: post['liked'] == true ? widget.accentColor : Colors.white70, size: 20),
                            onPressed: _currentAuthUser != null ? () async { await _likePost(post['id'], post['liked'] ?? false, _user['id']); } : null,
                          ),
                          Text('${post['likes_count'] ?? 0}', style: const TextStyle(color: Colors.white70)),
                        ]),
                        if (_user['id'] == _currentAuthUser?.uid)
                          IconButton(
                            icon: Icon(Icons.delete, color: widget.accentColor),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  backgroundColor: const Color.fromARGB(255, 17, 25, 40),
                                  title: Text("Delete Post", style: TextStyle(color: Colors.white)),
                                  content: Text("Are you sure you want to delete this post?", style: TextStyle(color: Colors.white70)),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(c, false), child: Text("Cancel", style: TextStyle(color: Colors.white70))),
                                    ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: widget.accentColor), onPressed: () => Navigator.pop(c, true), child: const Text("Delete")),
                                  ],
                                ),
                              );
                              if (confirm == true) await _deletePost(post['id']);
                            },
                          )
                      ]),
                    )
                  ]),
                );
              },
            );
          },
        ),
      );
    });
  }

  Widget buildStoriesTab() {
    final userStories = _stories.where((s) => s['userId'] == _user['id']).toList();
    if (userStories.isEmpty) {
      return Center(child: Text("No recent stories.", style: TextStyle(color: Colors.white70)));
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: StoriesRow(
        stories: userStories,
        height: 420, // Story playback will manage its own size
        currentUserAvatar: _user['avatar'],
        currentUser: _user,
        accentColor: widget.accentColor,
        forceNavigateOnAdd: false,
        onAddStory: () {},
      ),
    );
  }

  Widget buildFindUsersTab() {
    final currentUser = _currentAuthUser;
    final results = _searchUsers(_searchController.text.trim());
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: "Search users",
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
              filled: true,
              fillColor: Colors.white.withOpacity(0.02),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              prefixIcon: Icon(Icons.search, color: widget.accentColor),
            ),
          ),
          const SizedBox(height: 12),
          if (_isLoadingUsers)
            const Center(child: CircularProgressIndicator())
          else if (results.isEmpty)
            Center(child: Text("No users found.", style: TextStyle(color: Colors.white70)))
          else
            LayoutBuilder(builder: (context, constraints) {
              final width = constraints.maxWidth;
              int crossAxisCount = 3;
              if (width > 1100) crossAxisCount = 6;
              else if (width > 800) crossAxisCount = 4;
              else if (width > 600) crossAxisCount = 3;
              else crossAxisCount = 2;

              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: results.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  childAspectRatio: 0.75,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemBuilder: (context, idx) {
                  final other = results[idx];
                  final otherUsername = (other['username'] ?? '').toString();
                  final otherInitial = _initial(otherUsername);
                  final otherAvatar = (other['avatar'] ?? '').toString();

                  return GestureDetector(
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (c) => UserProfileScreen(key: ValueKey(other['id']), user: other, showAppBar: true, accentColor: widget.accentColor))),
                    onLongPress: () {
                      showDialog(context: context, builder: (c) => AlertDialog(
                        backgroundColor: const Color.fromARGB(255, 17, 25, 40),
                        title: Text('Hide ${otherUsername.isNotEmpty ? otherUsername : 'User'}', style: const TextStyle(color: Colors.white)),
                        content: const Text('Do you want to hide this user from search results?', style: TextStyle(color: Colors.white70)),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
                          ElevatedButton(onPressed: () { _hideUser(other['id']); Navigator.pop(c); }, style: ElevatedButton.styleFrom(backgroundColor: widget.accentColor), child: const Text('Hide')),
                        ],
                      ));
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.01),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: widget.accentColor.withOpacity(0.06)),
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor: widget.accentColor,
                          child: otherAvatar.isNotEmpty
                              ? ClipOval(
                                  child: CachedNetworkImage(
                                    imageUrl: otherAvatar,
                                    width: 56,
                                    height: 56,
                                    fit: BoxFit.cover,
                                    errorWidget: (c, u, e) => Center(child: Text(otherInitial, style: const TextStyle(color: Colors.white))),
                                  ),
                                )
                              : Text(otherInitial, style: const TextStyle(color: Colors.white)),
                        ),
                        const SizedBox(height: 8),
                        Flexible(
                          child: Text(otherUsername.isNotEmpty ? otherUsername : 'Unknown', style: const TextStyle(color: Colors.white, fontSize: 12), overflow: TextOverflow.ellipsis, maxLines: 1),
                        ),
                        const SizedBox(height: 8),
                        if (currentUser != null)
                          StreamBuilder<DocumentSnapshot>(
                            stream: FirebaseFirestore.instance.collection('users').doc(currentUser.uid).collection('following').doc(other['id']).snapshots(),
                            builder: (context, snap) {
                              if (snap.connectionState == ConnectionState.waiting) return const SizedBox(height: 28, width: 80, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
                              final isFollowing = snap.data?.exists ?? false;
                              return SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: () async {
                                    if (isFollowing) await _unfollowUser(currentUser.uid, other['id']);
                                    else await _followUser(currentUser.uid, other['id']);
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isFollowing ? widget.accentColor.withOpacity(0.28) : widget.accentColor,
                                    padding: const EdgeInsets.symmetric(vertical: 6),
                                    minimumSize: const Size.fromHeight(32),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  child: Text(isFollowing ? 'Unfollow' : 'Follow', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                                ),
                              );
                            },
                          )
                      ]),
                    ),
                  );
                },
              );
            }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayName = (_user['username'] ?? 'Profile').toString();

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: widget.showAppBar
          ? AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              title: Text(displayName, style: const TextStyle(color: Colors.white)),
            )
          : null,
      body: Container(
        color: const Color(0xFF0B1220),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(center: Alignment.center, radius: 1.6, colors: [widget.accentColor.withOpacity(0.08), Colors.transparent]),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.55), blurRadius: 12, offset: const Offset(0, 8))],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  decoration: frostedPanelDecoration(widget.accentColor, radius: 14),
                  child: DefaultTabController(
                    length: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // header (fixed)
                        buildHeader(context),
                        // tabs
                        Material(
                          color: Colors.transparent,
                          child: TabBar(
                            isScrollable: true,
                            indicator: UnderlineTabIndicator(borderSide: BorderSide(width: 3.0, color: widget.accentColor)),
                            labelColor: widget.accentColor,
                            unselectedLabelColor: Colors.white70,
                            tabs: const [
                              Tab(text: 'Overview'),
                              Tab(text: 'Posts'),
                              Tab(text: 'Stories'),
                              Tab(text: 'Find Users'),
                            ],
                          ),
                        ),
                        Expanded(
                          child: TabBarView(
                            children: [
                              buildOverviewTab(),
                              buildPostsTab(),
                              buildStoriesTab(),
                              buildFindUsersTab(),
                            ],
                          ),
                        ),
                        // optional footer actions: logout (only for own profile)
                        if (_user['id'] == _currentAuthUser?.uid)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                            child: ElevatedButton(
                              onPressed: () async => await FirebaseAuth.instance.signOut(),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: widget.accentColor,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              child: const Text('Log out'),
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
      ),
    );
  }
}

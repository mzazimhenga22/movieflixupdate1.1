import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';

class ProfileScreen extends StatelessWidget {
  final Map<String, dynamic> user;

  const ProfileScreen({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final Function(String)? onBackgroundSet = user['onBackgroundSet'];

    if (!user.containsKey('id')) {
      return const Scaffold(
        body: Center(
          child: Text("User data not provided.", style: TextStyle(fontSize: 16)),
        ),
      );
    }

    return Scaffold(
      body: Column(
        children: [
          Stack(
            children: [
              Container(
                height: 220,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF6A85B6), Color(0xFFbac8e0)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(30)),
                ),
              ),
              Positioned(
                top: 40,
                left: 16,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              Positioned.fill(
                top: 70,
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 50,
                      backgroundColor: Colors.white,
                      backgroundImage: user['photoUrl'] != null && user['photoUrl'] != ''
                          ? NetworkImage(user['photoUrl'])
                          : const AssetImage('assets/default_user.png') as ImageProvider,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      user['username'] ?? 'Unknown User',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                ElevatedButton.icon(
                  onPressed: () => _blockOrUnblock(context, user['id']),
                  icon: const Icon(Icons.block),
                  label: const Text("Block / Unblock"),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    backgroundColor: const Color.fromARGB(255, 92, 0, 0),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: () => _startVoiceCall(context, user),
                  icon: const Icon(Icons.phone),
                  label: const Text("Voice Call"),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: () => _startVideoCall(context, user),
                  icon: const Icon(Icons.videocam),
                  label: const Text("Video Call"),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ElevatedButton.icon(
              onPressed: () => _showChatSettings(context, user, onBackgroundSet),
              icon: const Icon(Icons.settings),
              label: const Text("Chat Settings"),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _blockOrUnblock(BuildContext context, String currentUserId) async {
    final userRef = FirebaseFirestore.instance.collection('users').doc(currentUserId);
    final doc = await userRef.get();
    final blockedUsers = List<String>.from(doc.data()?['blockedUsers'] ?? []);
    final isBlocked = blockedUsers.contains(currentUserId);
    final action = isBlocked ? FieldValue.arrayRemove : FieldValue.arrayUnion;

    await userRef.update({'blockedUsers': action([currentUserId])});

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(isBlocked ? 'User unblocked' : 'User blocked')),
    );
  }

  Future<void> _startVoiceCall(BuildContext context, Map<String, dynamic> user) async {
    try {
      final callId = await RtcManager.startVoiceCall(caller: user, receiver: user);
      Navigator.pushNamed(context, '/voiceCall', arguments: {
        'callId': callId,
        'caller': user,
        'receiver': user,
      });
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start voice call')),
      );
    }
  }

  Future<void> _startVideoCall(BuildContext context, Map<String, dynamic> user) async {
    try {
      final callId = await RtcManager.startVideoCall(caller: user, receiver: user);
      Navigator.pushNamed(context, '/videoCall', arguments: {
        'callId': callId,
        'caller': user,
        'receiver': user,
      });
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start video call')),
      );
    }
  }

  void _showChatSettings(BuildContext context, Map<String, dynamic> user, Function(String)? onBackgroundSet) {
    final chatId = "${user['id']}";
    final TextEditingController urlController = TextEditingController();

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color.fromARGB(193, 202, 207, 255),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text("Change Chat Background", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(
              controller: urlController,
              decoration: InputDecoration(
                labelText: "Enter image URL",
                suffixIcon: IconButton(
                  icon: const Icon(Icons.check),
                  onPressed: () async {
                    final url = urlController.text.trim();
                    if (url.isNotEmpty) {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('chat_background_$chatId', url);
                      onBackgroundSet?.call(url);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Background updated!")),
                      );
                      Navigator.pop(context);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text("Movie Themes", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: _buildThemePreviews(context, movieThemes, chatId, onBackgroundSet)),
            const SizedBox(height: 24),
            const Text("Standard Themes", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: _buildThemePreviews(context, standardThemes, chatId, onBackgroundSet)),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildThemePreviews(BuildContext context, List<Map<String, dynamic>> themes,
      String chatId, Function(String)? onBackgroundSet) {
    return themes.map((theme) {
      return GestureDetector(
        onTap: () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('chat_background_$chatId', theme['url']);
          onBackgroundSet?.call(theme['url']);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Theme '${theme['name']}' applied")),
          );
          Navigator.pop(context);
        },
        child: Container(
          width: 100,
          height: 60,
          decoration: BoxDecoration(
            image: DecorationImage(
              image: NetworkImage(theme['url']),
              fit: BoxFit.cover,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Container(
            alignment: Alignment.bottomCenter,
            decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(8)),
            child: Text(theme['name'], style: const TextStyle(color: Colors.white, fontSize: 10)),
          ),
        ),
      );
    }).toList();
  }
}

// Predefined themes
final List<Map<String, dynamic>> movieThemes = [
  {'name': 'The Matrix', 'url': 'https://wallpapercave.com/wp/wp1826759.jpg'},
  {'name': 'Interstellar', 'url': 'https://wallpapercave.com/wp/wp1944055.jpg'},
  {'name': 'Blade Runner', 'url': 'https://wallpapercave.com/wp/wp2325539.jpg'},
  {'name': 'Dune', 'url': 'https://wallpapercave.com/wp/wp9943687.jpg'},
  {'name': 'Inception', 'url': 'https://wallpapercave.com/wp/wp2486940.jpg'},
];

final List<Map<String, dynamic>> standardThemes = [
  {'name': 'Light Blue', 'url': 'https://via.placeholder.com/300x150/ADD8E6/000000?text=Light+Blue'},
  {'name': 'Dark Mode', 'url': 'https://via.placeholder.com/300x150/1A1A1A/FFFFFF?text=Dark+Mode'},
];

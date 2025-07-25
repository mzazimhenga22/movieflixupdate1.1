import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ProfileScreen extends StatelessWidget {
  final Map<String, dynamic> user;

  const ProfileScreen({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("${user['username']}'s Profile"),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 50,
              backgroundImage: user['photoUrl'] != null && user['photoUrl'] != ''
                  ? NetworkImage(user['photoUrl'])
                  : const AssetImage('assets/default_user.png') as ImageProvider,
            ),
            const SizedBox(height: 16),
            Text(
              user['username'] ?? 'Unknown User',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () => _showChatSettings(context),
              icon: const Icon(Icons.settings),
              label: const Text("Chat Settings"),
            ),
          ],
        ),
      ),
    );
  }

  void _showChatSettings(BuildContext context) {
    final TextEditingController urlController = TextEditingController();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (ctx) {
        return Padding(
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
                        await prefs.setString('chatBackground', url);
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
              const Text("Movie Style Themes", style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _buildThemePreviews(context, movieThemes),
              ),
              const SizedBox(height: 24),
              const Text("Standard Themes", style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _buildThemePreviews(context, standardThemes),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildThemePreviews(BuildContext context, List<Map<String, dynamic>> themes) {
    return themes.map((theme) {
      return GestureDetector(
        onTap: () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('chatBackground', theme['url']);
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
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              theme['name'],
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ),
        ),
      );
    }).toList();
  }
}

// Movie-style backgrounds
final List<Map<String, dynamic>> movieThemes = [
  {
    'name': 'The Matrix',
    'url': 'https://wallpapercave.com/wp/wp1826759.jpg',
  },
  {
    'name': 'Interstellar',
    'url': 'https://wallpapercave.com/wp/wp1944055.jpg',
  },
  {
    'name': 'Blade Runner',
    'url': 'https://wallpapercave.com/wp/wp2325539.jpg',
  },
  {
    'name': 'Dune',
    'url': 'https://wallpapercave.com/wp/wp9943687.jpg',
  },
  {
    'name': 'Inception',
    'url': 'https://wallpapercave.com/wp/wp2486940.jpg',
  },
];

// Standard backgrounds
final List<Map<String, dynamic>> standardThemes = [
  {
    'name': 'Light Blue',
    'url': 'https://via.placeholder.com/300x150/ADD8E6/000000?text=Light+Blue',
  },
  {
    'name': 'Dark Mode',
    'url': 'https://via.placeholder.com/300x150/1A1A1A/FFFFFF?text=Dark+Mode',
  },
];

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class GroupProfileScreen extends StatelessWidget {
  final String groupId;

  const GroupProfileScreen({super.key, required this.groupId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('groups').doc(groupId).get(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const Scaffold(
            body: Center(child: Text('Group not found')),
          );
        }

        final groupData = snapshot.data!.data() as Map<String, dynamic>;
        final groupName = groupData['name'] ?? 'Unnamed Group';
        final groupPhoto = groupData['photoUrl'];
        final userIds = List<String>.from(groupData['userIds'] ?? []);

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
                      borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(30),
                      ),
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
                          backgroundImage:
                              groupPhoto != null ? NetworkImage(groupPhoto) : null,
                          child: groupPhoto == null
                              ? const Icon(Icons.group, size: 40, color: Colors.grey)
                              : null,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          groupName,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _exitGroup(context, groupId, userIds),
                      icon: const Icon(Icons.exit_to_app),
                      label: const Text("Exit Group"),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        backgroundColor: Colors.redAccent,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: () => _addToFavorites(context, groupId),
                      icon: const Icon(Icons.star_border),
                      label: const Text("Add to Favorites"),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: () => _showOthersOptions(context),
                      icon: const Icon(Icons.more_horiz),
                      label: const Text("Others"),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
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
                  child: Text(
                    'Members',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: userIds.length,
                  itemBuilder: (context, index) {
                    final userId = userIds[index];
                    return FutureBuilder<DocumentSnapshot>(
                      future: FirebaseFirestore.instance
                          .collection('users')
                          .doc(userId)
                          .get(),
                      builder: (context, userSnapshot) {
                        if (!userSnapshot.hasData || !userSnapshot.data!.exists) {
                          return const ListTile(title: Text('Unknown user'));
                        }

                        final userData =
                            userSnapshot.data!.data() as Map<String, dynamic>;
                        final username = userData['username'] ?? 'User';
                        final photoUrl = userData['photoUrl'];

                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          child: Card(
                            elevation: 1,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundImage:
                                    photoUrl != null ? NetworkImage(photoUrl) : null,
                                child:
                                    photoUrl == null ? const Icon(Icons.person) : null,
                              ),
                              title: Text(username),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _exitGroup(BuildContext context, String groupId, List<String> userIds) async {
    final currentUserId = FirebaseFirestore.instance.collection('users').doc().id; // Placeholder, replace with actual user ID
    if (userIds.contains(currentUserId)) {
      try {
        await FirebaseFirestore.instance.collection('groups').doc(groupId).update({
          'userIds': FieldValue.arrayRemove([currentUserId]),
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You have left the group')),
        );
        Navigator.pop(context);
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to exit group: $e')),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are not a member of this group')),
      );
    }
  }

  Future<void> _addToFavorites(BuildContext context, String groupId) async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? favorites = prefs.getStringList('favoriteGroups') ?? [];
    if (!favorites.contains(groupId)) {
      favorites.add(groupId);
      await prefs.setStringList('favoriteGroups', favorites);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group added to favorites')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group is already in favorites')),
      );
    }
  }

  void _showOthersOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.info),
                title: const Text('Group Info'),
                onTap: () {
                  Navigator.pop(context);
                  // Add group info logic here
                },
              ),
              ListTile(
                leading: const Icon(Icons.notifications),
                title: const Text('Notification Settings'),
                onTap: () {
                  Navigator.pop(context);
                  // Add notification settings logic here
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
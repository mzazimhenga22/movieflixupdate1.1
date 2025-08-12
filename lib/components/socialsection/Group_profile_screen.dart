import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';

class GroupProfileScreen extends StatefulWidget {
  final String groupId;
  final String currentUserId;

  const GroupProfileScreen({
    super.key,
    required this.groupId,
    required this.currentUserId,
  });

  @override
  State<GroupProfileScreen> createState() => _GroupProfileScreenState();
}

class _GroupProfileScreenState extends State<GroupProfileScreen> {
  final TextEditingController _nameController = TextEditingController();
  String? _groupPhotoUrl;
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _updateGroupName(String newName) async {
    if (newName.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group name cannot be empty')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).update({
        'name': newName.trim(),
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group name updated')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update group name: $e')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _updateGroupPhoto() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;

    setState(() => _isLoading = true);
    try {
      // Placeholder for uploading to storage (e.g., Firebase Storage)
      // For now, we'll use the local file path as a mock
      final photoUrl = pickedFile.path; // Replace with actual storage upload logic
      await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).update({
        'avatarUrl': photoUrl,
      });
      setState(() => _groupPhotoUrl = photoUrl);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group photo updated')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update group photo: $e')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addMembers() async {
    final snapshot = await FirebaseFirestore.instance.collection('users').get();
    final currentMembers = await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .get()
        .then((doc) => List<String>.from(doc.data()?['userIds'] ?? []));

    final availableUsers = snapshot.docs
        .where((doc) => !currentMembers.contains(doc.id) && doc.id != widget.currentUserId)
        .map((doc) => doc.data()..['id'] = doc.id)
        .toList();

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final selectedUsers = <String>{};

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Add Members',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: availableUsers.length,
                    itemBuilder: (context, index) {
                      final user = availableUsers[index];
                      final isSelected = selectedUsers.contains(user['id']);

                      return CheckboxListTile(
                        title: Text(user['username'] ?? 'User'),
                        subtitle: Text(user['email'] ?? ''),
                        value: isSelected,
                        onChanged: (value) {
                          setModalState(() {
                            if (value == true) {
                              selectedUsers.add(user['id']);
                            } else {
                              selectedUsers.remove(user['id']);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: ElevatedButton(
                    onPressed: selectedUsers.isEmpty
                        ? null
                        : () async {
                            setState(() => _isLoading = true);
                            try {
                              await FirebaseFirestore.instance
                                  .collection('groups')
                                  .doc(widget.groupId)
                                  .update({
                                'userIds': FieldValue.arrayUnion(selectedUsers.toList()),
                              });
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Members added')),
                              );
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Failed to add members: $e')),
                              );
                            } finally {
                              setState(() => _isLoading = false);
                            }
                          },
                    child: const Text('Add Selected'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _exitGroup(List<String> userIds) async {
    if (!userIds.contains(widget.currentUserId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are not a member of this group')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).update({
        'userIds': FieldValue.arrayRemove([widget.currentUserId]),
        'deletedBy': FieldValue.arrayUnion([widget.currentUserId]),
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You have left the group')),
      );
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to exit group: $e')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addToFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? favorites = prefs.getStringList('favoriteGroups') ?? [];
    if (!favorites.contains(widget.groupId)) {
      favorites.add(widget.groupId);
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

  void _showOthersOptions() {
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

  void _editGroupName(String currentName) {
    _nameController.text = currentName;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Group Name'),
        content: TextField(
          controller: _nameController,
          decoration: const InputDecoration(hintText: 'Enter new group name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              _updateGroupName(_nameController.text);
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('groups').doc(widget.groupId).get(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting || _isLoading) {
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
        final groupPhoto = groupData['avatarUrl'];
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
                        GestureDetector(
                          onTap: _updateGroupPhoto,
                          child: CircleAvatar(
                            radius: 50,
                            backgroundColor: Colors.grey[200],
                            backgroundImage: groupPhoto != null ? NetworkImage(groupPhoto) : null,
                            child: groupPhoto == null
                                ? const Icon(Icons.group, size: 40, color: Colors.grey)
                                : null,
                          ),
                        ),
                        const SizedBox(height: 10),
                        GestureDetector(
                          onTap: () => _editGroupName(groupName),
                          child: Text(
                            groupName,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
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
                      onPressed: () => _exitGroup(userIds),
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
                      onPressed: _addToFavorites,
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
                      onPressed: _addMembers,
                      icon: const Icon(Icons.person_add),
                      label: const Text("Add Members"),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: _showOthersOptions,
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

                    // Listen to the user's document for real-time presence changes
                    return StreamBuilder<DocumentSnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('users')
                          .doc(userId)
                          .snapshots(),
                      builder: (context, userSnapshot) {
                        if (!userSnapshot.hasData || !userSnapshot.data!.exists) {
                          return const ListTile(title: Text('Unknown user'));
                        }

                        final userData = userSnapshot.data!.data()! as Map<String, dynamic>;
                        final username = userData['username'] ?? 'User';
                        final photoUrl = userData['avatarUrl'] as String?;
                        final bool isOnline = userData['isOnline'] as bool? ?? false;

                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          child: Card(
                            elevation: 1,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: Colors.grey[200],
                                backgroundImage:
                                    photoUrl != null ? NetworkImage(photoUrl) : null,
                                child: photoUrl == null
                                    ? Text(
                                        username.substring(0, 1).toUpperCase(),
                                        style: const TextStyle(color: Colors.grey),
                                      )
                                    : null,
                              ),

                              // Member name
                              title: Text(username),

                              // Online/offline subtitle
                              subtitle: Text(
                                isOnline ? 'Online' : 'Offline',
                                style: TextStyle(
                                  color: isOnline ? Colors.green : Colors.grey,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),

                              // A little dot indicator on the right
                              trailing: Icon(
                                Icons.circle,
                                size: 12,
                                color: isOnline ? Colors.green : Colors.grey,
                              ),
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
}
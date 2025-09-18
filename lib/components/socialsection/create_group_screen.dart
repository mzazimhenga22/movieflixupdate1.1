import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'Group_chat_screen.dart';

class CreateGroupScreen extends StatefulWidget {
  final Map<String, dynamic> currentUser;
  final String initialGroupName;
  final List<Map<String, dynamic>> availableUsers;
  final Function(String chatId)? onGroupCreated;

  const CreateGroupScreen({
    super.key,
    required this.currentUser,
    required this.initialGroupName,
    required this.availableUsers,
    this.onGroupCreated,
  });

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final TextEditingController nameController = TextEditingController();
  List<Map<String, dynamic>> allUsers = [];
  List<Map<String, dynamic>> selectedUsers = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    nameController.text = widget.initialGroupName;
    allUsers = widget.availableUsers
        .where((user) => user['id'] != widget.currentUser['id'])
        .toList();
    isLoading = false;
  }

Future<void> createGroup() async {
  final name = nameController.text.trim();
  if (name.isEmpty || selectedUsers.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Group name and members are required')),
    );
    return;
  }

  final userIds = selectedUsers.map((u) => u['id']).toSet().toList()
    ..add(widget.currentUser['id']);

  try {
    final docRef = FirebaseFirestore.instance.collection('groups').doc(); // Create doc ref with ID

    await docRef.set({
      'id': docRef.id, // Include document ID
      'name': name,
      'isGroup': true,
      'userIds': userIds,
      'timestamp': FieldValue.serverTimestamp(),
      'lastMessage': '',
      'deletedBy': [],
    });

if (widget.onGroupCreated != null) {
  widget.onGroupCreated?.call(docRef.id);
} else {
  Navigator.pushReplacement(
    context,
    MaterialPageRoute(
      builder: (_) => GroupChatScreen(
        chatId: docRef.id,
        currentUser: widget.currentUser,
        authenticatedUser: widget.currentUser,
        accentColor: _parseAccentColor(widget.currentUser['accentColor']),
      ),
    ),
  );
}
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Failed to create group: $e')),
    );
  }
}

  Color _parseAccentColor(dynamic colorData) {
    if (colorData is int) {
      return Color(colorData);
    }
    return const Color.fromARGB(255, 255, 68, 77);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final accentColor = _parseAccentColor(widget.currentUser['accentColor']);

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Background Gradient
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.redAccent, Colors.blueAccent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),

          // Radial Layer
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.1, -0.4),
                radius: 1.2,
                colors: [accentColor.withOpacity(0.4), Colors.black],
                stops: const [0.0, 0.6],
              ),
            ),
          ),

          // Content
          CustomScrollView(
            slivers: [
              SliverAppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                pinned: true,
                expandedHeight: 150,
                flexibleSpace: const FlexibleSpaceBar(
                  title: Text(
                    'Create Group',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  centerTitle: true,
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 1.6,
                        colors: [
                          accentColor.withOpacity(0.2),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 1.0],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: accentColor.withOpacity(0.4),
                          blurRadius: 10,
                          spreadRadius: 1,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color.fromARGB(59, 105, 3, 20),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.1),
                            ),
                          ),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minHeight: screenHeight),
                            child: isLoading
                                ? const Center(child: CircularProgressIndicator())
                                : Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        // Group name input
                                        TextField(
                                          controller: nameController,
                                          decoration: InputDecoration(
                                            labelText: 'Group Name',
                                            labelStyle: TextStyle(color: accentColor),
                                            filled: true,
                                            fillColor: Colors.white.withOpacity(0.1),
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(12),
                                              borderSide: BorderSide.none,
                                            ),
                                          ),
                                          style: const TextStyle(color: Colors.white),
                                        ),
                                        const SizedBox(height: 16),

                                        // Members section
                                        Text(
                                          'Select Members',
                                          style: TextStyle(
                                            color: accentColor,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 18,
                                          ),
                                        ),
                                        const SizedBox(height: 8),

                                        // Users list
                                        ListView.builder(
                                          shrinkWrap: true,
                                          physics: const NeverScrollableScrollPhysics(),
                                          itemCount: allUsers.length,
                                          itemBuilder: (_, index) {
                                            final user = allUsers[index];
                                            final isSelected = selectedUsers.any((u) => u['id'] == user['id']);

                                            return Card(
                                              elevation: 4,
                                              shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(12),
                                              ),
                                              margin: const EdgeInsets.symmetric(vertical: 8),
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  gradient: LinearGradient(
                                                    colors: [
                                                      accentColor.withOpacity(0.1),
                                                      accentColor.withOpacity(0.3),
                                                    ],
                                                    begin: Alignment.topLeft,
                                                    end: Alignment.bottomRight,
                                                  ),
                                                  borderRadius: BorderRadius.circular(12),
                                                  border: Border.all(
                                                    color: accentColor.withOpacity(0.3),
                                                  ),
                                                ),
                                                child: CheckboxListTile(
  value: isSelected,
  title: Text(
    (user['username'] ?? 'Unknown User').toString(),
    style: TextStyle(
      color: accentColor,
      fontWeight: FontWeight.bold,
    ),
  ),
  subtitle: Text(
    (user['email'] ?? 'No email').toString(),
    style: TextStyle(
      color: accentColor.withOpacity(0.7),
    ),
  ),
  secondary: CircleAvatar(
    backgroundColor: Colors.grey[300],
    backgroundImage: (user['photoUrl'] != null &&
            user['photoUrl'].toString().isNotEmpty)
        ? NetworkImage(user['photoUrl'])
        : null,
    child: (user['photoUrl'] == null ||
            user['photoUrl'].toString().isEmpty)
        ? Text(
            (user['username'] ?? '?').toString().isNotEmpty
                ? (user['username'] ?? '?')[0].toUpperCase()
                : '?',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          )
        : null,
  ),
  onChanged: (selected) {
    setState(() {
      if (selected == true && !isSelected) {
        selectedUsers.add(user);
      } else if (selected == false) {
        selectedUsers.removeWhere((u) => u['id'] == user['id']);
      }
    });
  },
  activeColor: accentColor,
  checkColor: Colors.white,
),

                                              ),
                                            );
                                          },
                                        ),
                                        const SizedBox(height: 16),

                                        // Create Group Button
                                        Center(
                                          child: ElevatedButton(
                                            onPressed: createGroup,
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: accentColor,
                                              foregroundColor: Colors.white,
                                              shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(12),
                                              ),
                                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                            ),
                                            child: const Text('Create Group'),
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
              ),
            ],
          ),
        ],
      ),
    );
  }
}

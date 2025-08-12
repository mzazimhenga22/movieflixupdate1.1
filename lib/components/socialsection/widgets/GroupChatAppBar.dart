import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../presence_wrapper.dart';

class GroupChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String groupId;
  final String groupName;
  final String groupPhotoUrl;
  final VoidCallback onBack;
  final VoidCallback onGroupInfoTap;
  final VoidCallback onVideoCall;
  final VoidCallback onVoiceCall;
  final Color accentColor;

  const GroupChatAppBar({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.onBack,
    required this.onGroupInfoTap,
    required this.onVideoCall,
    required this.onVoiceCall,
    this.accentColor = Colors.blueAccent,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) {
    return PresenceWrapper(
      userId:
          'current_user_id', // Replace with actual user ID from context or auth
      groupIds: [groupId],
      child: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('groups')
            .doc(groupId)
            .snapshots(),
        builder: (context, groupSnapshot) {
          if (!groupSnapshot.hasData || !groupSnapshot.data!.exists) {
            return AppBar(
              title: Text(groupName),
              leading: IconButton(
                icon: Icon(Icons.arrow_back, color: accentColor),
                onPressed: onBack,
              ),
            );
          }

          final groupData = groupSnapshot.data!.data() as Map<String, dynamic>;
          final userIds = List<String>.from(groupData['userIds'] ?? []);

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('groups')
                .doc(groupId)
                .collection('presence')
                .snapshots(),
            builder: (context, presenceSnapshot) {
              final presenceDocs = presenceSnapshot.data?.docs ?? [];
              final onlineCount = presenceDocs
                  .where((doc) =>
                      doc['isOnline'] == true && userIds.contains(doc.id))
                  .length;
              final totalMembers = userIds.length;

              return AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                flexibleSpace: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        accentColor.withOpacity(0.3),
                        Colors.black.withOpacity(0.5),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: accentColor.withOpacity(0.2),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                    border: Border(
                      bottom: BorderSide(
                        color: accentColor.withOpacity(0.1),
                        width: 1,
                      ),
                    ),
                  ),
                ),
                leading: IconButton(
                  icon: Icon(Icons.arrow_back, color: accentColor),
                  onPressed: onBack,
                ),
                title: InkWell(
                  onTap: onGroupInfoTap,
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundImage: NetworkImage(
                          groupPhotoUrl.isNotEmpty
                              ? groupPhotoUrl
                              : 'https://via.placeholder.com/150',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            groupName,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: accentColor,
                            ),
                          ),
                          Text(
                            '$onlineCount of $totalMembers online',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                actions: [
                  IconButton(
                    icon: Icon(Icons.call, color: accentColor),
                    onPressed: onVoiceCall,
                  ),
                  IconButton(
                    icon: Icon(Icons.videocam, color: accentColor),
                    onPressed: onVideoCall,
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

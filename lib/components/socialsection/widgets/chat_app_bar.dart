import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import '../VoiceCallScreen_1to1.dart';
import '../VideoCallScreen_1to1.dart';
import '../presence_wrapper.dart';

class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;
  final String chatId;
  final VoidCallback onBack;
  final VoidCallback onProfileTap;
  final VoidCallback onVideoCall;
  final VoidCallback onVoiceCall;
  final bool isOnline;
  final bool hasStory;
  final Color accentColor;

  const ChatAppBar({
    super.key,
    required this.currentUser,
    required this.otherUser,
    required this.chatId,
    required this.onBack,
    required this.onProfileTap,
    required this.onVideoCall,
    required this.onVoiceCall,
    required this.hasStory,
    required this.isOnline,
    this.accentColor = const Color.fromARGB(255, 255, 61, 71),
  });

  Future<void> _startCall(BuildContext context, bool isVideo) async {
    try {
      // Check if user is blocked
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser['id'])
          .get();
      final blockedUsers = List<String>.from(userDoc.data()?['blockedUsers'] ?? []);
      if (blockedUsers.contains(otherUser['id'])) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot initiate call to blocked user')),
          );
        }
        return;
      }

      // Start call using RtcManager
      final callId = isVideo
          ? await RtcManager.startVideoCall(
              caller: currentUser,
              receiver: otherUser,
            )
          : await RtcManager.startVoiceCall(
              caller: currentUser,
              receiver: otherUser,
            );

      // Store call data in Firestore
      await FirebaseFirestore.instance.collection('calls').doc(callId).set({
        'type': isVideo ? 'video' : 'voice',
        'callerId': currentUser['id'],
        'receiverId': otherUser['id'],
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'ringing',
        'participantStatus': {currentUser['id']: 'joined'},
      });

      // Navigate to call screen
      if (context.mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => isVideo
                ? VideoCallScreen1to1(
                    callId: callId,
                    callerId: currentUser['id'],
                    receiverId: otherUser['id'],
                    currentUserId: currentUser['id'],
                    caller: currentUser,
                    receiver: otherUser,
                  )
                : VoiceCallScreen1to1(
                    callId: callId,
                    callerId: currentUser['id'],
                    receiverId: otherUser['id'],
                    currentUserId: currentUser['id'],
                    caller: currentUser,
                    receiver: otherUser,
                  ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start call: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final otherUserId = otherUser['id'] as String;
    return PresenceWrapper(
      userId: currentUser['id'],
      groupIds: [chatId],
      child: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(otherUserId)
            .snapshots(),
        builder: (context, snapshot) {
          final data = snapshot.data?.data() as Map<String, dynamic>? ?? {};
          final online = data['isOnline'] == true;
          final lastSeenTs = data['lastSeen'] as Timestamp?;
          final lastSeenText = lastSeenTs != null
              ? 'Last seen ${TimeOfDay.fromDateTime(lastSeenTs.toDate()).format(context)}'
              : 'Offline';

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
              onTap: onProfileTap,
              child: Row(
                children: [
                  Stack(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundImage: NetworkImage(
                          otherUser['photoUrl'] ?? 'https://via.placeholder.com/150',
                        ),
                      ),
                      if (hasStory)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                              color: accentColor,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        otherUser['username'] ?? 'User',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: accentColor,
                        ),
                      ),
                      Text(
                        online ? 'Online' : lastSeenText,
                        style: TextStyle(
                          fontSize: 12,
                          color: online ? Colors.green : Colors.grey,
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
                onPressed: () {
                  onVoiceCall();
                  _startCall(context, false);
                },
              ),
              IconButton(
                icon: Icon(Icons.videocam, color: accentColor),
                onPressed: () {
                  onVideoCall();
                  _startCall(context, true);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}
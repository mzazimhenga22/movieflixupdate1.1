import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:movie_app/webrtc/group_rtc_manager.dart';
import 'Group_profile_screen.dart';
import 'widgets/GroupChatAppBar.dart';
import 'widgets/typing_area.dart';
import 'widgets/GroupChatList.dart';
import 'package:movie_app/utils/read_status_utils.dart';

class GroupChatScreen extends StatefulWidget {
  final String chatId;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> authenticatedUser;
  final Color accentColor;

  const GroupChatScreen({
    super.key,
    required this.chatId,
    required this.currentUser,
    required this.authenticatedUser,
    this.accentColor = Colors.blueAccent,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  String? backgroundUrl;
  List<Map<String, dynamic>> groupMembers = [];
  Map<String, dynamic>? groupData;
  int _onlineCount = 0;
  QueryDocumentSnapshot<Object?>? replyingTo;
  bool _isLoading = true; // Track loading state

  @override
  void initState() {
    super.initState();
    _loadChatBackground();
    _loadGroupDataAndListen();
    markGroupAsRead(widget.chatId, widget.currentUser['id']);
  }

  Future<void> _loadChatBackground() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      backgroundUrl = prefs.getString('chat_background');
    });
  }

  void _onReplyToMessage(QueryDocumentSnapshot<Object?> message) {
    setState(() {
      replyingTo = message;
    });
  }

  void _onCancelReply() {
    setState(() {
      replyingTo = null;
    });
  }

  void _loadGroupDataAndListen() async {
    try {
      final chatDoc = await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.chatId)
          .get();

      if (chatDoc.exists && chatDoc.data()!['isGroup'] == true) {
        final memberIds = List<String>.from(chatDoc.data()!['userIds'] ?? []);
        final membersSnapshots = await Future.wait(memberIds.map(
          (uid) => FirebaseFirestore.instance.collection('users').doc(uid).get(),
        ));

        setState(() {
          groupData = chatDoc.data();
          groupMembers = membersSnapshots
              .where((doc) => doc.exists)
              .map((doc) => doc.data()!..['id'] = doc.id)
              .toList();
          _isLoading = false; // Data loaded
        });

        FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: memberIds)
            .snapshots()
            .listen((snapshot) {
          int online =
              snapshot.docs.where((doc) => doc.data()['isOnline'] == true).length;
          setState(() {
            _onlineCount = online;
          });
        });
      } else {
        setState(() {
          _isLoading = false; // Handle case where group doesn't exist
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false; // Handle error
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load group data: $e')),
      );
    }
  }

  void sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    final messageData = {
      'text': text,
      'senderId': widget.currentUser['id'],
      'timestamp': FieldValue.serverTimestamp(),
      'type': 'text',
    };

    await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.chatId)
        .collection('messages')
        .add(messageData);

    await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.chatId)
        .set({
      'lastMessage': text,
      'timestamp': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  void sendFile(File file) {
    print("Sending file: ${file.path}");
    // TODO: Implement file upload and sending
  }

  void sendAudio(File audio) {
    print("Sending audio: ${audio.path}");
    // TODO: Implement audio upload and sending
  }

  void startVoiceCall() async {
    try {
      final callId = await GroupRtcManager.startGroupCall(
        caller: widget.currentUser,
        participants: groupMembers,
        isVideo: false,
      );

      await FirebaseFirestore.instance.collection('calls').doc(callId).set({
        'type': 'voice',
        'groupId': widget.chatId,
        'callerId': widget.currentUser['id'],
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'ongoing',
      });
    } catch (e) {
      print("Voice call failed: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start voice call: $e')),
      );
    }
  }

  void startVideoCall() async {
    try {
      final callId = await GroupRtcManager.startGroupCall(
        caller: widget.currentUser,
        participants: groupMembers,
        isVideo: true,
      );

      await FirebaseFirestore.instance.collection('calls').doc(callId).set({
        'type': 'video',
        'groupId': widget.chatId,
        'callerId': widget.currentUser['id'],
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'ongoing',
      });
    } catch (e) {
      print("Video call failed: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start video call: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    if (_isLoading || groupData == null) {
      return Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.1, -0.4),
              radius: 1.2,
              colors: [widget.accentColor.withOpacity(0.4), Colors.black],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        widget.accentColor,
                        widget.accentColor.withOpacity(0.6),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: const CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    strokeWidth: 3,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Loading Group Chat...',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    shadows: [
                      Shadow(
                        blurRadius: 4,
                        color: widget.accentColor.withOpacity(0.5),
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Fetching group details',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: GroupChatAppBar(
          groupId: widget.chatId,
          groupName: groupData!['name'] ?? 'Group',
          groupPhotoUrl: groupData!['avatarUrl'] ?? '',
          onlineCount: _onlineCount,
          totalMembers: groupMembers.length,
          onBack: () => Navigator.pop(context),
          onGroupInfoTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => GroupProfileScreen(groupId: widget.chatId),
              ),
            );
          },
          onVideoCall: startVideoCall,
          onVoiceCall: startVoiceCall,
          accentColor: widget.accentColor,
        ),
      ),
      body: Stack(
        children: [
          _buildBackground(),
          Positioned.fill(
            top: kToolbarHeight + MediaQuery.of(context).padding.top,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 1.6,
                      colors: [
                        widget.accentColor.withOpacity(0.2),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 1.0],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: widget.accentColor.withOpacity(0.1)),
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: screenHeight),
                    child: Column(
                      children: [
                        Expanded(
                          child: GroupChatList(
                            groupId: widget.chatId,
                            currentUser: widget.currentUser,
                            groupMembers: groupMembers,
                            onReplyToMessage: _onReplyToMessage,
                          ),
                        ),
                        TypingArea(
                          onSendMessage: sendMessage,
                          onSendFile: sendFile,
                          onSendAudio: sendAudio,
                          accentColor: widget.accentColor,
                          replyingTo: replyingTo,
                          onCancelReply: _onCancelReply,
                        ),
                      ],
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

  Widget _buildBackground() {
    return backgroundUrl != null
        ? Container(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: backgroundUrl!.startsWith('http')
                    ? NetworkImage(backgroundUrl!)
                    : AssetImage(backgroundUrl!) as ImageProvider,
                fit: BoxFit.cover,
              ),
            ),
          )
        : Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.1, -0.4),
                radius: 1.2,
                colors: [widget.accentColor.withOpacity(0.4), Colors.black],
              ),
            ),
          );
  }
}
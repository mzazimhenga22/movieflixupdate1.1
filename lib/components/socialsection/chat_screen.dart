import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'widgets/chat_app_bar.dart';
import 'widgets/typing_area.dart';
import 'widgets/advanced_chat_list.dart';
import 'package:movie_app/utils/read_status_utils.dart';


class ChatScreen extends StatefulWidget {
  final String chatId;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;
  final Map<String, dynamic> authenticatedUser;
  final List<dynamic> storyInteractions;
  final Color accentColor;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.currentUser,
    required this.otherUser,
    required this.authenticatedUser,
    required this.storyInteractions,
    this.accentColor = Colors.blueAccent,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  String? backgroundUrl;

  @override
  void initState() {
    super.initState();
    _loadChatBackground();
    markChatAsRead(widget.chatId, widget.currentUser['id']);
  }

  Future<void> _loadChatBackground() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      backgroundUrl = prefs.getString('chat_background');
    });
  }

  Future<void> _setChatBackground(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat_background', url);
    setState(() {
      backgroundUrl = url;
    });
  }

  Future<bool> _isUserBlocked(String userId) async {
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.currentUser['id'])
        .get();
    final blockedUsers = List<String>.from(userDoc.get('blockedUsers') ?? []);
    return blockedUsers.contains(userId);
  }

  void sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    final isBlocked = await _isUserBlocked(widget.otherUser['id']);
    if (isBlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot send message to blocked user')),
      );
      return;
    }

    final messageData = {
      'text': text,
      'senderId': widget.currentUser['id'],
      'receiverId': widget.otherUser['id'],
      'timestamp': FieldValue.serverTimestamp(),
      'type': 'text',
    };

    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .add(messageData);

    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).set({
      'lastMessage': text,
      'timestamp': FieldValue.serverTimestamp(),
      'userIds': [widget.currentUser['id'], widget.otherUser['id']],
    }, SetOptions(merge: true));
  }

  void sendFile(File file) async {
    final isBlocked = await _isUserBlocked(widget.otherUser['id']);
    if (isBlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot send file to blocked user')),
      );
      return;
    }
    print("Sending file: ${file.path}");
    // TODO: Upload file to Firebase Storage and send file message
  }

  void sendAudio(File audio) async {
    final isBlocked = await _isUserBlocked(widget.otherUser['id']);
    if (isBlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot send audio to blocked user')),
      );
      return;
    }
    print("Sending audio: ${audio.path}");
    // TODO: Upload audio and send audio message
  }

  void startVoiceCall() async {
    final isBlocked = await _isUserBlocked(widget.otherUser['id']);
    if (isBlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot call blocked user')),
      );
      return;
    }

    final callId = await RtcManager.startVoiceCall(
      caller: widget.currentUser,
      receiver: widget.otherUser,
    );

    await FirebaseFirestore.instance.collection('calls').doc(callId).set({
      'type': 'voice',
      'callerId': widget.currentUser['id'],
      'receiverId': widget.otherUser['id'],
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'ongoing',
    });
  }

  void startVideoCall() async {
    final isBlocked = await _isUserBlocked(widget.otherUser['id']);
    if (isBlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot call blocked user')),
      );
      return;
    }

    final callId = await RtcManager.startVideoCall(
      caller: widget.currentUser,
      receiver: widget.otherUser,
    );

    await FirebaseFirestore.instance.collection('calls').doc(callId).set({
      'type': 'video',
      'callerId': widget.currentUser['id'],
      'receiverId': widget.otherUser['id'],
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'ongoing',
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      extendBodyBehindAppBar: false,
      backgroundColor: Colors.transparent,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ChatAppBar(
          currentUser: widget.currentUser,
          otherUser: widget.otherUser,
          chatId: widget.chatId,
          onBack: () => Navigator.pop(context),
          onProfileTap: () {
            Navigator.pushNamed(context, '/profile', arguments: {
              ...widget.otherUser,
              'onBackgroundSet': _setChatBackground,
            });
          },
          onVideoCall: startVideoCall,
          onVoiceCall: startVoiceCall,
          isOnline: widget.otherUser['isOnline'] ?? false,
          hasStory: widget.storyInteractions.contains(widget.otherUser['id']),
        ),
      ),
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.redAccent, Colors.blueAccent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.1, -0.4),
                radius: 1.2,
                colors: [widget.accentColor.withOpacity(0.4), Colors.black],
                stops: const [0.0, 0.6],
              ),
            ),
          ),
          Positioned.fill(
            top: kToolbarHeight + MediaQuery.of(context).padding.top,
            child: Container(
              decoration: backgroundUrl != null
                  ? BoxDecoration(
                      image: DecorationImage(
                        image: backgroundUrl!.startsWith('http')
                            ? NetworkImage(backgroundUrl!)
                            : AssetImage(backgroundUrl!) as ImageProvider,
                        fit: BoxFit.cover,
                      ),
                    )
                  : null,
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
                      border: Border.all(
                          color: widget.accentColor.withOpacity(0.1)),
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: screenHeight),
                      child: Column(
                        children: [
                          Expanded(
                            child: AdvancedChatList(
                              chatId: widget.chatId,
                              currentUser: widget.currentUser,
                              otherUser: widget.otherUser,
                            ),
                          ),
                          TypingArea(
  onSendMessage: sendMessage,
  onSendFile: sendFile,
  onSendAudio: sendAudio,
  accentColor: widget.accentColor,
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
}
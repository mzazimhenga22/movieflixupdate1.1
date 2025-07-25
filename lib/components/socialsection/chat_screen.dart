import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'widgets/chat_app_bar.dart';
import 'widgets/typing_area.dart';
import 'widgets/advanced_chat_list.dart';
import 'dart:io';

class ChatScreen extends StatefulWidget {
  final String chatId;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;
  final Map<String, dynamic> authenticatedUser;
  final List<dynamic> storyInteractions;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.currentUser,
    required this.otherUser,
    required this.authenticatedUser,
    required this.storyInteractions,
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

  void sendMessage(String text) async {
    if (text.trim().isEmpty) return;

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
    print("Sending file: ${file.path}");
    // TODO: Upload file to Firebase Storage and send file message
  }

  void sendAudio(File audio) async {
    print("Sending audio: ${audio.path}");
    // TODO: Upload audio and send audio message
  }

  void startVoiceCall() async {
    final callId = await RtcManager.startVoiceCall(
      caller: widget.currentUser,
      receiver: widget.otherUser,
    );

    FirebaseFirestore.instance.collection('calls').doc(callId).set({
      'type': 'voice',
      'callerId': widget.currentUser['id'],
      'receiverId': widget.otherUser['id'],
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'ongoing',
    });
  }

  void startVideoCall() async {
    final callId = await RtcManager.startVideoCall(
      caller: widget.currentUser,
      receiver: widget.otherUser,
    );

    FirebaseFirestore.instance.collection('calls').doc(callId).set({
      'type': 'video',
      'callerId': widget.currentUser['id'],
      'receiverId': widget.otherUser['id'],
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'ongoing',
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ChatAppBar(
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
      body: Container(
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
            ),
          ],
        ),
      ),
    );
  }
}

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
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:movie_app/utils/read_status_utils.dart';
import 'widgets/message_actions.dart';

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
  bool _isLoading = true;
  bool isActionOverlayVisible = false;

  @override
  void initState() {
    super.initState();
    _loadChatBackground();
    _loadGroupDataAndListen();
    markGroupAsRead(widget.chatId, widget.currentUser['id']);
  }

  Future<void> _loadChatBackground() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => backgroundUrl = prefs.getString('chat_background'));
  }

  void _onReplyToMessage(QueryDocumentSnapshot<Object?> message) {
    setState(() => replyingTo = message);
  }

  void _onCancelReply() {
    setState(() => replyingTo = null);
  }

  void _showMessageActions(
      QueryDocumentSnapshot<Object?> message, bool isMe, GlobalKey bubbleKey) {
    setState(() {
      isActionOverlayVisible = true;
    });
    showMessageActions(
      context: context,
      message: message,
      isMe: isMe,
      messageKey: bubbleKey,
      onReply: () {
        _onReplyToMessage(message);
        setState(() {
          isActionOverlayVisible = false;
        });
      },
      onPin: () async {
        await FirebaseFirestore.instance
            .collection('groups')
            .doc(widget.chatId)
            .set({
          'pinnedMessageId': message.id,
          'pinnedMessageText': message['text'],
          'pinnedMessageSenderId': message['senderId'],
        }, SetOptions(merge: true));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                color: widget.accentColor,
                borderRadius: BorderRadius.circular(8.0),
              ),
              child: Text(
                message['text'],
                style: const TextStyle(color: Colors.black),
              ),
            ),
          ),
        );
        setState(() {
          isActionOverlayVisible = false;
        });
      },
      onDelete: () async {
        final data = message.data() as Map<String, dynamic>;
        final deletedFor = List<String>.from(data['deletedFor'] ?? []);
        deletedFor.add(widget.currentUser['id']);
        await FirebaseFirestore.instance
            .collection('groups')
            .doc(widget.chatId)
            .collection('messages')
            .doc(message.id)
            .update({'deletedFor': deletedFor});
        setState(() {
          isActionOverlayVisible = false;
        });
      },
      onBlock: () async {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.currentUser['id'])
            .update({
          'blockedUsers': FieldValue.arrayUnion([message['senderId']])
        });
        setState(() {
          isActionOverlayVisible = false;
        });
      },
      onForward: () {
        Navigator.pushNamed(context, '/forward', arguments: {
          'message': message,
          'currentUser': widget.currentUser,
        });
        setState(() {
          isActionOverlayVisible = false;
        });
      },
      onEdit: () {
        if (isMe) {
          Navigator.pushNamed(context, '/editMessage', arguments: {
            'message': message,
            'chatId': widget.chatId,
          });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot edit others\' messages')),
          );
        }
        setState(() {
          isActionOverlayVisible = false;
        });
      },
      onReactEmoji: (emoji) async {
        await FirebaseFirestore.instance
            .collection('groups')
            .doc(widget.chatId)
            .collection('messages')
            .doc(message.id)
            .update({
          'reactions': FieldValue.arrayUnion([emoji])
        });
        setState(() {
          isActionOverlayVisible = false;
        });
      },
    );
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
          (uid) =>
              FirebaseFirestore.instance.collection('users').doc(uid).get(),
        ));

        setState(() {
          groupData = chatDoc.data();
          groupMembers = membersSnapshots
              .where((doc) => doc.exists)
              .map((doc) => doc.data()!..['id'] = doc.id)
              .toList();
          _isLoading = false;
        });

        FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: memberIds)
            .snapshots()
            .listen((snapshot) {
          final online =
              snapshot.docs.where((d) => d.data()['isOnline'] == true).length;
          setState(() => _onlineCount = online);
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  void sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    final msg = {
      'text': text,
      'senderId': widget.currentUser['id'],
      'timestamp': FieldValue.serverTimestamp(),
      'type': 'text',
      if (replyingTo != null) ...{
        'replyToId': replyingTo!.id,
        'replyToText': replyingTo!['text'],
        'replyToSenderId': replyingTo!['senderId'],
      },
    };
    await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.chatId)
        .collection('messages')
        .add(msg);
    await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.chatId)
        .set({
      'lastMessage': text,
      'timestamp': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    setState(() => replyingTo = null);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    if (_isLoading || groupData == null) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator()),
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
          onGroupInfoTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GroupProfileScreen(groupId: widget.chatId),
            ),
          ),
          onVideoCall: () => {},
          onVoiceCall: () => {},
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
                        Colors.transparent
                      ],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border:
                        Border.all(color: widget.accentColor.withOpacity(0.1)),
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        child: GroupChatList(
                          groupId: widget.chatId,
                          currentUser: widget.currentUser,
                          groupMembers: groupMembers,
                          onMessageLongPressed: _showMessageActions,
                          replyingTo: replyingTo,
                          onCancelReply: _onCancelReply,
                        ),
                      ),
                      KeyboardVisibilityBuilder(
                        builder: (context, isVisible) => Padding(
                          padding: EdgeInsets.only(
                              bottom: MediaQuery.of(context).viewInsets.bottom),
                          child: TypingArea(
                            onSendMessage: sendMessage,
                            onSendFile: (file) {},
                            onSendAudio: (audio) {},
                            isGroup: true,
                            accentColor: widget.accentColor,
                            replyingTo: replyingTo,
                            currentUser: {'id': 'abc123', 'username': 'Alice'},
                            otherUser: {'id': 'xyz456', 'username': 'Bob'},
                            onCancelReply: _onCancelReply,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground() => backgroundUrl != null
      ? DecoratedBox(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: backgroundUrl!.startsWith('http')
                  ? NetworkImage(backgroundUrl!)
                  : AssetImage(backgroundUrl!) as ImageProvider,
              fit: BoxFit.cover,
            ),
          ),
        )
      : Container(color: widget.accentColor.withOpacity(0.4));
}
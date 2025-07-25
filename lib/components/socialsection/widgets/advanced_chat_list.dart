// /chat/advanced_chat_list.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'message_bubble.dart';
import 'message_actions.dart';
import 'reply_preview.dart';
import 'pinned_message_bar.dart';

class AdvancedChatList extends StatefulWidget {
  final String chatId;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;

  const AdvancedChatList({
    required this.chatId,
    required this.currentUser,
    required this.otherUser,
    super.key,
  });

  @override
  State<AdvancedChatList> createState() => _AdvancedChatListState();
}

class _AdvancedChatListState extends State<AdvancedChatList> {
  DocumentSnapshot? replyingTo;
  DocumentSnapshot? pinnedMessage;

  @override
  void initState() {
    super.initState();
    _fetchPinnedMessage();
  }

void _fetchPinnedMessage() async {
  final doc = await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).get();

  // ✅ Check if field exists and is not null
  if (doc.exists && doc.data() != null && doc.data()!.containsKey('pinnedMessageId')) {
    final pinnedId = doc['pinnedMessageId'];
    if (pinnedId != null) {
      final pinned = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .doc(pinnedId)
          .get();

      if (pinned.exists) {
        setState(() => pinnedMessage = pinned);
      }
    }
  }
}


  void _onReply(DocumentSnapshot message) {
    setState(() => replyingTo = message);
  }

  void _onCancelReply() {
    setState(() => replyingTo = null);
  }

  Future<void> _pinMessage(DocumentSnapshot msg) async {
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).set({
      'pinnedMessageId': msg.id,
    }, SetOptions(merge: true));
    setState(() => pinnedMessage = msg);
  }

  @override
  Widget build(BuildContext context) {
    final messagesRef = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true);

    return Column(
      children: [
        if (pinnedMessage != null)
     PinnedMessageBar(
  pinnedText: pinnedMessage!['text'],
  onDismiss: () => setState(() => pinnedMessage = null),
),

        if (replyingTo != null)
         ReplyPreview(
  replyText: replyingTo!['text'],
  onCancel: _onCancelReply,
),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: messagesRef.snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const CircularProgressIndicator();
              final messages = snapshot.data!.docs;
              return ListView.builder(
                reverse: true,
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index];
                  final isMe = message['senderId'] == widget.currentUser['id'];
                  return GestureDetector(
                    onLongPress: () => showMessageActions(
  context: context,
  message: message, // ← keep it as DocumentSnapshot
  isMe: isMe,
  onReply: () => _onReply(message),
  onPin: () => _pinMessage(message),
),

                    child: MessageBubble(
                      message: message,
                      currentUser: widget.currentUser,
                      otherUser: widget.otherUser,
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'message_bubble.dart';
import 'reply_preview.dart';
import 'pinned_message_bar.dart';
import 'mark_read_unread.dart';

class AdvancedChatList extends StatefulWidget {
  final String chatId;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;
  final void Function(QueryDocumentSnapshot<Object?> message, bool isMe, GlobalKey bubbleKey) onMessageLongPressed;
  final QueryDocumentSnapshot<Object?>? replyingTo;
  final VoidCallback? onCancelReply;
  final void Function(QueryDocumentSnapshot<Object?> message)? onReply;

  const AdvancedChatList({
    required this.chatId,
    required this.currentUser,
    required this.otherUser,
    required this.onMessageLongPressed,
    this.replyingTo,
    this.onCancelReply,
    this.onReply,
    super.key,
  });

  @override
  State<AdvancedChatList> createState() => _AdvancedChatListState();
}

class _AdvancedChatListState extends State<AdvancedChatList> {
  DocumentSnapshot? pinnedMessage;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchPinnedMessage();
    _markChatAsRead();
    _listenForPinnedMessageChanges();
  }

  void _fetchPinnedMessage() async {
    final doc = await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .get();

    await _updatePinnedMessage(doc);
  }

  void _listenForPinnedMessageChanges() {
    FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .snapshots()
        .listen((doc) async {
      await _updatePinnedMessage(doc);
    });
  }

Future<void> _updatePinnedMessage(DocumentSnapshot doc) async {
  if (doc.exists && doc.data() != null) {
    final data = doc.data() as Map<String, dynamic>;
    if (data.containsKey('pinnedMessageId')) {
      final pinnedId = data['pinnedMessageId'];
      if (pinnedId != null) {
        final pinned = await FirebaseFirestore.instance
            .collection('chats')
            .doc(widget.chatId)
            .collection('messages')
            .doc(pinnedId)
            .get();

        if (pinned.exists) {
          if (mounted) {
            setState(() => pinnedMessage = pinned);
          }
        } else {
          await _clearPinnedMessage();
        }
      } else {
        await _clearPinnedMessage();
      }
    } else {
      await _clearPinnedMessage();
    }
  }
}


Future<void> _clearPinnedMessage() async {
  await FirebaseFirestore.instance
      .collection('chats')
      .doc(widget.chatId)
      .update({'pinnedMessageId': null});

  if (mounted) {
    setState(() => pinnedMessage = null);
  }
}


  void _markChatAsRead() async {
    await MessageStatusUtils.markAsRead(
      chatId: widget.chatId,
      userId: widget.currentUser['id'],
      isGroup: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final messagesRef = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(30);

    return Column(
      children: [
        if (pinnedMessage != null)
          PinnedMessageBar(
            pinnedText: pinnedMessage!['text'],
            onDismiss: _clearPinnedMessage,
          ),
        if (widget.replyingTo != null)
          ReplyPreview(
            replyText: widget.replyingTo!['text'],
            onCancel: widget.onCancelReply ?? () {},
          ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: messagesRef.snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  (snapshot.data?.docs.isEmpty ?? true)) {
                return const Center(child: CircularProgressIndicator());
              }

              final messages = snapshot.data?.docs ?? [];
              return ListView.builder(
                controller: _scrollController,
                reverse: true,
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index] as QueryDocumentSnapshot;
                  final isMe = message['senderId'] == widget.currentUser['id'];
                  final bubbleKey = GlobalKey();

                  return GestureDetector(
                    onLongPress: () async {
                      await Scrollable.ensureVisible(
                        bubbleKey.currentContext!,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                      widget.onMessageLongPressed(message, isMe, bubbleKey);
                    },
                    child: MessageBubble(
                      message: message,
                      currentUser: widget.currentUser,
                      otherUser: widget.otherUser,
                      bubbleKey: bubbleKey,
                      accentColor: Colors.blueAccent,
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

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
}

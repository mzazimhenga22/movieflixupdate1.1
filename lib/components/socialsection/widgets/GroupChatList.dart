import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'message_bubble.dart';
import 'message_actions.dart'; // Updated import name to match
import 'pinned_message_bar.dart';
import 'mark_read_unread.dart';

class GroupChatList extends StatefulWidget {
  final String groupId;
  final Map<String, dynamic> currentUser;
  final List<Map<String, dynamic>> groupMembers;
  final void Function(QueryDocumentSnapshot<Object?> message)? onReplyToMessage;

  const GroupChatList({
    required this.groupId,
    required this.currentUser,
    required this.groupMembers,
    this.onReplyToMessage,
    super.key,
  });

  @override
  State<GroupChatList> createState() => _GroupChatListState();
}

class _GroupChatListState extends State<GroupChatList> {
  DocumentSnapshot? pinnedMessage;

  @override
  void initState() {
    super.initState();
    _fetchPinnedMessage();
    _markGroupAsRead();
  }

  void _fetchPinnedMessage() async {
    final doc = await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .get();

    if (doc.exists &&
        doc.data() != null &&
        doc.data()!.containsKey('pinnedMessageId')) {
      final pinnedId = doc['pinnedMessageId'];
      if (pinnedId != null) {
        final pinned = await FirebaseFirestore.instance
            .collection('groups')
            .doc(widget.groupId)
            .collection('messages')
            .doc(pinnedId)
            .get();
        if (pinned.exists) {
          setState(() => pinnedMessage = pinned);
        }
      }
    }
  }

  void _markGroupAsRead() async {
    await MessageStatusUtils.markAsRead(
      chatId: widget.groupId,
      userId: widget.currentUser['id'],
      isGroup: true,
    );
  }

  Future<void> _pinMessage(QueryDocumentSnapshot<Object?> msg) async {
    await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .set({
      'pinnedMessageId': msg.id,
    }, SetOptions(merge: true));
    setState(() => pinnedMessage = msg);
  }

  Map<String, dynamic>? _getSenderInfo(String senderId) {
    return widget.groupMembers.firstWhere(
      (member) => member['id'] == senderId,
      orElse: () => {},
    );
  }

  @override
  Widget build(BuildContext context) {
    final messagesRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .collection('messages')
        .orderBy('timestamp', descending: true);

    return Column(
      children: [
        if (pinnedMessage != null)
          PinnedMessageBar(
            pinnedText: pinnedMessage!['text'],
            onDismiss: () => setState(() => pinnedMessage = null),
          ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: messagesRef.snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final messages = snapshot.data!.docs;

              return ListView.builder(
                reverse: true,
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index] as QueryDocumentSnapshot<Object?>;
                  final isMe = message['senderId'] == widget.currentUser['id'];
                  final sender = _getSenderInfo(message['senderId']);

                  return GestureDetector(
                    onLongPress: () => showMessageActions(
                      context: context,
                      message: message,
                      isMe: isMe,
                      onReply: () {
                        if (widget.onReplyToMessage != null) {
                          widget.onReplyToMessage!(message);
                        }
                      },
                      onPin: () => _pinMessage(message),
                      onDelete: () async {
                        await FirebaseFirestore.instance
                            .collection('groups')
                            .doc(widget.groupId)
                            .collection('messages')
                            .doc(message.id)
                            .delete();
                      },
                      onBlock: () async {
                        await FirebaseFirestore.instance
                            .collection('users')
                            .doc(widget.currentUser['id'])
                            .update({
                          'blockedUsers': FieldValue.arrayUnion([message['senderId']])
                        });
                      },
                      onForward: () {
                        Navigator.pushNamed(context, '/forward', arguments: {
                          'message': message,
                          'currentUser': widget.currentUser,
                        });
                      },
                      onEdit: () {
                        if (isMe) {
                          Navigator.pushNamed(context, '/editMessage', arguments: {
                            'message': message,
                            'chatId': widget.groupId,
                          });
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Cannot edit messages sent by others')),
                          );
                        }
                      },
                      onReactEmoji: (emoji) async {
                        await FirebaseFirestore.instance
                            .collection('groups')
                            .doc(widget.groupId)
                            .collection('messages')
                            .doc(message.id)
                            .update({
                          'reactions': FieldValue.arrayUnion([emoji])
                        });
                      },
                    ),
                    child: MessageBubble(
                      message: message,
                      currentUser: widget.currentUser,
                      otherUser: sender ?? {},
                      showSenderName: !isMe,
                      isGroup: true,
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
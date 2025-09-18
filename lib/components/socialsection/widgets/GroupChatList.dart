import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'message_bubble.dart';
import 'reply_preview.dart';
import 'pinned_message_bar.dart';
import 'mark_read_unread.dart';

class GroupChatList extends StatefulWidget {
  final String groupId;
  final Map<String, dynamic> currentUser;
  final List<Map<String, dynamic>> groupMembers;
  final void Function(QueryDocumentSnapshot<Object?> message, bool isMe, GlobalKey bubbleKey) onMessageLongPressed;
  final QueryDocumentSnapshot<Object?>? replyingTo;
  final VoidCallback? onCancelReply;
  final void Function(QueryDocumentSnapshot<Object?> message)? onReplyToMessage;

  const GroupChatList({
    required this.groupId,
    required this.currentUser,
    required this.groupMembers,
    required this.onMessageLongPressed,
    this.replyingTo,
    this.onCancelReply,
    this.onReplyToMessage,
    super.key,
  });

  @override
  State<GroupChatList> createState() => _GroupChatListState();
}

class _GroupChatListState extends State<GroupChatList> {
  DocumentSnapshot? pinnedMessage;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchPinnedMessage();
    _markGroupAsRead();
    _listenForPinnedMessageChanges();
  }

  void _fetchPinnedMessage() async {
    final doc = await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .get();

    await _updatePinnedMessage(doc);
  }

  void _listenForPinnedMessageChanges() {
    FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
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
              .collection('groups')
              .doc(widget.groupId)
              .collection('messages')
              .doc(pinnedId)
              .get();

          if (pinned.exists) {
            if (!mounted) return;
            setState(() => pinnedMessage = pinned);
          } else {
            await _clearPinnedMessage();
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

  Future<void> _clearPinnedMessage() async {
    try {
      await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupId)
          .update({'pinnedMessageId': null});
    } catch (_) {
      // ignore update errors (doc might not exist or field already null)
    }

    if (!mounted) return;

    setState(() => pinnedMessage = null);
  }

  void _markGroupAsRead() async {
    await MessageStatusUtils.markAsRead(
      chatId: widget.groupId,
      userId: widget.currentUser['id'],
      isGroup: true,
    );
  }

  /// Safe sender lookup that returns null when not found.
  Map<String, dynamic>? _getSenderInfo(String senderId) {
    try {
      return widget.groupMembers.firstWhere((member) => (member['id']?.toString() ?? '') == senderId);
    } catch (e) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final messagesRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
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
                  final message = messages[index] as QueryDocumentSnapshot<Object?>;
                  final isMe = (message.data() as Map<String, dynamic>)['senderId'] == widget.currentUser['id'];
                  final bubbleKey = GlobalKey();

                  // Build a fast participants map for MessageBubble to synchronously resolve senders.
                  final Map<String, Map<String, dynamic>> participantsMap = {};
                  for (final m in widget.groupMembers) {
                    final id = (m['id'] ?? '').toString();
                    if (id.isNotEmpty) {
                      participantsMap[id] = Map<String, dynamic>.from(m);
                    }
                  }

                  final sender = _getSenderInfo((message.data() as Map<String, dynamic>)['senderId']?.toString() ?? '');

                  return GestureDetector(
                    onLongPress: () async {
                      // Guard against null context (bubble may not be mounted yet)
                      if (bubbleKey.currentContext != null) {
                        await Scrollable.ensureVisible(
                          bubbleKey.currentContext!,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      }
                      widget.onMessageLongPressed(message, isMe, bubbleKey);
                    },
                    child: MessageBubble(
                      message: message,
                      currentUser: widget.currentUser,
                      otherUser: sender, // may be null
                      participants: participantsMap, // synchronous lookup map
                      showSenderName: !isMe,
                      isGroup: true,
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

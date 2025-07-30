import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class MessageBubble extends StatelessWidget {
  final dynamic message;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;
  final bool isGroup;
  final bool showSenderName;

  const MessageBubble({
    required this.message,
    required this.currentUser,
    required this.otherUser,
    this.isGroup = false,
    this.showSenderName = false,
    super.key,
  });

  bool get isMe => message['senderId'] == currentUser['id'];

  @override
  Widget build(BuildContext context) {
    final data = message.data() as Map<String, dynamic>;
    final deletedFor = (data['deletedFor'] ?? []) as List<dynamic>;
    if (deletedFor.contains(currentUser['id'])) return const SizedBox.shrink();

    return GestureDetector(
      onLongPress: () {
        showDialog(
          context: context,
          barrierColor: Colors.black.withOpacity(0.3),
          builder: (_) => MessageActionsOverlay(
            messageWidget: this,
            onReply: () {
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Reply action triggered')),
              );
            },
            onPin: () async {
              Navigator.of(context).pop();
              final docRef = message.reference;
              final isPinned = data['isPinned'] ?? false;
              await docRef.update({'isPinned': !isPinned});
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(isPinned ? 'Unpinned' : 'Pinned')),
              );
            },
            onReact: () async {
              Navigator.of(context).pop();
              await message.reference.update({'reaction': '❤️'});
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Reacted ❤️')),
              );
            },
            onDelete: () async {
              Navigator.of(context).pop();
              final docRef = message.reference;
              final senderId = message['senderId'];
              final currentId = currentUser['id'];

              final confirm = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Delete Message'),
                  content: const Text('Do you want to delete this message for everyone?'),
                  actions: [
                    TextButton(
                      child: const Text('Cancel'),
                      onPressed: () => Navigator.pop(context, false),
                    ),
                    TextButton(
                      child: const Text('Delete for Me'),
                      onPressed: () => Navigator.pop(context, null),
                    ),
                    if (senderId == currentId)
                      TextButton(
                        child: const Text('Delete for Everyone'),
                        onPressed: () => Navigator.pop(context, true),
                      ),
                  ],
                ),
              );

              if (confirm == true) {
                await docRef.delete();
              } else if (confirm == null) {
                await docRef.update({
                  'deletedFor': FieldValue.arrayUnion([currentId])
                });
              }
            },
          ),
        );
      },
      child: _MessageContent(
        data: data,
        isMe: isMe,
        isGroup: isGroup,
        currentUser: currentUser,
        buildContent: _buildContent,
      ),
    );
  }

  Widget _buildContent() {
    final data = message.data() as Map<String, dynamic>;
    final content = data['text'] ?? '';

    if (data['isCall'] == true) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.call, size: 16),
          const SizedBox(width: 4),
          Text(data['callType'] ?? 'Call'),
        ],
      );
    } else if (data['voiceUrl'] != null) {
      return VoicePlayer(url: data['voiceUrl']);
    } else if (data['mediaUrl'] != null) {
      return Image.network(data['mediaUrl']);
    } else if (data['location'] != null) {
      return Text(
        "📍 Location: ${data['location']['address'] ?? 'shared'}",
        style: const TextStyle(color: Colors.black),
      );
    } else {
      return Text(
        content,
        textAlign: isMe ? TextAlign.right : TextAlign.left,
        style: const TextStyle(color: Colors.black),
      );
    }
  }
}

class _MessageContent extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isMe;
  final bool isGroup;
  final Map<String, dynamic> currentUser;
  final Widget Function() buildContent;

  const _MessageContent({
    required this.data,
    required this.isMe,
    required this.isGroup,
    required this.currentUser,
    required this.buildContent,
  });

  @override
  Widget build(BuildContext context) {
    final bubbleColor = isMe ? Colors.green[100] : Colors.grey[300];
    final crossAlign = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    const maxBubbleWidth = 0.25; // 25% of screen width

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (isGroup && !isMe) ...[
            CircleAvatar(
              radius: 16,
              backgroundImage: NetworkImage(data['senderAvatarUrl'] ?? ''),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * maxBubbleWidth,
              ),
              child: Column(
                      crossAxisAlignment: crossAlign,
                      children: [
                        if (isGroup && !isMe)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              data['senderName'] ?? 'User',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                  if (data['replyToText'] != null)
                    Container(
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey[200]?.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(10),
                        border: Border(
                          left: BorderSide(
                            color: Colors.grey.shade400,
                            width: 3,
                          ),
                        ),
                      ),
                      child: Text(
                        data['replyToText'],
                        style: const TextStyle(
                          fontStyle: FontStyle.italic,
                          color: Colors.black87,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  CustomPaint(
                    painter: BubbleTailPainter(isMe: isMe, color: bubbleColor!),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        color: bubbleColor,
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(16),
                          topRight: const Radius.circular(16),
                          bottomLeft: isMe ? const Radius.circular(16) : Radius.zero,
                          bottomRight: isMe ? Radius.zero : const Radius.circular(16),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.15),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: crossAlign,
                        children: [
                          buildContent(),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                            children: [
                              if (data['reaction'] != null)
                                Text(
                                  data['reaction'],
                                  style: const TextStyle(fontSize: 16),
                                ),
                              const SizedBox(width: 4),
                              Text(
                                data['timestamp'] != null
                                    ? DateFormat.jm().format(data['timestamp'].toDate())
                                    : '',
                                style: const TextStyle(fontSize: 10, color: Colors.grey),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BubbleTailPainter extends CustomPainter {
  final bool isMe;
  final Color color;

  BubbleTailPainter({required this.isMe, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();

    if (isMe) {
      path.moveTo(size.width, size.height);
      path.lineTo(size.width - 10, size.height - 10);
      path.lineTo(size.width - 10, size.height);
    } else {
      path.moveTo(0, size.height);
      path.lineTo(10, size.height - 10);
      path.lineTo(10, size.height);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class VoicePlayer extends StatefulWidget {
  final String url;
  const VoicePlayer({required this.url, super.key});

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  final player = AudioPlayer();
  bool isPlaying = false;

  @override
  void initState() {
    super.initState();
    player.setUrl(widget.url);
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  void _toggle() async {
    if (isPlaying) {
      await player.pause();
    } else {
      await player.play();
    }
    setState(() => isPlaying = !isPlaying);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
            onPressed: _toggle,
          ),
          const Text("Voice message"),
        ],
      ),
    );
  }
}

class MessageActionsOverlay extends StatelessWidget {
  final Widget messageWidget;
  final VoidCallback onReply;
  final VoidCallback onPin;
  final VoidCallback onReact;
  final VoidCallback onDelete;

  const MessageActionsOverlay({
    super.key,
    required this.messageWidget,
    required this.onReply,
    required this.onPin,
    required this.onReact,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black.withOpacity(0.4),
      body: Stack(
        children: [
          Center(child: messageWidget),
          Positioned(
            top: MediaQuery.of(context).size.height * 0.3,
            left: MediaQuery.of(context).size.width * 0.2,
            right: MediaQuery.of(context).size.width * 0.2,
            child: Material(
              borderRadius: BorderRadius.circular(12),
              color: Colors.white,
              elevation: 4,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  IconButton(icon: const Icon(Icons.reply), onPressed: onReply),
                  IconButton(icon: const Icon(Icons.push_pin), onPressed: onPin),
                  IconButton(icon: const Icon(Icons.favorite_border), onPressed: onReact),
                  IconButton(icon: const Icon(Icons.delete), onPressed: onDelete),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
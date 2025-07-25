import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class MessageBubble extends StatelessWidget {
  final dynamic message;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;

  const MessageBubble({
    required this.message,
    required this.currentUser,
    required this.otherUser,
    super.key,
  });

  bool get isMe => message['senderId'] == currentUser['id'];

  @override
  Widget build(BuildContext context) {
    final alignment = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final color = isMe ? Colors.green[100] : Colors.grey[300];
    final textAlign = isMe ? TextAlign.right : TextAlign.left;
    final data = message.data() as Map<String, dynamic>;
    final content = data['text'] ?? '';

    Widget buildContent() {
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
          textAlign: textAlign,
          style: const TextStyle(color: Colors.black), // Ensure visibility
        );
      }
    }

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
              final isPinned = message['isPinned'] ?? false;
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
      child: Builder(
        builder: (context) {
          final deletedFor = (message.data()['deletedFor'] ?? []) as List<dynamic>;
          if (deletedFor.contains(currentUser['id'])) return const SizedBox.shrink();

          return Row(
            mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: alignment,
                children: [
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(12),
                        topRight: const Radius.circular(12),
                        bottomLeft: isMe ? const Radius.circular(12) : const Radius.circular(0),
                        bottomRight: isMe ? const Radius.circular(0) : const Radius.circular(12),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: alignment,
                      children: [
                        if (data['replyToText'] != null)
                          Container(
                            padding: const EdgeInsets.all(6),
                            margin: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              color: Colors.black12,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              data['replyToText'],
                              style: const TextStyle(fontStyle: FontStyle.italic),
                            ),
                          ),
                        buildContent(),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: isMe
                              ? MainAxisAlignment.end
                              : MainAxisAlignment.start,
                          children: [
                            if (data['reaction'] != null)
                              Text(data['reaction'], style: const TextStyle(fontSize: 16)),
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
                ],
              ),
            ],
          );
        },
      ),
    );
  }
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
          onPressed: _toggle,
        ),
        const Text("Voice message"),
      ],
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
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  IconButton(
                    icon: const Icon(Icons.reply),
                    onPressed: onReply,
                  ),
                  IconButton(
                    icon: const Icon(Icons.push_pin),
                    onPressed: onPin,
                  ),
                  IconButton(
                    icon: const Icon(Icons.favorite_border),
                    onPressed: onReact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: onDelete,
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

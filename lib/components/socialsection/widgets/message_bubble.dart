import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:ui';

class MessageBubble extends StatelessWidget {
  final QueryDocumentSnapshot message;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;
  final bool isGroup;
  final bool showSenderName;
  final GlobalKey? bubbleKey;
  final Color accentColor;

  const MessageBubble({
    required this.message,
    required this.currentUser,
    required this.otherUser,
    this.isGroup = false,
    this.showSenderName = false,
    this.bubbleKey,
    this.accentColor = Colors.blueAccent,
    super.key,
  });

  bool get isMe => message['senderId'] == currentUser['id'];

  @override
  Widget build(BuildContext context) {
    final data = message.data() as Map<String, dynamic>;
    final deletedFor = (data['deletedFor'] ?? []) as List<dynamic>;
    if (deletedFor.contains(currentUser['id'])) {
      return const SizedBox.shrink();
    }

    return _MessageContent(
      key: bubbleKey,
      data: data,
      isMe: isMe,
      isGroup: isGroup,
      currentUser: currentUser,
      otherUser: otherUser,
      buildContent: _buildContent,
      accentColor: accentColor,
    );
  }

  Widget _buildContent() {
    final data = message.data() as Map<String, dynamic>;
    final content = data['text'] ?? '';

    if (data['isCall'] == true) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.call, size: 16, color: accentColor),
          const SizedBox(width: 4),
          Text(
            data['callType'] ?? 'Call',
            style: TextStyle(color: accentColor),
          ),
        ],
      );
    } else if (data['voiceUrl'] != null) {
      return VoicePlayer(url: data['voiceUrl'], accentColor: accentColor);
    } else if (data['mediaUrl'] != null) {
      return Image.network(data['mediaUrl']);
    } else if (data['location'] != null) {
      return Text(
        "📍 Location: ${data['location']['address'] ?? 'shared'}",
        style: const TextStyle(color: Colors.white),
      );
    } else {
      return Text(
        content,
        textAlign: isMe ? TextAlign.right : TextAlign.left,
        style: const TextStyle(color: Colors.white),
      );
    }
  }
}

class _MessageContent extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isMe;
  final bool isGroup;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;
  final Widget Function() buildContent;
  final Color accentColor;

  const _MessageContent({
    super.key,
    required this.data,
    required this.isMe,
    required this.isGroup,
    required this.currentUser,
    required this.otherUser,
    required this.buildContent,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final crossAlign = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    const maxBubbleWidth = 0.75;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isMe) ...[
            CircleAvatar(
              radius: 16,
              backgroundImage: NetworkImage(otherUser['avatarUrl'] ?? ''),
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
                        otherUser['name'] ?? 'User',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: accentColor,
                        ),
                      ),
                    ),
                  if (data['replyToText'] != null)
                    Container(
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  color: accentColor,
                                  width: 3,
                                ),
                              ),
                            ),
                            child: Text(
                              data['replyToText'],
                              style: const TextStyle(
                                fontStyle: FontStyle.italic,
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  CustomPaint(
                    painter: BubbleTailPainter(isMe: isMe, accentColor: accentColor),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: isMe
                              ? [accentColor.withOpacity(0.6), accentColor.withOpacity(0.3)]
                              : [accentColor.withOpacity(0.4), accentColor.withOpacity(0.2)],
                        ),
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(16),
                          topRight: const Radius.circular(16),
                          bottomLeft: isMe ? const Radius.circular(16) : Radius.zero,
                          bottomRight: isMe ? Radius.zero : const Radius.circular(16),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(16),
                          topRight: const Radius.circular(16),
                          bottomLeft: isMe ? const Radius.circular(16) : Radius.zero,
                          bottomRight: isMe ? Radius.zero : const Radius.circular(16),
                        ),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              border: Border.all(color: accentColor.withOpacity(0.3)),
                              borderRadius: BorderRadius.only(
                                topLeft: const Radius.circular(16),
                                topRight: const Radius.circular(16),
                                bottomLeft: isMe ? const Radius.circular(16) : Radius.zero,
                                bottomRight: isMe ? Radius.zero : const Radius.circular(16),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: crossAlign,
                              children: [
                                buildContent(),
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisAlignment:
                                      isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                                  children: [
                                    if (data['reaction'] != null)
                                      Text(
                                        data['reaction'],
                                        style: const TextStyle(fontSize: 16, color: Colors.white),
                                      ),
                                    const SizedBox(width: 4),
                                    Text(
                                      data['timestamp'] != null
                                          ? DateFormat.jm().format(data['timestamp'].toDate())
                                          : '',
                                      style: const TextStyle(fontSize: 10, color: Colors.white70),
                                    ),
                                  ],
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
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundImage: NetworkImage(currentUser['avatarUrl'] ?? ''),
            ),
          ],
        ],
      ),
    );
  }
}

class BubbleTailPainter extends CustomPainter {
  final bool isMe;
  final Color accentColor;

  BubbleTailPainter({required this.isMe, required this.accentColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = LinearGradient(
        colors: isMe
            ? [accentColor.withOpacity(0.6), accentColor.withOpacity(0.3)]
            : [accentColor.withOpacity(0.4), accentColor.withOpacity(0.2)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

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
  final Color accentColor;

  const VoicePlayer({required this.url, required this.accentColor, super.key});

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
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            widget.accentColor.withOpacity(0.4),
            widget.accentColor.withOpacity(0.2),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: widget.accentColor.withOpacity(0.3)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: widget.accentColor,
                  ),
                  onPressed: _toggle,
                ),
                Text(
                  "Voice message",
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
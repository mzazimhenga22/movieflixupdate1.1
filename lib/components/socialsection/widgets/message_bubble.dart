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
    final reactions = (data['reactions'] ?? []) as List<dynamic>;

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
      reactions: reactions,
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
      return Image.network(
        data['mediaUrl'],
        cacheWidth: 800,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => const Icon(Icons.error),
      );
    } else if (data['location'] != null) {
      return const Text(
        "📍 Location: shared",
        style: TextStyle(color: Colors.white),
      );
    } else {
      return Text(
        content,
        style: const TextStyle(color: Colors.white),
        softWrap: true,
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
  final List<dynamic> reactions;

  const _MessageContent({
    super.key,
    required this.data,
    required this.isMe,
    required this.isGroup,
    required this.currentUser,
    required this.otherUser,
    required this.buildContent,
    required this.accentColor,
    required this.reactions,
  });

  @override
  Widget build(BuildContext context) {
    final crossAlign = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isMe) ...[
            CircleAvatar(
              radius: 16,
              backgroundImage: otherUser['avatarUrl'] != null
                  ? NetworkImage(otherUser['avatarUrl'])
                  : null,
              child: otherUser['avatarUrl'] == null
                  ? Text(
                      otherUser['name']?.isNotEmpty == true
                          ? otherUser['name'][0].toUpperCase()
                          : 'U',
                      style: const TextStyle(color: Colors.white),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: crossAlign,
              children: [
                if (isGroup && !isMe)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      otherUser['name'] ?? 'User',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: accentColor,
                      ),
                    ),
                  ),
                if (data['forwardedFrom'] != null)
                  FutureBuilder<DocumentSnapshot>(
                    future: FirebaseFirestore.instance
                        .collection('users')
                        .doc(data['forwardedFrom'])
                        .get(),
                    builder: (context, snapshot) {
                      String forwarderName = 'Unknown';
                      if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
                        final userData = snapshot.data!.data() as Map<String, dynamic>?;
                        forwarderName = userData?['username'] ?? 'Unknown';
                      }
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          'Forwarded from $forwarderName',
                          style: const TextStyle(
                            fontStyle: FontStyle.italic,
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      );
                    },
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FutureBuilder<DocumentSnapshot>(
                                future: FirebaseFirestore.instance
                                    .collection('users')
                                    .doc(data['replyToSenderId'])
                                    .get(),
                                builder: (context, snapshot) {
                                  String senderName = 'Unknown';
                                  if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
                                    final userData = snapshot.data!.data() as Map<String, dynamic>?;
                                    senderName = userData?['username'] ?? 'Unknown';
                                  } else if (data['replyToSenderId'] == currentUser['id']) {
                                    senderName = currentUser['username'] ?? 'You';
                                  } else if (data['replyToSenderId'] == otherUser['id']) {
                                    senderName = otherUser['username'] ?? 'Unknown';
                                  }
                                  return Text(
                                    senderName,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: accentColor,
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 4),
                              Text(
                                data['replyToText'],
                                style: const TextStyle(
                                  fontStyle: FontStyle.italic,
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                                softWrap: true,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                CustomPaint(
                  painter: BubbleTailPainter(
                    isMe: isMe,
                    accentColor: accentColor,
                    avatarRadius: 16,
                  ),
                  child: IntrinsicWidth(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.7,
                      ),
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
                                Wrap(
                                  spacing: 4,
                                  runSpacing: 4,
                                  alignment: isMe ? WrapAlignment.end : WrapAlignment.start,
                                  children: [
                                    if (reactions.isNotEmpty)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.3),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: reactions
                                              .map((reaction) => Padding(
                                                    padding: const EdgeInsets.symmetric(horizontal: 2),
                                                    child: Text(
                                                      reaction,
                                                      style: const TextStyle(fontSize: 16, color: Colors.white),
                                                    ),
                                                  ))
                                              .toList(),
                                        ),
                                      ),
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
                ),
              ],
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundImage: currentUser['avatarUrl'] != null
                  ? NetworkImage(currentUser['avatarUrl'])
                  : null,
              child: currentUser['avatarUrl'] == null
                  ? Text(
                      currentUser['name']?.isNotEmpty == true
                          ? currentUser['name'][0].toUpperCase()
                          : 'U',
                      style: const TextStyle(color: Colors.white),
                    )
                  : null,
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
  final double avatarRadius;

  BubbleTailPainter({
    required this.isMe,
    required this.accentColor,
    required this.avatarRadius,
  });

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
      path.moveTo(size.width, size.height - 4);
      path.quadraticBezierTo(
        size.width + 8,
        size.height - 8,
        size.width + avatarRadius * 1.5,
        size.height - avatarRadius * 0.5,
      );
      path.lineTo(size.width + avatarRadius * 0.5, size.height - avatarRadius * 0.5);
      path.quadraticBezierTo(
        size.width + 4,
        size.height - 4,
        size.width,
        size.height - 4,
      );
    } else {
      path.moveTo(0, size.height - 4);
      path.quadraticBezierTo(
        -8,
        size.height - 8,
        -avatarRadius * 1.5,
        size.height - avatarRadius * 0.5,
      );
      path.lineTo(-avatarRadius * 0.5, size.height - avatarRadius * 0.5);
      path.quadraticBezierTo(
        -4,
        size.height - 4,
        0,
        size.height - 4,
      );
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
  Duration duration = Duration.zero;
  Duration position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _initAudioPlayer();
  }

  Future<void> _initAudioPlayer() async {
    try {
      await player.setUrl(widget.url);
      player.durationStream.listen((d) {
        if (mounted) setState(() => duration = d ?? Duration.zero);
      });
      player.positionStream.listen((p) {
        if (mounted) setState(() => position = p);
      });
    } catch (e) {
      debugPrint('Error loading audio: $e');
    }
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  void _toggle() async {
    try {
      if (isPlaying) {
        await player.pause();
      } else {
        await player.play();
      }
      if (mounted) setState(() => isPlaying = !isPlaying);
    } catch (e) {
      debugPrint('Error toggling audio: $e');
    }
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
                  "Voice message (${_formatDuration(position)} / ${_formatDuration(duration)})",
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
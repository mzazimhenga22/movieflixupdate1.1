import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';

// ---------- Small helper to avoid deprecated withOpacity calls ----------
Color _withOpacity(Color color, double opacity) =>
    Color.fromARGB((opacity * 255).round(), color.red, color.green, color.blue);

// ---------- Simple in-memory cache for user data (fallback/preload) ----------
class UserCache {
  static final Map<String, Map<String, dynamic>> _cache = {};

  /// Try to return cached user, otherwise fetch from Firestore and cache.
  static Future<Map<String, dynamic>?> getUser(String userId) async {
    if (_cache.containsKey(userId)) return _cache[userId];
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get()
          .timeout(const Duration(seconds: 6));
      if (userDoc.exists) {
        final userData = Map<String, dynamic>.from(userDoc.data()! as Map);
        userData['id'] = userDoc.id;
        _cache[userId] = userData;
        return userData;
      }
    } catch (e) {
      debugPrint('UserCache error: $e');
    }
    return null;
  }

  static void put(String id, Map<String, dynamic> user) => _cache[id] = user;
  static void clear() => _cache.clear();
}

// ---------- Shared audio player service (singleton) ----------
class SharedAudioService extends ChangeNotifier {
  SharedAudioService._internal() {
    _player.positionStream.listen((p) {
      position = p;
      notifyListeners();
    });
    _player.durationStream.listen((d) {
      duration = d ?? Duration.zero;
      notifyListeners();
    });
    _player.playerStateStream.listen((state) {
      isPlaying = state.playing;
      notifyListeners();
    });
  }

  static final SharedAudioService instance = SharedAudioService._internal();

  final AudioPlayer _player = AudioPlayer();
  String? _currentUrl;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool isPlaying = false;

  Future<void> play(String url) async {
    try {
      if (_currentUrl != url) {
        await _player.stop();
        _currentUrl = url;
        await _player.setUrl(url);
      }
      await _player.play();
    } catch (e) {
      debugPrint('SharedAudioService.play error: $e');
    }
  }

  Future<void> pause() async {
    try {
      await _player.pause();
    } catch (e) {
      debugPrint('SharedAudioService.pause error: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('SharedAudioService.stop error: $e');
    }
  }

  bool playingUrl(String url) => _currentUrl == url && isPlaying;

  void disposeService() {
    _player.dispose();
  }
}

// ---------- MessageBubble (optimized) ----------
/// Note: prefer to preload `participants` at chat screen level and pass as prop.
class MessageBubble extends StatelessWidget {
  final QueryDocumentSnapshot message;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic>? otherUser; // for 1:1 chats (optional)
  final Map<String, Map<String, dynamic>>? participants; // preloaded users map
  final bool isGroup;
  final bool showSenderName;
  final GlobalKey? bubbleKey;
  final Color accentColor;

  const MessageBubble({
    required this.message,
    required this.currentUser,
    this.otherUser,
    this.participants,
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

    // Precompute formatted timestamp once per build
    final timestampText = (data['timestamp'] != null)
        ? DateFormat.jm().format((data['timestamp'] as Timestamp).toDate())
        : '';

    return _MessageContent(
      key: bubbleKey,
      data: data,
      isMe: isMe,
      isGroup: isGroup,
      currentUser: currentUser,
      otherUser: otherUser,
      participants: participants,
      buildContent: _buildContent,
      accentColor: accentColor,
      reactions: reactions,
      senderId: message['senderId'] as String,
      timestampText: timestampText,
    );
  }

  Widget _buildContent(Map<String, dynamic> data) {
    final content = data['text'] ?? '';

    if (data['isCall'] == true) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.call, size: 16, color: accentColor),
          const SizedBox(width: 6),
          Text(data['callType'] ?? 'Call', style: TextStyle(color: accentColor)),
        ],
      );
    } else if (data['voiceUrl'] != null) {
      return VoicePlayer(url: data['voiceUrl'], accentColor: accentColor);
    } else if (data['mediaUrl'] != null) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: CachedNetworkImage(
          imageUrl: data['mediaUrl'],
          placeholder: (c, s) => SizedBox(width: 120, height: 80, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
          errorWidget: (c, s, e) => const Icon(Icons.error),
          fit: BoxFit.cover,
        ),
      );
    } else if (data['location'] != null) {
      return const Text('📍 Location: shared', style: TextStyle(color: Colors.white));
    } else {
      return Text(content, style: const TextStyle(color: Colors.white), softWrap: true);
    }
  }
}

// ---------- Internal message content widget (avoids repeated FutureBuilders) ----------
class _MessageContent extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isMe;
  final bool isGroup;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic>? otherUser;
  final Map<String, Map<String, dynamic>>? participants;
  final Widget Function(Map<String, dynamic>) buildContent;
  final Color accentColor;
  final List<dynamic> reactions;
  final String senderId;
  final String timestampText;

  const _MessageContent({
    super.key,
    required this.data,
    required this.isMe,
    required this.isGroup,
    required this.currentUser,
    required this.otherUser,
    required this.participants,
    required this.buildContent,
    required this.accentColor,
    required this.reactions,
    required this.senderId,
    required this.timestampText,
  });

  @override
  Widget build(BuildContext context) {
    final crossAlign = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    // Try to synchronously get user data from preloaded participants or otherUser.
    Map<String, dynamic>? syncUser;
    if (!isMe) {
      if (isGroup) {
        syncUser = participants != null ? participants![senderId] : null;
      } else {
        syncUser = otherUser;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMe) ...[
            // Avatar (sync when possible, fallback to async fetch if not preloaded)
            _AvatarWidget(syncUser: syncUser, userId: senderId, accentColor: accentColor),
            const SizedBox(width: 8),
          ],

          // Bubble area
          Flexible(
            child: Column(
              crossAxisAlignment: crossAlign,
              children: [
                CustomPaint(
                  painter: BubbleTailPainter(isMe: isMe, accentColor: accentColor, avatarRadius: 16, isTopTail: true),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: isMe
                              ? [_withOpacity(accentColor, 0.65), _withOpacity(accentColor, 0.35)]
                              : [_withOpacity(accentColor, 0.45), _withOpacity(accentColor, 0.22)],
                        ),
                        borderRadius: BorderRadius.only(
                          topLeft: isMe ? const Radius.circular(16) : Radius.zero,
                          topRight: isMe ? Radius.zero : const Radius.circular(16),
                          bottomLeft: const Radius.circular(16),
                          bottomRight: const Radius.circular(16),
                        ),
                      ),
                      child: Container(
                        // Keep a single lightweight visual effect without nesting expensive blurs.
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          border: Border.all(color: _withOpacity(accentColor, 0.28)),
                          borderRadius: BorderRadius.only(
                            topLeft: isMe ? const Radius.circular(16) : Radius.zero,
                            topRight: isMe ? Radius.zero : const Radius.circular(16),
                            bottomLeft: const Radius.circular(16),
                            bottomRight: const Radius.circular(16),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: crossAlign,
                          children: [
                            // Sender name for group
                            if (isGroup && !isMe)
                              _GroupNameWidget(userId: senderId, participants: participants, currentUser: currentUser, accentColor: accentColor),

                            // Forwarded
                            if (data['forwardedFrom'] != null) _ForwardedWidget(forwardedId: data['forwardedFrom'] as String),

                            // Reply preview
                            if (data['replyToText'] != null)
                              _ReplyPreviewWidget(data: data, participants: participants, currentUser: currentUser, accentColor: accentColor),

                            // Actual content
                            buildContent(data),

                            const SizedBox(height: 6),

                            // Reactions + timestamp
                            Row(
                              mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                              children: [
                                if (reactions.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(color: _withOpacity(Colors.black, 0.18), borderRadius: BorderRadius.circular(12)),
                                    child: Row(mainAxisSize: MainAxisSize.min, children: reactions.map((r) => Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: Text(r.toString(), style: const TextStyle(fontSize: 16, color: Colors.white)))).toList()),
                                  ),
                                const SizedBox(width: 8),
                                Text(timestampText, style: const TextStyle(fontSize: 10, color: Colors.white70)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // My avatar on the right
          if (isMe) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundImage: currentUser['avatarUrl'] != null ? CachedNetworkImageProvider(currentUser['avatarUrl']) : null,
              child: currentUser['avatarUrl'] == null ? Text((currentUser['username'] ?? 'U')[0].toUpperCase(), style: const TextStyle(color: Colors.white)) : null,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------- Helper widgets used inside message content ----------
class _AvatarWidget extends StatelessWidget {
  final Map<String, dynamic>? syncUser;
  final String userId;
  final Color accentColor;
  const _AvatarWidget({this.syncUser, required this.userId, required this.accentColor});

  @override
  Widget build(BuildContext context) {
    if (syncUser != null) {
      final avatarUrl = syncUser!['avatarUrl'] as String?;
      final initial = (syncUser!['username'] as String?)?.isNotEmpty == true ? syncUser!['username'][0].toUpperCase() : 'U';
      return CircleAvatar(
        radius: 16,
        backgroundImage: avatarUrl != null ? CachedNetworkImageProvider(avatarUrl) : null,
        child: avatarUrl == null ? Text(initial, style: const TextStyle(color: Colors.white)) : null,
      );
    }

    // Fallback: fetch user asynchronously
    return FutureBuilder<Map<String, dynamic>?>(
      future: UserCache.getUser(userId),
      builder: (context, snapshot) {
        String initial = 'U';
        ImageProvider? avatar;
        if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
          final user = snapshot.data!;
          avatar = (user['avatarUrl'] != null) ? CachedNetworkImageProvider(user['avatarUrl']) : null;
          initial = (user['username'] as String?)?.isNotEmpty == true ? user['username'][0].toUpperCase() : 'U';
        }
        return CircleAvatar(radius: 16, backgroundImage: avatar, child: avatar == null ? Text(initial, style: const TextStyle(color: Colors.white)) : null);
      },
    );
  }
}

class _GroupNameWidget extends StatelessWidget {
  final String userId;
  final Map<String, Map<String, dynamic>>? participants;
  final Map<String, dynamic> currentUser;
  final Color accentColor;
  const _GroupNameWidget({required this.userId, required this.participants, required this.currentUser, required this.accentColor});

  @override
  Widget build(BuildContext context) {
    final sync = participants != null ? participants![userId] : null;
    if (sync != null) {
      final name = sync['username'] ?? 'Unknown';
      return Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: accentColor)));
    }
    return FutureBuilder<Map<String, dynamic>?>(
      future: UserCache.getUser(userId),
      builder: (context, snapshot) {
        String name = 'Loading...';
        if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) name = snapshot.data!['username'] ?? 'Unknown';
        return Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: accentColor)));
      },
    );
  }
}

class _ForwardedWidget extends StatelessWidget {
  final String forwardedId;
  const _ForwardedWidget({required this.forwardedId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: UserCache.getUser(forwardedId),
      builder: (context, snapshot) {
        String forwarderName = 'Unknown';
        if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) forwarderName = snapshot.data!['username'] ?? 'Unknown';
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('Forwarded from $forwarderName', style: const TextStyle(fontStyle: FontStyle.italic, color: Colors.white70, fontSize: 12)),
        );
      },
    );
  }
}

class _ReplyPreviewWidget extends StatelessWidget {
  final Map<String, dynamic> data;
  final Map<String, Map<String, dynamic>>? participants;
  final Map<String, dynamic> currentUser;
  final Color accentColor;
  const _ReplyPreviewWidget({required this.data, this.participants, required this.currentUser, required this.accentColor});

  @override
  Widget build(BuildContext context) {
    final replyToSenderId = data['replyToSenderId'] as String?;
    final replyToText = data['replyToText'] as String?;
    if (replyToText == null) {
      return const SizedBox.shrink();
    }

    final sync = replyToSenderId != null ? (participants != null ? participants![replyToSenderId] : null) : null;

    return Container(
      padding: const EdgeInsets.all(8),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: _withOpacity(Colors.black, 0.2), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (replyToSenderId != null) ...[
          if (sync != null) ...[
            Text(sync['username'] ?? 'Unknown', style: TextStyle(fontWeight: FontWeight.bold, color: accentColor)),
          ] else ...[
            FutureBuilder<Map<String, dynamic>?>(
              future: UserCache.getUser(replyToSenderId),
              builder: (c, s) {
                String senderName = 'Unknown';
                if (s.connectionState == ConnectionState.done && s.hasData) senderName = s.data!['username'] ?? 'Unknown';
                else if (replyToSenderId == currentUser['id']) senderName = currentUser['username'] ?? 'You';
                return Text(senderName, style: TextStyle(fontWeight: FontWeight.bold, color: accentColor));
              },
            ),
          ]
        ],
        const SizedBox(height: 4),
        Text(replyToText, style: const TextStyle(fontStyle: FontStyle.italic, color: Colors.white, fontSize: 13)),
      ]),
    );
  }
}

// ---------- Bubble tail painter (optimized shouldRepaint) ----------
class BubbleTailPainter extends CustomPainter {
  final bool isMe;
  final Color accentColor;
  final double avatarRadius;
  final bool isTopTail;

  BubbleTailPainter({required this.isMe, required this.accentColor, required this.avatarRadius, this.isTopTail = false});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = LinearGradient(
        colors: isMe ? [_withOpacity(accentColor, 0.6), _withOpacity(accentColor, 0.3)] : [_withOpacity(accentColor, 0.4), _withOpacity(accentColor, 0.2)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final path = Path();

    if (isMe) {
      if (isTopTail) {
        path.moveTo(size.width, 4);
        path.quadraticBezierTo(size.width + 8, 8, size.width + avatarRadius * 1.5, avatarRadius * 0.5);
        path.lineTo(size.width + avatarRadius * 0.5, avatarRadius * 0.5);
        path.quadraticBezierTo(size.width + 4, 4, size.width, 4);
      } else {
        path.moveTo(size.width, size.height - 4);
        path.quadraticBezierTo(size.width + 8, size.height - 8, size.width + avatarRadius * 1.5, size.height - avatarRadius * 0.5);
        path.lineTo(size.width + avatarRadius * 0.5, size.height - avatarRadius * 0.5);
        path.quadraticBezierTo(size.width + 4, size.height - 4, size.width, size.height - 4);
      }
    } else {
      if (isTopTail) {
        path.moveTo(0, 4);
        path.quadraticBezierTo(-8, 8, -avatarRadius * 1.5, avatarRadius * 0.5);
        path.lineTo(-avatarRadius * 0.5, avatarRadius * 0.5);
        path.quadraticBezierTo(-4, 4, 0, 4);
      } else {
        path.moveTo(0, size.height - 4);
        path.quadraticBezierTo(-8, size.height - 8, -avatarRadius * 1.5, size.height - avatarRadius * 0.5);
        path.lineTo(-avatarRadius * 0.5, size.height - avatarRadius * 0.5);
        path.quadraticBezierTo(-4, size.height - 4, 0, size.height - 4);
      }
    }

    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant BubbleTailPainter oldDelegate) {
    return oldDelegate.isMe != isMe || oldDelegate.accentColor != accentColor || oldDelegate.avatarRadius != avatarRadius || oldDelegate.isTopTail != isTopTail;
  }
}

// ---------- Voice player that uses the shared audio service (no per-message player) ----------
class VoicePlayer extends StatelessWidget {
  final String url;
  final Color accentColor;

  const VoicePlayer({required this.url, required this.accentColor, super.key});

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final audio = SharedAudioService.instance;

    return AnimatedBuilder(
      animation: audio,
      builder: (context, _) {
        final playing = audio.playingUrl(url);
        final pos = audio.position;
        final dur = audio.duration;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_withOpacity(accentColor, 0.4), _withOpacity(accentColor, 0.2)]),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(playing ? Icons.pause : Icons.play_arrow, color: accentColor),
                onPressed: () => playing ? audio.pause() : audio.play(url),
              ),
              Text('Voice message (${_formatDuration(pos)} / ${_formatDuration(dur)})', style: const TextStyle(color: Colors.white)),
            ],
          ),
        );
      },
    );
  }
}

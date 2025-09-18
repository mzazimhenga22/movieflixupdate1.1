// message_bubble.dart
import 'dart:io' show File;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';

Color _withOpacity(Color color, double opacity) {
  final int r = (color.value >> 16) & 0xFF;
  final int g = (color.value >> 8) & 0xFF;
  final int b = color.value & 0xFF;
  return Color.fromARGB((opacity * 255).round(), r, g, b);
}

// ---------- Small in-memory cache for user data ----------
class UserCache {
  static final Map<String, Map<String, dynamic>> _cache = {};

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

// ---------- Shared audio player ----------
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

// ---------- Utilities ----------
ImageProvider? _imageProviderFromUrl(String? url) {
  if (url == null) return null;
  final s = url.toString();
  if (s.isEmpty) return null;
  try {
    if (kIsWeb || s.startsWith('http')) {
      return CachedNetworkImageProvider(s);
    } else {
      return FileImage(File(s));
    }
  } catch (e) {
    debugPrint('imageProviderFromUrl error for "$url": $e');
    return null;
  }
}

// ---------- MessageBubble ----------
class MessageBubble extends StatelessWidget {
  final QueryDocumentSnapshot message;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic>? otherUser;
  final Map<String, Map<String, dynamic>>? participants;
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

  bool get isMe => (message.data() as Map<String, dynamic>)['senderId'] == currentUser['id'];

  @override
  Widget build(BuildContext context) {
    final data = message.data() as Map<String, dynamic>;
    final deletedFor = (data['deletedFor'] ?? []) as List<dynamic>;
    final reactions = (data['reactions'] ?? []) as List<dynamic>;

    if (deletedFor.contains(currentUser['id'])) {
      return const SizedBox.shrink();
    }

    final timestampText = (data['timestamp'] != null && data['timestamp'] is Timestamp)
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
      senderId: (data['senderId'] ?? '') as String,
      timestampText: timestampText,
    );
  }

  /// now accepts BuildContext so the widget can navigate when necessary
  Widget _buildContent(BuildContext context, Map<String, dynamic> data) {
    final content = (data['text'] ?? '') as String;

    // watch party invite
    if ((data['type'] ?? '') == 'watch_party' || data['partyId'] != null) {
      final partyId = (data['partyId'] ?? data['party']?['id'])?.toString() ?? '';
      final hostName = data['senderName'] ?? 'Host';
      final requiredMinutes = (data['requiredMinutes'] is int) ? data['requiredMinutes'] as int : ((data['requiredMinutes'] is String) ? int.tryParse(data['requiredMinutes']) ?? 0 : 0);

      // NOTE: watch party bubble sizes to its content (no fixed width/height here).
      return GestureDetector(
        onTap: () {
          if (partyId.isNotEmpty) {
            try {
              Navigator.of(context).pushNamed('/watch_party', arguments: {'partyId': partyId});
            } catch (e) {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('Watch Party')),
                body: Center(child: Text('Open watch party: $partyId (please wire route)')),
              )));
            }
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No watch party id available')));
          }
        },
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [_withOpacity(accentColor, 0.75), _withOpacity(accentColor, 0.35)], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8, offset: const Offset(0, 4))],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.live_tv, size: 36, color: Colors.white),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$hostName started a Watch Party',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      content.isNotEmpty ? content : 'Tap to join the watch party',
                      style: const TextStyle(color: Colors.white70),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (requiredMinutes > 0) ...[
                      const SizedBox(height: 6),
                      Text('Required: $requiredMinutes minute(s) to join', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white24,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onPressed: () {
                  if (partyId.isNotEmpty) {
                    try {
                      Navigator.of(context).pushNamed('/watch_party', arguments: {'partyId': partyId});
                    } catch (_) {
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('Watch Party')),
                        body: Center(child: Text('Open watch party: $partyId (please wire route)')),
                      )));
                    }
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No watch party id available')));
                  }
                },
                child: const Text('Join', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      );
    }

    // existing branches: call, voice, media, location, text
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
      return VoicePlayer(url: data['voiceUrl'] as String, accentColor: accentColor);
    } else if (data['mediaUrl'] != null) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: CachedNetworkImage(
          imageUrl: data['mediaUrl'] as String,
          placeholder: (c, s) => const SizedBox(width: 120, height: 80, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
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

// ---------- Internal message content widget ----------
class _MessageContent extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isMe;
  final bool isGroup;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic>? otherUser;
  final Map<String, Map<String, dynamic>>? participants;
  final Widget Function(BuildContext, Map<String, dynamic>) buildContent;
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

    // Prefer synchronous participants lookup. If missing, fall back to otherUser.
    Map<String, dynamic>? syncUser;
    if (!isMe) {
      if (isGroup) {
        if (participants != null && participants!.containsKey(senderId)) {
          syncUser = participants![senderId];
        } else if ((otherUser?.isNotEmpty ?? false)) {
          // null-safe check to avoid analyzer promotion issues on public fields
          syncUser = otherUser;
        } else {
          syncUser = null;
        }
      } else {
        syncUser = otherUser;
      }
    }

    // default message bubble max width (32% of screen)
    final maxBubbleWidth = MediaQuery.of(context).size.width * 0.32;

    // detect whether the message is a watch party so we can allow it to size to its content
    final isWatchParty = (data['type'] ?? '') == 'watch_party' || data['partyId'] != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMe) ...[
            _AvatarWidget(syncUser: syncUser, userId: senderId, accentColor: accentColor),
            const SizedBox(width: 8),
          ],

          Flexible(
            child: Column(
              crossAxisAlignment: crossAlign,
              children: [
                if (isWatchParty)
                  buildContent(context, data)
                else
                  CustomPaint(
                    painter: BubbleTailPainter(isMe: isMe, accentColor: accentColor, avatarRadius: 16, isTopTail: true),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxBubbleWidth),
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
                              if (isGroup && !isMe)
                                _GroupNameWidget(userId: senderId, participants: participants, currentUser: currentUser, accentColor: accentColor),

                              if (data['forwardedFrom'] != null) _ForwardedWidget(forwardedId: data['forwardedFrom'] as String),

                              if (data['replyToText'] != null)
                                _ReplyPreviewWidget(data: data, participants: participants, currentUser: currentUser, accentColor: accentColor),

                              // Pass context so special content (watch_party) can navigate
                              buildContent(context, data),

                              const SizedBox(height: 6),

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

          if (isMe) ...[
            const SizedBox(width: 8),
            Builder(builder: (ctx) {
              final name = (currentUser['username'] ?? currentUser['displayName'] ?? '')?.toString() ?? '';
              final initial = name.isNotEmpty ? name[0].toUpperCase() : 'U';
              final avatarProv = _imageProviderFromUrl((currentUser['avatarUrl'] ?? currentUser['photoUrl'] ?? '').toString());
              return CircleAvatar(
                radius: 16,
                backgroundImage: avatarProv,
                child: avatarProv == null ? Text(initial, style: const TextStyle(color: Colors.white)) : null,
              );
            }),
          ],
        ],
      ),
    );
  }
}

// ---------- Helper widgets ----------

class _AvatarWidget extends StatefulWidget {
  final Map<String, dynamic>? syncUser;
  final String userId;
  final Color accentColor;
  const _AvatarWidget({this.syncUser, required this.userId, required this.accentColor});

  @override
  State<_AvatarWidget> createState() => _AvatarWidgetState();
}

class _AvatarWidgetState extends State<_AvatarWidget> {
  ImageProvider? _cachedProvider;
  String? _cachedAvatarUrl;
  String _cachedInitial = 'U';

  @override
  void initState() {
    super.initState();
    _initFromWidget();
  }

  @override
  void didUpdateWidget(covariant _AvatarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldAvatar = _extractAvatarUrl(oldWidget.syncUser);
    final newAvatar = _extractAvatarUrl(widget.syncUser);
    final idsChanged = oldWidget.userId != widget.userId;

    if (idsChanged || (newAvatar != oldAvatar && newAvatar != _cachedAvatarUrl)) {
      _initFromWidget();
    }
  }

  String? _extractAvatarUrl(Map<String, dynamic>? u) {
    if (u == null) return null;
    return (u['avatarUrl'] ?? u['photoUrl'] ?? u['avatar'])?.toString();
  }

  String _initialFrom(Map<String, dynamic>? u) {
    final n = (u?['username'] ?? u?['displayName'] ?? '')?.toString() ?? '';
    if (n.isNotEmpty) return n[0].toUpperCase();
    return 'U';
  }

  void _initFromWidget() {
    final sync = widget.syncUser;
    final avatarUrl = _extractAvatarUrl(sync);
    final initial = _initialFrom(sync);
    _cachedInitial = initial;

    // If we already have the exact provider for this URL, keep it.
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      final prov = _imageProviderFromUrl(avatarUrl);
      setState(() {
        _cachedProvider = prov;
        _cachedAvatarUrl = avatarUrl;
        _cachedInitial = initial;
      });
      return;
    }

    // Try fast cache via UserCache.getUser (which checks internal cache first).
    UserCache.getUser(widget.userId).then((user) {
      if (!mounted) return;
      final uAvatar = _extractAvatarUrl(user);
      final uname = (user?['username'] ?? user?['displayName'])?.toString() ?? '';
      if (uAvatar != null && uAvatar.isNotEmpty) {
        final prov = _imageProviderFromUrl(uAvatar);
        setState(() {
          _cachedProvider = prov;
          _cachedAvatarUrl = uAvatar;
          if (uname.isNotEmpty) _cachedInitial = uname[0].toUpperCase();
        });
      } else {
        // No avatar in cache — keep initial from syncUser or set from fetched name
        if (uname.isNotEmpty) {
          setState(() {
            _cachedInitial = uname[0].toUpperCase();
          });
        }
      }
    }).catchError((e) {
      // ignore fetch errors, leave initial/provider as-is
      debugPrint('AvatarWidget UserCache.getUser error: $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_cachedProvider != null) {
      return CircleAvatar(radius: 16, backgroundImage: _cachedProvider, child: null);
    }
    return CircleAvatar(
      radius: 16,
      backgroundColor: widget.accentColor.withOpacity(0.12),
      child: Text(_cachedInitial, style: const TextStyle(color: Colors.white)),
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
    // If participants map is available prefer it for synchronous display
    final sync = participants != null ? participants![userId] : null;
    if (sync != null) {
      final name = sync['username'] ?? 'Unknown';
      return Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: accentColor)));
    }

    // If the name belongs to the current user, show their display name immediately
    if ((currentUser['id']?.toString() ?? '') == userId) {
      final name = (currentUser['username'] ?? currentUser['displayName'] ?? 'You')?.toString() ?? 'You';
      return Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: accentColor)));
    }

    // Otherwise, fall back to cache / network lookup. Use a safe default while loading.
    return FutureBuilder<Map<String, dynamic>?>(
      future: UserCache.getUser(userId),
      builder: (context, snapshot) {
        String name = 'Unknown';
        if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
          name = snapshot.data!['username'] ?? 'Unknown';
        }
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
        if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
          forwarderName = snapshot.data!['username'] ?? 'Unknown';
        }
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
                if (s.connectionState == ConnectionState.done && s.hasData) {
                  senderName = s.data!['username'] ?? 'Unknown';
                } else if (replyToSenderId == currentUser['id']) {
                  senderName = currentUser['username'] ?? 'You';
                }
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

// ---------- Bubble tail painter ----------
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

// ---------- Voice player ----------
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

import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:movie_app/utils/read_status_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'VideoCallScreen_1to1.dart';
import 'VoiceCallScreen_1to1.dart';
import 'widgets/chat_app_bar.dart';
import 'widgets/typing_area.dart';
import 'widgets/advanced_chat_list.dart';
import 'widgets/message_actions.dart';
import 'forward_message_screen.dart';
import 'presence_wrapper.dart';

class ChatScreen extends StatefulWidget {
  final String chatId;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;
  final Map<String, dynamic> authenticatedUser;
  final List<dynamic> storyInteractions;
  final Color accentColor;
  final Map<String, dynamic>? forwardedMessage;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.currentUser,
    required this.otherUser,
    required this.authenticatedUser,
    required this.storyInteractions,
    this.forwardedMessage,
    this.accentColor = Colors.blueAccent,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with AutomaticKeepAliveClientMixin {
  String? backgroundUrl;
  QueryDocumentSnapshot<Object?>? replyingTo;
  bool isActionOverlayVisible = false;
  late SharedPreferences prefs;

  // Notifiers used to avoid unnecessary rebuilds of the whole screen:
  final ValueNotifier<String?> _backgroundUrlNotifier =
      ValueNotifier<String?>(null);
  final ValueNotifier<QueryDocumentSnapshot<Object?>?> _replyingToNotifier =
      ValueNotifier<QueryDocumentSnapshot<Object?>?>(null);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();

    SharedPreferences.getInstance().then((p) {
      prefs = p;
      _loadChatBackground();
      markChatAsRead(widget.chatId, widget.currentUser['id']);
      _listenForIncomingCalls();
    });
  }

  @override
  void dispose() {
    _backgroundUrlNotifier.dispose();
    _replyingToNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadChatBackground() async {
    // load from prefs and notify listeners only if changed
    final stored = prefs.getString('chat_background_${widget.chatId}');
    if (_backgroundUrlNotifier.value != stored) {
      _backgroundUrlNotifier.value = stored;
    }
  }

  Future<void> _setChatBackground(String url) async {
    await prefs.setString('chat_background_${widget.chatId}', url);
    _backgroundUrlNotifier.value = url;
  }

  Future<bool> _isUserBlocked(String userId) async {
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.currentUser['id'])
        .get();
    final blockedUsers = List<String>.from(userDoc.data()?['blockedUsers'] ?? []);
    return blockedUsers.contains(userId);
  }

  void sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    final isBlocked = await _isUserBlocked(widget.otherUser['id']);
    if (isBlocked && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot send message to blocked user')),
      );
      return;
    }

    final messageData = {
      'text': text,
      'senderId': widget.currentUser['id'],
      'senderName': widget.currentUser['username'] ?? 'You',
      'receiverId': widget.otherUser['id'],
      'timestamp': FieldValue.serverTimestamp(),
      'type': 'text',
      'reactions': [],
      'deletedFor': [],
      if (_replyingToNotifier.value != null) ...{
        'replyToId': _replyingToNotifier.value!.id,
        'replyToText': _replyingToNotifier.value!['text'],
        'replyToSenderId': _replyingToNotifier.value!['senderId'],
        'replyToSenderName': _replyingToNotifier.value!['senderId'] ==
                widget.currentUser['id']
            ? widget.currentUser['username'] ?? 'You'
            : widget.otherUser['username'] ?? 'Unknown',
      },
    };

    await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .add(messageData);

    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).set({
      'lastMessage': text,
      'timestamp': FieldValue.serverTimestamp(),
      'userIds': [widget.currentUser['id'], widget.otherUser['id']],
    }, SetOptions(merge: true));

    // clear reply state only
    _replyingToNotifier.value = null;
  }

  void sendFile(File file) async {
    if (await _isUserBlocked(widget.otherUser['id'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot send file to blocked user')),
        );
      }
      return;
    }
    debugPrint("Sending file: ${file.path}");
  }

  void sendAudio(File audio) async {
    if (await _isUserBlocked(widget.otherUser['id'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot send audio to blocked user')),
        );
      }
      return;
    }
    debugPrint("Sending audio: ${audio.path}");
  }

  void startVoiceCall() async {
    if (await _isUserBlocked(widget.otherUser['id'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot call blocked user')),
        );
      }
      return;
    }

    try {
      final callId = await RtcManager.startVoiceCall(
        caller: widget.currentUser,
        receiver: widget.otherUser,
      );

      await FirebaseFirestore.instance.collection('calls').doc(callId).set({
        'type': 'voice',
        'callerId': widget.currentUser['id'],
        'receiverId': widget.otherUser['id'],
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'ongoing',
      });

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VoiceCallScreen1to1(
              callId: callId,
              callerId: widget.currentUser['id'],
              receiverId: widget.otherUser['id'],
              currentUserId: widget.currentUser['id'],
              caller: widget.currentUser,
              receiver: widget.otherUser,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to start voice call')),
        );
      }
    }
  }

  void startVideoCall() async {
    if (await _isUserBlocked(widget.otherUser['id'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot call blocked user')),
        );
      }
      return;
    }

    try {
      final callId = await RtcManager.startVideoCall(
        caller: widget.currentUser,
        receiver: widget.otherUser,
      );

      await FirebaseFirestore.instance.collection('calls').doc(callId).set({
        'type': 'video',
        'callerId': widget.currentUser['id'],
        'receiverId': widget.otherUser['id'],
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'ongoing',
      });

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VideoCallScreen1to1(
              callId: callId,
              callerId: widget.currentUser['id'],
              receiverId: widget.otherUser['id'],
              currentUserId: widget.currentUser['id'],
              caller: widget.currentUser,
              receiver: widget.otherUser,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to start video call')),
        );
      }
    }
  }

  void _onReplyToMessage(QueryDocumentSnapshot<Object?> message) {
    _replyingToNotifier.value = message;
  }

  void _onCancelReply() {
    _replyingToNotifier.value = null;
  }

  void _showMessageActions(
      QueryDocumentSnapshot<Object?> message, bool isMe, GlobalKey messageKey) {
    if (isActionOverlayVisible) return;

    isActionOverlayVisible = true;

    showMessageActions(
      context: context,
      message: message,
      isMe: isMe,
      messageKey: messageKey,
      onReply: () {
        _replyingToNotifier.value = message;
        isActionOverlayVisible = false;
      },
      onPin: () async {
        await FirebaseFirestore.instance
            .collection('chats')
            .doc(widget.chatId)
            .set({
          'pinnedMessageId': message.id,
          'pinnedMessageText': message['text'],
          'pinnedMessageSenderId': message['senderId'],
        }, SetOptions(merge: true));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: widget.accentColor,
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: Text(
                  message['text'],
                  style: const TextStyle(color: Colors.black),
                ),
              ),
            ),
          );
          isActionOverlayVisible = false;
        }
      },
      onDelete: () async {
        final data = message.data() as Map<String, dynamic>;
        final deletedFor = List<String>.from(data['deletedFor'] ?? []);
        deletedFor.add(widget.currentUser['id']);

        await FirebaseFirestore.instance
            .collection('chats')
            .doc(widget.chatId)
            .collection('messages')
            .doc(message.id)
            .update({'deletedFor': deletedFor});

        final chatDoc = await FirebaseFirestore.instance
            .collection('chats')
            .doc(widget.chatId)
            .get();

        if (chatDoc.exists && chatDoc['pinnedMessageId'] == message.id) {
          await FirebaseFirestore.instance
              .collection('chats')
              .doc(widget.chatId)
              .update({'pinnedMessageId': null});
        }

        if (mounted) {
          Navigator.of(context, rootNavigator: false).pop();
          isActionOverlayVisible = false;
        }
      },
      onBlock: () async {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.currentUser['id'])
            .update({
          'blockedUsers': FieldValue.arrayUnion([widget.otherUser['id']])
        });
        if (mounted) {
          Navigator.of(context, rootNavigator: false).pop();
          isActionOverlayVisible = false;
        }
      },
      onForward: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ForwardMessageScreen(),
            settings: RouteSettings(
              arguments: {
                'message': message,
                'currentUser': widget.currentUser,
                'isForwarded': true,
              },
            ),
          ),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Message forwarded')),
          );
          Navigator.of(context, rootNavigator: false).pop();
          isActionOverlayVisible = false;
        }
      },
      onEdit: () async {
        if (isMe) {
          await Navigator.pushNamed(context, '/editMessage', arguments: {
            'message': message,
            'chatId': widget.chatId,
          });
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot edit others\' messages')),
          );
        }
        if (mounted) {
          Navigator.of(context, rootNavigator: false).pop();
          isActionOverlayVisible = false;
        }
      },
      onReactEmoji: (emoji) async {
        final data = message.data() as Map<String, dynamic>;
        final currentReactions = List<String>.from(data['reactions'] ?? []);

        if (currentReactions.contains(emoji)) {
          await FirebaseFirestore.instance
              .collection('chats')
              .doc(widget.chatId)
              .collection('messages')
              .doc(message.id)
              .update({
            'reactions': FieldValue.arrayRemove([emoji])
          });
        } else {
          await FirebaseFirestore.instance
              .collection('chats')
              .doc(widget.chatId)
              .collection('messages')
              .doc(message.id)
              .update({
            'reactions': FieldValue.arrayUnion([emoji])
          });
        }
        if (mounted) {
          Navigator.of(context, rootNavigator: false).pop();
          isActionOverlayVisible = false;
        }
      },
    );
  }

  void _listenForIncomingCalls() {
    FirebaseFirestore.instance
        .collection('calls')
        .where('receiverId', isEqualTo: widget.currentUser['id'])
        .where('status', isEqualTo: 'ringing')
        .snapshots()
        .listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added ||
            change.type == DocumentChangeType.modified) {
          final data = change.doc.data()! as Map<String, dynamic>;

          if (data['callerId'] == widget.otherUser['id'] && mounted) {
            final callId = change.doc.id;

            final route = data['type'] == 'video'
                ? VideoCallScreen1to1(
                    callId: callId,
                    callerId: data['callerId'],
                    receiverId: data['receiverId'],
                    currentUserId: widget.currentUser['id'],
                    caller: widget.otherUser,
                    receiver: widget.currentUser,
                  )
                : VoiceCallScreen1to1(
                    callId: callId,
                    callerId: data['callerId'],
                    receiverId: data['receiverId'],
                    currentUserId: widget.currentUser['id'],
                    caller: widget.otherUser,
                    receiver: widget.currentUser,
                  );

            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => route),
            );
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return PresenceWrapper(
      userId: widget.currentUser['id'],
      groupIds: [widget.chatId],
      child: Scaffold(
        extendBodyBehindAppBar: false,
        backgroundColor: Colors.transparent,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: ChatAppBar(
            currentUser: widget.currentUser,
            otherUser: widget.otherUser,
            chatId: widget.chatId,
            onBack: () => Navigator.pop(context),
            onProfileTap: () {
              Navigator.pushNamed(context, '/profile', arguments: {
                ...widget.otherUser,
                'onBackgroundSet': _setChatBackground,
              });
            },
            onVideoCall: startVideoCall,
            onVoiceCall: startVoiceCall,
            isOnline: widget.otherUser['isOnline'] ?? false,
            hasStory: widget.storyInteractions.contains(widget.otherUser['id']),
          ),
        ),
        body: Stack(
          children: [
            // Background (isolated so it doesn't rebuild with the chat list)
            ValueListenableBuilder<String?>(              // <-- kept as before
              valueListenable: _backgroundUrlNotifier,
              builder: (context, backgroundUrl, _) {
                return _ChatBackground(backgroundUrl: backgroundUrl);
              },
            ),

            // Foreground chat column
            Column(
              children: [
                SizedBox(
                    height: kToolbarHeight + MediaQuery.of(context).padding.top),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: widget.accentColor.withOpacity(0.1),
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          // Messages (independent widget so background doesn't rebuild)
                          Expanded(
                            child: _ChatMessagesWrapper(
                              chatId: widget.chatId,
                              currentUser: widget.currentUser,
                              otherUser: widget.otherUser,
                              replyingToNotifier: _replyingToNotifier,
                              onMessageLongPressed: _showMessageActions,
                              onReplyToMessage: _onReplyToMessage,
                            ),
                          ),

                          // Typing area (let Flutter handle keyboard insets)
                          Container(
                            color: Colors.black.withOpacity(0.5),
                            child: _TypingAreaWrapper(
                              replyingToNotifier: _replyingToNotifier,
                              bottomInset: bottomInset,
                              onSendMessage: sendMessage,
                              onSendFile: sendFile,
                              onSendAudio: sendAudio,
                              onCancelReply: _onCancelReply,
                              accentColor: widget.accentColor,
                              currentUser: widget.currentUser,
                              otherUser: widget.otherUser,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// ---------------------------
/// Helper widgets below
/// ---------------------------

class _ChatBackground extends StatelessWidget {
  final String? backgroundUrl;
  const _ChatBackground({this.backgroundUrl});

  @override
  Widget build(BuildContext context) {
    // Keep in a RepaintBoundary so it doesn't repaint on unrelated rebuilds.
    return RepaintBoundary(
      child: Stack(
        children: [
          if (backgroundUrl != null)
            Positioned.fill(
              child: CachedNetworkImage(
                imageUrl: backgroundUrl!,
                fit: BoxFit.cover,
                placeholder: (_, __) => const SizedBox.shrink(),
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
            )
          else
            // Optional: a fallback background so there is something visible
            Positioned.fill(
              child: Container(color: Colors.black),
            ),

          // Blur overlay (BackdropFilter is expensive, but kept inside RepaintBoundary)
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Container(
                color: Colors.black.withOpacity(0.2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatMessagesWrapper extends StatelessWidget {
  final String chatId;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;
  final ValueNotifier<QueryDocumentSnapshot<Object?>?> replyingToNotifier;
  final void Function(QueryDocumentSnapshot<Object?>, bool, GlobalKey) onMessageLongPressed;
  final void Function(QueryDocumentSnapshot<Object?>) onReplyToMessage;

  const _ChatMessagesWrapper({
    required this.chatId,
    required this.currentUser,
    required this.otherUser,
    required this.replyingToNotifier,
    required this.onMessageLongPressed,
    required this.onReplyToMessage,
  });

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary prevents expensive background repaints from affecting the list
    return RepaintBoundary(
      child: ValueListenableBuilder<QueryDocumentSnapshot<Object?>?>( 
        valueListenable: replyingToNotifier,
        builder: (context, replyingTo, _) {
          return AdvancedChatList(
            chatId: chatId,
            currentUser: currentUser,
            otherUser: otherUser,
            onMessageLongPressed: onMessageLongPressed,
            replyingTo: replyingTo,
            onCancelReply: () {
              replyingToNotifier.value = null;
            },
            onReply: onReplyToMessage,
          );
        },
      ),
    );
  }
}

class _TypingAreaWrapper extends StatelessWidget {
  final ValueNotifier<QueryDocumentSnapshot<Object?>?> replyingToNotifier;
  final double bottomInset;
  final void Function(String) onSendMessage;
  final void Function(File) onSendFile;
  final void Function(File) onSendAudio;
  final VoidCallback onCancelReply;
  final Color accentColor;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;

  const _TypingAreaWrapper({
    required this.replyingToNotifier,
    required this.bottomInset,
    required this.onSendMessage,
    required this.onSendFile,
    required this.onSendAudio,
    required this.onCancelReply,
    required this.accentColor,
    required this.currentUser,
    required this.otherUser,
  });

  @override
  Widget build(BuildContext context) {
    // Nest ValueListenableBuilders so only typing area and necessary small parts rebuild
    return ValueListenableBuilder<QueryDocumentSnapshot<Object?>?>(
      valueListenable: replyingToNotifier,
      builder: (context, replyingTo, _) {
        // We use bottom padding equal to MediaQuery.viewInsetsOf(context).bottom so typing area can react to keyboard open,
        // but this only rebuilds the TypingArea section.
        return Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: RepaintBoundary(
            child: TypingArea(
              onSendMessage: onSendMessage,
              onSendFile: onSendFile,
              onSendAudio: onSendAudio,
              accentColor: accentColor,
              replyingTo: replyingTo,
              isGroup: false,
              currentUser: currentUser,
              otherUser: otherUser,
              onCancelReply: onCancelReply,
            ),
          ),
        );
      },
    );
  }
}

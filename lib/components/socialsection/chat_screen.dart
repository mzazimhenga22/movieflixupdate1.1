import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:movie_app/utils/read_status_utils.dart';
import 'package:flutter/foundation.dart';
import 'VideoCallScreen_1to1.dart';
import 'VoiceCallScreen_1to1.dart';
import 'widgets/chat_app_bar.dart';
import 'widgets/typing_area.dart';
import 'widgets/advanced_chat_list.dart';
import 'widgets/message_actions.dart';
import 'package:movie_app/utils/native_keyboard_bridge.dart';

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

class _ChatScreenState extends State<ChatScreen> with AutomaticKeepAliveClientMixin {
  String? backgroundUrl;
  QueryDocumentSnapshot<Object?>? replyingTo;
  bool isActionOverlayVisible = false;
  late SharedPreferences prefs;
  final _kbBridge = NativeKeyboardBridge();

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
    _kbBridge.keyboardHeight.addListener(_onKeyboardHeightChanged);
  }

  void _onKeyboardHeightChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _kbBridge.keyboardHeight.removeListener(_onKeyboardHeightChanged);
    super.dispose();
  }

  Future<void> _loadChatBackground() async {
    if (mounted) {
      setState(() => backgroundUrl = prefs.getString('chat_background_${widget.chatId}'));
    }
  }

  Future<void> _setChatBackground(String url) async {
    await prefs.setString('chat_background_${widget.chatId}', url);
    if (mounted) {
      setState(() => backgroundUrl = url);
    }
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
      if (replyingTo != null) ...{
        'replyToId': replyingTo!.id,
        'replyToText': replyingTo!['text'],
        'replyToSenderId': replyingTo!['senderId'],
        'replyToSenderName': replyingTo!['senderId'] == widget.currentUser['id']
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

    if (mounted) setState(() => replyingTo = null);
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
              caller: widget.otherUser,
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
    if (mounted) setState(() => replyingTo = message);
  }

  void _onCancelReply() {
    if (mounted) setState(() => replyingTo = null);
  }

  void _showMessageActions(QueryDocumentSnapshot<Object?> message, bool isMe, GlobalKey messageKey) {
    if (isActionOverlayVisible) return;

    isActionOverlayVisible = true;

    showMessageActions(
      context: context,
      message: message,
      isMe: isMe,
      messageKey: messageKey,
      onReply: () {
        _onReplyToMessage(message);
        Navigator.pop(context);
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
        }
        Navigator.pop(context);
        isActionOverlayVisible = false;
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

        Navigator.pop(context);
        isActionOverlayVisible = false;
      },
      onBlock: () async {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.currentUser['id'])
            .update({
          'blockedUsers': FieldValue.arrayUnion([widget.otherUser['id']])
        });
        Navigator.pop(context);
        isActionOverlayVisible = false;
      },
      onForward: () async {
        await Navigator.pushNamed(context, '/forward', arguments: {
          'message': message,
          'currentUser': widget.currentUser,
        });
        Navigator.pop(context);
        isActionOverlayVisible = false;
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
        Navigator.pop(context);
        isActionOverlayVisible = false;
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
        Navigator.pop(context);
        isActionOverlayVisible = false;
      },
    );
  }

  void _listenForIncomingCalls() {
    FirebaseFirestore.instance
        .collection('calls')
        .where('receiverId', isEqualTo: widget.currentUser['id'])
        .where('status', isEqualTo: 'ongoing')
        .snapshots()
        .listen((qs) {
          if (qs.docs.isEmpty) return;
          for (final doc in qs.docs) {
            final data = doc.data();
            if (data['callerId'] == widget.otherUser['id'] && mounted) {
              final callId = doc.id;
              final route = data['type'] == 'video'
                  ? VideoCallScreen1to1(
                      callId: callId,
                      callerId: widget.currentUser['id'],
                      receiverId: widget.otherUser['id'],
                      currentUserId: widget.currentUser['id'],
                      caller: widget.currentUser,
                      receiver: widget.otherUser,
                    )
                  : VoiceCallScreen1to1(
                      callId: callId,
                      callerId: widget.otherUser['id'],
                      receiverId: widget.currentUser['id'],
                      currentUserId: widget.currentUser['id'],
                      caller: widget.otherUser,
                      receiver: widget.currentUser,
                    );
              Navigator.push(context, MaterialPageRoute(builder: (_) => route));
            }
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final bottomInset = _kbBridge.keyboardHeight.value;

    return Scaffold(
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
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.redAccent, Colors.blueAccent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.1, -0.4),
                radius: 1.2,
                colors: [widget.accentColor.withOpacity(0.4), Colors.black],
                stops: const [0.0, 0.6],
              ),
            ),
          ),
          Positioned.fill(
            top: kToolbarHeight + MediaQuery.of(context).padding.top,
            child: Container(
              decoration: backgroundUrl != null
                  ? BoxDecoration(
                      image: DecorationImage(
                        image: NetworkImage(backgroundUrl!, scale: 1.5),
                        fit: BoxFit.cover,
                        onError: (exception, stackTrace) => debugPrint('Background image error: $exception'),
                      ),
                    )
                  : null,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 1.6,
                        colors: [
                          widget.accentColor.withOpacity(0.2),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 1.0],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: widget.accentColor.withOpacity(0.1),
                      ),
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: RepaintBoundary(
                            child: AdvancedChatList(
                              chatId: widget.chatId,
                              currentUser: widget.currentUser,
                              otherUser: widget.otherUser,
                              onMessageLongPressed: _showMessageActions,
                              replyingTo: replyingTo,
                              onCancelReply: _onCancelReply,
                            ),
                          ),
                        ),
                        AnimatedPadding(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                          padding: EdgeInsets.only(bottom: bottomInset),
                          child: Container(
                            color: Colors.black.withOpacity(0.5),
                            child: RepaintBoundary(
                              child: TypingArea(
                                onSendMessage: sendMessage,
                                onSendFile: sendFile,
                                onSendAudio: sendAudio,
                                accentColor: widget.accentColor,
                                replyingTo: replyingTo,
                                isGroup: false,
                                currentUser: widget.currentUser,
                                otherUser: widget.otherUser,
                                onCancelReply: _onCancelReply,
                              ),
                            ),
                          ),
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
    );
  }
}
// chat_screen.dart
import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:movie_app/webrtc/rtc_manager.dart';
import 'package:movie_app/utils/read_status_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:cached_network_image/cached_network_image.dart';

// <-- Make sure this import matches the actual file name in your project.
// If your file is `services/fcm_sender.dart` use that path; if it's `services/fcmsender.dart` change accordingly.
import 'package:movie_app/services/fcm_sender.dart' show sendFcmPush;

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

class _ChatScreenState extends State<ChatScreen> with AutomaticKeepAliveClientMixin {
  String? backgroundUrl;
  QueryDocumentSnapshot<Object?>? replyingTo;
  bool isActionOverlayVisible = false;
  late SharedPreferences prefs;

  // Notifiers used to avoid unnecessary rebuilds:
  final ValueNotifier<String?> _backgroundUrlNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<QueryDocumentSnapshot<Object?>?> _replyingToNotifier = ValueNotifier<QueryDocumentSnapshot<Object?>?>(null);

  // Manage streams so we cancel them on dispose (prevents ValueNotifier-after-dispose bugs)
  StreamSubscription<QuerySnapshot<Object?>>? _incomingCallsSub;

  bool _isDisposed = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();

    SharedPreferences.getInstance().then((p) {
      if (mounted) prefs = p;
      _loadChatBackground();
      markChatAsRead(widget.chatId, widget.currentUser['id']);
      _listenForIncomingCalls();
    });
  }

  @override
  void dispose() {
    // Cancel subscriptions & timers BEFORE disposing notifiers
    _incomingCallsSub?.cancel();

    _isDisposed = true;

    _backgroundUrlNotifier.dispose();
    _replyingToNotifier.dispose();

    super.dispose();
  }

  Future<void> _loadChatBackground() async {
    try {
      final stored = prefs.getString('chat_background_${widget.chatId}');
      if (_isDisposed) return;
      if (_backgroundUrlNotifier.value != stored) {
        _backgroundUrlNotifier.value = stored;
      }
    } catch (e) {
      debugPrint('Failed to load background: $e');
    }
  }

  Future<void> _setChatBackground(String url) async {
    try {
      await prefs.setString('chat_background_${widget.chatId}', url);
      if (!_isDisposed) _backgroundUrlNotifier.value = url;
    } catch (e) {
      debugPrint('Failed to set background: $e');
    }
  }

  Future<bool> _isUserBlocked(String userId) async {
    final userDoc = await FirebaseFirestore.instance.collection('users').doc(widget.currentUser['id']).get();
    final blockedUsers = List<String>.from(userDoc.data()?['blockedUsers'] ?? []);
    return blockedUsers.contains(userId);
  }

  /// Sends a message and triggers a data-only FCM push to the other user (fire-and-forget).
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
        'replyToSenderName': _replyingToNotifier.value!.id == widget.currentUser['id']
            ? widget.currentUser['username'] ?? 'You'
            : widget.otherUser['username'] ?? 'Unknown',
      },
    };

    try {
      // add message to messages subcollection
      final msgRef = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add(messageData);

      // Update chat doc: lastMessage + timestamp + ensure userIds exist + add unreadBy receiver
      await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).set({
        'lastMessage': text,
        'timestamp': FieldValue.serverTimestamp(),
        'userIds': [widget.currentUser['id'], widget.otherUser['id']],
        'unreadBy': FieldValue.arrayUnion([widget.otherUser['id']]),
      }, SetOptions(merge: true));

      // Reset reply UI
      if (!_isDisposed) _replyingToNotifier.value = null;

      // Fire-and-forget: send FCM push to receiver
      unawaited(_sendMessagePush(
        receiverId: widget.otherUser['id'],
        senderId: widget.currentUser['id'],
        senderName: widget.currentUser['username'] ?? 'Someone',
        text: text,
        chatId: widget.chatId,
        messageId: msgRef.id,
      ));
    } catch (e, st) {
      debugPrint('sendMessage error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to send message')),
        );
      }
    }
  }

  /// Sends file message and push (file message currently only writes metadata here).
  void sendFile(File file) async {
    if (await _isUserBlocked(widget.otherUser['id'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot send file to blocked user')),
        );
      }
      return;
    }
    try {
      // TODO: actually upload file to storage and retrieve URL; here we store placeholder
      final messageData = {
        'text': 'File',
        'fileName': file.path.split('/').last,
        'senderId': widget.currentUser['id'],
        'senderName': widget.currentUser['username'] ?? 'You',
        'receiverId': widget.otherUser['id'],
        'timestamp': FieldValue.serverTimestamp(),
        'type': 'file',
        'reactions': [],
        'deletedFor': [],
      };

      final msgRef = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add(messageData);

      await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).set({
        'lastMessage': 'Sent a file',
        'timestamp': FieldValue.serverTimestamp(),
        'userIds': [widget.currentUser['id'], widget.otherUser['id']],
        'unreadBy': FieldValue.arrayUnion([widget.otherUser['id']]),
      }, SetOptions(merge: true));

      unawaited(_sendMessagePush(
        receiverId: widget.otherUser['id'],
        senderId: widget.currentUser['id'],
        senderName: widget.currentUser['username'] ?? 'Someone',
        text: 'Sent a file',
        chatId: widget.chatId,
        messageId: msgRef.id,
        messageType: 'file',
      ));

      debugPrint("Sending file: ${file.path}");
    } catch (e, st) {
      debugPrint('sendFile error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to send file')),
        );
      }
    }
  }

  /// Sends audio message and push (placeholder implementation)
  void sendAudio(File audio) async {
    if (await _isUserBlocked(widget.otherUser['id'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot send audio to blocked user')),
        );
      }
      return;
    }
    try {
      // TODO: upload audio to storage and attach URL
      final messageData = {
        'text': 'Voice message',
        'fileName': audio.path.split('/').last,
        'senderId': widget.currentUser['id'],
        'senderName': widget.currentUser['username'] ?? 'You',
        'receiverId': widget.otherUser['id'],
        'timestamp': FieldValue.serverTimestamp(),
        'type': 'audio',
        'reactions': [],
        'deletedFor': [],
      };

      final msgRef = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add(messageData);

      await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).set({
        'lastMessage': 'Sent a voice message',
        'timestamp': FieldValue.serverTimestamp(),
        'userIds': [widget.currentUser['id'], widget.otherUser['id']],
        'unreadBy': FieldValue.arrayUnion([widget.otherUser['id']]),
      }, SetOptions(merge: true));

      unawaited(_sendMessagePush(
        receiverId: widget.otherUser['id'],
        senderId: widget.currentUser['id'],
        senderName: widget.currentUser['username'] ?? 'Someone',
        text: 'Sent a voice message',
        chatId: widget.chatId,
        messageId: msgRef.id,
        messageType: 'audio',
      ));

      debugPrint("Sending audio: ${audio.path}");
    } catch (e, st) {
      debugPrint('sendAudio error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to send audio')),
        );
      }
    }
  }

  /// Helper: fetch receiver FCM token and send data-only push via sendFcmPush().
  Future<void> _sendMessagePush({
    required String receiverId,
    required String senderId,
    required String senderName,
    required String text,
    required String chatId,
    required String messageId,
    String messageType = 'text',
  }) async {
    try {
      // read receiver user doc
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(receiverId).get();
      if (!userDoc.exists) {
        debugPrint('[push] receiver user doc not found: $receiverId');
        return;
      }
      final userData = userDoc.data()!;
      final fcmToken = userData['fcmToken'] as String?;
      final isMuted = (userData['mutedChats'] as List<dynamic>?)?.contains(chatId) == true;
      final blockedByReceiver = (userData['blockedUsers'] as List<dynamic>?)?.contains(senderId) == true;

      // do not send push if token not present, receiver muted this chat, or receiver blocked the sender
      if (fcmToken == null || fcmToken.isEmpty) {
        debugPrint('[push] no token for receiver $receiverId - skipping push');
        return;
      }
      if (isMuted) {
        debugPrint('[push] receiver $receiverId muted chat $chatId - skipping push');
        return;
      }
      if (blockedByReceiver) {
        debugPrint('[push] receiver $receiverId has blocked sender $senderId - skipping push');
        return;
      }

      // Choose projectId used by your FCM service account (match your service-account.json)
      const projectId = 'movieflix-53a51';

      // Compose title/body - keep them short
      final title = senderName;
      final body = (messageType == 'text') ? (text.length <= 120 ? text : '${text.substring(0, 117)}...') : (messageType == 'file' ? 'Sent a file' : 'Sent a voice message');

      // Extra data delivered to app (background handler should inspect these keys)
      final extraData = <String, String>{
        'type': 'message',
        'chatId': chatId,
        'messageId': messageId,
        'senderId': senderId,
        'senderName': senderName,
        'messageType': messageType,
        'text': messageType == 'text' ? text : body,
      };

      // Send data-only push (non-blocking)
      unawaited(sendFcmPush(
        fcmToken: fcmToken,
        projectId: projectId,
        title: title,
        body: body,
        extraData: extraData,
      ));
      debugPrint('[push] pushed message to $receiverId');
    } catch (e, st) {
      debugPrint('[push] failed to send push: $e\n$st');
    }
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
    if (!_isDisposed) _replyingToNotifier.value = message;
  }

  void _onCancelReply() {
    if (!_isDisposed) _replyingToNotifier.value = null;
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
        if (!_isDisposed) _replyingToNotifier.value = message;
        isActionOverlayVisible = false;
      },
      onPin: () async {
        await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).set({
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

        await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(message.id).update({'deletedFor': deletedFor});

        final chatDoc = await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).get();
        if (chatDoc.exists && chatDoc['pinnedMessageId'] == message.id) {
          await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).update({'pinnedMessageId': null});
        }

        if (mounted) {
          Navigator.of(context, rootNavigator: false).pop();
          isActionOverlayVisible = false;
        }
      },
      onBlock: () async {
        await FirebaseFirestore.instance.collection('users').doc(widget.currentUser['id']).update({
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
            settings: RouteSettings(arguments: {'message': message, 'currentUser': widget.currentUser, 'isForwarded': true}),
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
          await Navigator.pushNamed(context, '/editMessage', arguments: {'message': message, 'chatId': widget.chatId});
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
          await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(message.id).update({
            'reactions': FieldValue.arrayRemove([emoji])
          });
        } else {
          await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(message.id).update({
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
    // cancel previous if any
    _incomingCallsSub?.cancel();

    _incomingCallsSub = FirebaseFirestore.instance
        .collection('calls')
        .where('receiverId', isEqualTo: widget.currentUser['id'])
        .where('status', isEqualTo: 'ringing')
        .snapshots()
        .listen((snapshot) {
      if (_isDisposed) return;

      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added || change.type == DocumentChangeType.modified) {
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

            Navigator.push(context, MaterialPageRoute(builder: (_) => route));
          }
        }
      }
    }, onError: (err) {
      debugPrint('Incoming calls listen error: $err');
    });
  }

  // Reusable bottom sheet for quick actions (was previously a FAB menu)
  void _showQuickActionsBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.85),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            border: Border.all(color: widget.accentColor.withOpacity(0.08)),
          ),
          padding: const EdgeInsets.all(12),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundImage: widget.otherUser['avatarUrl'] != null
                      ? CachedNetworkImageProvider(widget.otherUser['avatarUrl'])
                      : null,
                  backgroundColor: widget.accentColor.withOpacity(0.2),
                  child: widget.otherUser['avatarUrl'] == null ? const Icon(Icons.person) : null,
                ),
                title: Text(widget.otherUser['username'] ?? 'Contact'),
                subtitle: Text(widget.otherUser['status'] ?? ''),
                trailing: IconButton(
                  icon: const Icon(Icons.info_outline),
                  color: widget.accentColor,
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.pushNamed(context, '/profile', arguments: {
                      ...widget.otherUser,
                      'onBackgroundSet': _setChatBackground,
                    });
                  },
                ),
              ),
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: widget.accentColor),
                    onPressed: () {
                      Navigator.pop(ctx);
                      startVoiceCall();
                    },
                    icon: const Icon(Icons.call),
                    label: const Text('Voice'),
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: widget.accentColor),
                    onPressed: () {
                      Navigator.pop(ctx);
                      startVideoCall();
                    },
                    icon: const Icon(Icons.videocam),
                    label: const Text('Video'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(side: BorderSide(color: widget.accentColor)),
                    onPressed: () {
                      Navigator.pop(ctx);
                      // future: open media picker
                    },
                    icon: const Icon(Icons.image),
                    label: const Text('Media'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return PresenceWrapper(
      userId: widget.currentUser['id'],
      groupIds: [widget.chatId],
      child: Scaffold(
        resizeToAvoidBottomInset: true,
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
        // NOTE: removed floatingActionButton to avoid overlapping typing area
        body: Stack(
          children: [
            // Background
            ValueListenableBuilder<String?>(
              valueListenable: _backgroundUrlNotifier,
              builder: (context, backgroundUrl, _) {
                return _ChatBackground(backgroundUrl: backgroundUrl, accentColor: widget.accentColor);
              },
            ),

            // Foreground column with compact features bar + messages + typing area
            Column(
              children: [
                // Compact contact features bar (replaces the old 'intro' which acted like another navbar)
                SafeArea(
                  top: false,
                  child: ContactFeaturesBar(
                    otherUser: widget.otherUser,
                    accentColor: widget.accentColor,
                    onProfileTap: () {
                      Navigator.pushNamed(context, '/profile', arguments: {
                        ...widget.otherUser,
                        'onBackgroundSet': _setChatBackground,
                      });
                    },
                    onVoiceCall: startVoiceCall,
                    onVideoCall: startVideoCall,
                    onActions: _showQuickActionsBottomSheet, // moved Actions here
                  ),
                ),

                // Main content container
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 8.0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: widget.accentColor.withOpacity(0.12)),
                          color: Colors.black.withOpacity(0.45),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          children: [
                            // Messages
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

                            // Typing area
                            // ensure there is no overlap by not using FAB and by giving some padding
                            Container(
                              color: Colors.black.withOpacity(0.55),
                              child: _TypingAreaWrapper(
                                replyingToNotifier: _replyingToNotifier,
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
  final Color accentColor;
  const _ChatBackground({this.backgroundUrl, required this.accentColor});

  @override
  Widget build(BuildContext context) {
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
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [accentColor.withOpacity(0.06), Colors.black],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
            ),

          // Lightweight overlay
          Positioned.fill(
            child: Container(
              color: Colors.black.withOpacity(0.24),
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
  final void Function(String) onSendMessage;
  final void Function(File) onSendFile;
  final void Function(File) onSendAudio;
  final VoidCallback onCancelReply;
  final Color accentColor;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> otherUser;

  const _TypingAreaWrapper({
    required this.replyingToNotifier,
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
    return ValueListenableBuilder<QueryDocumentSnapshot<Object?>?>(
      valueListenable: replyingToNotifier,
      builder: (context, replyingTo, _) {
        return RepaintBoundary(
          child: SafeArea(
            top: false,
            bottom: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
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
          ),
        );
      },
    );
  }
}

/// Compact contact features bar that replaced the old "intro" (no second navbar)
class ContactFeaturesBar extends StatelessWidget {
  final Map<String, dynamic> otherUser;
  final Color accentColor;
  final VoidCallback onProfileTap;
  final VoidCallback onVoiceCall;
  final VoidCallback onVideoCall;
  final VoidCallback onActions;

  const ContactFeaturesBar({
    required this.otherUser,
    required this.accentColor,
    required this.onProfileTap,
    required this.onVoiceCall,
    required this.onVideoCall,
    required this.onActions,
  });

  @override
  Widget build(BuildContext context) {
    final avatarUrl = otherUser['avatarUrl'] as String?;
    final name = otherUser['username'] ?? 'Contact';
    final status = otherUser['status'] ?? (otherUser['isOnline'] == true ? 'Online' : 'Last seen recently');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onProfileTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Colors.black.withOpacity(0.18),
              border: Border.all(color: accentColor.withOpacity(0.04)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: accentColor.withOpacity(0.12),
                  backgroundImage: avatarUrl != null ? CachedNetworkImageProvider(avatarUrl) : null,
                  child: avatarUrl == null ? const Icon(Icons.person) : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
                      const SizedBox(height: 2),
                      Text(status, style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.75))),
                    ],
                  ),
                ),
                // quick icons (voice/video)
                IconButton(
                  onPressed: onVoiceCall,
                  icon: Icon(Icons.call, color: accentColor),
                  tooltip: 'Voice call',
                ),
                IconButton(
                  onPressed: onVideoCall,
                  icon: Icon(Icons.videocam, color: accentColor),
                  tooltip: 'Video call',
                ),
                // moved actions (three dots) here - opens bottom sheet
                IconButton(
                  onPressed: onActions,
                  icon: Icon(Icons.more_vert, color: accentColor),
                  tooltip: 'More',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

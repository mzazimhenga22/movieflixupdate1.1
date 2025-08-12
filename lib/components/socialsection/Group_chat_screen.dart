import 'dart:io';
import 'dart:ui';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:movie_app/webrtc/group_rtc_manager.dart';
import 'package:movie_app/utils/read_status_utils.dart';
import 'package:flutter/foundation.dart';
import 'Group_profile_screen.dart';
import 'widgets/GroupChatAppBar.dart';
import 'widgets/typing_area.dart';
import 'widgets/GroupChatList.dart';
import 'widgets/message_actions.dart';
import 'forward_message_screen.dart';
import 'VideoCallScreen_Group.dart';
import 'VoiceCallScreen_Group.dart';
import 'package:movie_app/utils/native_keyboard_bridge.dart';
import 'presence_wrapper.dart';

class GroupChatScreen extends StatefulWidget {
  final String chatId;
  final Map<String, dynamic> currentUser;
  final Map<String, dynamic> authenticatedUser;
  final Color accentColor;
  final Map<String, dynamic>? forwardedMessage;

  const GroupChatScreen({
    super.key,
    required this.chatId,
    required this.currentUser,
    required this.authenticatedUser,
    this.forwardedMessage,
    this.accentColor = Colors.blueAccent,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen>
    with AutomaticKeepAliveClientMixin {
  // Use ValueNotifiers to avoid full-screen rebuilds on keyboard / small state changes
  final ValueNotifier<String?> _backgroundUrlNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<List<Map<String, dynamic>>> _groupMembersNotifier =
      ValueNotifier<List<Map<String, dynamic>>>([]);
  final ValueNotifier<Map<String, dynamic>?> _groupDataNotifier =
      ValueNotifier<Map<String, dynamic>?>(null);
  final ValueNotifier<QueryDocumentSnapshot<Object?>?> _replyingToNotifier =
      ValueNotifier<QueryDocumentSnapshot<Object?>?>(null);
  final ValueNotifier<double> _keyboardHeightNotifier = ValueNotifier<double>(0);

  bool isActionOverlayVisible = false;
  late SharedPreferences prefs;
  final _kbBridge = NativeKeyboardBridge();
  Timer? _debounce;
  String? _activeCallId;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      prefs = p;
      _loadChatBackground();
      _loadCachedGroupData();
      _loadGroupDataAndListen();
      _listenForIncomingCalls();
    });
    _kbBridge.keyboardHeight.addListener(_onKeyboardHeightChanged);
  }

  void _onKeyboardHeightChanged() {
    // avoid calling setState — update notifier so only typing area rebuilds
    _keyboardHeightNotifier.value = _kbBridge.keyboardHeight.value;
  }

  @override
  void dispose() {
    _kbBridge.keyboardHeight.removeListener(_onKeyboardHeightChanged);
    _backgroundUrlNotifier.dispose();
    _groupMembersNotifier.dispose();
    _groupDataNotifier.dispose();
    _replyingToNotifier.dispose();
    _keyboardHeightNotifier.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadChatBackground() async {
    final stored = prefs.getString('chat_background_${widget.chatId}');
    if (_backgroundUrlNotifier.value != stored) {
      _backgroundUrlNotifier.value = stored;
    }
  }

  Future<void> _loadCachedGroupData() async {
    final cachedData = prefs.getString('group_data_${widget.chatId}');
    if (cachedData != null) {
      try {
        final data = await compute(jsonDecode, cachedData) as Map<String, dynamic>;
        final members = List<Map<String, dynamic>>.from(data['members'] ?? []);
        _groupDataNotifier.value = data;
        _groupMembersNotifier.value = members;
      } catch (e) {
        debugPrint('Failed to load cached group data: $e');
      }
    }
  }

  Future<void> _cacheGroupData(Map<String, dynamic> data, List<Map<String, dynamic>> members) async {
    final serializableData = _convertTimestamps(Map<String, dynamic>.from(data));
    final serializableMembers = members.map((member) {
      return _convertTimestamps(Map<String, dynamic>.from(member));
    }).toList();

    await prefs.setString(
      'group_data_${widget.chatId}',
      jsonEncode({
        ...serializableData,
        'members': serializableMembers,
      }),
    );
  }

  /// Recursively converts all `Timestamp` values in a map to ISO8601 strings.
  Map<String, dynamic> _convertTimestamps(Map<String, dynamic> map) {
    map.forEach((key, value) {
      if (value is Timestamp) {
        map[key] = value.toDate().toIso8601String();
      } else if (value is Map<String, dynamic>) {
        map[key] = _convertTimestamps(Map<String, dynamic>.from(value));
      } else if (value is List) {
        map[key] = value.map((item) {
          if (item is Timestamp) {
            return item.toDate().toIso8601String();
          } else if (item is Map<String, dynamic>) {
            return _convertTimestamps(Map<String, dynamic>.from(item));
          }
          return item;
        }).toList();
      }
    });
    return map;
  }

  Future<bool> _isUserBlocked(String userId) async {
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.currentUser['id'])
        .get();
    final blockedUsers = List<String>.from(userDoc.data()?['blockedUsers'] ?? []);
    return blockedUsers.contains(userId);
  }

  void _loadGroupDataAndListen() {
    FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.chatId)
        .snapshots()
        .listen((chatDoc) async {
      if (!chatDoc.exists || chatDoc.data()?['isGroup'] != true) {
        // keep notifiers as-is or clear them
        _groupDataNotifier.value = chatDoc.data();
        return;
      }

      final memberIds = List<String>.from(chatDoc.data()?['userIds'] ?? []);
      final membersSnapshots = await Future.wait(memberIds.map(
        (uid) => FirebaseFirestore.instance.collection('users').doc(uid).get(),
      ));

      final members = membersSnapshots
          .where((doc) => doc.exists)
          .map((doc) {
            final d = Map<String, dynamic>.from(doc.data()!);
            d['id'] = doc.id;
            return d;
          })
          .toList();

      _groupDataNotifier.value = chatDoc.data();
      _groupMembersNotifier.value = members;

      await _cacheGroupData(chatDoc.data()!, members);

      // Listen to members changes but debounce UI updates to avoid churn
      FirebaseFirestore.instance
          .collection('users')
          .where(FieldPath.documentId, whereIn: memberIds.isEmpty ? [''] : memberIds)
          .snapshots()
          .listen((snapshot) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 300), () {
          // simple refresh — since members could update presence etc.
          if (mounted) {
            // We only update notifiers; avoid full-screen setState
            _groupMembersNotifier.value = List<Map<String, dynamic>>.from(_groupMembersNotifier.value);
          }
        });
      });

      await markGroupAsRead(widget.chatId, widget.currentUser['id']);
    });
  }

  void sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    final messageData = {
      'text': text,
      'senderId': widget.currentUser['id'],
      'senderName': widget.currentUser['username'] ?? 'You',
      'timestamp': FieldValue.serverTimestamp(),
      'type': 'text',
      'reactions': [],
      'deletedFor': [],
      'readBy': [widget.currentUser['id']],
      if (_replyingToNotifier.value != null) ...{
        'replyToId': _replyingToNotifier.value!.id,
        'replyToText': _replyingToNotifier.value!['text'],
        'replyToSenderId': _replyingToNotifier.value!['senderId'],
        'replyToSenderName': _groupMembersNotifier.value.firstWhere(
          (member) => member['id'] == _replyingToNotifier.value!['senderId'],
          orElse: () => {'username': 'Unknown'},
        )['username'] ?? 'Unknown',
      },
    };

    await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.chatId)
        .collection('messages')
        .add(messageData);

    await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).set({
      'lastMessage': text,
      'timestamp': FieldValue.serverTimestamp(),
      'unreadBy': FieldValue.arrayUnion(
          _groupMembersNotifier.value.map((m) => m['id']).where((id) => id != widget.currentUser['id']).toList()),
    }, SetOptions(merge: true));

    // clear reply state only
    _replyingToNotifier.value = null;
  }

  void sendFile(File file) async {
    if (await _isUserBlocked(widget.currentUser['id'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot send file from blocked user')),
        );
      }
      return;
    }
    debugPrint("Sending file: ${file.path}");
  }

  void sendAudio(File audio) async {
    if (await _isUserBlocked(widget.currentUser['id'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot send audio from blocked user')),
        );
      }
      return;
    }
    debugPrint("Sending audio: ${audio.path}");
  }

  void startGroupCall(bool isVideo) async {
    if (await _isUserBlocked(widget.currentUser['id'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot initiate call from blocked user')),
        );
      }
      return;
    }

    try {
      final existingCall = await FirebaseFirestore.instance
          .collection('groupCalls')
          .where('groupId', isEqualTo: widget.chatId)
          .where('status', isEqualTo: 'ringing')
          .get();

      if (existingCall.docs.isNotEmpty) {
        final callId = existingCall.docs.first.id;
        if (mounted && _activeCallId == null) {
          setState(() => _activeCallId = callId);
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => isVideo
                  ? VideoCallScreenGroup(
                      callId: callId,
                      callerId: widget.currentUser['id'],
                      groupId: widget.chatId,
                      participants: _groupMembersNotifier.value,
                    )
                  : VoiceCallScreen(
                      callId: callId,
                      callerId: widget.currentUser['id'],
                      groupId: widget.chatId,
                      receiverId: widget.currentUser['id'],
                      participants: _groupMembersNotifier.value,
                    ),
            ),
          );
          if (mounted) {
            setState(() => _activeCallId = null);
          }
        }
        return;
      }

      final callId = await GroupRtcManager.startGroupCall(
        caller: widget.currentUser,
        participants: _groupMembersNotifier.value,
        isVideo: isVideo,
      );

      await FirebaseFirestore.instance.collection('groupCalls').doc(callId).set({
        'type': isVideo ? 'video' : 'voice',
        'callerId': widget.currentUser['id'],
        'groupId': widget.chatId,
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'ringing',
        'participants': _groupMembersNotifier.value.map((m) => m['id']).toList(),
        'participantStatus': {widget.currentUser['id']: 'joined'},
      });

      if (mounted) {
        setState(() => _activeCallId = callId);
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => isVideo
                ? VideoCallScreenGroup(
                    callId: callId,
                    callerId: widget.currentUser['id'],
                    groupId: widget.chatId,
                    participants: _groupMembersNotifier.value,
                  )
                : VoiceCallScreen(
                    callId: callId,
                    callerId: widget.currentUser['id'],
                    groupId: widget.chatId,
                    receiverId: widget.currentUser['id'],
                    participants: _groupMembersNotifier.value,
                  ),
          ),
        );
        if (mounted) {
          setState(() => _activeCallId = null);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start call: $e')),
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

  void _showMessageActions(QueryDocumentSnapshot<Object?> message, bool isMe, GlobalKey messageKey) {
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
            .collection('groups')
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
          setState(() => isActionOverlayVisible = false);
        }
      },
      onDelete: () async {
        final data = message.data() as Map<String, dynamic>;
        final deletedFor = List<String>.from(data['deletedFor'] ?? []);
        deletedFor.add(widget.currentUser['id']);

        await FirebaseFirestore.instance
            .collection('groups')
            .doc(widget.chatId)
            .collection('messages')
            .doc(message.id)
            .update({'deletedFor': deletedFor});

        final chatDoc = await FirebaseFirestore.instance
            .collection('groups')
            .doc(widget.chatId)
            .get();

        if (chatDoc.exists && chatDoc['pinnedMessageId'] == message.id) {
          await FirebaseFirestore.instance
              .collection('groups')
              .doc(widget.chatId)
              .update({'pinnedMessageId': null});
        }

        if (mounted) {
          Navigator.of(context, rootNavigator: false).pop();
          setState(() => isActionOverlayVisible = false);
        }
      },
      onBlock: () async {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.currentUser['id'])
            .update({
          'blockedUsers': FieldValue.arrayUnion([message['senderId']])
        });
        if (mounted) {
          Navigator.of(context, rootNavigator: false).pop();
          setState(() => isActionOverlayVisible = false);
        }
      },
      onForward: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const ForwardMessageScreen(),
            settings: RouteSettings(arguments: {
              'message': message,
              'currentUser': widget.currentUser,
              'isForwarded': true,
            }),
          ),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Message forwarded')),
          );
          Navigator.of(context, rootNavigator: false).pop();
          setState(() => isActionOverlayVisible = false);
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
          setState(() => isActionOverlayVisible = false);
        }
      },
      onReactEmoji: (emoji) async {
        final data = message.data() as Map<String, dynamic>;
        final currentReactions = List<String>.from(data['reactions'] ?? []);

        if (currentReactions.contains(emoji)) {
          await FirebaseFirestore.instance
              .collection('groups')
              .doc(widget.chatId)
              .collection('messages')
              .doc(message.id)
              .update({
            'reactions': FieldValue.arrayRemove([emoji])
          });
        } else {
          await FirebaseFirestore.instance
              .collection('groups')
              .doc(widget.chatId)
              .collection('messages')
              .doc(message.id)
              .update({
            'reactions': FieldValue.arrayUnion([emoji])
          });
        }
        if (mounted) {
          Navigator.of(context, rootNavigator: false).pop();
          setState(() => isActionOverlayVisible = false);
        }
      },
    );
  }

  void _listenForIncomingCalls() {
    FirebaseFirestore.instance
        .collection('groupCalls')
        .where('groupId', isEqualTo: widget.chatId)
        .where('status', isEqualTo: 'ringing')
        .snapshots()
        .listen((snapshot) {
      if (snapshot.docs.isEmpty) return;

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final callId = doc.id;

        final isIncoming = data['callerId'] != widget.currentUser['id'];

        if (mounted && _activeCallId == null && isIncoming) {
          setState(() => _activeCallId = callId);

          final callScreen = data['type'] == 'video'
              ? VideoCallScreenGroup(
                  callId: callId,
                  callerId: data['callerId'],
                  groupId: widget.chatId,
                  participants: _groupMembersNotifier.value,
                )
              : VoiceCallScreen(
                  callId: callId,
                  callerId: data['callerId'],
                  groupId: widget.chatId,
                  receiverId: widget.currentUser['id'],
                  participants: _groupMembersNotifier.value,
                );

          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => callScreen),
          ).then((_) {
            if (mounted) {
              setState(() => _activeCallId = null);
            }
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // leave bottomInset read if you need it for fallback logic
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return PresenceWrapper(
      userId: widget.currentUser['id'],
      groupIds: [widget.chatId],
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: ValueListenableBuilder<Map<String, dynamic>?>(
            valueListenable: _groupDataNotifier,
            builder: (context, groupData, _) {
              return GroupChatAppBar(
                groupId: widget.chatId,
                groupName: groupData?['name'] ?? 'Loading...',
                groupPhotoUrl: groupData?['avatarUrl'] ?? '',
                onBack: () => Navigator.pop(context),
                onGroupInfoTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GroupProfileScreen(
                      groupId: widget.chatId,
                      currentUserId: widget.currentUser['id'],
                    ),
                  ),
                ),
                onVideoCall: () => startGroupCall(true),
                onVoiceCall: () => startGroupCall(false),
                accentColor: widget.accentColor,
              );
            },
          ),
        ),
        body: Stack(
          children: [
            // base gradient
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.redAccent, Colors.blueAccent],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),

            // second gradient layer
            Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.1, -0.4),
                  radius: 1.2,
                  colors: [widget.accentColor.withValues(alpha: 0.4), Colors.black],
                  stops: const [0.0, 0.6],
                ),
              ),
            ),

            // Foreground content placed under appbar
            Positioned.fill(
              top: kToolbarHeight + MediaQuery.of(context).padding.top,
              child: ValueListenableBuilder<String?>(
                valueListenable: _backgroundUrlNotifier,
                builder: (context, backgroundUrl, _) {
                  return _GroupBackground(
                    backgroundUrl: backgroundUrl,
                    accentColor: widget.accentColor,
                    groupMembersNotifier: _groupMembersNotifier,
                    groupDataNotifier: _groupDataNotifier,
                    replyingToNotifier: _replyingToNotifier,
                    keyboardHeightNotifier: _keyboardHeightNotifier,
                    chatId: widget.chatId,
                    currentUser: widget.currentUser,
                    onShowMessageActions: _showMessageActions,
                    onSendMessage: sendMessage,
                    onSendFile: sendFile,
                    onSendAudio: sendAudio,
                    onCancelReply: _onCancelReply,
                    accentColorWidget: widget.accentColor,
                  );
                },
              ),
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

class _GroupBackground extends StatelessWidget {
  final String? backgroundUrl;
  final Color accentColor;
  final ValueNotifier<List<Map<String, dynamic>>> groupMembersNotifier;
  final ValueNotifier<Map<String, dynamic>?> groupDataNotifier;
  final ValueNotifier<QueryDocumentSnapshot<Object?>?> replyingToNotifier;
  final ValueNotifier<double> keyboardHeightNotifier;
  final String chatId;
  final Map<String, dynamic> currentUser;
  final void Function(QueryDocumentSnapshot<Object?>, bool, GlobalKey) onShowMessageActions;
  final void Function(String) onSendMessage;
  final void Function(File) onSendFile;
  final void Function(File) onSendAudio;
  final VoidCallback onCancelReply;
  final Color accentColorWidget;

  const _GroupBackground({
    required this.backgroundUrl,
    required this.accentColor,
    required this.groupMembersNotifier,
    required this.groupDataNotifier,
    required this.replyingToNotifier,
    required this.keyboardHeightNotifier,
    required this.chatId,
    required this.currentUser,
    required this.onShowMessageActions,
    required this.onSendMessage,
    required this.onSendFile,
    required this.onSendAudio,
    required this.onCancelReply,
    required this.accentColorWidget,
  });

  @override
  Widget build(BuildContext context) {
    // keep background in RepaintBoundary so it doesn't repaint on list scroll
    return Container(
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
                  accentColor.withValues(alpha: 0.2),
                  Colors.transparent,
                ],
                stops: const [0.0, 1.0],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: accentColor.withValues(alpha: 0.1),
              ),
            ),
            child: Column(
              children: [
                // Messages area and typing area are isolated into small widgets
                Expanded(
                  child: _GroupMessagesWrapper(
                    groupId: chatId,
                    currentUser: currentUser,
                    groupMembersNotifier: groupMembersNotifier,
                    replyingToNotifier: replyingToNotifier,
                    onMessageLongPressed: onShowMessageActions,
                    onCancelReply: onCancelReply,
                  ),
                ),
                Container(
                  color: Colors.black.withValues(alpha: 0.5),
                  child: _GroupTypingAreaWrapper(
                    replyingToNotifier: replyingToNotifier,
                    keyboardHeightNotifier: keyboardHeightNotifier,
                    onSendMessage: onSendMessage,
                    onSendFile: onSendFile,
                    onSendAudio: onSendAudio,
                    accentColor: accentColorWidget,
                    currentUser: currentUser,
                    groupMembersNotifier: groupMembersNotifier,
                    onCancelReply: onCancelReply,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupMessagesWrapper extends StatelessWidget {
  final String groupId;
  final Map<String, dynamic> currentUser;
  final ValueNotifier<List<Map<String, dynamic>>> groupMembersNotifier;
  final ValueNotifier<QueryDocumentSnapshot<Object?>?> replyingToNotifier;
  final void Function(QueryDocumentSnapshot<Object?>, bool, GlobalKey) onMessageLongPressed;
  final VoidCallback onCancelReply;

  const _GroupMessagesWrapper({
    required this.groupId,
    required this.currentUser,
    required this.groupMembersNotifier,
    required this.replyingToNotifier,
    required this.onMessageLongPressed,
    required this.onCancelReply,
  });

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary so background repaints don't affect the list
    return RepaintBoundary(
      child: ValueListenableBuilder<QueryDocumentSnapshot<Object?>?>(
        valueListenable: replyingToNotifier,
        builder: (context, replyingTo, _) {
          return ValueListenableBuilder<List<Map<String, dynamic>>>(
            valueListenable: groupMembersNotifier,
            builder: (context, groupMembers, __) {
              return GroupChatList(
                groupId: groupId,
                currentUser: currentUser,
                groupMembers: groupMembers,
                onMessageLongPressed: onMessageLongPressed,
                replyingTo: replyingTo,
                onCancelReply: onCancelReply,
              );
            },
          );
        },
      ),
    );
  }
}

class _GroupTypingAreaWrapper extends StatelessWidget {
  final ValueNotifier<QueryDocumentSnapshot<Object?>?> replyingToNotifier;
  final ValueNotifier<double> keyboardHeightNotifier;
  final void Function(String) onSendMessage;
  final void Function(File) onSendFile;
  final void Function(File) onSendAudio;
  final VoidCallback onCancelReply;
  final Color accentColor;
  final Map<String, dynamic> currentUser;
  final ValueNotifier<List<Map<String, dynamic>>> groupMembersNotifier;

  const _GroupTypingAreaWrapper({
    required this.replyingToNotifier,
    required this.keyboardHeightNotifier,
    required this.onSendMessage,
    required this.onSendFile,
    required this.onSendAudio,
    required this.onCancelReply,
    required this.accentColor,
    required this.currentUser,
    required this.groupMembersNotifier,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<QueryDocumentSnapshot<Object?>?>(
      valueListenable: replyingToNotifier,
      builder: (context, replyingTo, _) {
        return ValueListenableBuilder<double>(
          valueListenable: keyboardHeightNotifier,
          builder: (context, kbHeight, __) {
            return Padding(
              padding: EdgeInsets.only(bottom: kbHeight),
              child: RepaintBoundary(
                child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                  valueListenable: groupMembersNotifier,
                  builder: (context, groupMembers, ___) {
                    final otherUser = groupMembers.isNotEmpty
                        ? groupMembers[0]
                        : {'id': 'xyz456', 'username': 'Group'};
                    return TypingArea(
                      onSendMessage: onSendMessage,
                      onSendFile: onSendFile,
                      onSendAudio: onSendAudio,
                      isGroup: true,
                      accentColor: accentColor,
                      replyingTo: replyingTo,
                      currentUser: currentUser,
                      otherUser: otherUser,
                      onCancelReply: onCancelReply,
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }
}

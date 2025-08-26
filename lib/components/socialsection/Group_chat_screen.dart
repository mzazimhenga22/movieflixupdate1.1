// group_chat_screen.dart
// Members bar moved inside the container at the top (sliding horizontal row).
// Typing area pinned to bottom; scaffold set to resizeToAvoidBottomInset:false.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'package:movie_app/webrtc/group_rtc_manager.dart';
import 'package:movie_app/utils/read_status_utils.dart';

// Make sure this import matches your project path
import 'package:movie_app/services/fcm_sender.dart' show sendFcmPush;

import 'Group_profile_screen.dart';
import 'widgets/GroupChatAppBar.dart';
import 'widgets/typing_area.dart';
import 'widgets/GroupChatList.dart';
import 'widgets/message_actions.dart';
import 'forward_message_screen.dart';
import 'VideoCallScreen_Group.dart';
import 'VoiceCallScreen_Group.dart';
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
  // ValueNotifiers to minimize rebuild surface
  final ValueNotifier<String?> _backgroundUrlNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<List<Map<String, dynamic>>> _groupMembersNotifier =
      ValueNotifier<List<Map<String, dynamic>>>([]);
  final ValueNotifier<Map<String, dynamic>?> _groupDataNotifier =
      ValueNotifier<Map<String, dynamic>?>(null);
  final ValueNotifier<QueryDocumentSnapshot<Object?>?> _replyingToNotifier =
      ValueNotifier<QueryDocumentSnapshot<Object?>?>(null);

  // Subscriptions - cancel them on dispose to avoid "used after disposed" crashes
  StreamSubscription<DocumentSnapshot<Object?>>? _groupDocSub;
  StreamSubscription<QuerySnapshot<Object?>>? _membersSub;
  StreamSubscription<QuerySnapshot<Object?>>? _incomingCallsSub;

  bool isActionOverlayVisible = false;
  late SharedPreferences prefs;
  Timer? _debounce;
  String? _activeCallId;

  bool _isDisposed = false; // guard to prevent notifier updates after dispose

  // Project ID matching your service-account.json used by sendFcmPush
  static const String _fcmProjectId = 'movieflix-53a51';

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
  }

  @override
  void dispose() {
    // Cancel subscriptions first so they won't call notifiers after we dispose them
    _groupDocSub?.cancel();
    _membersSub?.cancel();
    _incomingCallsSub?.cancel();

    // Cancel timers
    _debounce?.cancel();

    // Mark disposed before disposing notifiers
    _isDisposed = true;

    // Now dispose notifiers
    _backgroundUrlNotifier.dispose();
    _groupMembersNotifier.dispose();
    _groupDataNotifier.dispose();
    _replyingToNotifier.dispose();

    super.dispose();
  }

  Future<void> _loadChatBackground() async {
    final stored = prefs.getString('chat_background_${widget.chatId}');
    if (_isDisposed) return;
    if (_backgroundUrlNotifier.value != stored) {
      _backgroundUrlNotifier.value = stored;
    }
  }

  Future<void> _loadCachedGroupData() async {
    final cachedData = prefs.getString('group_data_${widget.chatId}');
    if (cachedData != null) {
      try {
        // compute + jsonDecode can be used safely to avoid blocking UI
        final decoded = await compute(jsonDecode, cachedData);
        if (_isDisposed) return;
        if (decoded is Map) {
          final data = Map<String, dynamic>.from(decoded as Map);
          final members = List<Map<String, dynamic>>.from(data['members'] ?? []);
          _groupDataNotifier.value = data;
          _groupMembersNotifier.value = members;
        }
      } catch (e) {
        debugPrint('Failed to load cached group data: $e');
      }
    }
  }

  Future<void> _cacheGroupData(Map<String, dynamic> data, List<Map<String, dynamic>> members) async {
    // Convert timestamps to ISO strings so preferences can store them safely
    final serializableData = _convertTimestamps(Map<String, dynamic>.from(data));
    final serializableMembers = members.map((m) => _convertTimestamps(Map<String, dynamic>.from(m))).toList();

    try {
      await prefs.setString(
        'group_data_${widget.chatId}',
        jsonEncode({
          ...serializableData,
          'members': serializableMembers,
        }),
      );
    } catch (e) {
      debugPrint('Failed to cache group data: $e');
    }
  }

  Map<String, dynamic> _convertTimestamps(Map<String, dynamic> map) {
    map.forEach((key, value) {
      if (value is Timestamp) {
        map[key] = value.toDate().toIso8601String();
      } else if (value is Map) {
        map[key] = _convertTimestamps(Map<String, dynamic>.from(value));
      } else if (value is List) {
        map[key] = value.map((item) {
          if (item is Timestamp) {
            return item.toDate().toIso8601String();
          } else if (item is Map) {
            return _convertTimestamps(Map<String, dynamic>.from(item));
          }
          return item;
        }).toList();
      }
    });
    return map;
  }

  Future<bool> _isUserBlocked(String userId) async {
    final userDoc = await FirebaseFirestore.instance.collection('users').doc(widget.currentUser['id']).get();
    final blockedUsers = List<String>.from(userDoc.data()?['blockedUsers'] ?? []);
    return blockedUsers.contains(userId);
  }

  void _loadGroupDataAndListen() {
    // Make sure to cancel previous subscription if any
    _groupDocSub?.cancel();

    _groupDocSub = FirebaseFirestore.instance.collection('groups').doc(widget.chatId).snapshots().listen((chatDoc) async {
      if (_isDisposed) return;

      // Update notifiers defensively
      final data = chatDoc.data();
      if (!_isDisposed) {
        _groupDataNotifier.value = data == null ? null : Map<String, dynamic>.from(data as Map<String, dynamic>);
      }
      if (!chatDoc.exists) return;

      final docData = chatDoc.data()!;
      final memberIds = List<String>.from((docData as Map<String, dynamic>)['userIds'] ?? []);

      // fetch members in parallel (first time snapshot)
      try {
        if (memberIds.isNotEmpty) {
          // chunking may be needed for very large groups (Firestore whereIn limit), but left simple for clarity
          final membersSnapshots = await Future.wait(memberIds.map((uid) => FirebaseFirestore.instance.collection('users').doc(uid).get()));
          final members = membersSnapshots.where((d) => d.exists).map((d) {
            final m = Map<String, dynamic>.from(d.data()!);
            m['id'] = d.id;
            return m;
          }).toList();

          if (!_isDisposed) {
            // update notifier without causing a full rebuild
            _groupMembersNotifier.value = members;
          }

          // cache for offline quick load
          await _cacheGroupData(Map<String, dynamic>.from(docData), members);
        } else {
          if (!_isDisposed) _groupMembersNotifier.value = [];
        }
      } catch (e) {
        debugPrint('Failed to fetch member docs: $e');
      }

      // observe member docs for updates but debounce UI refreshes
      // cancel existing members subscription before creating a new one
      _membersSub?.cancel();
      if (memberIds.isNotEmpty) {
        try {
          _membersSub = FirebaseFirestore.instance
              .collection('users')
              .where(FieldPath.documentId, whereIn: memberIds)
              .snapshots()
              .listen((snapshot) {
            if (_isDisposed) return;
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), () {
              // Refresh the members notifier without bubbling a full-screen setState
              if (_isDisposed) return;
              // If we have the latest members list, reassign to trigger ValueListenableBuilder listeners
              _groupMembersNotifier.value = List<Map<String, dynamic>>.from(_groupMembersNotifier.value);
            });
          });
        } catch (e) {
          // Firestore whereIn might throw if memberIds is empty or too large; handle gracefully
          debugPrint('Failed to start members listener: $e');
        }
      }

      // mark as read
      try {
        await markGroupAsRead(widget.chatId, widget.currentUser['id']);
      } catch (e) {
        debugPrint('Failed to mark group as read: $e');
      }
    }, onError: (err) {
      debugPrint('Group doc listen error: $err');
    });
  }

  /// Send a text message to the group and notify members via FCM (non-blocking).
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
        'replyToSenderName': _groupMembersNotifier.value
                .firstWhere((m) => m['id'] == _replyingToNotifier.value!['senderId'],
                    orElse: () => {'username': 'Unknown'})['username'] ??
            'Unknown',
      },
    };

    try {
      final msgRef = await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).collection('messages').add(messageData);

      // update group-level lastMessage / unreadBy
      final recipientIds = _groupMembersNotifier.value
          .map((m) => m['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty && id != widget.currentUser['id'])
          .toList();

      if (recipientIds.isNotEmpty) {
        await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).set({
          'lastMessage': text,
          'timestamp': FieldValue.serverTimestamp(),
          'unreadBy': FieldValue.arrayUnion(recipientIds),
        }, SetOptions(merge: true));
      } else {
        await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).set({
          'lastMessage': text,
          'timestamp': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      if (!_isDisposed) _replyingToNotifier.value = null;

      // Fire-and-forget: push notify group members (exclude sender)
      unawaited(_sendGroupPush(
        chatId: widget.chatId,
        senderId: widget.currentUser['id'],
        senderName: widget.currentUser['username'] ?? 'Someone',
        title: widget.currentUser['username'] ?? 'New message',
        body: text.length <= 120 ? text : '${text.substring(0, 117)}...',
        data: {
          'type': 'group_message',
          'groupId': widget.chatId,
          'messageId': msgRef.id,
          'senderId': widget.currentUser['id'],
          'senderName': widget.currentUser['username'] ?? 'Someone',
          'messageType': 'text',
          'text': text,
        },
      ));
    } catch (e, st) {
      debugPrint('sendGroupMessage error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to send message')));
      }
    }
  }

  void sendFile(File file) async {
    if (await _isUserBlocked(widget.currentUser['id'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot send file from blocked user')));
      }
      return;
    }

    try {
      // TODO: upload file to storage and retrieve URL; this is placeholder metadata
      final messageData = {
        'text': 'File',
        'fileName': file.path.split('/').last,
        'senderId': widget.currentUser['id'],
        'senderName': widget.currentUser['username'] ?? 'You',
        'timestamp': FieldValue.serverTimestamp(),
        'type': 'file',
        'reactions': [],
        'deletedFor': [],
        'readBy': [widget.currentUser['id']],
      };

      final msgRef = await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).collection('messages').add(messageData);

      final recipientIds = _groupMembersNotifier.value
          .map((m) => m['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty && id != widget.currentUser['id'])
          .toList();

      if (recipientIds.isNotEmpty) {
        await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).set({
          'lastMessage': 'Sent a file',
          'timestamp': FieldValue.serverTimestamp(),
          'unreadBy': FieldValue.arrayUnion(recipientIds),
        }, SetOptions(merge: true));
      } else {
        await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).set({
          'lastMessage': 'Sent a file',
          'timestamp': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      unawaited(_sendGroupPush(
        chatId: widget.chatId,
        senderId: widget.currentUser['id'],
        senderName: widget.currentUser['username'] ?? 'Someone',
        title: widget.currentUser['username'] ?? 'Sent a file',
        body: 'Sent a file',
        data: {
          'type': 'group_message',
          'groupId': widget.chatId,
          'messageId': msgRef.id,
          'senderId': widget.currentUser['id'],
          'senderName': widget.currentUser['username'] ?? 'Someone',
          'messageType': 'file',
          'text': 'Sent a file',
        },
      ));

      debugPrint("Sending file: ${file.path}");
    } catch (e, st) {
      debugPrint('sendGroupFile error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to send file')));
      }
    }
  }

  void sendAudio(File audio) async {
    if (await _isUserBlocked(widget.currentUser['id'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot send audio from blocked user')));
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
        'timestamp': FieldValue.serverTimestamp(),
        'type': 'audio',
        'reactions': [],
        'deletedFor': [],
        'readBy': [widget.currentUser['id']],
      };

      final msgRef = await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).collection('messages').add(messageData);

      final recipientIds = _groupMembersNotifier.value
          .map((m) => m['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty && id != widget.currentUser['id'])
          .toList();

      if (recipientIds.isNotEmpty) {
        await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).set({
          'lastMessage': 'Sent a voice message',
          'timestamp': FieldValue.serverTimestamp(),
          'unreadBy': FieldValue.arrayUnion(recipientIds),
        }, SetOptions(merge: true));
      } else {
        await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).set({
          'lastMessage': 'Sent a voice message',
          'timestamp': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      unawaited(_sendGroupPush(
        chatId: widget.chatId,
        senderId: widget.currentUser['id'],
        senderName: widget.currentUser['username'] ?? 'Someone',
        title: widget.currentUser['username'] ?? 'Sent a voice message',
        body: 'Sent a voice message',
        data: {
          'type': 'group_message',
          'groupId': widget.chatId,
          'messageId': msgRef.id,
          'senderId': widget.currentUser['id'],
          'senderName': widget.currentUser['username'] ?? 'Someone',
          'messageType': 'audio',
          'text': 'Sent a voice message',
        },
      ));

      debugPrint("Sending audio: ${audio.path}");
    } catch (e, st) {
      debugPrint('sendGroupAudio error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to send audio')));
      }
    }
  }

  /// Send push notifications to all group members except sender.
  /// Filters out users w/o fcmToken, users who've muted this chat (mutedChats), and users who've blocked the sender.
  Future<void> _sendGroupPush({
    required String chatId,
    required String senderId,
    required String senderName,
    required String title,
    required String body,
    Map<String, String>? data,
  }) async {
    try {
      // Read group doc to get the canonical member list (fallback to notifier if needed)
      final groupDoc = await FirebaseFirestore.instance.collection('groups').doc(chatId).get();
      final memberIds = groupDoc.exists
          ? List<String>.from(groupDoc.data()?['userIds'] ?? [])
          : _groupMembersNotifier.value.map((m) => (m['id'] as String?) ?? '').where((id) => id.isNotEmpty).toList();

      final targetIds = memberIds.where((id) => id != senderId).toSet().toList();
      if (targetIds.isEmpty) {
        debugPrint('[push] no recipients for group $chatId');
        return;
      }

      // Fetch tokens in parallel (limit concurrency in production)
      final tokenFutures = targetIds.map((uid) async {
        try {
          final udoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
          if (!udoc.exists) return null;
          final udata = udoc.data()!;
          final fcmToken = (udata['fcmToken'] as String?) ?? '';
          final mutedChats = List<String>.from(udata['mutedChats'] ?? []);
          final blockedUsers = List<String>.from(udata['blockedUsers'] ?? []);

          // Skip if no token or if user muted this chat or user blocked the sender
          if (fcmToken.isEmpty) return null;
          if (mutedChats.contains(chatId)) {
            debugPrint('[push] user $uid muted chat $chatId - skip');
            return null;
          }
          if (blockedUsers.contains(senderId)) {
            debugPrint('[push] user $uid blocked sender $senderId - skip');
            return null;
          }
          return fcmToken;
        } catch (e) {
          debugPrint('[push] failed to fetch user doc for $uid: $e');
          return null;
        }
      }).toList();

      final tokensWithNulls = await Future.wait(tokenFutures);
      final tokens = tokensWithNulls.whereType<String>().toSet().toList(); // deduplicate

      if (tokens.isEmpty) {
        debugPrint('[push] no valid tokens after filtering for group $chatId');
        return;
      }

      // Send to each token (fire-and-forget)
      for (final token in tokens) {
        try {
          final extraData = <String, String>{};
          if (data != null) extraData.addAll(data);
          // sendFcmPush signature used in chat_screen: fcmToken, projectId, title, body, extraData
          unawaited(sendFcmPush(
            fcmToken: token,
           
            title: title,
            body: body,
            extraData: extraData,
          ));
        } catch (e) {
          debugPrint('[push] failed to call sendFcmPush for token: $e');
        }
      }

      debugPrint('[push] group push queued for ${tokens.length} tokens (group $chatId)');
    } catch (e, st) {
      debugPrint('[push] error preparing group push: $e\n$st');
    }
  }

  Future<void> startGroupCall(bool isVideo) async {
    if (await _isUserBlocked(widget.currentUser['id'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot initiate call from blocked user')));
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
          if (mounted) {
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
            if (mounted) setState(() => _activeCallId = null);
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
        if (mounted) setState(() => _activeCallId = null);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to start call: $e')));
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
        await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).set({
          'pinnedMessageId': message.id,
          'pinnedMessageText': message['text'],
          'pinnedMessageSenderId': message['senderId'],
        }, SetOptions(merge: true));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(color: widget.accentColor, borderRadius: BorderRadius.circular(8.0)),
              child: Text(message['text'], style: const TextStyle(color: Colors.black)),
            ),
          ));
          setState(() => isActionOverlayVisible = false);
        }
      },
      onDelete: () async {
        final data = message.data() as Map<String, dynamic>;
        final deletedFor = List<String>.from(data['deletedFor'] ?? []);
        deletedFor.add(widget.currentUser['id']);

        await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).collection('messages').doc(message.id).update({'deletedFor': deletedFor});

        final chatDoc = await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).get();
        if (chatDoc.exists && chatDoc['pinnedMessageId'] == message.id) {
          await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).update({'pinnedMessageId': null});
        }

        if (mounted) {
          Navigator.of(context, rootNavigator: false).pop();
          setState(() => isActionOverlayVisible = false);
        }
      },
      onBlock: () async {
        await FirebaseFirestore.instance.collection('users').doc(widget.currentUser['id']).update({
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
            settings: RouteSettings(arguments: {'message': message, 'currentUser': widget.currentUser, 'isForwarded': true}),
          ),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message forwarded')));
          Navigator.of(context, rootNavigator: false).pop();
          setState(() => isActionOverlayVisible = false);
        }
      },
      onEdit: () async {
        if (isMe) {
          await Navigator.pushNamed(context, '/editMessage', arguments: {'message': message, 'chatId': widget.chatId});
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot edit others\' messages')));
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
          await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).collection('messages').doc(message.id).update({
            'reactions': FieldValue.arrayRemove([emoji])
          });
        } else {
          await FirebaseFirestore.instance.collection('groups').doc(widget.chatId).collection('messages').doc(message.id).update({
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
    // Cancel previous if any
    _incomingCallsSub?.cancel();

    _incomingCallsSub = FirebaseFirestore.instance
        .collection('groupCalls')
        .where('groupId', isEqualTo: widget.chatId)
        .where('status', isEqualTo: 'ringing')
        .snapshots()
        .listen((snapshot) {
      if (_isDisposed) return;
      if (snapshot.docs.isEmpty) return;

      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final callId = doc.id;
        final isIncoming = data['callerId'] != widget.currentUser['id'];

        if (mounted && _activeCallId == null && isIncoming) {
          setState(() => _activeCallId = callId);

          final callScreen = data['type'] == 'video'
              ? VideoCallScreenGroup(callId: callId, callerId: data['callerId'], groupId: widget.chatId, participants: _groupMembersNotifier.value)
              : VoiceCallScreen(callId: callId, callerId: data['callerId'], groupId: widget.chatId, receiverId: widget.currentUser['id'], participants: _groupMembersNotifier.value);

          Navigator.push(context, MaterialPageRoute(builder: (_) => callScreen)).then((_) {
            if (mounted) setState(() => _activeCallId = null);
          });
        }
      }
    }, onError: (err) {
      debugPrint('Incoming calls listen error: $err');
    });
  }

  // Reusable bottom sheet for group actions (replaces the old FAB)
  void _showGroupActionsBottomSheet() {
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
                  backgroundImage: (widget.currentUser['avatarUrl'] != null) ? NetworkImage(widget.currentUser['avatarUrl']) : null,
                  backgroundColor: widget.accentColor.withOpacity(0.2),
                  child: widget.currentUser['avatarUrl'] == null ? const Icon(Icons.person) : null,
                ),
                title: Text(_groupDataNotifier.value?['name'] ?? 'Group'),
                subtitle: Text(
                  '${_groupMembersNotifier.value.length} members',
                  style: TextStyle(color: Colors.white70),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.info_outline),
                  color: widget.accentColor,
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => GroupProfileScreen(groupId: widget.chatId, currentUserId: widget.currentUser['id'])));
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
                      startGroupCall(false);
                    },
                    icon: const Icon(Icons.call),
                    label: const Text('Voice'),
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: widget.accentColor),
                    onPressed: () {
                      Navigator.pop(ctx);
                      startGroupCall(true);
                    },
                    icon: const Icon(Icons.videocam),
                    label: const Text('Video'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(side: BorderSide(color: widget.accentColor)),
                    onPressed: () {
                      Navigator.pop(ctx);
                      // future: open invite / share
                    },
                    icon: const Icon(Icons.person_add),
                    label: const Text('Invite'),
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
        // IMPORTANT: prevent scaffold from resizing the whole page when keyboard opens
        resizeToAvoidBottomInset: false,
        extendBodyBehindAppBar: false,
        backgroundColor: Colors.transparent,
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
                onGroupInfoTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GroupProfileScreen(groupId: widget.chatId, currentUserId: widget.currentUser['id']))),
                onVideoCall: () => startGroupCall(true),
                onVoiceCall: () => startGroupCall(false),
                accentColor: widget.accentColor,
              );
            },
          ),
        ),
        body: Stack(
          children: [
            // Background (image/gradient overlay)
            ValueListenableBuilder<String?>(
              valueListenable: _backgroundUrlNotifier,
              builder: (context, backgroundUrl, _) {
                return _GroupBackground(backgroundUrl: backgroundUrl, accentColor: widget.accentColor);
              },
            ),

            // Foreground column with features bar + messages + pinned bottom (typing)
            Column(
              children: [
                // Compact group features bar (above container)
                SafeArea(
                  top: false,
                  child: GroupFeaturesBar(
                    groupDataNotifier: _groupDataNotifier,
                    accentColor: widget.accentColor,
                    onInfoTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GroupProfileScreen(groupId: widget.chatId, currentUserId: widget.currentUser['id']))),
                    onVoiceCall: () => startGroupCall(false),
                    onVideoCall: () => startGroupCall(true),
                    onActions: _showGroupActionsBottomSheet,
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

                        // Use a Stack so messages area stays stable, members bar sits at the top of this container,
                        // and only the pinned bottom typing area animates when the keyboard opens.
                        child: Stack(
                          children: [
                            // Messages: fill the available space (won't be relaid out on keyboard)
                            Positioned.fill(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  // dismiss keyboard when tapping messages area
                                  FocusScope.of(context).unfocus();
                                },
                                // add top padding so messages are not covered by the members bar overlay
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 80.0), // match members bar height + spacing
                                  child: RepaintBoundary(
                                    child: _GroupMessagesWrapper(
                                      groupId: widget.chatId,
                                      currentUser: widget.currentUser,
                                      groupMembersNotifier: _groupMembersNotifier,
                                      replyingToNotifier: _replyingToNotifier,
                                      onMessageLongPressed: _showMessageActions,
                                      onCancelReply: _onCancelReply,
                                      onReplyToMessage: _onReplyToMessage, // forward taps from list to set reply target
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            // MEMBERS BAR: placed at the top INSIDE the container and slides horizontally
                            Positioned(
                              top: 8,
                              left: 8,
                              right: 8,
                              child: Container(
                                // translucent background to visually separate from messages
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.28),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: widget.accentColor.withOpacity(0.04)),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                                child: _GroupMembersBar(
                                  groupMembersNotifier: _groupMembersNotifier,
                                  accentColor: widget.accentColor,
                                  chatId: widget.chatId,
                                  currentUserId: widget.currentUser['id'] as String? ?? '',
                                ),
                              ),
                            ),

                            // Pinned bottom: typing area animate only bottom inset
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: AnimatedPadding(
                                padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
                                duration: const Duration(milliseconds: 160),
                                curve: Curves.easeOut,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Typing area wrapper
                                    Container(
                                      color: Colors.black.withOpacity(0.55),
                                      child: _GroupTypingAreaWrapper(
                                        replyingToNotifier: _replyingToNotifier,
                                        onSendMessage: sendMessage,
                                        onSendFile: sendFile,
                                        onSendAudio: sendAudio,
                                        onCancelReply: _onCancelReply,
                                        accentColor: widget.accentColor,
                                        currentUser: widget.currentUser,
                                        groupMembersNotifier: _groupMembersNotifier,
                                      ),
                                    ),
                                  ],
                                ),
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

class GroupFeaturesBar extends StatelessWidget {
  final ValueNotifier<Map<String, dynamic>?> groupDataNotifier;
  final Color accentColor;
  final VoidCallback onInfoTap;
  final VoidCallback onVoiceCall;
  final VoidCallback onVideoCall;
  final VoidCallback onActions;

  const GroupFeaturesBar({
    required this.groupDataNotifier,
    required this.accentColor,
    required this.onInfoTap,
    required this.onVoiceCall,
    required this.onVideoCall,
    required this.onActions,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: groupDataNotifier,
      builder: (context, groupData, _) {
        final name = groupData?['name'] ?? 'Group';
        final avatarUrl = groupData?['avatarUrl'] as String? ?? '';
        final membersCount = (groupData?['userIds'] as List?)?.length ?? 0;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onInfoTap,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                      backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
                      child: avatarUrl.isEmpty ? const Icon(Icons.group) : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
                          const SizedBox(height: 2),
                          Text('$membersCount members', style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.75))),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: onVoiceCall,
                      icon: Icon(Icons.call, color: accentColor),
                      tooltip: 'Start voice call',
                    ),
                    IconButton(
                      onPressed: onVideoCall,
                      icon: Icon(Icons.videocam, color: accentColor),
                      tooltip: 'Start video call',
                    ),
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
      },
    );
  }
}

// Background widget now only manages background image/overlay (cheap)
class _GroupBackground extends StatelessWidget {
  final String? backgroundUrl;
  final Color accentColor;
  const _GroupBackground({this.backgroundUrl, required this.accentColor});

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
              color: Colors.black.withOpacity(0.25),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupMembersBar extends StatelessWidget {
  final ValueNotifier<List<Map<String, dynamic>>> groupMembersNotifier;
  final Color accentColor;
  final String chatId;
  final String currentUserId;

  const _GroupMembersBar({
    required this.groupMembersNotifier,
    required this.accentColor,
    required this.chatId,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    // Fixed height small bar - sliding horizontal avatars
    return RepaintBoundary(
      child: ValueListenableBuilder<List<Map<String, dynamic>>>(
        valueListenable: groupMembersNotifier,
        builder: (context, members, _) {
          final showMembers = members.isNotEmpty;
          final count = members.isNotEmpty ? (members.length > 20 ? members.length : members.length) : 0;

          return Row(
            children: [
              if (showMembers)
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      itemCount: count + 1, // +1 for trailing group icon
                      itemBuilder: (context, index) {
                        if (index < members.length) {
                          final member = members[index];
                          final avatarUrl = (member['avatarUrl'] as String?) ?? '';
                          return Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: GestureDetector(
                              onTap: () {
                                Navigator.pushNamed(
                                  context,
                                  '/profile',
                                  arguments: {
                                    ...member,
                                  },
                                );
                              },
                              child: CircleAvatar(
                                radius: 20,
                                backgroundColor: accentColor.withOpacity(0.12),
                                backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
                                child: avatarUrl.isEmpty ? const Icon(Icons.person, size: 18) : null,
                              ),
                            ),
                          );
                        } else {
                          // trailing group icon
                          return Padding(
                            padding: const EdgeInsets.only(left: 6.0),
                            child: Material(
                              color: Colors.transparent,
                              child: IconButton(
                                icon: Icon(Icons.group, color: accentColor),
                                tooltip: 'Group info',
                                onPressed: () {
                                  Navigator.push(context, MaterialPageRoute(builder: (_) => GroupProfileScreen(groupId: chatId, currentUserId: currentUserId)));
                                },
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                )
              else
                const Spacer(),
            ],
          );
        },
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
  final void Function(QueryDocumentSnapshot<Object?> message)? onReplyToMessage;

  const _GroupMessagesWrapper({
    required this.groupId,
    required this.currentUser,
    required this.groupMembersNotifier,
    required this.replyingToNotifier,
    required this.onMessageLongPressed,
    required this.onCancelReply,
    this.onReplyToMessage,
  });

  @override
  Widget build(BuildContext context) {
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
                onReplyToMessage: onReplyToMessage,
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
  final void Function(String) onSendMessage;
  final void Function(File) onSendFile;
  final void Function(File) onSendAudio;
  final VoidCallback onCancelReply;
  final Color accentColor;
  final Map<String, dynamic> currentUser;
  final ValueNotifier<List<Map<String, dynamic>>> groupMembersNotifier;

  const _GroupTypingAreaWrapper({
    required this.replyingToNotifier,
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
    // Keep typing area isolated; let Scaffold handle keyboard insets
    return ValueListenableBuilder<QueryDocumentSnapshot<Object?>?>(
      valueListenable: replyingToNotifier,
      builder: (context, replyingTo, _) {
        return RepaintBoundary(
          child: SafeArea(
            top: false,
            bottom: true,
            child: ValueListenableBuilder<List<Map<String, dynamic>>>(
              valueListenable: groupMembersNotifier,
              builder: (context, groupMembers, __) {
                final otherUser = groupMembers.isNotEmpty ? groupMembers[0] : {'id': 'group', 'username': 'Group'};
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
  }
}

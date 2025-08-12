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
import 'package:cached_network_image/cached_network_image.dart';
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

class _GroupChatScreenState extends State<GroupChatScreen> with AutomaticKeepAliveClientMixin {
  String? backgroundUrl;
  List<Map<String, dynamic>> groupMembers = [];
  Map<String, dynamic>? groupData;
  QueryDocumentSnapshot<Object?>? replyingTo;
  bool isActionOverlayVisible = false;
  late SharedPreferences prefs;
  final _kbBridge = NativeKeyboardBridge();
  Timer? _debounce;
  String? _activeCallId;
  final ValueNotifier<String?> _backgroundUrlNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<QueryDocumentSnapshot<Object?>?> _replyingToNotifier = ValueNotifier<QueryDocumentSnapshot<Object?>?>(null);

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
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _kbBridge.keyboardHeight.removeListener(_onKeyboardHeightChanged);
    _debounce?.cancel();
    _backgroundUrlNotifier.dispose();
    _replyingToNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadChatBackground() async {
    if (mounted) {
      _backgroundUrlNotifier.value = prefs.getString('chat_background_${widget.chatId}');
    }
  }

  Future<void> _loadCachedGroupData() async {
    final cachedData = prefs.getString('group_data_${widget.chatId}');
    if (cachedData != null) {
      final data = await compute(jsonDecode, cachedData) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          groupData = data;
          groupMembers = List<Map<String, dynamic>>.from(data['members'] ?? []);
        });
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

  Map<String, dynamic> _convertTimestamps(Map<String, dynamic> map) {
    map.forEach((key, value) {
      if (value is Timestamp) {
        map[key] = value.toDate().toIso8601String();
      } else if (value is Map<String, dynamic>) {
        map[key] = _convertTimestamps(value);
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
            if (mounted) setState(() {});
            return;
          }

          final memberIds = List<String>.from(chatDoc.data()?['userIds'] ?? []);
          final membersSnapshots = await Future.wait(memberIds.map(
            (uid) => FirebaseFirestore.instance.collection('users').doc(uid).get(),
          ));

          final members = membersSnapshots
              .where((doc) => doc.exists)
              .map((doc) => doc.data()!..['id'] = doc.id)
              .toList();

          if (mounted) {
            setState(() {
              groupData = chatDoc.data();
              groupMembers = members;
            });
          }

          await _cacheGroupData(chatDoc.data()!, members);

          FirebaseFirestore.instance
              .collection('users')
              .where(FieldPath.documentId, whereIn: memberIds)
              .snapshots()
              .listen((snapshot) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () {
                  if (mounted) setState(() {});
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
        'replyToSenderName': groupMembers.firstWhere(
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
          groupMembers.map((m) => m['id']).where((id) => id != widget.currentUser['id']).toList()),
    }, SetOptions(merge: true));

    if (mounted) _replyingToNotifier.value = null;
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
          _activeCallId = callId;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => isVideo
                  ? VideoCallScreenGroup(
                      callId: callId,
                      callerId: widget.currentUser['id'],
                      groupId: widget.chatId,
                      participants: groupMembers,
                    )
                  : VoiceCallScreen(
                      callId: callId,
                      callerId: widget.currentUser['id'],
                      groupId: widget.chatId,
                      receiverId: widget.currentUser['id'],
                      participants: groupMembers,
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
        participants: groupMembers,
        isVideo: isVideo,
      );

      await FirebaseFirestore.instance.collection('groupCalls').doc(callId).set({
        'type': isVideo ? 'video' : 'voice',
        'callerId': widget.currentUser['id'],
        'groupId': widget.chatId,
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'ringing',
        'participants': groupMembers.map((m) => m['id']).toList(),
        'participantStatus': {widget.currentUser['id']: 'joined'},
      });

      if (mounted) {
        _activeCallId = callId;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => isVideo
                ? VideoCallScreenGroup(
                    callId: callId,
                    callerId: widget.currentUser['id'],
                    groupId: widget.chatId,
                    participants: groupMembers,
                  )
                : VoiceCallScreen(
                    callId: callId,
                    callerId: widget.currentUser['id'],
                    groupId: widget.chatId,
                    receiverId: widget.currentUser['id'],
                    participants: groupMembers,
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
    if (mounted) _replyingToNotifier.value = message;
  }

  void _onCancelReply() {
    if (mounted) _replyingToNotifier.value = null;
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
          isActionOverlayVisible = false;
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
          isActionOverlayVisible = false;
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
          isActionOverlayVisible = false;
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
          isActionOverlayVisible = false;
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
              _activeCallId = callId;

              final callScreen = data['type'] == 'video'
                  ? VideoCallScreenGroup(
                      callId: callId,
                      callerId: data['callerId'],
                      groupId: widget.chatId,
                      participants: groupMembers,
                    )
                  : VoiceCallScreen(
                      callId: callId,
                      callerId: data['callerId'],
                      groupId: widget.chatId,
                      receiverId: widget.currentUser['id'],
                      participants: groupMembers,
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
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return PresenceWrapper(
      userId: widget.currentUser['id'],
      groupIds: [widget.chatId],
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: GroupChatAppBar(
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
          ),
        ),
        body: Stack(
          children: [
            ValueListenableBuilder<String?>(
              valueListenable: _backgroundUrlNotifier,
              builder: (context, backgroundUrl, _) {
                return Stack(
                  children: [
                    if (backgroundUrl != null)
                      Positioned.fill(
                        child: CachedNetworkImage(
                          imageUrl: backgroundUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => const SizedBox.shrink(),
                          errorWidget: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      ),
                    Positioned.fill(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                        child: Container(
                          color: Colors.black.withOpacity(0.2),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            Column(
              children: [
                SizedBox(height: kToolbarHeight + MediaQuery.of(context).padding.top),
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
                          Expanded(
                            child: RepaintBoundary(
                              child: ValueListenableBuilder<QueryDocumentSnapshot<Object?>?>(
                                valueListenable: _replyingToNotifier,
                                builder: (context, replyingTo, _) {
                                  return GroupChatList(
                                    groupId: widget.chatId,
                                    currentUser: widget.currentUser,
                                    groupMembers: groupMembers,
                                    onMessageLongPressed: _showMessageActions,
                                    replyingTo: replyingTo,
                                    onCancelReply: _onCancelReply,
                                  );
                                },
                              ),
                            ),
                          ),
                          Container(
                            color: Colors.black.withOpacity(0.5),
                            child: RepaintBoundary(
                              child: ValueListenableBuilder<QueryDocumentSnapshot<Object?>?>(
                                valueListenable: _replyingToNotifier,
                                builder: (context, replyingTo, _) {
                                  return TypingArea(
                                    onSendMessage: sendMessage,
                                    onSendFile: sendFile,
                                    onSendAudio: sendAudio,
                                    isGroup: true,
                                    accentColor: widget.accentColor,
                                    replyingTo: replyingTo,
                                    currentUser: widget.currentUser,
                                    otherUser: groupMembers.isNotEmpty
                                        ? groupMembers[0]
                                        : {'id': 'xyz456', 'username': 'Group'},
                                    onCancelReply: _onCancelReply,
                                  );
                                },
                              ),
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
// messages_controller.dart
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'Group_chat_screen.dart';
import 'create_group_screen.dart';
import 'chat_screen.dart';

String getChatId(String userId1, String userId2) =>
    userId1.compareTo(userId2) < 0 ? '${userId1}_$userId2' : '${userId2}_$userId1';

/// Lightweight summary for the chat list UI (like WhatsApp conversation row).
class ChatSummary {
  final String id;
  bool isGroup;
  String title;
  Map<String, dynamic>? otherUser;
  String lastMessageText;
  DateTime timestamp;
  int unreadCount; // 0 or >0, kept simple (WhatsApp-like badge)
  bool isPinned;
  bool isMuted;
  bool isBlocked;

  ChatSummary({
    required this.id,
    this.isGroup = false,
    this.title = '',
    this.otherUser,
    this.lastMessageText = '',
    DateTime? timestamp,
    this.unreadCount = 0,
    this.isPinned = false,
    this.isMuted = false,
    this.isBlocked = false,
  }) : timestamp = timestamp ?? DateTime.fromMillisecondsSinceEpoch(0);

  Map<String, dynamic> toCache() => {
        'id': id,
        'isGroup': isGroup,
        'title': title,
        'otherUser': otherUser,
        'lastMessageText': lastMessageText,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'unreadCount': unreadCount,
        'isPinned': isPinned,
        'isMuted': isMuted,
        'isBlocked': isBlocked,
      };

  factory ChatSummary.fromCache(Map<String, dynamic> map) {
    return ChatSummary(
      id: map['id'] ?? '',
      isGroup: map['isGroup'] ?? false,
      title: map['title'] ?? '',
      otherUser:
          map['otherUser'] != null ? Map<String, dynamic>.from(map['otherUser']) : null,
      lastMessageText: map['lastMessageText'] ?? '',
      timestamp: map['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['timestamp'])
          : DateTime.fromMillisecondsSinceEpoch(0),
      unreadCount: map['unreadCount'] ?? 0,
      isPinned: map['isPinned'] ?? false,
      isMuted: map['isMuted'] ?? false,
      isBlocked: map['isBlocked'] ?? false,
    );
  }
}

/// Outbox item model (kept simple — stored as map)
class _OutboxItem {
  String localId; // local generated id
  String chatId;
  bool isGroup;
  Map<String, dynamic> message; // minimal message payload
  int attempts;
  int nextRetryAtEpochMs;

  _OutboxItem({
    required this.localId,
    required this.chatId,
    required this.isGroup,
    required this.message,
    this.attempts = 0,
    int? nextRetryAtEpochMs,
  }) : nextRetryAtEpochMs = nextRetryAtEpochMs ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
        'localId': localId,
        'chatId': chatId,
        'isGroup': isGroup,
        'message': message,
        'attempts': attempts,
        'nextRetryAtEpochMs': nextRetryAtEpochMs,
      };

  factory _OutboxItem.fromMap(Map<String, dynamic> m) {
    return _OutboxItem(
      localId: m['localId'] ?? '',
      chatId: m['chatId'] ?? '',
      isGroup: m['isGroup'] ?? false,
      message: Map<String, dynamic>.from(m['message'] ?? {}),
      attempts: m['attempts'] ?? 0,
      nextRetryAtEpochMs: m['nextRetryAtEpochMs'] ?? DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class MessagesController extends ChangeNotifier {
  final Map<String, dynamic> currentUser;
  final BuildContext context;

  // Publicly consumable list (UI should read this)
  final List<ChatSummary> chatSummaries = [];

  // Public simple unread badge total (UI can show on app icon or tab)
  int totalUnread = 0;

  // Local caches for quick checks (persisted)
  final List<String> _blockedUsers = [];
  final List<String> _mutedUsers = [];
  final List<String> _pinnedChats = [];

  // small in-memory user cache to avoid repeated lookups
  final Map<String, Map<String, dynamic>> _userCache = {};

  // Firestore listeners/subscriptions
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _chatsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _groupsSub;

  // typing + presence subscriptions (created on demand)
  final Map<String, StreamSubscription<QuerySnapshot<Map<String, dynamic>>>> _typingListeners = {};
  final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>> _presenceListeners = {};

  // to avoid duplicate last-message fetches on many rapid doc changes
  // we now store tokens "<chatId>|<isGroupFlag>"
  final Set<String> _pendingLastMessageFetches = {};

  // queue + concurrency limiter
  final Queue<String> _fetchQueue = Queue<String>();
  int _activeFetches = 0;
  static const int _maxConcurrentFetches = 5;

  // Debounce for snapshot bursts
  Timer? _docsChangedDebounce;

  // SharedPrefs key prefix
  String get _prefsPrefix => 'msgs_${currentUser['id'] ?? 'unknown'}';

  // ---------- Outbox ----------
  final List<_OutboxItem> _outbox = [];
  Timer? _outboxTimer;
  bool _outboxProcessing = false;

  // ---------- Random for local ids ----------
  final Random _random = Random();

  MessagesController(this.currentUser, this.context) {
    _loadCachedLists().whenComplete(() {
      _startRealtimeListeners();
      // load outbox and start processing it
      _loadOutbox().whenComplete(() => _scheduleOutboxProcessing(immediate: true));
    });
  }

  // ---------------------
  // Caching helpers
  // ---------------------
  Future<void> _loadCachedLists() async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null || uid.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final blockedRaw = prefs.getString('blockedUsers_$uid');
      final mutedRaw = prefs.getString('mutedUsers_$uid');
      final pinnedRaw = prefs.getString('pinnedChats_$uid');

      _blockedUsers
        ..clear()
        ..addAll(_safeDecodeStringList(blockedRaw));
      _mutedUsers
        ..clear()
        ..addAll(_safeDecodeStringList(mutedRaw));
      _pinnedChats
        ..clear()
        ..addAll(_safeDecodeStringList(pinnedRaw));

      // load cached chats if present (so UI is instant)
      final chatsRaw = prefs.getString('${_prefsPrefix}_chatSummaries');
      if (chatsRaw != null) {
        final decoded = jsonDecode(chatsRaw);
        if (decoded is List) {
          chatSummaries.clear();
          for (var item in decoded) {
            if (item is Map) {
              chatSummaries.add(ChatSummary.fromCache(Map<String, dynamic>.from(item)));
            }
          }
          _recomputeTotalUnread();
          notifyListeners();
        }
      }
    } catch (e, st) {
      debugPrint('[MessagesController] _loadCachedLists error: $e\n$st');
    }
  }

  List<String> _safeDecodeStringList(String? raw) {
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map((e) => e?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .cast<String>()
            .toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  Future<void> _saveCachedLists() async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null || uid.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('blockedUsers_$uid', jsonEncode(_blockedUsers));
      await prefs.setString('mutedUsers_$uid', jsonEncode(_mutedUsers));
      await prefs.setString('pinnedChats_$uid', jsonEncode(_pinnedChats));
      // cache chat summaries
      final cached = chatSummaries.map((c) => c.toCache()).toList();
      await prefs.setString('${_prefsPrefix}_chatSummaries', jsonEncode(cached));
      // save outbox too
      await _saveOutbox();
    } catch (e, st) {
      debugPrint('[MessagesController] _saveCachedLists error: $e\n$st');
    }
  }

  // ---------------------
  // Outbox persistence + processing
  // ---------------------
  Future<void> _loadOutbox() async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null || uid.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('${_prefsPrefix}_outbox');
      _outbox.clear();
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              try {
                _outbox.add(_OutboxItem.fromMap(Map<String, dynamic>.from(item)));
              } catch (_) {}
            }
          }
        }
      }
    } catch (e, st) {
      debugPrint('[MessagesController] _loadOutbox error: $e\n$st');
    }
  }

  Future<void> _saveOutbox() async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null || uid.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final list = _outbox.map((o) => o.toMap()).toList();
      await prefs.setString('${_prefsPrefix}_outbox', jsonEncode(list));
    } catch (e, st) {
      debugPrint('[MessagesController] _saveOutbox error: $e\n$st');
    }
  }

  void _scheduleOutboxProcessing({bool immediate = false}) {
    _outboxTimer?.cancel();
    if (immediate) {
      // run almost immediately
      _outboxTimer = Timer(const Duration(milliseconds: 200), () => _processOutbox());
    } else {
      // process periodically; every 10s when there are items
      _outboxTimer = Timer.periodic(const Duration(seconds: 10), (_) => _processOutbox());
    }
  }

  Future<void> _processOutbox() async {
    if (_outboxProcessing) return;
    if (_outbox.isEmpty) return;
    _outboxProcessing = true;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      // work on a copy to avoid mutation issues while iterating
      final itemsDue = _outbox.where((o) => o.nextRetryAtEpochMs <= nowMs).toList();
      for (final item in itemsDue) {
        final success = await _attemptSendOutboxItem(item);
        if (success) {
          _outbox.removeWhere((o) => o.localId == item.localId);
          await _saveOutbox();
        } else {
          // increase attempts and schedule next retry using exponential backoff (capped)
          item.attempts = item.attempts + 1;
          final backoffMs = _computeBackoffMs(item.attempts);
          item.nextRetryAtEpochMs = DateTime.now().millisecondsSinceEpoch + backoffMs;
          await _saveOutbox();
        }
      }
    } catch (e, st) {
      debugPrint('[MessagesController] _processOutbox error: $e\n$st');
    } finally {
      _outboxProcessing = false;
    }
  }

  int _computeBackoffMs(int attempts) {
    // exponential backoff with jitter, capped at 5 minutes
    final base = pow(2, min(attempts, 10)).toInt() * 1000;
    final jitter = _random.nextInt(1000);
    return min(base + jitter, 5 * 60 * 1000);
  }

  Future<bool> _attemptSendOutboxItem(_OutboxItem item) async {
    try {
      final messagesCol = FirebaseFirestore.instance
          .collection(item.isGroup ? 'groups' : 'chats')
          .doc(item.chatId)
          .collection('messages');

      // write message doc using the provided localId as a stable id to avoid duplicates
      final messageId = item.localId;
      final messageData = Map<String, dynamic>.from(item.message);
      // Ensure timestamp is a Firestore Timestamp when possible
      if (messageData['timestamp'] == null) messageData['timestamp'] = FieldValue.serverTimestamp();

      await messagesCol.doc(messageId).set(messageData);
      // update parent doc with lastMessage + timestamp + unreadBy similarly to other code
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final parentRef = FirebaseFirestore.instance.collection(item.isGroup ? 'groups' : 'chats').doc(item.chatId);
        final parentSnap = await tx.get(parentRef);
        final parentData = parentSnap.exists ? (parentSnap.data() as Map<String, dynamic>?) : null;
        final textSnippet = (messageData['text'] is String && (messageData['text'] as String).isNotEmpty)
            ? messageData['text']
            : (messageData['type'] == 'media' ? 'Media' : '');

        final tsValue = messageData['timestamp'] is Timestamp ? messageData['timestamp'] : FieldValue.serverTimestamp();

        final updateData = <String, dynamic>{
          'lastMessage': textSnippet,
          'timestamp': tsValue,
        };

        // Build unreadBy: all userIds in parent doc except sender
        if (parentData != null && parentData.containsKey('userIds')) {
          final userIds = List<dynamic>.from(parentData['userIds'] ?? []);
          final senderId = messageData['senderId'];
          final recipientIds = userIds.where((id) => id != senderId).toList().cast<String>();
          if (recipientIds.isNotEmpty) updateData['unreadBy'] = FieldValue.arrayUnion(recipientIds);
        }

        tx.set(parentRef, updateData, SetOptions(merge: true));
      });

      // Optimistically update in-memory summary for immediate UI feedback
      final idx = chatSummaries.indexWhere((c) => c.id == item.chatId && c.isGroup == item.isGroup);
      final timestamp = DateTime.now();
      if (idx >= 0) {
        final s = chatSummaries[idx];
        final text = (messageData['text'] as String?) ?? (messageData['type'] == 'media' ? 'Media' : '');
        s.lastMessageText = text;
        s.timestamp = timestamp.isAfter(s.timestamp) ? timestamp : s.timestamp;
        s.unreadCount = 0; // since sender has read it
        _recomputeTotalUnread();
        _saveCachedLists();
        notifyListeners();
      }

      return true;
    } catch (e, st) {
      debugPrint('[MessagesController] _attemptSendOutboxItem failed: $e\n$st');
      return false;
    }
  }

  

  /// Public API: send a message (will attempt immediately; if network fails it goes to outbox)
  /// messagePayload should include at least: senderId, text or type, optionally attachments, timestamp (optional)
  Future<void> sendMessage(String chatId, Map<String, dynamic> messagePayload, {required bool isGroup}) async {
    // normalize payload
    final uid = currentUser['id'] as String?;
    if (uid == null || uid.isEmpty) return;
    final localId = '${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(1 << 32)}';
    final payload = Map<String, dynamic>.from(messagePayload);
    payload['senderId'] = uid;
    // keep local timestamp for optimistic UI; serverTimestamp will replace it on server write if needed
    payload['timestamp'] = payload['timestamp'] ?? DateTime.now().toIso8601String();

    // attempt write immediately
    final item = _OutboxItem(localId: localId, chatId: chatId, isGroup: isGroup, message: payload);
    // optimistic UI: update summary instantly
    final idx = chatSummaries.indexWhere((c) => c.id == chatId && c.isGroup == isGroup);
    final displayText = (payload['text'] as String?) ?? (payload['type'] == 'media' ? 'Media' : '');
    final now = DateTime.now();
    if (idx >= 0) {
      final s = chatSummaries[idx];
      s.lastMessageText = displayText;
      s.timestamp = now.isAfter(s.timestamp) ? now : s.timestamp;
      s.unreadCount = 0;
      _recomputeTotalUnread();
      notifyListeners();
    } else {
      // create a lightweight summary so UI shows something
      final s = ChatSummary(
        id: chatId,
        isGroup: isGroup,
        title: isGroup ? 'Group' : '',
        lastMessageText: displayText,
        timestamp: now,
        unreadCount: 0,
        isPinned: _pinnedChats.contains(chatId),
        isMuted: _mutedUsers.contains(chatId),
        isBlocked: false,
      );
      chatSummaries.add(s);
      _recomputeTotalUnread();
      notifyListeners();
    }

    try {
      // try immediate send; if fails -> push to outbox for retry
      final success = await _attemptSendOutboxItem(item);
      if (!success) {
        _outbox.add(item);
        await _saveOutbox();
        _scheduleOutboxProcessing(immediate: true);
      }
    } catch (e) {
      debugPrint('[MessagesController] sendMessage immediate attempt exception: $e');
      _outbox.add(item);
      await _saveOutbox();
      _scheduleOutboxProcessing(immediate: true);
    }
  }

  /// Compatibility helper: UI code may call `.refresh()` on the controller.
/// This forces a one-off refresh of summaries from Firestore and restarts listeners.
Future<void> refresh() async {
  try {
    final uid = currentUser['id'] as String?;
    if (uid == null || uid.isEmpty) return;

    // Cancel realtime listeners to avoid duplicates while we do a one-off refresh.
    try { await _chatsSub?.cancel(); } catch (_) {}
    try { await _groupsSub?.cancel(); } catch (_) {}

    // one-off fetch current remote chat/group docs and apply them to in-memory summaries
    try {
      final chatsSnap = await FirebaseFirestore.instance
          .collection('chats')
          .where('userIds', arrayContains: uid)
          .get();
      _processDocsChanged(chatsSnap.docs, isGroup: false);
    } catch (e, st) {
      debugPrint('[MessagesController] refresh: failed to fetch chats: $e\n$st');
    }

    try {
      final groupsSnap = await FirebaseFirestore.instance
          .collection('groups')
          .where('userIds', arrayContains: uid)
          .get();
      _processDocsChanged(groupsSnap.docs, isGroup: true);
    } catch (e, st) {
      debugPrint('[MessagesController] refresh: failed to fetch groups: $e\n$st');
    }

    // restart realtime listeners (so future updates stream in normally)
    _startRealtimeListeners();

    // optional housekeeping: refresh cached lists and notify UI
    _saveCachedLists();
    _recomputeTotalUnread();
    notifyListeners();
  } catch (e, st) {
    debugPrint('[MessagesController] refresh error: $e\n$st');
  }
}


  

  // ---------------------
  // Real-time listeners
  // ---------------------
  void _startRealtimeListeners() {
    final uid = currentUser['id'] as String?;
    if (uid == null || uid.isEmpty) return;

    // Listen to top-level chat docs for the current user.
    _chatsSub = FirebaseFirestore.instance
        .collection('chats')
        .where('userIds', arrayContains: uid)
        .snapshots()
        .listen((snap) {
      _handleDocsChanged(snap.docs, isGroup: false);
    }, onError: (e) {
      debugPrint('[MessagesController] chats snapshot error: $e');
    });

    // Listen to groups as well
    _groupsSub = FirebaseFirestore.instance
        .collection('groups')
        .where('userIds', arrayContains: uid)
        .snapshots()
        .listen((snap) {
      _handleDocsChanged(snap.docs, isGroup: true);
    }, onError: (e) {
      debugPrint('[MessagesController] groups snapshot error: $e');
    });
  }

  /// Debounce incoming doc-changed bursts and process once per small window.
  void _handleDocsChanged(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
      {required bool isGroup}) {
    _docsChangedDebounce?.cancel();
    _docsChangedDebounce = Timer(const Duration(milliseconds: 200), () {
      _processDocsChanged(docs, isGroup: isGroup);
    });
  }

  /// Original _handleDocsChanged logic moved here; gets called by the debounce timer.
  void _processDocsChanged(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
      {required bool isGroup}) {
    // Build map so we can merge remote order/pins/etc into local in-memory list.
    final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> docsById = {
      for (var d in docs) d.id: d
    };

    // Update or add chat summaries based on remote docs
    for (var doc in docs) {
      _updateOrInsertChatFromDoc(doc, isGroup: isGroup);
    }

    // Remove local summaries that no longer exist in remote (deleted)
    final remoteIds = docsById.keys.toSet();
    chatSummaries.removeWhere((c) => c.isGroup == isGroup && !remoteIds.contains(c.id));

    // Sort pinned first, then by timestamp desc
    chatSummaries.sort((a, b) {
      final aPinned = _pinnedChats.contains(a.id);
      final bPinned = _pinnedChats.contains(b.id);
      if (aPinned && !bPinned) return -1;
      if (!aPinned && bPinned) return 1;
      return b.timestamp.compareTo(a.timestamp);
    });

    _recomputeTotalUnread();
    _saveCachedLists();
    notifyListeners();
  }

  /// Called whenever a chat/group doc is added/modified/exists in the snapshot.
  /// We prefer using doc fields (lastMessage, timestamp, unreadBy) but will fetch
  /// the latest message from subcollection if needed (or to get accurate readBy).
  void _updateOrInsertChatFromDoc(
      QueryDocumentSnapshot<Map<String, dynamic>> doc,
      {required bool isGroup}) {
    final id = doc.id;
    final data = doc.data();
    final uid = currentUser['id'] as String?;

    // find existing
    final idx = chatSummaries.indexWhere((c) => c.id == id && c.isGroup == isGroup);

    // Base values from the chat doc
    final title = (isGroup ? (data['name'] ?? 'Group') : '') as String;
    final docTimestamp = _parseTimestamp(data['timestamp']);
    String docLastMessage = '';
    if (data.containsKey('lastMessage')) {
      final lm = data['lastMessage'];
      if (lm is String) {
        docLastMessage = lm;
      } else if (lm is Map && lm['text'] != null) {
        docLastMessage = lm['text'];
      }
    }

    // Determine unread from doc-level fields if present
    bool unreadForUser = false;
    int unreadCountForUI = 0;
    try {
      if (data.containsKey('unreadBy')) {
        final unreadBy = List<dynamic>.from(data['unreadBy'] ?? []);
        unreadForUser = unreadBy.contains(uid);
      } else if (data.containsKey('readStatus')) {
        final readStatus = data['readStatus'] as Map<dynamic, dynamic>? ?? {};
        unreadForUser = readStatus[uid] != true;
      } else {
        unreadForUser = false;
      }
      unreadCountForUI = unreadForUser ? 1 : 0;
    } catch (_) {
      unreadForUser = false;
      unreadCountForUI = 0;
    }

    // Determine otherUser for 1:1 chats if available (client may store in doc)
    Map<String, dynamic>? otherUser;
    String? otherId;
    if (!isGroup) {
      try {
        final userIds = List<dynamic>.from(data['userIds'] ?? []);
        otherId = userIds.firstWhere((e) => e != uid, orElse: () => null) as String?;

        if (otherId != null) {
          // Prefer per-user cached object if present and keyed by otherId
          if (data.containsKey('cachedUsers')) {
            try {
              final rawCached = data['cachedUsers'];
              if (rawCached is Map) {
                // cachedUsers might be Map<String, dynamic> or Map<dynamic, dynamic>
                final entry = rawCached[otherId] ?? rawCached[otherId.toString()];
                if (entry is Map) {
                  otherUser = Map<String, dynamic>.from(entry);
                  // ensure id is present and correct
                  otherUser['id'] = otherId;
                }
              }
            } catch (_) {
              // ignore parse problems and fallthrough to otherUser handling
            }
          }

          // If no valid cachedUsers entry, try legacy 'otherUser' field BUT only accept it
          // if it already corresponds to otherId. Otherwise prefer to fetch the profile.
          if (otherUser == null && data.containsKey('otherUser')) {
            try {
              final raw = data['otherUser'];
              if (raw is Map) {
                final mapRaw = Map<String, dynamic>.from(raw);
                // If the doc stored an id that matches otherId, use it.
                if (mapRaw.containsKey('id')) {
                  final storedId = mapRaw['id']?.toString();
                  if (storedId == otherId) {
                    otherUser = mapRaw;
                    otherUser['id'] = otherId;
                  } else {
                    // legacy mismatch: stored otherUser is not for this otherId (ignore)
                    otherUser = {'id': otherId};
                  }
                } else {
                  // raw has no id: not trustworthy (could be cached from creator's view).
                  // Use minimal placeholder and fetch profile below.
                  otherUser = {'id': otherId};
                }
              } else {
                otherUser = {'id': otherId};
              }
            } catch (_) {
              otherUser = {'id': otherId};
            }
          }

          // If still null, set minimal placeholder so UI can fetch profile
          otherUser ??= {'id': otherId};
        }
      } catch (_) {}
    }

    // If doc lacks lastMessage or read metadata, fetch the latest message once
    final needsFetch = (docLastMessage.isEmpty && (data['timestamp'] != null)) ||
        (!data.containsKey('unreadBy') && !data.containsKey('readStatus'));

    // Upsert summary (timestamp might be 0 if missing)
    if (idx >= 0) {
      final existing = chatSummaries[idx];
      existing.isGroup = isGroup;
      existing.title = isGroup
          ? (data['name'] ?? existing.title)
          : (existing.title.isNotEmpty
              ? existing.title
              : (otherUser != null ? (otherUser['username'] ?? existing.title) : existing.title));
      existing.otherUser = otherUser ?? existing.otherUser;
      existing.lastMessageText =
          docLastMessage.isNotEmpty ? docLastMessage : existing.lastMessageText;
      existing.timestamp = docTimestamp.isAfter(existing.timestamp) ? docTimestamp : existing.timestamp;
      existing.unreadCount = unreadCountForUI;
      existing.isPinned = _pinnedChats.contains(existing.id);
      existing.isMuted = _mutedUsers.contains(existing.id) ||
          (existing.otherUser != null && _mutedUsers.contains(existing.otherUser?['id']));
      existing.isBlocked = existing.otherUser != null && _blockedUsers.contains(existing.otherUser?['id']);
      // If we don't have username/photo for the other user, fetch it in background.
      if (!isGroup && existing.otherUser != null && (existing.otherUser?['username'] == null || (existing.otherUser?['username'] as String).isEmpty)) {
        final oid = existing.otherUser?['id'] as String?;
        if (oid != null) {
          _fetchAndApplyProfile(oid, id, isGroup);
        }
      }
    } else {
      final summary = ChatSummary(
        id: id,
        isGroup: isGroup,
        title: isGroup ? (data['name'] ?? 'Group') : (otherUser != null ? (otherUser['username'] ?? '') : ''),
        otherUser: otherUser,
        lastMessageText: docLastMessage,
        timestamp: docTimestamp,
        unreadCount: unreadCountForUI,
        isPinned: _pinnedChats.contains(id),
        isMuted: _mutedUsers.contains(id) || (otherUser != null && _mutedUsers.contains(otherUser['id'])),
        isBlocked: otherUser != null && _blockedUsers.contains(otherUser['id']),
      );
      chatSummaries.add(summary);

      // If we added a summary for a direct chat but the summary lacks username, fetch it.
      if (!isGroup && otherUser != null && (otherUser['username'] == null || (otherUser['username'] as String).isEmpty)) {
        final oid = otherUser['id'] as String?;
        if (oid != null) {
          _fetchAndApplyProfile(oid, id, isGroup);
        }
      }
    }

    // If necessary, queue a fetch of latest message for more accurate lastMessage/readBy info
    if (needsFetch) {
      final token = '$id|${isGroup ? '1' : '0'}';
      if (!_pendingLastMessageFetches.contains(token)) {
        _pendingLastMessageFetches.add(token);
        _enqueueLastMessageFetch(token);
      }
    }
  }

  /// queue helpers for controlled concurrency
  void _enqueueLastMessageFetch(String token) {
    _fetchQueue.add(token);
    _tryProcessQueue();
  }

  void _tryProcessQueue() {
    if (_activeFetches >= _maxConcurrentFetches) return;
    if (_fetchQueue.isEmpty) return;

    final token = _fetchQueue.removeFirst();
    _activeFetches++;

    final parts = token.split('|');
    final chatId = parts[0];
    final isGroup = parts.length > 1 && parts[1] == '1';

    // call and when complete, decrement active and continue
    _fetchLastMessageAndUpdate(chatId, isGroup: isGroup).whenComplete(() {
      _activeFetches--;
      _pendingLastMessageFetches.remove(token);
      _tryProcessQueue();
      _saveCachedLists();
      notifyListeners();
    });
  }

  /// Fetch a user profile and apply to the in-memory chat summary (if present).
  Future<void> _fetchAndApplyProfile(String userId, String chatId, bool isGroup) async {
    try {
      final profile = await _fetchUserProfile(userId);
      if (profile == null) return;
      final idx = chatSummaries.indexWhere((c) => c.id == chatId && c.isGroup == isGroup);
      if (idx >= 0) {
        final s = chatSummaries[idx];
        s.otherUser = {
          ...?s.otherUser,
          'id': profile['id'],
          if (profile['username'] != null) 'username': profile['username'],
          if (profile['photoUrl'] != null) 'photoUrl': profile['photoUrl'],
        };
        // If title is empty and username available, set title for display
        if ((s.title.isEmpty) && (profile['username'] as String?)?.isNotEmpty == true) {
          s.title = profile['username'];
        }
        _saveCachedLists();
        notifyListeners();
      }
    } catch (e, st) {
      debugPrint('[MessagesController] _fetchAndApplyProfile error: $e\n$st');
    }
  }

  /// Batch prefetch user profiles to reduce per-profile reads.
  /// This will store results in the in-memory cache.
  Future<void> prefetchUserProfiles(List<String> userIds) async {
    try {
      final idsToFetch = userIds.where((id) => id.isNotEmpty && !_userCache.containsKey(id)).toList();
      if (idsToFetch.isEmpty) return;
      // Firestore supports 'whereIn' with up to 10; fetch in chunks of 10
      const chunkSize = 10;
      for (var i = 0; i < idsToFetch.length; i += chunkSize) {
        final chunk = idsToFetch.skip(i).take(chunkSize).toList();
        final snap = await FirebaseFirestore.instance.collection('users').where(FieldPath.documentId, whereIn: chunk).get();
        for (final d in snap.docs) {
          final map = Map<String, dynamic>.from(d.data() ?? {});
          map['id'] = d.id;
          _userCache[d.id] = map;
        }
      }
    } catch (e, st) {
      debugPrint('[MessagesController] prefetchUserProfiles error: $e\n$st');
    }
  }

  /// Fetch user document from Firestore (small in-memory cache to reduce reads).
  Future<Map<String, dynamic>?> _fetchUserProfile(String userId) async {
    if (userId.isEmpty) return null;
    // return cached copy when present
    if (_userCache.containsKey(userId)) return _userCache[userId];
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
      if (!doc.exists) return null;
      final data = Map<String, dynamic>.from(doc.data() ?? {});
      data['id'] = doc.id;
      _userCache[userId] = data;
      return data;
    } catch (e, st) {
      debugPrint('[MessagesController] _fetchUserProfile error: $e\n$st');
      return null;
    }
  }

  /// Fetch the latest message from the messages subcollection and update local summary.
  /// Workaround: if parent doc lacks lastMessage/unreadBy or has an older timestamp,
  /// update the parent doc inside a transaction so it behaves similar to a Cloud Function.
  /// Improvement: skip messages that are 'deletedFor' current user and, if none visible,
  /// clear the parent lastMessage so the snippet matches the opened chat.
  Future<void> _fetchLastMessageAndUpdate(String chatId, {required bool isGroup}) async {
    try {
      final msgsRef = FirebaseFirestore.instance
          .collection(isGroup ? 'groups' : 'chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(20); // fetch several recent messages to find first visible for user

      final snap = await msgsRef.get();
      if (snap.docs.isEmpty) {
        // no messages at all -> clear summary & optionally parent
        _applyEmptyLastMessageToSummary(chatId, isGroup);
        await _clearParentLastMessageIfNeeded(chatId, isGroup);
        return;
      }

      // pick first message not containing currentUser in deletedFor
      QueryDocumentSnapshot<Map<String, dynamic>>? chosen;
      for (final doc in snap.docs) {
        final data = doc.data();
        final deletedFor = List<dynamic>.from(data['deletedFor'] ?? []);
        if (!deletedFor.contains(currentUser['id'])) {
          chosen = doc;
          break;
        }
      }

      if (chosen == null) {
        // all recent messages are deleted for current user -> treat as "no visible messages"
        _applyEmptyLastMessageToSummary(chatId, isGroup);
        await _clearParentLastMessageIfNeeded(chatId, isGroup);
        return;
      }

      final mDoc = chosen;
      final m = mDoc.data();
      final senderId = m['senderId'] as String?;
      final text = (m['text'] as String?) ?? (m['type'] == 'media' ? 'Media' : '');
      final timestamp = _parseTimestamp(m['timestamp']);
      final readBy = List<dynamic>.from(m['readBy'] ?? []);
      final unreadForUser = !(readBy.contains(currentUser['id']));

      // Update in-memory summary
      final idx = chatSummaries.indexWhere((c) => c.id == chatId && c.isGroup == isGroup);
      if (idx >= 0) {
        final s = chatSummaries[idx];
        s.lastMessageText = text;
        s.timestamp = timestamp.isAfter(s.timestamp) ? timestamp : s.timestamp;
        s.unreadCount = unreadForUser ? 1 : 0;
      } else {
        // create a new summary if it didn't exist yet
        final summary = ChatSummary(
          id: chatId,
          isGroup: isGroup,
          title: isGroup ? 'Group' : '',
          otherUser: null,
          lastMessageText: text,
          timestamp: timestamp,
          unreadCount: unreadForUser ? 1 : 0,
          isPinned: _pinnedChats.contains(chatId),
          isMuted: _mutedUsers.contains(chatId),
        );
        chatSummaries.add(summary);
      }

      // Repair parent doc if it is missing lastMessage or has older timestamp than chosen message:
      try {
        final parentRef = FirebaseFirestore.instance.collection(isGroup ? 'groups' : 'chats').doc(chatId);
        await FirebaseFirestore.instance.runTransaction((tx) async {
          final parentSnap = await tx.get(parentRef);
          final parentData = parentSnap.exists ? (parentSnap.data() as Map<String, dynamic>?) : null;
          final parentTs = _parseTimestamp(parentData?['timestamp']);

          final shouldUpdateParent = parentData == null ||
              !(parentData.containsKey('lastMessage')) ||
              timestamp.isAfter(parentTs);

          if (shouldUpdateParent) {
            // Build unreadBy: all userIds in parent doc except sender
            List<dynamic> userIds = [];
            if (parentData != null && parentData.containsKey('userIds')) {
              userIds = List<dynamic>.from(parentData['userIds'] ?? []);
            } else {
              userIds = parentData?['userIds'] ?? [];
            }

            // recipients = all userIds except the sender
            final recipientIds = userIds.where((id) => id != senderId).toList().cast<String>();

            // use message timestamp if it's a Firestore Timestamp; otherwise use serverTimestamp
            final tsValue = m['timestamp'] is Timestamp ? m['timestamp'] : FieldValue.serverTimestamp();

            final updateData = <String, dynamic>{
              'lastMessage': text,
              'timestamp': tsValue,
            };

            if (recipientIds.isNotEmpty) {
              updateData['unreadBy'] = FieldValue.arrayUnion(recipientIds);
            }

            tx.set(parentRef, updateData, SetOptions(merge: true));
          }
        });
      } catch (e, st) {
        // don't fail the whole fetch because parent update failed; just log
        debugPrint('[MessagesController] parent doc repair failed for $chatId: $e\n$st');
      }
    } catch (e, st) {
      debugPrint('[MessagesController] _fetchLastMessageAndUpdate error: $e\n$st');
    }
  }

  /// Helper: apply "no visible message" to in-memory summary
  void _applyEmptyLastMessageToSummary(String chatId, bool isGroup) {
    final idx = chatSummaries.indexWhere((c) => c.id == chatId && c.isGroup == isGroup);
    if (idx >= 0) {
      final s = chatSummaries[idx];
      s.lastMessageText = '';
      s.unreadCount = 0;
      // keep timestamp as-is (do not override with epoch unless desired)
    }
  }

  /// If parent doc still claims a lastMessage but there are no visible messages for this user,
  /// clear the parent's lastMessage so UI doesn't display a snippet which won't show in the opened chat.
  Future<void> _clearParentLastMessageIfNeeded(String chatId, bool isGroup) async {
    try {
      final parentRef = FirebaseFirestore.instance.collection(isGroup ? 'groups' : 'chats').doc(chatId);
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final parentSnap = await tx.get(parentRef);
        if (!parentSnap.exists) return;
        final parentData = parentSnap.data() as Map<String, dynamic>? ?? {};
        final last = parentData['lastMessage'];
        if (last != null && (last is String && last.isNotEmpty)) {
          tx.update(parentRef, {'lastMessage': '', 'timestamp': FieldValue.serverTimestamp()});
        }
      });
    } catch (e, st) {
      debugPrint('[MessagesController] _clearParentLastMessageIfNeeded error: $e\n$st');
    }
  }

  // ---------------------
  // Public helpers
  // ---------------------

  /// Convenience compatibility method expected by some UI widgets.
  /// Returns the total unread count (simple badge count).
  Future<int> getUnreadCount(String? userId) async {
    _recomputeTotalUnread();
    return totalUnread;
  }

  /// Quick local check used by UI to know if a chat is pinned.
  bool isChatPinned(String chatId) {
    return _pinnedChats.contains(chatId);
  }

  /// Quick local check used by UI to know if a user/chat id is muted.
  bool isUserMuted(String id) {
    return _mutedUsers.contains(id);
  }

  /// Quick local check used by UI to know if a user is blocked.
  bool isUserBlocked(String userId) {
    return _blockedUsers.contains(userId);
  }

  /// Call to mark a chat as read (WhatsApp-like behaviour).
  /// This updates the chat doc's unreadBy and also patches recent messages' readBy in a small batch.
  Future<void> markAsRead(String chatId, {required bool isGroup}) async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return;

      final chatRef = FirebaseFirestore.instance.collection(isGroup ? 'groups' : 'chats').doc(chatId);

      // Remove user from chat-level unreadBy if present
      await chatRef.update({'unreadBy': FieldValue.arrayRemove([uid])});

      // Update recent messages readBy to include this user (last 50)
      final msgsSnap = await chatRef.collection('messages').orderBy('timestamp', descending: true).limit(50).get();
      if (msgsSnap.docs.isNotEmpty) {
        final batch = FirebaseFirestore.instance.batch();
        for (final m in msgsSnap.docs) {
          final data = m.data();
          final readBy = List<dynamic>.from(data['readBy'] ?? []);
          if (!readBy.contains(uid)) {
            batch.update(m.reference, {'readBy': FieldValue.arrayUnion([uid])});
          }
        }
        await batch.commit();
      }

      // Update in-memory
      final idx = chatSummaries.indexWhere((c) => c.id == chatId && c.isGroup == isGroup);
      if (idx >= 0) {
        chatSummaries[idx].unreadCount = 0;
        _recomputeTotalUnread();
        _saveCachedLists();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[MessagesController] markAsRead error: $e');
    }
  }

  /// Delete conversation for current user (marks messages deletedFor current user)
  Future<void> deleteConversation(String chatId, {required bool isGroup}) async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return;

      final chatRef = FirebaseFirestore.instance.collection(isGroup ? 'groups' : 'chats').doc(chatId);

      // mark deletedBy on chat doc
      await chatRef.set({'deletedBy': FieldValue.arrayUnion([uid])}, SetOptions(merge: true));

      // mark each message 'deletedFor' for this user in chunks
      const pageSize = 200;
      Query<Map<String, dynamic>> q = chatRef.collection('messages').orderBy('timestamp').limit(pageSize);
      bool more = true;
      while (more) {
        final snap = await q.get();
        if (snap.docs.isEmpty) break;
        final batch = FirebaseFirestore.instance.batch();
        for (final d in snap.docs) {
          final deletedFor = List<String>.from(d.data()['deletedFor'] ?? []);
          if (!deletedFor.contains(uid)) {
            batch.update(d.reference, {'deletedFor': FieldValue.arrayUnion([uid])});
          }
        }
        await batch.commit();
        more = snap.docs.length == pageSize;
        if (more) {
          q = chatRef.collection('messages').orderBy('timestamp').startAfterDocument(snap.docs.last).limit(pageSize);
        }
      }

      // remove from in-memory list
      chatSummaries.removeWhere((c) => c.id == chatId && c.isGroup == isGroup);
      _recomputeTotalUnread();
      _saveCachedLists();
      notifyListeners();
    } catch (e) {
      debugPrint('[MessagesController] deleteConversation error: $e');
    }
  }

  // ---------------------
  // Pin / Mute / Block
  // ---------------------
  Future<void> pinConversation(String chatId) async {
    if (!_pinnedChats.contains(chatId)) _pinnedChats.add(chatId);
    await _saveCachedLists();
    // persist to server user doc
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return;
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'pinnedChats': FieldValue.arrayUnion([chatId])
      });
    } catch (e) {
      debugPrint('[MessagesController] pinConversation error: $e');
    }
    // update local view
    final idx = chatSummaries.indexWhere((c) => c.id == chatId);
    if (idx >= 0) {
      chatSummaries[idx].isPinned = true;
      chatSummaries.sort((a, b) {
        final aPinned = _pinnedChats.contains(a.id);
        final bPinned = _pinnedChats.contains(b.id);
        if (aPinned && !bPinned) return -1;
        if (!aPinned && bPinned) return 1;
        return b.timestamp.compareTo(a.timestamp);
      });
      _saveCachedLists();
      notifyListeners();
    }
  }

  Future<void> unpinConversation(String chatId) async {
    if (_pinnedChats.contains(chatId)) _pinnedChats.remove(chatId);
    await _saveCachedLists();
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return;
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'pinnedChats': FieldValue.arrayRemove([chatId])
      });
    } catch (e) {
      debugPrint('[MessagesController] unpinConversation error: $e');
    }
    final idx = chatSummaries.indexWhere((c) => c.id == chatId);
    if (idx >= 0) {
      chatSummaries[idx].isPinned = false;
      chatSummaries.sort((a, b) {
        final aPinned = _pinnedChats.contains(a.id);
        final bPinned = _pinnedChats.contains(b.id);
        if (aPinned && !bPinned) return -1;
        if (!aPinned && bPinned) return 1;
        return b.timestamp.compareTo(a.timestamp);
      });
      _saveCachedLists();
      notifyListeners();
    }
  }

  Future<void> mute(String id) async {
    if (!_mutedUsers.contains(id)) _mutedUsers.add(id);
    await _saveCachedLists();
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return;
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'mutedUsers': FieldValue.arrayUnion([id])
      });
    } catch (e) {
      debugPrint('[MessagesController] mute error: $e');
    }
    final idx = chatSummaries.indexWhere((c) => c.id == id);
    if (idx >= 0) {
      chatSummaries[idx].isMuted = true;
      _saveCachedLists();
      notifyListeners();
    }
  }

  Future<void> unmute(String id) async {
    if (_mutedUsers.contains(id)) _mutedUsers.remove(id);
    await _saveCachedLists();
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return;
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'mutedUsers': FieldValue.arrayRemove([id])
      });
    } catch (e) {
      debugPrint('[MessagesController] unmute error: $e');
    }
    final idx = chatSummaries.indexWhere((c) => c.id == id);
    if (idx >= 0) {
      chatSummaries[idx].isMuted = false;
      _saveCachedLists();
      notifyListeners();
    }
  }

  Future<void> blockUser(String userId, {String? chatId}) async {
    if (!_blockedUsers.contains(userId)) _blockedUsers.add(userId);
    await _saveCachedLists();
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return;
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'blockedUsers': FieldValue.arrayUnion([userId])
      });
      // optionally delete/mark chat as deleted
      if (chatId != null) {
        await deleteConversation(chatId, isGroup: false);
      }
    } catch (e) {
      debugPrint('[MessagesController] blockUser error: $e');
    }
    // update in-memory
    for (final s in chatSummaries) {
      if (s.otherUser != null && s.otherUser?['id'] == userId) {
        s.isBlocked = true;
      }
    }
    _saveCachedLists();
    notifyListeners();
  }

  Future<void> unblockUser(String userId) async {
    if (_blockedUsers.contains(userId)) _blockedUsers.remove(userId);
    await _saveCachedLists();
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return;
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'blockedUsers': FieldValue.arrayRemove([userId])
      });
    } catch (e) {
      debugPrint('[MessagesController] unblockUser error: $e');
    }
    for (final s in chatSummaries) {
      if (s.otherUser != null && s.otherUser?['id'] == userId) {
        s.isBlocked = false;
      }
    }
    _saveCachedLists();
    notifyListeners();
  }

  // ---------------------
  // Utility / housekeeping
  // ---------------------
  DateTime _parseTimestamp(dynamic ts) {
    if (ts == null) return DateTime.fromMillisecondsSinceEpoch(0);
    try {
      if (ts is Timestamp) return ts.toDate();
      if (ts is int) return DateTime.fromMillisecondsSinceEpoch(ts);
      if (ts is String) return DateTime.parse(ts);
    } catch (_) {}
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _recomputeTotalUnread() {
    totalUnread = chatSummaries.fold(0, (p, c) => p + (c.unreadCount > 0 ? 1 : 0));
  }

  /// Should be called when your app is going away to cancel subscriptions.
  @override
  void dispose() {
    _chatsSub?.cancel();
    _groupsSub?.cancel();
    _docsChangedDebounce?.cancel();
    _outboxTimer?.cancel();
    for (final s in _typingListeners.values) {
      s.cancel();
    }
    for (final s in _presenceListeners.values) {
      s.cancel();
    }
    super.dispose();
  }

  // ---------------------
  // Convenience / Creation helpers
  // ---------------------

  /// Create or open a 1:1 chat then navigate to ChatScreen
  /// NOTE: to avoid using BuildContext across async gaps the method captures NavigatorState.
  Future<void> openOrCreateDirectChat(BuildContext ctx, Map<String, dynamic> otherUser) async {
    final navigator = Navigator.of(ctx);
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return;
      final otherId = otherUser['id'] as String;
      final chatId = getChatId(uid, otherId);

      // Build per-user cached info to avoid "wrong otherUser" being read on the other side.
      final cachedUsers = <String, Map<String, dynamic>>{
        uid: {
          'id': uid,
          'username': currentUser['username'] ?? '',
          'photoUrl': currentUser['photoUrl'] ?? '',
        },
        otherId: {
          'id': otherId,
          'username': otherUser['username'] ?? '',
          'photoUrl': otherUser['photoUrl'] ?? '',
        },
      };

      await FirebaseFirestore.instance.collection('chats').doc(chatId).set({
        'userIds': [uid, otherId],
        'lastMessage': '',
        'timestamp': FieldValue.serverTimestamp(),
        'unreadBy': [],
        'deletedBy': [],
        'isGroup': false,
        // store per-user cached profiles to be unambiguous for both participants
        'cachedUsers': cachedUsers,
      }, SetOptions(merge: true));

      // navigate (use captured navigator)
      if (!navigator.mounted) return;
      navigator.push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: chatId,
            currentUser: currentUser,
            otherUser: otherUser,
            authenticatedUser: currentUser,
            storyInteractions: const [],
            accentColor: currentUser['accentColor'] ?? Colors.blueAccent,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[MessagesController] openOrCreateDirectChat error: $e');
    }
  }

  /// Create group flow
  Future<void> navigateToNewGroupChat(BuildContext ctx) async {
    // capture navigator for later navigation
    final navigator = Navigator.of(ctx);
    final name = await showGroupNameInput(ctx);
    if (name == null || name.trim().isEmpty) {
      // We can't safely show a SnackBar via ctx after await, so use ScaffoldMessenger with navigator.context
      if (navigator.mounted) {
        ScaffoldMessenger.of(navigator.context)
            .showSnackBar(const SnackBar(content: Text('Group name is required')));
      }
      return;
    }
    final groupName = name.trim();
    try {
      final snapshot = await FirebaseFirestore.instance.collection('users').get();
      final users = snapshot.docs.map((d) {
        final m = Map<String, dynamic>.from(d.data() ?? {});
        m['id'] = d.id;
        return m;
      }).where((u) => u['id'] != currentUser['id']).toList();

      if (!navigator.mounted) return;
      navigator.push(MaterialPageRoute(
        builder: (_) => CreateGroupScreen(
          initialGroupName: groupName,
          availableUsers: users,
          currentUser: currentUser,
          onGroupCreated: (chatId) {
            // push replacement into navigator (use navigator directly)
            if (navigator.mounted) {
              navigator.pushReplacement(MaterialPageRoute(builder: (_) => GroupChatScreen(
                chatId: chatId,
                currentUser: currentUser,
                authenticatedUser: currentUser,
                accentColor: currentUser['accentColor'] ?? Colors.blueAccent,
              )));
            }
          },
        ),
      ));
    } catch (e) {
      debugPrint('[MessagesController] navigateToNewGroupChat error: $e');
      if (navigator.mounted) {
        ScaffoldMessenger.of(navigator.context).showSnackBar(SnackBar(content: Text('Failed to fetch users: $e')));
      }
    }
  }

  Future<String?> showGroupNameInput(BuildContext context) async {
    String tempName = '';
    return await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.black87,
        title: const Text('Group Name', style: TextStyle(color: Colors.white)),
        content: TextField(
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'Enter group name', hintStyle: TextStyle(color: Colors.white54)),
          onChanged: (value) => tempName = value,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (tempName.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group name is required')));
                return;
              }
              Navigator.pop(context, tempName.trim());
            },
            child: const Text('Next'),
          ),
        ],
      ),
    );
  }

  /// Shows the "start new chat / new group" bottom sheet.
  /// This is the method your UI expects: call controller.showChatCreationOptions(context).
  Future<void> showChatCreationOptions(BuildContext ctx) async {
    final navigator = Navigator.of(ctx);

    // fetch users before showing the sheet (so the UI inside the sheet is immediate)
    List<Map<String, dynamic>> allUsers = [];
    try {
      final snapshot = await FirebaseFirestore.instance.collection('users').get();
      allUsers = snapshot.docs
          .where((doc) => doc.exists && doc.id != currentUser['id'] && !_blockedUsers.contains(doc.id))
          .map((doc) {
        final data = Map<String, dynamic>.from(doc.data() ?? {});
        data['id'] = doc.id;
        return data;
      }).toList();
    } catch (e) {
      debugPrint('[MessagesController] showChatCreationOptions: failed to fetch users: $e');
      if (navigator.mounted) {
        ScaffoldMessenger.of(navigator.context).showSnackBar(SnackBar(content: Text('Failed to fetch users: $e')));
      }
      return;
    }

    // show modal bottom sheet using navigator.context (so we don't use ctx after async gap)
    if (!navigator.mounted) return;
    await showModalBottomSheet(
      context: navigator.context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Container(
        decoration: BoxDecoration(
          color: Colors.black.withAlpha((0.3 * 255).round()),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withAlpha((0.1 * 255).round())),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.group_add, color: Colors.white),
              title: Text(
                'New Group Chat',
                style: TextStyle(
                  color: currentUser['accentColor'] ?? Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                // use navigator to push group flow
                if (navigator.mounted) {
                  navigateToNewGroupChat(navigator.context);
                }
              },
            ),
            const Divider(color: Colors.white12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: allUsers.map((user) {
                  final userId = user['id'] as String?;
                  if (userId == null) return const SizedBox.shrink();
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundImage: user['photoUrl'] != null ? NetworkImage(user['photoUrl']) as ImageProvider : null,
                      child: user['photoUrl'] == null
                          ? Text(
                              user['username'] != null && (user['username'] as String).isNotEmpty
                                  ? (user['username'] as String)[0].toUpperCase()
                                  : 'M',
                              style: const TextStyle(color: Colors.white),
                            )
                          : null,
                    ),
                    title: Text(
                      user['username'] ?? 'Unknown',
                      style: TextStyle(color: currentUser['accentColor'] ?? Colors.white, fontWeight: FontWeight.bold),
                    ),
                    onTap: () async {
                      Navigator.pop(sheetCtx);
                      // open or create direct chat using the captured navigator/context
                      await openOrCreateDirectChat(navigator.context, user);
                    },
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Public helper to mark a single message as deleted FOR THE CURRENT USER.
  /// Call this from your ChatScreen when user deletes one message.
  Future<void> markMessageDeletedForUser(String chatId, String messageId, {required bool isGroup}) async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null) return;

      final msgRef = FirebaseFirestore.instance
          .collection(isGroup ? 'groups' : 'chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId);

      // mark deletedFor this user
      await msgRef.update({'deletedFor': FieldValue.arrayUnion([uid])});

      // After marking, re-evaluate the latest visible message for this user and repair parent doc accordingly.
      await _fetchLastMessageAndUpdate(chatId, isGroup: isGroup);

      // Also persist cached lists and notify UI
      _saveCachedLists();
      notifyListeners();
    } catch (e, st) {
      debugPrint('[MessagesController] markMessageDeletedForUser error: $e\n$st');
    }
  }

  // ---------------------
  // Typing & Presence helpers
  // ---------------------

  /// Set typing state for the current user in a chat.
  /// Implementation: writes a small doc to collection `typing` with id `${chatId}_${uid}`.
  Future<void> setTyping(String chatId, bool isTyping, {Duration ttl = const Duration(seconds: 8)}) async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null || uid.isEmpty) return;
      final docId = '${chatId}_$uid';
      final ref = FirebaseFirestore.instance.collection('typing').doc(docId);
      if (isTyping) {
        await ref.set({
          'chatId': chatId,
          'userId': uid,
          'timestamp': FieldValue.serverTimestamp(),
          // optional expiry hint — your server / cleanup function could remove old entries
          'expiresAt': (DateTime.now().add(ttl).millisecondsSinceEpoch),
        }, SetOptions(merge: true));
      } else {
        await ref.delete();
      }
    } catch (e, st) {
      debugPrint('[MessagesController] setTyping error: $e\n$st');
    }
  }

  /// Listen to typing indicators for a chat. Returns a stream of Set<String> containing userIds currently typing.
  Stream<Set<String>> listenTyping(String chatId) {
    // Create a broadcast stream that listens to typing docs for the chatId
    final controller = StreamController<Set<String>>.broadcast();

    final sub = FirebaseFirestore.instance
        .collection('typing')
        .where('chatId', isEqualTo: chatId)
        .snapshots()
        .listen((snap) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final typingUsers = <String>{};
      for (final d in snap.docs) {
        try {
          final data = d.data();
          final userId = data['userId']?.toString();
          // optional: respect expiresAt if provided
          final expiresAt = (data['expiresAt'] is int) ? data['expiresAt'] as int : null;
          if (userId != null && userId.isNotEmpty) {
            if (expiresAt != null) {
              if (expiresAt > now) typingUsers.add(userId);
            } else {
              typingUsers.add(userId);
            }
          }
        } catch (_) {}
      }
      controller.add(typingUsers);
    }, onError: (e) {
      controller.addError(e);
    });

    // when controller is cancelled, cancel subscription
    controller.onCancel = () {
      sub.cancel();
    };

    return controller.stream;
  }

  /// Set presence for the current user (online/offline) in collection `presence/{uid}`
  Future<void> setPresence({required bool online}) async {
    try {
      final uid = currentUser['id'] as String?;
      if (uid == null || uid.isEmpty) return;
      final ref = FirebaseFirestore.instance.collection('presence').doc(uid);
      await ref.set({
        'online': online,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e, st) {
      debugPrint('[MessagesController] setPresence error: $e\n$st');
    }
  }

  /// Listen to a single user's presence doc. Useful to show presence indicator.
  Stream<Map<String, dynamic>?> listenPresenceForUser(String userId) {
    final controller = StreamController<Map<String, dynamic>?>.broadcast();

    final sub = FirebaseFirestore.instance.collection('presence').doc(userId).snapshots().listen((snap) {
      if (!snap.exists) {
        controller.add(null);
      } else {
        controller.add(snap.data());
      }
    }, onError: (e) => controller.addError(e));

    controller.onCancel = () {
      sub.cancel();
    };

    return controller.stream;
  }

  // ---------------------
  // Misc public helpers
  // ---------------------

  /// Force outbox processing (useful after regaining connectivity)
  Future<void> retryPendingOutbox() async {
    await _processOutbox();
  }
}

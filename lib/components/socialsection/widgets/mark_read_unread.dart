import 'package:cloud_firestore/cloud_firestore.dart';

class MessageStatusUtils {
  /// Marks messages in the chat as read for [userId].
  /// For efficiency and Firestore limitations we fetch a bounded number of recent messages
  /// and mark those that are unread AND not sent by [userId].
  static Future<void> markAsRead({
    required String chatId,
    required String userId,
    required bool isGroup,
  }) async {
    final path = isGroup ? 'groups' : 'chats';
    final messagesRef = FirebaseFirestore.instance
        .collection(path)
        .doc(chatId)
        .collection('messages');

    try {
      // Fetch recent messages (adjust limit as needed)
      final msgsSnapshot = await messagesRef
          .orderBy('timestamp', descending: true)
          .limit(500)
          .get();

      final batch = FirebaseFirestore.instance.batch();
      int messagesMarked = 0;

      for (final doc in msgsSnapshot.docs) {
        final data = doc.data();

        final senderId = data['senderId'] as String?;
        final readBy = List<dynamic>.from(data['readBy'] ?? []);

        // Only mark messages that were not sent by the current user and which don't already have the user's id in readBy
        if (senderId != userId && !(readBy.contains(userId))) {
          batch.update(doc.reference, {
            'readBy': FieldValue.arrayUnion([userId]),
          });
          messagesMarked++;
        }
      }

      // Update chat/group document to remove user from unread lists and mark readStatus
      final chatDocRef =
          FirebaseFirestore.instance.collection(path).doc(chatId);

      // Always remove the user from unreadBy, and set readStatus.<userId> = true
      batch.update(chatDocRef, {
        'unreadBy': FieldValue.arrayRemove([userId]),
        'readStatus.$userId': true,
      });

      await batch.commit();

      // Recompute unreadCount from server-side doc (best effort)
      try {
        final freshDoc = await chatDocRef.get();
        final freshData = freshDoc.data();
        if (freshData != null) {
          final unreadBy = List<dynamic>.from(freshData['unreadBy'] ?? []);
          final computedUnreadCount = unreadBy.length;
          // If unreadCount exists and differs, update it to the authoritative value
          await chatDocRef.update({'unreadCount': computedUnreadCount});
        }
      } catch (_) {
        // ignore recompute errors; not critical
      }
    } catch (e) {
      // bubble up or log as preferred
      rethrow;
    }
  }

  /// Mark conversation as unread for specified targets (or single user if no targets provided).
  /// This is useful when you want to mark a chat as unread for others (e.g., after sending a message,
  /// backend logic should call this with the recipients' IDs).
  /// Backwards-compatible: if [targetUserIds] is null, will add [userId] to unreadBy (previous behaviour).
  static Future<void> markAsUnread({
    required String chatId,
    required String userId,
    required bool isGroup,
    List<String>? targetUserIds,
  }) async {
    final path = isGroup ? 'groups' : 'chats';
    final docRef = FirebaseFirestore.instance.collection(path).doc(chatId);

    try {
      final batch = FirebaseFirestore.instance.batch();

      if (targetUserIds == null) {
        // legacy: mark the single user provided as unread
        batch.update(docRef, {
          'unreadBy': FieldValue.arrayUnion([userId]),
          'readStatus.$userId': false,
        });
      } else {
        // add multiple users to unreadBy and set readStatus.<id> = false for each
        batch.update(docRef, {
          'unreadBy': FieldValue.arrayUnion(targetUserIds),
          // build a map for readStatus updates using dot-paths
          ...Map.fromEntries(
            targetUserIds.map((id) => MapEntry('readStatus.$id', false)),
          ),
        });
      }

      await batch.commit();

      // Optionally recompute unreadCount for consistency
      try {
        final freshDoc = await docRef.get();
        final data = freshDoc.data();
        if (data != null) {
          final unreadBy = List<dynamic>.from(data['unreadBy'] ?? []);
          final computed = unreadBy.length;
          await docRef.update({'unreadCount': computed});
        }
      } catch (_) {}
    } catch (e) {
      rethrow;
    }
  }

  /// Returns whether the chat has unread content for this [userId].
  /// Checks both unreadBy array and readStatus map for robustness.
  static Future<bool> isUnread({
    required String chatId,
    required String userId,
    required bool isGroup,
  }) async {
    final path = isGroup ? 'groups' : 'chats';
    final doc = await FirebaseFirestore.instance.collection(path).doc(chatId).get();

    final data = doc.data();
    if (data == null) return false;

    final isInUnreadBy = (data['unreadBy'] as List<dynamic>?)?.contains(userId) ?? false;
    final readStatusMap = data['readStatus'];
    final readStatus = (readStatusMap is Map) ? (readStatusMap[userId] == true) : false;

    // unread if explicitly present in unreadBy OR if readStatus is explicitly false/unset
    return isInUnreadBy || !readStatus;
  }
}

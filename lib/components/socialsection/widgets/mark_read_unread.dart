
import 'package:cloud_firestore/cloud_firestore.dart';

class MessageStatusUtils {
  static Future<void> markAsRead({
    required String chatId,
    required String userId,
    required bool isGroup,
  }) async {
    final path = isGroup ? 'groups' : 'chats';
    final messagesSnapshot = await FirebaseFirestore.instance
        .collection(path)
        .doc(chatId)
        .collection('messages')
        .where('readBy', arrayContains: userId, isEqualTo: false)
        .get();

    final batch = FirebaseFirestore.instance.batch();
    
    // Mark all unread messages as read
    for (var doc in messagesSnapshot.docs) {
      batch.update(doc.reference, {
        'readBy': FieldValue.arrayUnion([userId]),
      });
    }

    // Remove user from unreadBy in chat/group document
    batch.update(
      FirebaseFirestore.instance.collection(path).doc(chatId),
      {
        'unreadBy': FieldValue.arrayRemove([userId]),
        'readStatus.$userId': true, // Maintain existing readStatus
      },
    );

    await batch.commit();
  }

  static Future<void> markAsUnread({
    required String chatId,
    required String userId,
    required bool isGroup,
  }) async {
    final path = isGroup ? 'groups' : 'chats';
    final docRef = FirebaseFirestore.instance.collection(path).doc(chatId);

    final batch = FirebaseFirestore.instance.batch();
    
    // Add user to unreadBy
    batch.update(docRef, {
      'unreadBy': FieldValue.arrayUnion([userId]),
      'readStatus.$userId': false,
    });

    await batch.commit();
  }

  static Future<bool> isUnread({
    required String chatId,
    required String userId,
    required bool isGroup,
  }) async {
    final path = isGroup ? 'groups' : 'chats';
    final doc = await FirebaseFirestore.instance.collection(path).doc(chatId).get();

    final data = doc.data();
    if (data == null) return false;

    // Check both unreadBy and readStatus for consistency
    final isInUnreadBy = (data['unreadBy'] as List<dynamic>?)?.contains(userId) ?? false;
    final readStatus = data['readStatus'] is Map ? data['readStatus'][userId] != true : true;

    return isInUnreadBy || readStatus;
  }
}
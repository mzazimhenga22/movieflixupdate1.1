import 'package:cloud_firestore/cloud_firestore.dart';

class MessageStatusUtils {
  static Future<void> markAsRead({
    required String chatId,
    required String userId,
    required bool isGroup,
  }) async {
    final path = isGroup ? 'groups' : 'chats';
    final docRef = FirebaseFirestore.instance.collection(path).doc(chatId);

    await docRef.set({
      'readStatus': {
        userId: true,
      },
    }, SetOptions(merge: true));
  }

  static Future<void> markAsUnread({
    required String chatId,
    required String userId,
    required bool isGroup,
  }) async {
    final path = isGroup ? 'groups' : 'chats';
    final docRef = FirebaseFirestore.instance.collection(path).doc(chatId);

    await docRef.set({
      'readStatus': {
        userId: false,
      },
    }, SetOptions(merge: true));
  }

  static Future<bool> isUnread({
    required String chatId,
    required String userId,
    required bool isGroup,
  }) async {
    final path = isGroup ? 'groups' : 'chats';
    final doc = await FirebaseFirestore.instance.collection(path).doc(chatId).get();

    final data = doc.data();
    if (data != null &&
        data.containsKey('readStatus') &&
        data['readStatus'] is Map &&
        data['readStatus'][userId] != true) {
      return true;
    }
    return false;
  }
}

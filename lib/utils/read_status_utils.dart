import 'package:cloud_firestore/cloud_firestore.dart';

/// Marks an individual chat as read
Future<void> markChatAsRead(String chatId, String userId) async {
  await FirebaseFirestore.instance
      .collection('chats')
      .doc(chatId)
      .collection('readStatus')
      .doc(userId)
      .set({'isRead': true, 'timestamp': FieldValue.serverTimestamp()});
}

/// Marks an individual chat as unread
Future<void> markChatAsUnread(String chatId, String userId) async {
  await FirebaseFirestore.instance
      .collection('chats')
      .doc(chatId)
      .collection('readStatus')
      .doc(userId)
      .set({'isRead': false, 'timestamp': FieldValue.serverTimestamp()});
}

/// Marks a group chat as read
Future<void> markGroupAsRead(String groupId, String userId) async {
  await FirebaseFirestore.instance
      .collection('groups')
      .doc(groupId)
      .collection('readStatus')
      .doc(userId)
      .set({'isRead': true, 'timestamp': FieldValue.serverTimestamp()});
}

/// Marks a group chat as unread
Future<void> markGroupAsUnread(String groupId, String userId) async {
  await FirebaseFirestore.instance
      .collection('groups')
      .doc(groupId)
      .collection('readStatus')
      .doc(userId)
      .set({'isRead': false, 'timestamp': FieldValue.serverTimestamp()});
}

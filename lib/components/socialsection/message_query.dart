import 'package:cloud_firestore/cloud_firestore.dart';

Query<Map<String, dynamic>> getMessageQuery({
  required String conversationId,
  DocumentSnapshot? lastDoc,
  int limit = 20,
}) {
  var query = FirebaseFirestore.instance
      .collection('conversations')
      .doc(conversationId)
      .collection('messages')
      .orderBy('timestamp', descending: false)
      .limit(limit);
  if (lastDoc != null) {
    query = query.startAfterDocument(lastDoc);
  }
  return query;
}
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/foundation.dart';

Map<String, dynamic> _normalizeAndDecryptIsolate(Map<String, dynamic> params) {
  final data = params['data'] as Map<String, dynamic>;
  final docId = params['docId'] as String;
  final encrypter = params['encrypter'] as encrypt.Encrypter;

  final messageData = {
    'id': data['id']?.toString() ?? docId,
    'firestore_id': docId,
    'conversation_id': data['conversation_id']?.toString() ?? '',
    'sender_id': data['sender_id']?.toString() ?? '',
    'receiver_id': data['receiver_id']?.toString() ?? '',
    'message': data['message']?.toString() ?? '',
    'iv': data['iv']?.toString(),
    'type': data['type']?.toString() ?? 'text',
    'is_read': data['is_read'] == true,
    'is_pinned': data['is_pinned'] == true,
    'replied_to': data['replied_to']?.toString(),
    'reactions': data['reactions'] ?? {},
    'status': data['status']?.toString() ?? 'sent',
    'created_at': data['timestamp']?.toDate()?.toIso8601String() ?? DateTime.now().toIso8601String(),
    'delivered_at': data['delivered_at']?.toString(),
    'read_at': data['read_at']?.toString(),
    'scheduled_at': data['scheduled_at']?.toString(),
    'delete_after': data['delete_after']?.toString(),
    'is_story_reply': data['is_story_reply'] ?? false,
    'story_id': data['story_id'],
  };

  final isText = messageData['type'] == 'text';
  final ivString = messageData['iv'];

  if (isText && ivString != null && ivString.isNotEmpty) {
    try {
      final iv = encrypt.IV.fromBase64(ivString);
      messageData['message'] = encrypter.decrypt64(messageData['message'], iv: iv);
    } catch (e) {
      print("⚠️ Failed to decrypt message ${messageData['id']}: $e");
      messageData['message'] = '[Decryption Failed]';
    }
  } else if (isText) {
    print("⚠️ Skipping decryption: missing or empty IV for message ${messageData['id']}");
    messageData['message'] = '[Encrypted Message – IV Missing]';
  }

  return messageData;
}

Future<Map<String, dynamic>> decryptMessage(
  Map<String, dynamic> data,
  String docId,
  encrypt.Encrypter encrypter,
) async {
  return await compute(_normalizeAndDecryptIsolate, {
    'data': data,
    'docId': docId,
    'encrypter': encrypter,
  });
}

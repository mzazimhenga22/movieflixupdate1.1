import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'chat_widgets.dart';

class MessageList extends StatelessWidget {
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> interactions;
  final ScrollController scrollController;
  final Function(int) onReply;
  final Function(Map<String, dynamic>) onShare;
  final Function(Map<String, dynamic>) onLongPress;
  final Function(int) onTapOriginal;
  final Function(int) onDelete;
  final AudioPlayer audioPlayer;
  final Function(String?) setCurrentlyPlaying;
  final String? currentlyPlayingId;
  final encrypt.Encrypter encrypter;
  final Color textColor;
  final String currentUserId;

  const MessageList({
    super.key,
    required this.messages,
    required this.interactions,
    required this.scrollController,
    required this.onReply,
    required this.onShare,
    required this.onLongPress,
    required this.onTapOriginal,
    required this.onDelete,
    required this.audioPlayer,
    required this.setCurrentlyPlaying,
    required this.currentlyPlayingId,
    required this.encrypter,
    required this.textColor,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    final combinedItems = _mergeAndSortItems();

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: combinedItems.length,
      itemBuilder: (context, index) {
        final item = combinedItems[index];

        if (item['type'] == 'date-header') {
          return _buildDateHeader(item['date'], context);
        }

        if (item['type'] == 'interaction') {
          return _buildInteractionTile(item['data'], item['timestamp'], context);
        }

        final message = item['data'];
        return MessageWidget(
          message: message,
          isMe: message['sender_id'] == currentUserId,
          repliedToText: item['replied_to_text'],
          onReply: () => onReply(messages.indexOf(message)),
          onShare: () => onShare(message),
          onLongPress: () => onLongPress(message),
          onTapOriginal: () => onTapOriginal(messages.indexOf(message)),
          onDelete: () => onDelete(messages.indexOf(message)),
          audioPlayer: audioPlayer,
          setCurrentlyPlaying: setCurrentlyPlaying,
          currentlyPlayingId: currentlyPlayingId,
          encrypter: encrypter,
          isRead: message['is_read'] == true,
          isStoryReply: message['is_story_reply'] == true,
        );
      },
      cacheExtent: 1000.0,
    );
  }

List<Map<String, dynamic>> _mergeAndSortItems() {
  List<Map<String, dynamic>> combined = [];

  DateTime? lastDate;
  for (var m in messages) {
    final createdAtRaw = m['created_at'];

    if (createdAtRaw == null || createdAtRaw.toString().isEmpty) {
      debugPrint("⚠️ Skipping message with missing or empty 'created_at': ${m['id']}");
      continue;
    }

    DateTime? timestamp;
    try {
      timestamp = DateTime.parse(createdAtRaw.toString());
    } catch (e) {
      debugPrint("⚠️ Invalid date format for message ${m['id']}: $createdAtRaw");
      continue;
    }

    final date = DateTime(timestamp.year, timestamp.month, timestamp.day);

    if (lastDate == null || !isSameDay(lastDate, date)) {
      combined.add({'type': 'date-header', 'date': date});
      lastDate = date;
    }

    String? repliedToText;
    if (m['replied_to'] != null) {
      final replied = messages.firstWhere(
        (msg) => msg['id'] == m['replied_to'],
        orElse: () => {'message': 'Original message not found'},
      );

      try {
        repliedToText = replied['type'] == 'text' && replied['iv'] != null
            ? encrypter.decrypt64(
                replied['message'],
                iv: encrypt.IV.fromBase64(replied['iv']),
              )
            : replied['message'].toString();
      } catch (_) {
        repliedToText = '[Decryption Failed]';
      }
    }

    combined.add({
      'type': 'message',
      'data': m,
      'timestamp': timestamp,
      if (repliedToText != null) 'replied_to_text': repliedToText,
    });
  }

  for (var i in interactions) {
    DateTime timestamp;
    final rawTs = i['timestamp'];
    if (rawTs is DateTime) {
      timestamp = rawTs;
    } else {
      timestamp = DateTime.tryParse(rawTs.toString()) ?? DateTime.now();
    }

    combined.add({'type': 'interaction', 'data': i, 'timestamp': timestamp});
  }

  combined.sort((a, b) => a['timestamp'].compareTo(b['timestamp']));
  return combined;
}


  Widget _buildDateHeader(DateTime date, BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      alignment: Alignment.center,
      child: Text(
        getHeaderText(context, date),
        style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildInteractionTile(Map<String, dynamic> data, DateTime timestamp, BuildContext context) {
    final interactionType = data['type'];
    String message = switch (interactionType) {
      'like' => "You liked their story",
      'share' => "You shared their story",
      _ => "Unknown interaction"
    };

    return ListTile(
      leading: const Icon(Icons.notifications, color: Colors.deepPurple),
      title: Text(message, style: TextStyle(color: textColor)),
      subtitle: Text(
        DateFormat.yMMMd(Localizations.localeOf(context).languageCode).add_jm().format(timestamp),
        style: TextStyle(color: textColor.withOpacity(0.7)),
      ),
    );
  }

  bool isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String getHeaderText(BuildContext context, DateTime date) {
    final now = DateTime.now();
    if (isSameDay(date, now)) return "Today";
    if (isSameDay(date, now.subtract(const Duration(days: 1)))) return "Yesterday";
    return DateFormat.yMMMd(Localizations.localeOf(context).languageCode).format(date);
  }
}

// lib/utils/chat_utils.dart
String getChatId(String a, String b) =>
    a.compareTo(b) < 0 ? '$a\_$b' : '$b\_$a';

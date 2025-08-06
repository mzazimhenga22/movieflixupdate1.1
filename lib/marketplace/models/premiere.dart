// models/premiere.dart
class Premiere {
  final String? id;          // ← now a String?
  final String movieTitle;
  final String location;
  final DateTime date;
  final String organizerName;
  final String organizerEmail;

  Premiere({
    this.id,
    required this.movieTitle,
    required this.location,
    required this.date,
    required this.organizerName,
    required this.organizerEmail,
  });
}

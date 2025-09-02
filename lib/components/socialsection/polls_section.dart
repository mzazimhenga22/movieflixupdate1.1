// polls_section.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// PollsSection: displays active polls and allows logged-in user to vote.
/// Accepts `currentUser` as a Map (nullable) to match how you pass `_currentUser`.
class PollsSection extends StatelessWidget {
  final Color accentColor;
  final Map<String, dynamic>? currentUser;

  /// Optional: if provided, the polls will be filtered client-side by this key.
  /// Examples: 'all' | 'weekly' | 'movies' | 'users' or any exact category slug.
  final String categoryFilterKey;

  const PollsSection({
    super.key,
    required this.accentColor,
    required this.currentUser,
    this.categoryFilterKey = 'all',
  });

  @override
  Widget build(BuildContext context) {
    final Stream<QuerySnapshot> stream = FirebaseFirestore.instance
        .collection('polls')
        .where('active', isEqualTo: true)
        .orderBy('createdAt', descending: true)
        .snapshots();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      child: StreamBuilder<QuerySnapshot>(
        stream: stream,
        builder: (context, snap) {
          if (snap.hasError) {
            debugPrint('Polls stream error: ${snap.error}');
            final err = snap.error?.toString() ?? 'Unknown error';
            return _headerWithMessage('Failed to load polls', 'Error: $err');
          }

          if (snap.connectionState == ConnectionState.waiting) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Weekly polls',
                    style: TextStyle(
                        color: accentColor, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(children: [
                  const SizedBox(width: 12),
                  const CircularProgressIndicator()
                ]),
              ],
            );
          }

          final docs = snap.data?.docs ?? <QueryDocumentSnapshot>[];
          final filteredDocs = _applyFilterToDocs(docs, categoryFilterKey);

          if (filteredDocs.isEmpty) {
            return _headerWithMessage(
                'Weekly polls', 'No active polls right now — check back later!');
          }

          final ordered = filteredDocs;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Weekly polls',
                        style: TextStyle(
                            color: accentColor, fontWeight: FontWeight.bold)),
                    Text('Participate',
                        style:
                            TextStyle(color: Colors.white70, fontSize: 12)),
                  ]),
              const SizedBox(height: 8),
              ...ordered.map((doc) {
                final data = (doc.data() as Map<String, dynamic>?) ?? {};
                // options expected as List<Map> or List<dynamic>
                final optionsRaw = (data['options'] as List?) ?? <dynamic>[];
                // normalize options to List<Map<String,dynamic>> with id/label
                final options = optionsRaw.map<Map<String, dynamic>>((o) {
                  if (o is Map<String, dynamic>) {
                    return {
                      'id': (o['id'] ?? o['value'] ?? o['key'] ?? UniqueKey().toString()).toString(),
                      'label': (o['label'] ?? o['text'] ?? o['value'] ?? '').toString()
                    };
                  } else {
                    return {'id': o.toString(), 'label': o.toString()};
                  }
                }).toList();

                // votes stored as Map<userId, optionId> (most compact); convert to Map<String, String>
                final rawVotes = (data['votes'] as Map?) ?? <String, dynamic>{};
                final votes = rawVotes.map<String, String>((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));

                return Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: PollCard(
                    pollId: doc.id,
                    pollData: {
                      'title': data['title'] ?? data['question'] ?? '',
                      'category': data['category'] ?? '',
                      'start': data['start'],
                      'end': data['end'],
                    },
                    options: options,
                    votes: votes,
                    accentColor: accentColor,
                    currentUser: currentUser,
                  ),
                );
              }).toList(),
            ],
          );
        },
      ),
    );
  }

  List<QueryDocumentSnapshot> _applyFilterToDocs(
      List<QueryDocumentSnapshot> docs, String key) {
    if (key == 'all' || key.trim().isEmpty) return docs;
    final k = key.toLowerCase();
    return docs.where((doc) {
      final data = (doc.data() as Map<String, dynamic>?) ?? {};
      final cat = (data['category'] ?? '').toString().toLowerCase();
      if (k == 'weekly') return cat.contains('week') || cat.contains('weekly');
      if (k == 'movies') return cat.contains('movie');
      if (k == 'users') return cat.contains('user');
      // fallback exact match
      return cat == k;
    }).toList();
  }

  Widget _headerWithMessage(String title, String msg) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text(msg, style: const TextStyle(color: Colors.white70)),
    ]);
  }
}

/// PollCard: internal widget showing one poll. Behavior:
/// - If user hasn't voted: show clickable options only
/// - After vote: show counts + progress bars
class PollCard extends StatefulWidget {
  final String pollId;
  final Map<String, dynamic> pollData;
  final List<Map<String, dynamic>> options;
  final Map<String, String> votes; // Map<userId, optionId>
  final Color accentColor;
  final Map<String, dynamic>? currentUser;

  const PollCard({
    super.key,
    required this.pollId,
    required this.pollData,
    required this.options,
    required this.votes,
    required this.accentColor,
    required this.currentUser,
  });

  @override
  State<PollCard> createState() => _PollCardState();
}

class _PollCardState extends State<PollCard> {
  bool _isVoting = false;

  String? get _currentUserId => widget.currentUser?['id']?.toString();

  String? _userVotedOptionId(Map<String, String> votes) {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return null;
    return votes[uid];
  }

  Future<void> _vote(String optionId) async {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please log in to vote')));
      return;
    }
    if (_isVoting) return;
    setState(() => _isVoting = true);

    final docRef = FirebaseFirestore.instance.collection('polls').doc(widget.pollId);

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snapshot = await tx.get(docRef);
        if (!snapshot.exists) throw Exception('Poll not found');
        final votesObj = snapshot.data()?['votes'] as Map<String, dynamic>? ?? {};
        final existing = (votesObj[uid]?.toString() ?? '');
        if (existing == optionId) {
          // toggle off: delete the field votes.<uid>
          tx.update(docRef, { 'votes.$uid': FieldValue.delete() });
        } else {
          // set or change vote for this user
          tx.update(docRef, { 'votes.$uid': optionId });
        }
      });
    } catch (e) {
      debugPrint('Vote error: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Vote failed: $e')));
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  String _readableCategory(String cat) {
    switch (cat) {
      case 'best_feeds_week':
        return 'Top Feeds';
      case 'best_movie_week':
        return 'Best Movie';
      case 'user_of_week':
        return 'User of Week';
      case 'user_of_month':
        return 'User of Month';
      default:
        return (cat ?? '').toString().isEmpty ? 'Poll' : cat.replaceAll('_', ' ').toUpperCase();
    }
  }

  String _pollTimeframe(Map<String, dynamic> data) {
    try {
      final start = data['start']?.toString();
      final end = data['end']?.toString();
      if (start == null && end == null) return '';
      final s = start != null ? DateTime.parse(start).toLocal() : null;
      final e = end != null ? DateTime.parse(end).toLocal() : null;
      if (s != null && e != null) {
        return '${s.day}/${s.month} - ${e.day}/${e.month}';
      } else if (e != null) {
        return 'Ends ${e.day}/${e.month}';
      } else if (s != null) {
        return 'Starts ${s.day}/${s.month}';
      }
    } catch (_) {}
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.pollData['title']?.toString() ?? '';
    final category = widget.pollData['category']?.toString() ?? '';
    final votesMap = Map<String, String>.from(widget.votes); // userId -> optionId
    final totalVotes = votesMap.length;
    final userChoice = _userVotedOptionId(votesMap);
    final hasVoted = userChoice != null && userChoice.isNotEmpty;

    // build counts per option
    final Map<String, int> counts = {};
    for (final opt in widget.options) {
      final id = opt['id']?.toString() ?? '';
      counts[id] = votesMap.values.where((v) => v == id).length;
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: widget.accentColor.withOpacity(0.06)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 10, offset: const Offset(0, 6))],
      ),
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16))),
          const SizedBox(width: 8),
          if (category.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(color: widget.accentColor.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
              child: Text(_readableCategory(category), style: TextStyle(color: widget.accentColor, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
        ]),
        const SizedBox(height: 10),

        Column(
          children: widget.options.map((opt) {
            final id = opt['id']?.toString() ?? '';
            final label = opt['label']?.toString() ?? '';
            final count = counts[id] ?? 0;
            final pct = totalVotes == 0 ? 0.0 : (count / totalVotes).clamp(0.0, 1.0);
            final userPicked = userChoice == id;

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  if (widget.currentUser == null) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please log in to vote')));
                    return;
                  }
                  _vote(id);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: userPicked ? widget.accentColor.withOpacity(0.16) : Colors.white10,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: userPicked ? widget.accentColor : Colors.white12),
                  ),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
                          if (hasVoted) Text('$count', style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                        ]),
                        const SizedBox(height: 6),
                        if (hasVoted)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              minHeight: 8,
                              value: pct,
                              backgroundColor: Colors.white12,
                              valueColor: AlwaysStoppedAnimation<Color>(widget.accentColor),
                            ),
                          ),
                      ]),
                    ),
                    const SizedBox(width: 12),
                    _isVoting
                        ? SizedBox(width: 36, height: 36, child: CircularProgressIndicator(color: widget.accentColor, strokeWidth: 2))
                        : Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: userPicked ? widget.accentColor : Colors.transparent,
                              border: Border.all(color: userPicked ? widget.accentColor : Colors.white12),
                            ),
                            child: userPicked ? const Icon(Icons.check, size: 18, color: Colors.white) : const Icon(Icons.how_to_vote, size: 18, color: Colors.white54),
                          ),
                  ]),
                ),
              ),
            );
          }).toList(),
        ),

        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('$totalVotes votes', style: const TextStyle(color: Colors.white54, fontSize: 12)),
          Text(_pollTimeframe(widget.pollData), style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ]),
      ]),
    );
  }
}

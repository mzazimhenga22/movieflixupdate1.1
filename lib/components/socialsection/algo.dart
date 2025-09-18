// lib/components/socialsection/algo.dart
// Fair-ranking algorithm: balances engagement, freshness, personalization and
// reduces influence from follower count (caps celebrity effect).
//
// Usage:
// final ranked = Algo.rankPosts(posts, currentUser: currentUser, recentlySeenTags: [...], mode: 'for_everyone');

import 'dart:math' as math;

class Algo {
  /// Rank posts and return a new list sorted by descending score.
  /// posts: list of Map<String,dynamic> with keys optionally: timestamp (ISO string), likedBy (List), retweetCount (int),
  /// commentsCount (int), views (int), tags (String or List), followerCount (int), userId, etc.
  /// currentUser: optional map with 'id' and 'interests' (List<String>).
  /// recentlySeenTags: optional list of tags shown recently (for diversity penalty).
  /// mode: 'for_everyone' | 'trending' | 'personalized' | 'fresh'
  static List<Map<String, dynamic>> rankPosts(
    List<Map<String, dynamic>> posts, {
    Map<String, dynamic>? currentUser,
    List<String>? recentlySeenTags,
    String mode = 'for_everyone',
    int seed = 42,
  }) {
    final now = DateTime.now();
    // Defensive shallow copy so we don't mutate original objects
    final items = posts.map((p) => Map<String, dynamic>.from(p)).toList();

    // Precompute raw engagement values and find max (for normalization)
    double maxRawEng = 0.0;
    final rawEng = <int, double>{}; // index -> engagement

    for (int i = 0; i < items.length; i++) {
      final p = items[i];
      final likes = (p['likedBy'] as List?)?.length ?? 0;
      final retweets = (p['retweetCount'] as int?) ?? 0;
      final comments = (p['commentsCount'] as int?) ?? 0;
      final views = (p['views'] as int?) ?? 0;

      // Weighted engagement. Tune weights if needed.
      final engagement = likes + (retweets * 1.5) + (comments * 2) + (views * 0.05);
      rawEng[i] = engagement.toDouble();
      if (engagement > maxRawEng) maxRawEng = engagement.toDouble();
    }

    final denom = maxRawEng > 0 ? maxRawEng : 1.0;
    final rand = math.Random(seed);

    List<String> _asTagList(dynamic tags) {
      if (tags == null) return [];
      if (tags is String) {
        return tags.split(',').map((s) => s.trim().toLowerCase()).where((s) => s.isNotEmpty).toList();
      }
      if (tags is List) {
        try {
          return tags.cast<String>().map((s) => s.toLowerCase()).toList();
        } catch (_) {
          return tags.map((e) => e.toString().toLowerCase()).toList();
        }
      }
      return [];
    }

    final userInterests = (currentUser?['interests'] as List?)?.map((e) => e.toString().toLowerCase()).toSet() ?? <String>{};
    final seenTags = (recentlySeenTags ?? []).map((s) => s.toLowerCase()).toList();

    final scores = <int, double>{};

    for (int i = 0; i < items.length; i++) {
      final p = items[i];

      // parse timestamp safely
      DateTime ts;
      try {
        final t = p['timestamp'];
        if (t is DateTime) {
          ts = t;
        } else if (t is int) {
          ts = DateTime.fromMillisecondsSinceEpoch(t);
        } else if (t is String && t.isNotEmpty) {
          ts = DateTime.parse(t);
        } else {
          ts = now;
        }
      } catch (_) {
        ts = now;
      }

      final ageHours = now.difference(ts).inMinutes / 60.0;
      final engagementValue = (rawEng[i] ?? 0.0) + 1.0;

      // normalized engagement [0..1] using log-scaling
      final engagementNorm = math.log(engagementValue) / math.log(denom + 1.0);

      // Freshness: decays over time (24h scale)
      final freshness = 1.0 / (1.0 + ageHours / 24.0);

      // Personalization: tag overlap ratio
      final tags = _asTagList(p['tags']);
      double personalScore = 0.0;
      if (userInterests.isNotEmpty && tags.isNotEmpty) {
        final overlap = tags.where((t) => userInterests.contains(t)).length;
        personalScore = overlap / tags.length;
      }

      // follower penalty to dampen celebrities
      final followerCount = (p['followerCount'] as int?) ?? 0;
      final followerPenalty = followerCount <= 50 ? 0.0 : (log2(1 + followerCount) / log2(1 + 100000));

      // Diversity penalty if tags seen recently
      double diversityPenalty = 0.0;
      for (var t in tags) {
        if (seenTags.contains(t)) diversityPenalty += 0.2;
      }
      if (diversityPenalty > 0.8) diversityPenalty = 0.8;

      // Mode-dependent weights (tune as desired)
      double wEng = 0.4, wFresh = 0.25, wPers = 0.2, wBias = 0.15;
      if (mode == 'trending') {
        wEng = 0.6;
        wFresh = 0.2;
        wPers = 0.1;
        wBias = 0.1;
      } else if (mode == 'fresh') {
        wEng = 0.2;
        wFresh = 0.6;
        wPers = 0.15;
        wBias = 0.05;
      } else if (mode == 'personalized') {
        wEng = 0.35;
        wFresh = 0.2;
        wPers = 0.35;
        wBias = 0.1;
      } else if (mode == 'for_everyone') {
        wEng = 0.35;
        wFresh = 0.3;
        wPers = 0.2;
        wBias = 0.15;
      }

      // Exposure boost for low followers (in for_everyone mode)
      double lowFollowerBoost = 0.0;
      if (mode == 'for_everyone') {
        if (followerCount < 200) {
          lowFollowerBoost = ((200 - followerCount) / 200.0) * 0.15; // up to +0.15
        }
      }

      // Compose final score
      double score = (wEng * engagementNorm) + (wFresh * freshness) + (wPers * personalScore) + lowFollowerBoost - (wBias * followerPenalty) - diversityPenalty;

      // deterministic tiny jitter for tie-breaks
      score += (randDouble(rand) - 0.5) * 0.0001;

      scores[i] = score;
    }

    // Convert to list with scores attached
    final scored = <Map<String, dynamic>>[];
    for (int i = 0; i < items.length; i++) {
      final copy = Map<String, dynamic>.from(items[i]);
      copy['__score'] = scores[i] ?? 0.0;
      scored.add(copy);
    }

    // Sort descending by score
    scored.sort((a, b) => (b['__score'] as double).compareTo(a['__score'] as double));

    // Final fairness post-process: inject some low-popularity creators into top slots
    if (mode == 'for_everyone' && scored.isNotEmpty) {
      final topN = math.min(20, scored.length);
      final slotsToReplace = math.max(1, (topN * 0.20).round());
      final lowPop = scored.where((p) => (p['followerCount'] as int? ?? 0) < 500).toList();
      // shuffle deterministically
      lowPop.shuffle(rand);
      final replaced = List<Map<String, dynamic>>.from(scored);
      int inserted = 0;
      for (int i = 0; i < slotsToReplace && inserted < lowPop.length; i++) {
        // insert low-pop candidate at position i + inserted (spread)
        final pos = (i * 1 + inserted).clamp(0, replaced.length - 1);
        replaced[pos] = lowPop[inserted];
        inserted++;
      }
      return replaced;
    }

    return scored;
  }

  // helper random double generator using Random from dart:math
  static double randDouble(math.Random r) => r.nextDouble();

  // safe log2
  static double log2(num x) => x > 0 ? (math.log(x) / math.log(2)) : 0.0;
}

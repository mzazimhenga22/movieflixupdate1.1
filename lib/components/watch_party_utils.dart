// watch_party_utils.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:movie_app/settings_provider.dart';
import 'package:movie_app/streaming_service.dart';
import 'package:movie_app/tmdb_api.dart' as tmdb;
import 'watch_party_screen.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

void startControlsTimer(WatchPartyScreenState state) {
  state.hideControlsTimer();
}

/// Stronger alphanumeric party code (cryptographically seeded)
String generateSecurePartyCode() {
  const length = 6;
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // avoid ambiguous chars like I, O, 0, 1
  final rnd = Random.secure();
  final bytes = List<int>.generate(length, (_) => rnd.nextInt(256));
  // produce deterministic mapping to allowed chars
  final buffer = StringBuffer();
  for (var b in bytes) {
    buffer.write(chars[b % chars.length]);
  }
  return buffer.toString();
}

Future<void> fetchStreamingLinks(
    Map<String, dynamic> movie, WatchPartyScreenState state) async {
  try {
    final tmdbId = movie['id']?.toString() ?? '';
    final title = movie['title'] ?? state.title;
    final releaseDate = movie['release_date'] as String? ??
        movie['first_air_date'] as String? ??
        '1970-01-01';
    final releaseYear = int.parse(releaseDate.split('-')[0]);
    final streamingInfo = await StreamingService.getStreamingLink(
      tmdbId: tmdbId,
      title: title,
      releaseYear: releaseYear,
      resolution: '720p',
      enableSubtitles: false,
    );
    final streamUrl = streamingInfo['url'] ?? '';
    final subtitleUrl = streamingInfo['subtitleUrl'];
    final isHls = streamingInfo['type'] == 'm3u8';

    if (streamUrl.isNotEmpty && state.mounted) {
      state.updateStreamInfo(
        videoPath: streamUrl,
        title: streamingInfo['title'] ?? title,
        subtitleUrl: subtitleUrl,
        isHls: isHls,
      );
    } else {
      if (state.mounted) {
        showError(state.context, "No streaming links found for $title");
      }
    }
  } catch (e) {
    debugPrint("Streaming fetch error: $e");
    if (state.mounted) {
      showError(state.context, "Failed to fetch streaming links: $e");
    }
  }
}

Future<void> searchMovies(String query, WatchPartyScreenState state) async {
  if (query.isEmpty) {
    state.clearSearchResults();
    return;
  }
  state.startSearching();
  try {
    final results = await tmdb.TMDBApi.fetchSearchMovies(query);
    if (state.mounted) {
      state.updateSearchResults(
          results.cast<Map<String, dynamic>>()); // Cast to ensure correct type
    }
  } catch (e) {
    if (state.mounted) {
      showError(state.context, "Search failed: $e");
    }
  } finally {
    if (state.mounted) {
      state.stopSearching();
    }
  }
}

void showSuccess(BuildContext context, String message) {
  if (!context.mounted) return; // ✅ prevents error
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: Colors.green,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(12),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
  );
}

void showError(BuildContext context, String message) {
  if (!context.mounted) return; // ✅ prevents error
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: Colors.red,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(12),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
  );
}

void showPartyCode(BuildContext context, WatchPartyScreenState state) {
  if (state.mounted && state.partyCode != null) {
    final settings = context.read<SettingsProvider>();
    final referralLink = "https://watchparty.app/join/${state.partyCode}";
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Your party code: ${state.partyCode}\nReferral: $referralLink"),
        duration: const Duration(seconds: 5),
        backgroundColor: settings.accentColor,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        action: SnackBarAction(
          label: "Share",
          textColor: Colors.black,
          onPressed: () {
            showSuccess(context, "Referral link shared!");
            // NOTE: granting trial tickets on share should be server-verified,
            // but we keep a local bonus here for UX. Replace with server call later.
            if (!state.isPremium) {
              state.addTrialTicket();
              showSuccess(context, "Bonus trial ticket earned!");
            }
          },
        ),
      ),
    );
  }
}

void showTriviaDialog(BuildContext context, WatchPartyScreenState state) {
  final controller = TextEditingController();
  final settings = context.read<SettingsProvider>();

  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text("Movie Trivia"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Who is your favorite character?"),
          TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: "Enter your answer"),
          ),
        ],
      ),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12))),
      actions: [
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: settings.accentColor,
            shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(8))),
          ),
          onPressed: () {
            if (controller.text.isNotEmpty) {
              state.addTriviaMessage(controller.text);
              Navigator.pop(dialogContext);
              showSuccess(context, "Trivia answer submitted!");
            }
            controller.dispose();
          },
          child: const Text("Submit", style: TextStyle(color: Colors.black)),
        ),
      ],
    ),
  );
}

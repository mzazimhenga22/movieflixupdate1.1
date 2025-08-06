import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';

class PresenceService with WidgetsBindingObserver {
  final String userId;

  PresenceService(this.userId) {
    WidgetsBinding.instance.addObserver(this);
    _setOnline();
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _setOffline();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setOnline();
    } else if (state == AppLifecycleState.paused) {
      _setOffline();
    }
  }

  Future<void> _setOnline() async {
    final docRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(userId.split('_').first) // extract groupId if using composite
        .collection('presence')
        .doc(userId);

    await docRef.set({
      'isOnline': true,
      'lastSeen': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // Also update users collection for 1:1 presence
    await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .set({'isOnline': true}, SetOptions(merge: true));
  }

  Future<void> _setOffline() async {
    final docRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(userId.split('_').first)
        .collection('presence')
        .doc(userId);

    await docRef.set({
      'isOnline': false,
      'lastSeen': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .set({
      'isOnline': false,
      'lastSeen': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}


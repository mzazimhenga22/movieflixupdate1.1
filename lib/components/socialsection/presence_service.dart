import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';

class PresenceService extends ChangeNotifier with WidgetsBindingObserver {
  final String userId;
  final List<String>? groupIds;

  PresenceService(this.userId, {this.groupIds}) {
    WidgetsBinding.instance.addObserver(this);
    _setOnline();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _setOffline();
    super.dispose(); // ✅ Now valid because ChangeNotifier has dispose()
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
    await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .set({'isOnline': true, 'lastSeen': FieldValue.serverTimestamp()}, SetOptions(merge: true));

    if (groupIds != null) {
      for (String groupId in groupIds!) {
        await FirebaseFirestore.instance
            .collection('groups')
            .doc(groupId)
            .collection('presence')
            .doc(userId)
            .set({'isOnline': true, 'lastSeen': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      }
    }
  }

  Future<void> _setOffline() async {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .set({'isOnline': false, 'lastSeen': FieldValue.serverTimestamp()}, SetOptions(merge: true));

    if (groupIds != null) {
      for (String groupId in groupIds!) {
        await FirebaseFirestore.instance
            .collection('groups')
            .doc(groupId)
            .collection('presence')
            .doc(userId)
            .set({'isOnline': false, 'lastSeen': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      }
    }
  }
}

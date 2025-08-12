import 'package:flutter/material.dart';
import 'presence_service.dart';

class PresenceWrapper extends StatefulWidget {
  final Widget child;
  final String userId;
  final List<String>? groupIds; // Pass group IDs

  const PresenceWrapper({
    super.key,
    required this.child,
    required this.userId,
    this.groupIds,
  });

  @override
  State<PresenceWrapper> createState() => _PresenceWrapperState();
}

class _PresenceWrapperState extends State<PresenceWrapper> {
  PresenceService? _presenceService;

  @override
  void initState() {
    super.initState();
    _presenceService = PresenceService(widget.userId, groupIds: widget.groupIds);
  }

  @override
  void dispose() {
    _presenceService?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
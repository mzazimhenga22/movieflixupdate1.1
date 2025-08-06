import 'package:flutter/material.dart';
import 'presence_service.dart';

class PresenceWrapper extends StatefulWidget {
  final Widget child;
  final String userId;

  const PresenceWrapper({
    super.key,
    required this.child,
    required this.userId,
  });

  @override
  State<PresenceWrapper> createState() => _PresenceWrapperState();
}

class _PresenceWrapperState extends State<PresenceWrapper> {
  PresenceService? _presenceService;

  @override
  void initState() {
    super.initState();
    _presenceService = PresenceService(widget.userId);
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

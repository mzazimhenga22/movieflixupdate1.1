import 'package:flutter/material.dart';

class WatchPartyScreen extends StatelessWidget {
  const WatchPartyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Watch Party")),
      body: const Center(
        child: Text(
          "Watch Party Screen",
          style: TextStyle(fontSize: 20),
        ),
      ),
    );
  }
}

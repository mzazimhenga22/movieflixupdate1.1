// /chat/location_preview.dart
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class LocationPreview extends StatelessWidget {
  final double latitude;
  final double longitude;

  const LocationPreview({
    super.key,
    required this.latitude,
    required this.longitude,
  });

  void _openMap() async {
    final url = Uri.parse("https://www.google.com/maps/search/?api=1&query=$latitude,$longitude");
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final staticMapUrl =
        "https://maps.googleapis.com/maps/api/staticmap?center=$latitude,$longitude&zoom=15&size=600x300&markers=color:red%7C$latitude,$longitude&key=YOUR_API_KEY";

    return GestureDetector(
      onTap: _openMap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Image.network(
              staticMapUrl,
              height: 150,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(
                height: 150,
                child: Center(child: Text("Map unavailable")),
              ),
            ),
            const Icon(Icons.location_on, size: 40, color: Colors.red),
          ],
        ),
      ),
    );
  }
}

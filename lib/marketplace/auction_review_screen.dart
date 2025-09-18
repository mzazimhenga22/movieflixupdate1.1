import 'dart:convert';
import 'package:flutter/material.dart';
import 'marketplace_item_model.dart';

class AuctionReviewScreen extends StatelessWidget {
  final MarketplaceAuction auction;

  const AuctionReviewScreen({super.key, required this.auction});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Review Auction')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Name: ${auction.name}', style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Text('Description: ${auction.description}'),
            const SizedBox(height: 8),
            Text('Price: \$${auction.startingPrice.toStringAsFixed(2)}'),
            const SizedBox(height: 8),
            Text('Ends on: ${auction.endDate}'),
            if (auction.imageBase64 != null) ...[
              const SizedBox(height: 16),
              Image.memory(
                base64Decode(auction.imageBase64!),
                height: 200,
                fit: BoxFit.cover,
              ),
            ],
            const Spacer(),
            Center(
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Confirm & Post'),
              ),
            )
          ],
        ),
      ),
    );
  }
}

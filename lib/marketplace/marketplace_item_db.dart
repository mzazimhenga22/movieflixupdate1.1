import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'marketplace_item_model.dart';
import 'fan_events_screen.dart';

class MarketplaceItemDb {
  static final MarketplaceItemDb instance = MarketplaceItemDb._();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final SupabaseClient _supabase = Supabase.instance.client;
  final String _collection = 'marketplace_items';

  MarketplaceItemDb._();

  // Insert a new item to Firestore and upload image to Supabase
  Future<MarketplaceItem> insert(MarketplaceItem item) async {
    try {
      final itemId = _firestore.collection(_collection).doc().id;
      String? imageUrl;

      if (item is MarketplaceTicket && item.moviePoster?.isNotEmpty == true) {
        imageUrl = await _uploadImage(item.moviePoster!, itemId);
      } else if (item is MarketplaceCollectible && item.imageBase64?.isNotEmpty == true) {
        imageUrl = await _uploadImage(item.imageBase64!, itemId);
      } else if (item is MarketplaceAuction && item.imageBase64?.isNotEmpty == true) {
        imageUrl = await _uploadImage(item.imageBase64!, itemId);
      } else if (item is MarketplaceRental && item.imageBase64?.isNotEmpty == true) {
        imageUrl = await _uploadImage(item.imageBase64!, itemId);
      } else if (item is MarketplaceIndieFilm && item.videoBase64?.isNotEmpty == true) {
        imageUrl = await _uploadVideo(item.videoBase64!, itemId);
      }

      final updatedItem = item.copyWith(updates: {
        'id': itemId,
        if (imageUrl != null) 'imageUrl': imageUrl,
        if (item is MarketplaceTicket) 'movieId': item.movieId,
        if (item is MarketplaceTicket) 'location': item.location,
        if (item is MarketplaceTicket) 'date': item.date,
        if (item is MarketplaceCollectible) 'description': item.description,
        if (item is MarketplaceAuction) 'description': item.description,
        if (item is MarketplaceRental) 'description': item.description,
        if (item is MarketplacePremiere) 'location': item.location,
        if (item is MarketplacePremiere) 'date': item.date,
      });

      await _firestore.collection(_collection).doc(itemId).set(_toFirestore(updatedItem));
      debugPrint('Inserted item to Firestore with id: $itemId');
      return updatedItem;
    } catch (e) {
      debugPrint('Insertion error: $e');
      rethrow;
    }
  }

  // Insert a fan event to Firestore
  Future<void> insertFanEvent(FanEvent event) async {
    try {
      final eventId = _firestore.collection(_collection).doc().id;
      final updatedEvent = FanEvent(
        id: eventId,
        eventName: event.eventName,
        organizerName: event.organizerName,
        organizerEmail: event.organizerEmail,
        location: event.location,
        date: event.date,
        description: event.description,
        maxAttendees: event.maxAttendees,
      );
      await _firestore.collection(_collection).doc(eventId).set(_toFirestore(updatedEvent));
      debugPrint('Inserted fan event to Firestore with id: $eventId');
    } catch (e) {
      debugPrint('Fan event insertion error: $e');
      rethrow;
    }
  }

  // Update a fan event in Firestore
  Future<void> updateFanEvent(FanEvent event) async {
    try {
      await _firestore.collection(_collection).doc(event.id).update(_toFirestore(event));
      debugPrint('Updated fan event in Firestore with id: ${event.id}');
    } catch (e) {
      debugPrint('Fan event update error: $e');
      rethrow;
    }
  }

  // Read all items from Firestore, newest first
  Future<List<MarketplaceItem>> getAll() async {
    try {
      final snapshot = await _firestore
          .collection(_collection)
          .orderBy('created_at', descending: true)
          .get();
      debugPrint('Fetched ${snapshot.docs.length} items from Firestore');
      return snapshot.docs
          .map((doc) => _fromFirestore(doc))
          .whereType<MarketplaceItem>()
          .toList();
    } catch (e) {
      debugPrint('Retrieval error: $e');
      return [];
    }
  }

  // Read items by type from Firestore
  Future<List<MarketplaceItem>> getByType(String type) async {
    try {
      final snapshot = await _firestore
          .collection(_collection)
          .where('type', isEqualTo: type)
          .orderBy('created_at', descending: true)
          .get();
      debugPrint('Fetched ${snapshot.docs.length} $type items from Firestore');
      return snapshot.docs
          .map((doc) => _fromFirestore(doc))
          .whereType<MarketplaceItem>()
          .toList();
    } catch (e) {
      debugPrint('Retrieval error for type $type: $e');
      return [];
    }
  }

  // Read items by sellerEmail from Firestore
  Future<List<MarketplaceItem>> getBySeller(String sellerEmail) async {
    try {
      final snapshot = await _firestore
          .collection(_collection)
          .where('sellerEmail', isEqualTo: sellerEmail)
          .orderBy('created_at', descending: true)
          .get();
      debugPrint('Fetched ${snapshot.docs.length} items for $sellerEmail from Firestore');
      return snapshot.docs
          .map((doc) => _fromFirestore(doc))
          .whereType<MarketplaceItem>()
          .toList();
    } catch (e) {
      debugPrint('Retrieval error for seller $sellerEmail: $e');
      return [];
    }
  }

  // Update an existing item in Firestore
  Future<MarketplaceItem> update(MarketplaceItem item) async {
    try {
      String? imageUrl;
      if (item is MarketplaceTicket && item.moviePoster?.isNotEmpty == true) {
        imageUrl = await _uploadImage(item.moviePoster!, item.id!);
      } else if (item is MarketplaceCollectible && item.imageBase64?.isNotEmpty == true) {
        imageUrl = await _uploadImage(item.imageBase64!, item.id!);
      } else if (item is MarketplaceAuction && item.imageBase64?.isNotEmpty == true) {
        imageUrl = await _uploadImage(item.imageBase64!, item.id!);
      } else if (item is MarketplaceRental && item.imageBase64?.isNotEmpty == true) {
        imageUrl = await _uploadImage(item.imageBase64!, item.id!);
      } else if (item is MarketplaceIndieFilm && item.videoBase64?.isNotEmpty == true) {
        imageUrl = await _uploadVideo(item.videoBase64!, item.id!);
      }

      final updatedItem = item.copyWith(updates: {
        if (imageUrl != null) 'imageUrl': imageUrl,
        if (item is MarketplaceTicket) 'movieId': item.movieId,
        if (item is MarketplaceTicket) 'location': item.location,
        if (item is MarketplaceTicket) 'date': item.date,
        if (item is MarketplaceCollectible) 'description': item.description,
        if (item is MarketplaceAuction) 'description': item.description,
        if (item is MarketplaceRental) 'description': item.description,
        if (item is MarketplacePremiere) 'location': item.location,
        if (item is MarketplacePremiere) 'date': item.date,
      });

      await _firestore.collection(_collection).doc(item.id).update(_toFirestore(updatedItem));
      debugPrint('Updated item in Firestore with id: ${item.id}');
      return updatedItem;
    } catch (e) {
      debugPrint('Update error: $e');
      rethrow;
    }
  }

  // Delete an item from Firestore and Supabase storage
  Future<void> delete(String id) async {
    try {
      await _firestore.collection(_collection).doc(id).delete();
      await _supabase.storage.from('marketplace').remove(['marketplace_images/$id.jpg']);
      debugPrint('Deleted item from Firestore and Supabase with id: $id');
    } catch (e) {
      debugPrint('Deletion error: $e');
      rethrow;
    }
  }

  // Clear the entire Firestore collection (for debugging)
  Future<void> clearDatabase() async {
    try {
      final snapshot = await _firestore.collection(_collection).get();
      for (var doc in snapshot.docs) {
        await doc.reference.delete();
        await _supabase.storage.from('marketplace').remove(['marketplace_images/${doc.id}.jpg']);
      }
      debugPrint('Cleared Firestore collection and Supabase storage');
    } catch (e) {
      debugPrint('Clear database error: $e');
      rethrow;
    }
  }

  // Read all fan events from Firestore
  Future<List<FanEvent>> getFanEvents() async {
    try {
      final snapshot = await _firestore
          .collection(_collection)
          .where('type', isEqualTo: 'fan_event')
          .orderBy('created_at', descending: true)
          .get();
      debugPrint('Fetched ${snapshot.docs.length} fan events from Firestore');
      return snapshot.docs
          .map((doc) => _fromFirestore(doc))
          .whereType<FanEvent>()
          .toList();
    } catch (e) {
      debugPrint('Fan events retrieval error: $e');
      return [];
    }
  }

  // Upload image to Supabase storage and return URL
  Future<String?> _uploadImage(String base64Image, String itemId) async {
    try {
      final bytes = base64Decode(
        base64Image.contains(',') ? base64Image.split(',').last : base64Image,
      );
      final filePath = 'marketplace_images/$itemId.jpg';
      await _supabase.storage.from('marketplace').uploadBinary(filePath, bytes);
      final publicUrl = _supabase.storage.from('marketplace').getPublicUrl(filePath);
      return publicUrl;
    } catch (e) {
      debugPrint('Error uploading image to Supabase: $e');
      return null;
    }
  }

  // Upload video to Supabase storage and return URL
  Future<String?> _uploadVideo(String base64Video, String itemId) async {
    try {
      final bytes = base64Decode(
        base64Video.contains(',') ? base64Video.split(',').last : base64Video,
      );
      final filePath = 'marketplace_videos/$itemId.mp4';
      await _supabase.storage.from('marketplace').uploadBinary(filePath, bytes);
      final publicUrl = _supabase.storage.from('marketplace').getPublicUrl(filePath);
      return publicUrl;
    } catch (e) {
      debugPrint('Error uploading video to Supabase: $e');
      return null;
    }
  }

  // Convert Firestore document to MarketplaceItem or FanEvent
  dynamic _fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final type = data['type'] as String;
    switch (type) {
      case 'ticket':
        return MarketplaceTicket(
          id: doc.id,
          movieId: (data['movieId'] as num?)?.toInt() ?? 0,
          movieTitle: data['movieTitle'] ?? '',
          moviePoster: data['imageUrl'] ?? '',
          price: (data['price'] as num?)?.toDouble() ?? 0.0,
          sellerName: data['sellerName'] ?? '',
          sellerEmail: data['sellerEmail'] ?? '',
          location: data['location'] ?? '',
          date: data['date'] ?? '',
          seats: (data['seats'] as num?)?.toInt() ?? 0,
          seatDetails: data['seatDetails'] ?? '',
          ticketFileBase64: data['ticketFileBase64'] ?? '',
          isLocked: data['isLocked'] == true,
        );
      case 'collectible':
        return MarketplaceCollectible(
          id: doc.id,
          name: data['name'] ?? '',
          description: data['description'] ?? '',
          imageBase64: data['imageUrl'] ?? '',
          price: (data['price'] as num?)?.toDouble() ?? 0.0,
          sellerName: data['sellerName'] ?? '',
          sellerEmail: data['sellerEmail'] ?? '',
          authenticityDocBase64: data['authenticityDocBase64'] ?? '',
        );
      case 'auction':
        return MarketplaceAuction(
          id: doc.id,
          name: data['name'] ?? '',
          description: data['description'] ?? '',
          imageBase64: data['imageUrl'] ?? '',
          startingPrice: (data['startingPrice'] as num?)?.toDouble() ?? 0.0,
          endDate: data['endDate'] ?? '',
          sellerName: data['sellerName'] ?? '',
          sellerEmail: data['sellerEmail'] ?? '',
        );
      case 'rental':
        return MarketplaceRental(
          id: doc.id,
          name: data['name'] ?? '',
          description: data['description'] ?? '',
          imageBase64: data['imageUrl'] ?? '',
          pricePerDay: (data['pricePerDay'] as num?)?.toDouble() ?? 0.0,
          minDays: (data['minDays'] as num?)?.toInt() ?? 1,
          sellerName: data['sellerName'] ?? '',
          sellerEmail: data['sellerEmail'] ?? '',
        );
      case 'indie_film':
        return MarketplaceIndieFilm(
          id: doc.id,
          title: data['title'] ?? '',
          synopsis: data['synopsis'] ?? '',
          fundingGoal: (data['fundingGoal'] as num?)?.toDouble() ?? 0.0,
          videoBase64: data['videoUrl'] ?? '',
          creatorName: data['sellerName'] ?? '',
          creatorEmail: data['sellerEmail'] ?? '',
        );
      case 'premiere':
        return MarketplacePremiere(
          id: doc.id,
          movieTitle: data['movieTitle'] ?? '',
          location: data['location'] ?? '',
          date: data['date'] is String ? DateTime.parse(data['date']) : DateTime.now(),
          organizerName: data['sellerName'] ?? '',
          organizerEmail: data['sellerEmail'] ?? '',
        );
      case 'fan_event':
        return FanEvent(
          id: doc.id,
          eventName: data['eventName'] ?? '',
          organizerName: data['sellerName'] ?? '',
          organizerEmail: data['sellerEmail'] ?? '',
          location: data['location'] ?? '',
          date: data['date'] is String ? DateTime.parse(data['date']) : DateTime.now(),
          description: data['description'] ?? '',
          maxAttendees: (data['maxAttendees'] as num?)?.toInt() ?? 0,
        );
      default:
        throw Exception('Unknown item type: $type');
    }
  }

  // Convert MarketplaceItem or FanEvent to Firestore data
  Map<String, dynamic> _toFirestore(dynamic item) {
    final baseData = {
      'id': item.id,
      'sellerName': item.sellerName ?? item.organizerName,
      'sellerEmail': item.sellerEmail ?? item.organizerEmail,
      if (item.id == null) 'created_at': FieldValue.serverTimestamp(),
      'isHidden': item.isHidden ?? false,
    };

    if (item is MarketplaceTicket) {
      return {
        ...baseData,
        'type': 'ticket',
        'movieId': item.movieId,
        'movieTitle': item.movieTitle,
        'imageUrl': item.moviePoster,
        'price': item.price,
        'location': item.location,
        'date': item.date,
        'seats': item.seats,
        'seatDetails': item.seatDetails,
        'ticketFileBase64': item.ticketFileBase64,
        'isLocked': item.isLocked,
      };
    } else if (item is MarketplaceCollectible) {
      return {
        ...baseData,
        'type': 'collectible',
        'name': item.name,
        'description': item.description,
        'imageUrl': item.imageBase64,
        'price': item.price,
        'authenticityDocBase64': item.authenticityDocBase64,
      };
    } else if (item is MarketplaceAuction) {
      return {
        ...baseData,
        'type': 'auction',
        'name': item.name,
        'description': item.description,
        'imageUrl': item.imageBase64,
        'startingPrice': item.startingPrice,
        'endDate': item.endDate,
      };
    } else if (item is MarketplaceRental) {
      return {
        ...baseData,
        'type': 'rental',
        'name': item.name,
        'description': item.description,
        'imageUrl': item.imageBase64,
        'pricePerDay': item.pricePerDay,
        'minDays': item.minDays,
      };
    } else if (item is MarketplaceIndieFilm) {
      return {
        ...baseData,
        'type': 'indie_film',
        'title': item.title,
        'synopsis': item.synopsis,
        'fundingGoal': item.fundingGoal,
        'videoUrl': item.videoBase64,
      };
    } else if (item is MarketplacePremiere) {
      return {
        ...baseData,
        'type': 'premiere',
        'movieTitle': item.movieTitle,
        'location': item.location,
        'date': item.date.toIso8601String(),
      };
    } else if (item is FanEvent) {
      return {
        ...baseData,
        'type': 'fan_event',
        'eventName': item.eventName,
        'location': item.location,
        'date': item.date.toIso8601String(),
        'description': item.description,
        'maxAttendees': item.maxAttendees,
      };
    } else {
      throw Exception('Unknown item type');
    }
  }

  // Insert a premiere to Firestore
  Future<void> insertPremiere(MarketplacePremiere premiere) async {
    try {
      await insert(premiere);
      debugPrint('Inserted premiere to Firestore with id: ${premiere.id}');
    } catch (e) {
      debugPrint('Premiere insertion error: $e');
      rethrow;
    }
  }

  // Update a premiere in Firestore
  Future<void> updatePremiere(MarketplacePremiere premiere) async {
    try {
      await update(premiere);
      debugPrint('Updated premiere in Firestore with id: ${premiere.id}');
    } catch (e) {
      debugPrint('Premiere update error: $e');
      rethrow;
    }
  }
}
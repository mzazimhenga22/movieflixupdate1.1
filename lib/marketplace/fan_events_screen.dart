import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:movie_app/marketplace/marketplace_item_db.dart';

class FanEvent {
  final String? id;
  final String eventName;
  final String description;
  final DateTime date;
  final String location;
  final int maxAttendees;
  final String organizerName;
  final String organizerEmail;

  FanEvent({
    this.id,
    required this.eventName,
    required this.description,
    required this.date,
    required this.location,
    required this.maxAttendees,
    required this.organizerName,
    required this.organizerEmail,
  });

  Map<String, dynamic> toSqlMap() => {
        'id': id,
        'type': 'fan_event',
        'name': eventName,
        'description': description,
        'date': date.toIso8601String(),
        'location': location,
        'maxAttendees': maxAttendees,
        'organizerName': organizerName,
        'organizerEmail': organizerEmail,
      };

  factory FanEvent.fromSql(Map<String, dynamic> row) => FanEvent(
        id: row['id']?.toString(),
        eventName: row['name'] as String? ?? 'Unknown',
        description: row['description'] as String? ?? '',
        date: DateTime.parse(
            row['date'] as String? ?? DateTime.now().toIso8601String()),
        location: row['location'] as String? ?? '',
        maxAttendees: row['maxAttendees'] as int? ?? 0,
        organizerName: row['organizerName'] as String? ?? '',
        organizerEmail: row['organizerEmail'] as String? ?? '',
      );
}

class FanEventsScreen extends StatefulWidget {
  final String userName;
  final String userEmail;
  final FanEvent? existingEvent;
  final VoidCallback? onPosted;

  const FanEventsScreen({
    super.key,
    required this.userName,
    required this.userEmail,
    this.existingEvent,
    this.onPosted,
  });

  @override
  State<FanEventsScreen> createState() => _FanEventsScreenState();
}

class _FanEventsScreenState extends State<FanEventsScreen> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _attendeesCtrl = TextEditingController();
  DateTime? _eventDate;

  final accent = Colors.purpleAccent;

  @override
  void initState() {
    super.initState();
    final e = widget.existingEvent;
    if (e != null) {
      _nameCtrl.text = e.eventName;
      _descCtrl.text = e.description;
      _locationCtrl.text = e.location;
      _attendeesCtrl.text = e.maxAttendees.toString();
      _eventDate = e.date;
    }
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: GoogleFonts.poppins(color: Colors.white70),
      filled: true,
      fillColor: Colors.white.withOpacity(0.1),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accent),
      ),
    );
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _eventDate ?? DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 180)),
    );
    if (picked != null) {
      setState(() => _eventDate = picked);
    }
  }

  Future<void> _createEvent() async {
    if (_nameCtrl.text.isEmpty ||
        _descCtrl.text.isEmpty ||
        _locationCtrl.text.isEmpty ||
        _attendeesCtrl.text.isEmpty ||
        _eventDate == null) {
      _showMessage('Please fill all required fields');
      return;
    }

    try {
      final attendees = int.parse(_attendeesCtrl.text);
      if (attendees <= 0) throw 'Max attendees must be greater than 0';
      if (_eventDate!.isBefore(DateTime.now())) {
        throw 'Event date must be in the future';
      }

      final event = FanEvent(
        id: widget.existingEvent?.id,
        eventName: _nameCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        date: _eventDate!,
        location: _locationCtrl.text.trim(),
        maxAttendees: attendees,
        organizerName: widget.userName,
        organizerEmail: widget.userEmail,
      );

      final db = MarketplaceItemDb.instance;
      if (widget.existingEvent != null) {
        await db.updateFanEvent(event);
      } else {
        await db.insertFanEvent(event);
      }

      if (mounted) {
        _showMessage(
          'Event ${widget.existingEvent != null ? 'updated' : 'created'} successfully',
        );
        widget.onPosted?.call();
        Navigator.pop(context, true);
      }
    } catch (e) {
      _showMessage('Invalid input: $e');
    }
  }

  void _showMessage(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateText = _eventDate == null
        ? 'Select Event Date'
        : 'Date: ${DateFormat.yMMMd().format(_eventDate!)}';

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.5,
            colors: [accent.withOpacity(0.3), const Color(0xFF121212)],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Plan a Fan Event',
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _nameCtrl,
                  decoration: _inputDecoration('Event Name'),
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _descCtrl,
                  decoration: _inputDecoration('Event Description'),
                  style: GoogleFonts.poppins(color: Colors.white),
                  maxLines: 4,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _locationCtrl,
                  decoration: _inputDecoration('Location'),
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _attendeesCtrl,
                  decoration: _inputDecoration('Max Attendees'),
                  keyboardType: TextInputType.number,
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: _selectDate,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      dateText,
                      style: GoogleFonts.poppins(color: Colors.white70),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _createEvent,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    widget.existingEvent != null
                        ? 'Update Event'
                        : 'Create Event',
                    style: GoogleFonts.poppins(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _locationCtrl.dispose();
    _attendeesCtrl.dispose();
    super.dispose();
  }
}

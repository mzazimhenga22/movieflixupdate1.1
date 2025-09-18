import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:movie_app/marketplace/marketplace_item_db.dart';
import 'package:movie_app/marketplace/marketplace_item_model.dart';

class PremieresScreen extends StatefulWidget {
  final String userName;
  final String userEmail;
  final MarketplacePremiere? existingPremiere;

  const PremieresScreen({
    super.key,
    required this.userName,
    required this.userEmail,
    this.existingPremiere,
  });

  @override
  State<PremieresScreen> createState() => _PremieresScreenState();
}

class _PremieresScreenState extends State<PremieresScreen> {
  final _titleCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  DateTime? _premiereDate;

  @override
  void initState() {
    super.initState();
    final p = widget.existingPremiere;
    if (p != null) {
      _titleCtrl.text = p.movieTitle;
      _locationCtrl.text = p.location;
      _premiereDate = p.date;
    }
  }

  Future<void> _selectDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date != null && mounted) {
      setState(() => _premiereDate = date);
    }
  }

  Future<void> _createPremiere() async {
    if (_titleCtrl.text.isEmpty ||
        _locationCtrl.text.isEmpty ||
        _premiereDate == null) {
      _showSnack('Please fill all required fields');
      return;
    }

    try {
      if (_premiereDate!.isBefore(DateTime.now())) {
        throw Exception('Premiere date must be in the future');
      }

      final premiere = MarketplacePremiere(
        id: widget.existingPremiere?.id,
        movieTitle: _titleCtrl.text.trim(),
        location: _locationCtrl.text.trim(),
        date: _premiereDate!,
        organizerName: widget.userName,
        organizerEmail: widget.userEmail,
        isHidden: widget.existingPremiere?.isHidden ?? false,
      );

      final db = MarketplaceItemDb.instance;
      if (widget.existingPremiere != null) {
        await db.updatePremiere(premiere);
      } else {
        await db.insertPremiere(premiere);
      }

      _showSnack('Premiere ${widget.existingPremiere != null ? 'updated' : 'created'} successfully');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _showSnack('Error: $e');
    }
  }

  void _showSnack(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    const accent = Colors.redAccent;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: const AssetImage('assets/cinema_background.jpg'),
            fit: BoxFit.cover,
            colorFilter: ColorFilter.mode(
                Colors.black.withOpacity(0.6), BlendMode.darken),
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Create Premiere',
                    style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                _buildTextField(_titleCtrl, 'Movie Title'),
                const SizedBox(height: 16),
                _buildTextField(_locationCtrl, 'Location (e.g., Theater, City)'),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: _selectDate,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Text(
                      _premiereDate == null
                          ? 'Select Premiere Date'
                          : 'Date: ${_premiereDate!.toLocal().toString().split(' ')[0]}',
                      style: GoogleFonts.poppins(color: Colors.white70),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _createPremiere,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    minimumSize: const Size(double.infinity, 60),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15)),
                  ),
                  child: Text(
                    widget.existingPremiere != null
                        ? 'Update Premiere'
                        : 'Create Premiere',
                    style: GoogleFonts.poppins(
                        color: Colors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.poppins(color: Colors.white70),
        filled: true,
        fillColor: Colors.black.withOpacity(0.4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: const BorderSide(color: Colors.redAccent),
        ),
      ),
      style: GoogleFonts.poppins(color: Colors.white),
    );
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }
}
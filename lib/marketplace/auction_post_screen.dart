import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'marketplace_item_model.dart';
import 'marketplace_item_db.dart';
import 'auction_review_screen.dart';


// Imports remain the same...

class AuctionPostScreen extends StatefulWidget {
  final String userName;
  final String userEmail;
  final MarketplaceAuction? existingAuction;
  final VoidCallback? onPosted;

  const AuctionPostScreen({
    super.key,
    required this.userName,
    required this.userEmail,
    this.existingAuction,
    this.onPosted,
  });

  @override
  State<AuctionPostScreen> createState() => _AuctionPostScreenState();
}

class _AuctionPostScreenState extends State<AuctionPostScreen> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _startPriceCtrl = TextEditingController();
  final _endDateCtrl = TextEditingController();
  Uint8List? _imageBytes;
  File? _imageFile;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    if (widget.existingAuction case final a?) {
      _nameCtrl.text = a.name;
      _descCtrl.text = a.description;
      _startPriceCtrl.text = a.startingPrice.toString();
      _endDateCtrl.text = a.endDate;
      _imageBytes = a.imageBase64 != null ? base64Decode(a.imageBase64!) : null;
    }
  }

Future<void> _pickImage(ImageSource source) async {
  try {
    final picked = await _picker.pickImage(source: source, maxWidth: 800);
    if (picked != null) {
      if (kIsWeb) {
        final bytes = await picked.readAsBytes(); // ✅ await outside setState
        setState(() {
          _imageBytes = bytes; // ✅ Store image bytes for web
          _imageFile = null;
        });
      } else {
        setState(() {
          _imageFile = File(picked.path); // ✅ Store File for mobile
          _imageBytes = null;
        });
      }
    }
  } catch (e) {
    debugPrint('Image pick error: $e');
  }
}


  Future<void> _selectEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.existingAuction != null
          ? DateTime.tryParse(widget.existingAuction!.endDate) ?? DateTime.now()
          : DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) _endDateCtrl.text = picked.toIso8601String();
  }

  Future<void> _save() async {
    if (_nameCtrl.text.isEmpty ||
        _descCtrl.text.isEmpty ||
        _startPriceCtrl.text.isEmpty ||
        _endDateCtrl.text.isEmpty) {
      _showSnack('Please fill all required fields');
      return;
    }

    try {
      final price = double.parse(_startPriceCtrl.text.replaceAll(RegExp(r'[^\d.]'), ''));
      if (price <= 0) throw 'Starting price must be > 0';

      String? imageBase64;
      if (_imageBytes != null) {
        imageBase64 = base64Encode(_imageBytes!);
      } else if (_imageFile != null) {
        imageBase64 = base64Encode(await _imageFile!.readAsBytes());
      }

      final auction = MarketplaceAuction(
        id: widget.existingAuction?.id,
        name: _nameCtrl.text,
        description: _descCtrl.text,
        startingPrice: price,
        endDate: _endDateCtrl.text,
        imageBase64: imageBase64,
        sellerName: widget.userName,
        sellerEmail: widget.userEmail,
        isHidden: widget.existingAuction?.isHidden ?? false,
      );

      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => AuctionReviewScreen(auction: auction)),
      );

      if (result == true && mounted) {
        _showSnack('Auction ${widget.existingAuction != null ? 'updated' : 'posted'} successfully');
        widget.onPosted?.call();
        Navigator.pop(context, true);
      }
    } catch (e) {
      _showSnack('Invalid input: $e');
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    const accent = Colors.greenAccent;

    return Container(
      decoration: _bgGradient(accent),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: GlassBox(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _TitleText('Post an Auction'),
              const SizedBox(height: 16),
              _AuctionTextField(controller: _nameCtrl, label: 'Auction Name'),
              const SizedBox(height: 16),
              _AuctionTextField(controller: _descCtrl, label: 'Description', maxLines: 3),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _AuctionTextField(
                      controller: _startPriceCtrl,
                      label: 'Starting Price (\$)',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: GestureDetector(
                      onTap: _selectEndDate,
                      child: AbsorbPointer(
                        child: _AuctionTextField(controller: _endDateCtrl, label: 'End Date'),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _ImagePickerBox(
                imageBytes: _imageBytes,
                imageFile: _imageFile,
                onTap: () => _showImagePickerDialog(context),
              ),
              const SizedBox(height: 24),
              Center(
                child: ElevatedButton(
                  onPressed: _save,
                  style: _buttonStyle(accent),
                  child: Text(
                    widget.existingAuction != null ? 'Update' : 'Save',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showImagePickerDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text('Choose Image Source', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _pickImage(ImageSource.gallery);
            },
            child: const Text('Gallery', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _pickImage(ImageSource.camera);
            },
            child: const Text('Camera', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
BoxDecoration _bgGradient(Color accent) => BoxDecoration(
      color: const Color(0xFF111927),
      gradient: RadialGradient(
        center: const Alignment(0.0, -0.6),
        radius: 1.2,
        colors: [accent.withOpacity(0.2), Colors.transparent],
      ),
    );

ButtonStyle _buttonStyle(Color color) => ElevatedButton.styleFrom(
      backgroundColor: color,
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );

class _AuctionTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final TextInputType keyboardType;
  final int maxLines;

  const _AuctionTextField({
    required this.controller,
    required this.label,
    this.keyboardType = TextInputType.text,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: Colors.white.withOpacity(0.1),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.greenAccent)),
      ),
    );
  }
}

class _ImagePickerBox extends StatelessWidget {
  final Uint8List? imageBytes;
  final File? imageFile;
  final VoidCallback onTap;

  const _ImagePickerBox({
    required this.imageBytes,
    required this.imageFile,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final image = imageBytes != null
        ? Image.memory(imageBytes!, fit: BoxFit.cover)
        : imageFile != null
            ? Image.file(imageFile!, fit: BoxFit.cover)
            : const Center(
                child: Text(
                  'Tap to add auction image',
                  style: TextStyle(color: Colors.white70),
                ),
              );

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 150,
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.2)),
        ),
        child: image,
      ),
    );
  }
}

class _TitleText extends StatelessWidget {
  final String text;
  const _TitleText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

class GlassBox extends StatelessWidget {
  final Widget child;
  const GlassBox({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.2)),
          ),
          child: child,
        ),
      ),
    );
  }
}

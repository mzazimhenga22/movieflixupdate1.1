import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lottie/lottie.dart';
import 'marketplace_item_model.dart';
import 'marketplace_item_db.dart';

class CheckoutScreen extends StatelessWidget {
  final Map<String, int> cart;
  final List<MarketplaceTicket> tickets;

  const CheckoutScreen({
    super.key,
    required this.cart,
    required this.tickets,
  });

  void _showPaymentSheet(BuildContext context, VoidCallback onConfirm) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PaymentSheet(onConfirm: onConfirm),
    );
  }

  void _simulateStripePayment(BuildContext context, VoidCallback onSuccess) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Lottie.network(
          'https://assets.lottiefiles.com/packages/lf20_uwos7qsy.json',
          width: 100,
          height: 100,
          fit: BoxFit.contain,
        ),
      ),
    );

    await Future.delayed(const Duration(seconds: 2));

    if (context.mounted) {
      Navigator.pop(context);
      onSuccess();
    }
  }

  @override
  Widget build(BuildContext context) {
    const Color accent = Colors.blueAccent;
    final double total = tickets.fold(
      0,
      (sum, ticket) => sum + ticket.price * (cart[ticket.id!] ?? 0),
    );

    return Scaffold(
      appBar: const _CustomAppBar(title: 'Checkout'),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle('Order Summary'),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: tickets.length,
                itemBuilder: (context, index) {
                  final ticket = tickets[index];
                  final quantity = cart[ticket.id!] ?? 0;
                  return quantity > 0 ? _TicketSummaryTile(ticket: ticket, quantity: quantity) : const SizedBox.shrink();
                },
              ),
            ),
            const Divider(color: Colors.grey, height: 24),
            Text(
              'Total: \$${total.toStringAsFixed(2)}',
              style: GoogleFonts.poppins(
                color: accent,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: ElevatedButton(
                onPressed: () {
                  _showPaymentSheet(context, () {
                    _simulateStripePayment(context, () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TicketConfirmationScreen(tickets: tickets, cart: cart),
                        ),
                      );
                    });
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(
                  'Confirm Purchase',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentSheet extends StatefulWidget {
  final VoidCallback onConfirm;

  const _PaymentSheet({required this.onConfirm});

  @override
  _PaymentSheetState createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  final _cardNumberController = TextEditingController();
  final _expiryController = TextEditingController();
  final _cvcController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Choose Payment Method',
              style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.credit_card, color: Colors.white),
              title: const Text('Credit Card', style: TextStyle(color: Colors.white)),
              onTap: () => _showCardForm(context),
            ),
            ListTile(
              leading: const Icon(Icons.account_balance_wallet, color: Colors.white),
              title: const Text('Apple Pay / Google Pay', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                widget.onConfirm();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showCardForm(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 20,
            right: 20,
            top: 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter Card Details',
                style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _cardNumberController,
                decoration: const InputDecoration(
                  labelText: 'Card Number',
                  labelStyle: TextStyle(color: Colors.white70),
                  filled: true,
                  fillColor: Colors.grey,
                  border: OutlineInputBorder(borderSide: BorderSide.none),
                ),
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _expiryController,
                      decoration: const InputDecoration(
                        labelText: 'MM/YY',
                        labelStyle: TextStyle(color: Colors.white70),
                        filled: true,
                        fillColor: Colors.grey,
                        border: OutlineInputBorder(borderSide: BorderSide.none),
                      ),
                      style: const TextStyle(color: Colors.white),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _cvcController,
                      decoration: const InputDecoration(
                        labelText: 'CVC',
                        labelStyle: TextStyle(color: Colors.white70),
                        filled: true,
                        fillColor: Colors.grey,
                        border: OutlineInputBorder(borderSide: BorderSide.none),
                      ),
                      style: const TextStyle(color: Colors.white),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Center(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.pop(context);
                    widget.onConfirm();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(
                    'Pay Now',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _cardNumberController.dispose();
    _expiryController.dispose();
    _cvcController.dispose();
    super.dispose();
  }
}

class TicketConfirmationScreen extends StatelessWidget {
  final List<MarketplaceTicket> tickets;
  final Map<String, int> cart;

  const TicketConfirmationScreen({
    super.key,
    required this.tickets,
    required this.cart,
  });

  @override
  Widget build(BuildContext context) {
    const Color accent = Colors.blueAccent;

    return Scaffold(
      appBar: const _CustomAppBar(title: 'Ticket Confirmation'),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text(
              'Purchase Successful!',
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: tickets.length,
                itemBuilder: (context, index) {
                  final ticket = tickets[index];
                  final quantity = cart[ticket.id!] ?? 0;
                  return quantity > 0 ? _ConfirmationCard(ticket: ticket, quantity: quantity) : const SizedBox.shrink();
                },
              ),
            ),
            Center(
              child: ElevatedButton(
                onPressed: () async {
                  for (var ticket in tickets) {
                    ticket.isLocked = false;
                    await MarketplaceItemDb.instance.update(ticket);
                  }
                  if (context.mounted) {
                    Navigator.popUntil(context, (route) => route.isFirst);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(
                  'Back to Home',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  const _CustomAppBar({required this.title});

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title, style: GoogleFonts.poppins(color: Colors.white)),
      backgroundColor: Colors.black.withOpacity(0.8),
      elevation: 0,
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: GoogleFonts.poppins(
        color: Colors.white,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _TicketSummaryTile extends StatelessWidget {
  final MarketplaceTicket ticket;
  final int quantity;

  const _TicketSummaryTile({
    required this.ticket,
    required this.quantity,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.grey.shade900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: ticket.imageBase64 != null
            ? Image.memory(
                base64Decode(ticket.imageBase64!),
                width: 50,
                height: 75,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            : Image.network(
                ticket.moviePoster,
                width: 50,
                height: 75,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(Icons.movie, color: Colors.white70),
              ),
        title: Text(
          ticket.movieTitle,
          style: GoogleFonts.poppins(color: Colors.white, fontSize: 16),
        ),
        subtitle: Text(
          'Qty: $quantity | \$${ticket.price.toStringAsFixed(2)}',
          style: GoogleFonts.poppins(color: Colors.white70, fontSize: 14),
        ),
      ),
    );
  }
}

class _ConfirmationCard extends StatelessWidget {
  final MarketplaceTicket ticket;
  final int quantity;

  const _ConfirmationCard({
    required this.ticket,
    required this.quantity,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.grey.shade900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ticket.movieTitle,
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _InfoText(label: 'Location', value: ticket.location),
            _InfoText(
              label: 'Date',
              value: DateTime.parse(ticket.date).toLocal().toString().split('.')[0],
            ),
            _InfoText(
              label: 'Seats',
              value: ticket.seatDetails ?? ticket.seats.toString(),
            ),
            _InfoText(label: 'Quantity', value: quantity.toString()),
            if (ticket.imageBase64 != null)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Image.memory(
                  base64Decode(ticket.imageBase64!),
                  height: 80,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoText extends StatelessWidget {
  final String label;
  final String value;

  const _InfoText({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label: $value',
      style: GoogleFonts.poppins(color: Colors.white70, fontSize: 14),
    );
  }
}
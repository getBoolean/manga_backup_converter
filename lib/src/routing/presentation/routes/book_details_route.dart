import 'package:flutter/material.dart';
import 'package:mangabackupconverter/src/features/books/presentation/book_details_screen.dart';

class BookDetailsRoute extends StatefulWidget {
  const BookDetailsRoute({
    super.key,
    this.id,
  });
  final String? id;

  @override
  State<BookDetailsRoute> createState() => _BookDetailsRouteState();
}

class _BookDetailsRouteState extends State<BookDetailsRoute> {
  @override
  Widget build(BuildContext context) {
    return const BookDetailsScreen();
  }
}

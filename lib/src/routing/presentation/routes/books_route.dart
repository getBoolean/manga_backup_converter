// Dependencies (e.g. flex_color_scheme) still expose flutter/material types.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:mangabackupconverter/src/features/books/presentation/books_screen.dart';

class BooksRoute extends StatefulWidget {
  const BooksRoute({super.key});

  @override
  State<BooksRoute> createState() => _BooksRouteState();
}

class _BooksRouteState extends State<BooksRoute> {
  @override
  Widget build(BuildContext context) {
    return const BooksScreen();
  }
}

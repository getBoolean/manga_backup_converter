// Dependencies (e.g. flex_color_scheme) still expose flutter/material types.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

class BookDetailsScreen extends StatelessWidget {
  const BookDetailsScreen({this.id, super.key});
  final String? id;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.blueAccent,
      child: Center(
        child: Text(id != null ? 'Book $id' : 'Book Details Screen'),
      ),
    );
  }
}

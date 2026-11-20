// Dependencies (e.g. flex_color_scheme) still expose flutter/material types.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

class Blank extends StatelessWidget {
  const Blank({super.key});

  @override
  Widget build(BuildContext context) {
    return const Placeholder();
  }
}

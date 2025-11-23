import 'package:flutter/material.dart';

TextStyle numStyle({double? size, FontWeight? weight, Color? color}) {
  return TextStyle(
    fontSize: size,
    fontWeight: weight,
    color: color,
  );
}

String fmt0(num n) => n.toStringAsFixed(0);


import 'package:flutter/material.dart';

typedef ColorChangeRequest = void Function(String color, double x, double y);

Widget buildLivePreview(String htmlContent, {ColorChangeRequest? onColorRequest}) {
  return const Center(
    child: Text(
      "Live preview is only supported on Flutter Web.\nPlease run with: flutter run -d chrome",
      textAlign: TextAlign.center,
      style: TextStyle(color: Colors.black),
    ),
  );
}

void updatePreviewColor(String color) {}

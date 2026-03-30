// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'dart:ui_web' as ui_web;
import 'dart:convert';

typedef ColorChangeRequest = void Function(String color, double x, double y);

ColorChangeRequest? _onColorRequest;
html.IFrameElement? _currentIframe;
bool _isListenerAdded = false;

Widget buildLivePreview(String htmlContent, {ColorChangeRequest? onColorRequest}) {
  _onColorRequest = onColorRequest;
  final id = 'generated-html-view-${DateTime.now().millisecondsSinceEpoch}';

  ui_web.platformViewRegistry.registerViewFactory(id, (int viewId) {
    var iframe = html.IFrameElement()
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%';
    iframe.srcdoc = htmlContent;
    _currentIframe = iframe;
    return iframe;
  });

  if (!_isListenerAdded) {
    _isListenerAdded = true;
    html.window.onMessage.listen((event) {
      if (event.data is Map) {
        final data = event.data as Map;
        if (data['type'] == 'OPEN_COLOR_PICKER') {
          if (_onColorRequest != null) {
            final x = (data['x'] as num).toDouble();
            final y = (data['y'] as num).toDouble();
            _onColorRequest!(data['color'].toString(), x, y);
          }
        }
      } else if (event.data is String) {
        try {
          final data = jsonDecode(event.data);
          if (data['type'] == 'OPEN_COLOR_PICKER') {
            if (_onColorRequest != null) {
              final x = (data['x'] as num).toDouble();
              final y = (data['y'] as num).toDouble();
              _onColorRequest!(data['color'].toString(), x, y);
            }
          }
        } catch (_) {}
      }
    });
  }

  return HtmlElementView(viewType: id);
}

void updatePreviewColor(String color) {
  _currentIframe?.contentWindow?.postMessage(jsonEncode({'type': 'UPDATE_COLOR', 'color': color}), '*');
}

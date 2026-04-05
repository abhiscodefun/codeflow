import 'package:flutter/material.dart';

class DynamicFlutterPreview extends StatelessWidget {
  final Map<String, dynamic> uiJson;

  const DynamicFlutterPreview({Key? key, required this.uiJson}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (uiJson.isEmpty) {
      return const Center(child: Text("Waiting for UI generation..."));
    }
    
    // Determine the root structure. If the JSON has a 'type' at root, it's a direct widget.
    // Otherwise, try to extract 'appBar' and 'body' components.
    final dynamic bodyJson = uiJson.containsKey('type') ? uiJson : uiJson['body'];
    
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildAppBar(uiJson['appBar']),
      body: _buildWidget(context, bodyJson as Map<String, dynamic>?),
    );
  }

  PreferredSizeWidget? _buildAppBar(Map<String, dynamic>? appBarJson) {
    if (appBarJson == null) return null;
    return AppBar(
      title: Text(appBarJson['title'] ?? ''),
      backgroundColor: _parseColor(appBarJson['color'] ?? '#FFFFFF'),
      elevation: 0,
    );
  }

  dynamic _getProp(Map<String, dynamic> json, String propName) {
    if (json.containsKey(propName)) return json[propName];
    if (json['style'] != null && json['style'] is Map) {
      return json['style'][propName];
    }
    return null;
  }

  double? _parsePixel(dynamic val) {
    if (val == null) return null;
    if (val is num) return val.toDouble();
    if (val is String) {
      if (val.contains('%')) return null; // Let flutter flex instead of forcing 100px for "100%"
      final cleaned = val.replaceAll('px', '').trim();
      return double.tryParse(cleaned);
    }
    return null;
  }

  Widget _buildInteractiveWrapper(BuildContext context, Widget child, Map<String, dynamic> json, {bool isDefaultClickable = false}) {
    if (json['onTap'] != null || json['clickable'] == true || isDefaultClickable) {
      return GestureDetector(
        onTap: () {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(json['onTap'] ?? "Tapped on ${json['type'] ?? 'element'}!"),
              duration: const Duration(seconds: 1),
            ),
          );
        },
        child: child,
      );
    }
    return child;
  }

  Widget _buildWidget(BuildContext context, Map<String, dynamic>? json) {
    if (json == null) return const SizedBox.shrink();

    String type = json['type'] ?? '';
    Widget elementWidget;
    
    switch (type) {
      case 'Column':
        elementWidget = Column(
          mainAxisAlignment: _parseMainAxisAlignment(_getProp(json, 'mainAxisAlignment')),
          crossAxisAlignment: _parseCrossAxisAlignment(_getProp(json, 'crossAxisAlignment')),
          children: _buildChildren(context, json['children']),
        );
        break;
      case 'Row':
        elementWidget = Row(
          mainAxisAlignment: _parseMainAxisAlignment(_getProp(json, 'mainAxisAlignment')),
          crossAxisAlignment: _parseCrossAxisAlignment(_getProp(json, 'crossAxisAlignment')),
          children: _buildChildren(context, json['children']),
        );
        break;
      case 'Text':
        elementWidget = Text(
          json['text'] ?? '',
          textAlign: _parseTextAlign(_getProp(json, 'textAlign')),
          style: TextStyle(
            fontSize: _parsePixel(_getProp(json, 'fontSize')) ?? 14.0,
            fontWeight: (_getProp(json, 'fontWeight') == 'bold' || json['isBold'] == true) ? FontWeight.bold : FontWeight.normal,
            color: _parseColor(_getProp(json, 'color') ?? '#000000'),
          ),
        );
        break;
      case 'Container':
        Widget? childWidget;
        if (json['children'] != null) {
          childWidget = Stack(children: _buildChildren(context, json['children']));
        } else if (json['child'] != null) {
          childWidget = _buildWidget(context, json['child']);
        }
        
        elementWidget = Container(
          width: _parsePixel(_getProp(json, 'width')),
          height: _parsePixel(_getProp(json, 'height')),
          padding: _parseEdgeInsets(_getProp(json, 'padding')),
          margin: _parseEdgeInsets(_getProp(json, 'margin')),
          decoration: BoxDecoration(
            color: _parseColor(_getProp(json, 'backgroundColor') ?? '#00000000'),
            borderRadius: BorderRadius.circular(_parsePixel(_getProp(json, 'borderRadius')) ?? 0.0),
            border: Border.all(color: _parseColor(_getProp(json, 'borderColor') ?? '#00000000')),
          ),
          child: childWidget,
        );
        break;
      case 'Button':
        elementWidget = ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: _parseColor(_getProp(json, 'backgroundColor') ?? '#2196F3'),
          ),
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
               SnackBar(content: Text(json['onTap'] ?? "Button Clicked!"), duration: const Duration(seconds: 1))
            );
          },
          child: _buildWidget(context, json['child'] ?? (json['children'] != null && (json['children'] as List).isNotEmpty ? json['children'][0] : null)),
        );
        break;
      case 'Image':
        elementWidget = Image.network(
          json['src'] ?? '',
          width: _parsePixel(_getProp(json, 'width')),
          height: _parsePixel(_getProp(json, 'height')),
          fit: BoxFit.cover,
          errorBuilder: (ctx, err, stack) => Container(
            width: _parsePixel(_getProp(json, 'width')),
            height: _parsePixel(_getProp(json, 'height')),
            color: Colors.grey.shade300,
            child: const Center(child: Icon(Icons.image)),
          ),
        );
        // Force images to be clickable by default for a better preview experience
        return _buildInteractiveWrapper(context, elementWidget, json, isDefaultClickable: true);
      case 'Map':
        elementWidget = Container(
          width: double.infinity,
          height: _parsePixel(_getProp(json, 'height')) ?? 250,
          decoration: BoxDecoration(
            color: Colors.green.shade100,
            borderRadius: BorderRadius.circular(_parsePixel(_getProp(json, 'borderRadius')) ?? 0.0),
            border: Border.all(color: Colors.green.shade300),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.map, size: 50, color: Colors.green),
              const SizedBox(height: 10),
              Text(json['label'] ?? 'Interactive Map Placeholder'),
            ],
          ),
        );
        return _buildInteractiveWrapper(context, elementWidget, json, isDefaultClickable: true);
      case 'Expanded':
        elementWidget = Expanded(child: _buildWidget(context, json['child']));
        break;
      case 'Padding':
        elementWidget = Padding(
          padding: _parseEdgeInsets(_getProp(json, 'padding')) ?? EdgeInsets.zero,
          child: _buildWidget(context, json['child']),
        );
        break;
      case 'SizedBox':
        elementWidget = SizedBox(
          width: _parsePixel(_getProp(json, 'width')),
          height: _parsePixel(_getProp(json, 'height')),
        );
        break;
      default:
        // Try fallback to container if unknown type but has style
        if (json.containsKey('style') || json.containsKey('children')) {
           return _buildWidget(context, {...json, 'type': 'Container'});
        }
        return const SizedBox.shrink();
    }
    
    return _buildInteractiveWrapper(context, elementWidget, json);
  }

  List<Widget> _buildChildren(BuildContext context, List<dynamic>? children) {
    if (children == null) return [];
    return children.map((c) {
      final childJson = c as Map<String, dynamic>;
      Widget widget = _buildWidget(context, childJson);
      
      final style = childJson['style'] as Map<String, dynamic>?;
      if (style != null && style['position'] == 'absolute') {
        return Positioned(
          left: _parsePixel(style['left']),
          top: _parsePixel(style['top']),
          right: _parsePixel(style['right']),
          bottom: _parsePixel(style['bottom']),
          width: _parsePixel(style['width']),
          height: _parsePixel(style['height']),
          child: widget,
        );
      }
      return widget;
    }).toList();
  }

  Color _parseColor(String? hexString) {
    if (hexString == null || hexString.isEmpty) return Colors.black;
    if (hexString.startsWith('#')) {
      String hex = hexString.replaceAll('#', '');
      if (hex.length == 6) hex = 'FF$hex';
      return Color(int.tryParse(hex, radix: 16) ?? 0xFF000000);
    }
    return Colors.black;
  }

  MainAxisAlignment _parseMainAxisAlignment(String? alignment) {
    switch (alignment) {
      case 'center': return MainAxisAlignment.center;
      case 'spaceAround': return MainAxisAlignment.spaceAround;
      case 'spaceBetween': return MainAxisAlignment.spaceBetween;
      case 'spaceEvenly': return MainAxisAlignment.spaceEvenly;
      case 'end': return MainAxisAlignment.end;
      default: return MainAxisAlignment.start;
    }
  }

  CrossAxisAlignment _parseCrossAxisAlignment(String? alignment) {
    switch (alignment) {
      case 'center': return CrossAxisAlignment.center;
      case 'end': return CrossAxisAlignment.end;
      case 'stretch': return CrossAxisAlignment.stretch;
      default: return CrossAxisAlignment.start;
    }
  }

  EdgeInsets? _parseEdgeInsets(dynamic padding) {
    if (padding is num) return EdgeInsets.all(padding.toDouble());
    if (padding is Map<String, dynamic>) {
      return EdgeInsets.only(
        left: (padding['left'] as num?)?.toDouble() ?? 0,
        right: (padding['right'] as num?)?.toDouble() ?? 0,
        top: (padding['top'] as num?)?.toDouble() ?? 0,
        bottom: (padding['bottom'] as num?)?.toDouble() ?? 0,
      );
    }
    return null;
  }
  
  TextAlign? _parseTextAlign(String? align) {
    switch (align) {
      case 'center': return TextAlign.center;
      case 'right': return TextAlign.right;
      default: return TextAlign.left;
    }
  }
}

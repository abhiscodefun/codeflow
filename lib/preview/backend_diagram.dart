import 'package:flutter/material.dart';

class BackendDiagramPreview extends StatelessWidget {
  final Map<String, dynamic> backendJson;

  const BackendDiagramPreview({Key? key, required this.backendJson}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (backendJson.isEmpty) {
      return const Center(child: Text("Waiting for Backend architecture generation..."));
    }

    final nodes = backendJson['nodes'] as List<dynamic>? ?? [];
    final edges = backendJson['edges'] as List<dynamic>? ?? [];
    final description = backendJson['description'] ?? 'System Architecture';

    return Container(
      color: Colors.white,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Draw edges first
                CustomPaint(
                  size: Size.infinite,
                  painter: _NetworkPainter(nodes, edges),
                ),
                // Draw nodes
                ...nodes.map((node) => _buildNode(node)),
              ],
            ),
          ),
          // Description box at bottom
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(20),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF333333),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              description,
              style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNode(dynamic nodeData) {
    final x = (nodeData['x'] as num?)?.toDouble() ?? 100.0;
    final y = (nodeData['y'] as num?)?.toDouble() ?? 100.0;
    final label = nodeData['label'] ?? '';
    final type = nodeData['type'] ?? 'service'; // 'ui' (blue) or 'service' (black outline)

    return Positioned(
      left: x,
      top: y,
      child: Container(
        width: 100,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: type == 'ui' ? Colors.blue : Colors.white,
          border: type == 'ui' ? null : Border.all(color: Colors.black, width: 2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: type == 'ui' ? Colors.white : Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _NetworkPainter extends CustomPainter {
  final List<dynamic> nodes;
  final List<dynamic> edges;

  _NetworkPainter(this.nodes, this.edges);

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty || edges.isEmpty) return;

    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final Map<String, Offset> nodePositions = {};
    for (var n in nodes) {
      final id = n['id']?.toString() ?? '';
      final x = (n['x'] as num?)?.toDouble() ?? 0.0;
      final y = (n['y'] as num?)?.toDouble() ?? 0.0;
      // Center of the 100px wide node
      nodePositions[id] = Offset(x + 50, y + 20); 
    }

    for (var edge in edges) {
      final fromId = edge['from']?.toString() ?? '';
      final toId = edge['to']?.toString() ?? '';
      
      final p1 = nodePositions[fromId];
      final p2 = nodePositions[toId];

      if (p1 != null && p2 != null) {
        canvas.drawLine(p1, p2, paint);
        // Draw simple arrowhead
        final dx = p2.dx - p1.dx;
        final dy = p2.dy - p1.dy;
        final length = (dx * dx + dy * dy) > 0 ? 1.0 : 0.0; // Avoid division by zero
        if (length > 0) {
           final mx = p1.dx + dx * 0.8;
           final my = p1.dy + dy * 0.8;
           canvas.drawCircle(Offset(mx, my), 4, paint..style = PaintingStyle.fill);
           paint.style = PaintingStyle.stroke;
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

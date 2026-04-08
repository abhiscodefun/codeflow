import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:convert';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import 'preview/live_preview.dart';
import 'package:http/http.dart' as http;

const String functionsApiUrl = String.fromEnvironment('FUNCTIONS_API_URL', defaultValue: 'https://cinelock-nh1ei9rpn-abhiscodefuns-projects.vercel.app/api/generate');

const String supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON', defaultValue: '');

enum ResizeHandle {
  none,
  topLeft,
  topCenter,
  topRight,
  centerLeft,
  centerRight,
  bottomLeft,
  bottomCenter,
  bottomRight,
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  } catch (e) {
    debugPrint(
      "Failed to initialize Supabase. Check your URL and Anon Key. Error: $e",
    );
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Canvas AI Web App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
        iconTheme: const IconThemeData(weight: 100),
      ),
      home: const SketchPreviewScreen(),
    );
  }
}

class SketchPreviewScreen extends StatefulWidget {
  const SketchPreviewScreen({super.key});

  @override
  State<SketchPreviewScreen> createState() => _SketchPreviewScreenState();
}

class _SketchPreviewScreenState extends State<SketchPreviewScreen> {
  bool isDarkMode = false;
  bool isDesktopMode = false;
  bool _isSidebarOpen = true;
  List<DrawingPoint> points = [];
  bool hasGenerated = false;
  bool isGenerating = false;
  String generatedHtml = "";

  bool isClarifying = false;
  List<Map<String, dynamic>> ambiguities = [];
  double _leftPanelFraction = 0.5;
  int currentAmbiguityIndex = 0;
  String get clarifyQuestion => ambiguities.isNotEmpty
      ? (ambiguities[currentAmbiguityIndex]['question']?.toString() ?? "")
      : "";
  String get clarifySuggestion => ambiguities.isNotEmpty
      ? (ambiguities[currentAmbiguityIndex]['suggestion']?.toString() ?? "")
      : "";
  bool get clarifyNeedsImage => ambiguities.isNotEmpty
      ? (ambiguities[currentAmbiguityIndex]['needsImage'] == true)
      : false;

  DrawingMode currentMode = DrawingMode.pen;
  bool _isPencilHovered = false;
  bool _isPopupHovered = false;
  bool _isRectHovered = false;
  bool _isButtonHovered = false;
  bool _isAddHovered = false;
  bool _isGenerateHovered = false;
  bool _isSelectHovered = false;
  bool _isImageHovered = false;
  bool _isSketchHovered = false;
  bool _isColorPickerHovered = false;
  Timer? _popupHideTimer;

  DrawingPoint? _selectedFrame;
  Offset? _dragStartOffset;

  final TransformationController _transformationController =
      TransformationController();

  bool get _showDrawTools =>
      _isPencilHovered ||
      _isPopupHovered ||
      (_popupHideTimer?.isActive ?? false);

  final GlobalKey _canvasKey = GlobalKey();
  final GlobalKey _iframeContainerKey = GlobalKey();
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _globalPruneController = TextEditingController();
  final TextEditingController _aiReplyController = TextEditingController();
  final TextEditingController _elementTextController = TextEditingController();

  DrawingPoint? _editingElement;
  List<DrawingPoint> _dragChildren = [];
  Map<DrawingPoint, Rect> _initialChildRects = {};
  Rect? _initialFrameRect;
  ResizeHandle _activeResizeHandle = ResizeHandle.none;

  int _imageCounter = 0;
  Map<String, String> uploadedImages = {};
  bool _showColorPicker = false;
  Color _currentColor = Colors.white;
  Offset _colorPickerPosition = Offset.zero;

  bool _showPrunePopup = false;
  Offset _prunePosition = Offset.zero;
  String _pruneComponentHtml = "";
  final TextEditingController _pruneController = TextEditingController();

  Widget? _cachedLivePreview;
  String? _lastInjectedHtml;

  Color _parseCssColor(String colorStr) {
    try {
      if (colorStr.startsWith('#')) {
        String hex = colorStr.substring(1);
        if (hex.length == 3) {
          hex = '${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
        }
        if (hex.length == 6) {
          hex = 'FF$hex';
        }
        return Color(int.parse(hex, radix: 16));
      } else if (colorStr.startsWith('rgba') || colorStr.startsWith('rgb')) {
        final RegExp regex = RegExp(
          r'rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)',
        );
        final match = regex.firstMatch(colorStr);
        if (match != null) {
          int r = int.parse(match.group(1)!);
          int g = int.parse(match.group(2)!);
          int b = int.parse(match.group(3)!);
          double a = match.group(4) != null
              ? double.parse(match.group(4)!)
              : 1.0;
          return Color.fromRGBO(r, g, b, a);
        }
      }
    } catch (e) {
      debugPrint("Error parsing color: $e");
    }
    return Colors.white;
  }

  Future<Uint8List?> _capturePng() async {
    try {
      RenderRepaintBoundary boundary =
          _canvasKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      ui.Image image = await boundary.toImage(pixelRatio: 2.0);
      ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint("Error capturing canvas: $e");
      return null;
    }
  }

  Future<String> _callGemini(
    Uint8List imageBytes,
    String userPrompt,
    String frameMetadata,
    bool isInitialGeneration,
  ) async {
    final promptText = StringBuffer();
    promptText.writeln("You are an expert AI layout generator.");
    promptText.writeln(
      "Look at the provided wireframe/sketch drawn by a user.",
    );
    promptText.writeln(
      "Your job is to transform this sketch into a high-fidelity, clean, modern semantic HTML snippet (with INLINE CSS ONLY).",
    );
    promptText.writeln(
      "1. RECOGNIZE SHAPES AS UI COMPONENTS: Rectangles are typically buttons, cards, images, or input fields. Identify the layout hierarchy and structural components.",
    );
    promptText.writeln(
      "2. BE SMART: Ensure elements have realistic padding, margins, fonts, colors, and modern border-radii.It should look modern and appealing",
    );
    if (isDesktopMode) {
      promptText.writeln(
        "3. MULTI-SCREEN VIEWPORT RULES: The target output container represents a widescreen DESKTOP BROWSER. The generated layout must be designed for desktop resolutions (e.g. horizontal navigation, wide grids). Make it EXACTLY 100% width and 100% height. If there are MULTIPLE screens, they should all be contained within this single viewport. Each screen should be a full-size absolute container. By default, show the first screen (homepage) and hide the others. Place specific elements inside their respective containers. Prevent horizontal overflow. IMPORTANT DESKTOP LAYOUT RULE: Within any single screen, if elements (like an image, text, and button) are stacked vertically in a column in the mobile sketch, CONVERT that vertical group into a neat horizontal row (e.g. side-by-side flex layout) to properly utilize the wide desktop screen.",
      );
    } else {
      promptText.writeln(
        "3. MULTI-SCREEN VIEWPORT RULES: The target output container must always be EXACTLY 100% width and 100% height. If there's only 1 screen, just output that screen. If there are MULTIPLE screens, they should all be contained within this single viewport. Each screen should be a full-size absolute container (`width: 100%; height: 100%; position: absolute; top: 0; left: 0; overflow-y: auto; background: #fff;`). By default, show the first screen (homepage) and hide the others (using `display: none;` or similar). Place the specific elements for each screen inside its respective container. ID each screen using its screen name (e.g. `id=\"screen_1\"`). Prevent horizontal overflow inside the screens.",
      );
    }

    if (userPrompt.trim().isNotEmpty) {
      promptText.writeln(
        "4. STRICT STYLING: The user provided specific instructions below. You MUST aggressively apply their requested colors, themes, fonts, and specific styling to the components you identified.",
      );
      promptText.writeln('USER STYLE PROMPT: "$userPrompt"');
    }
    if (frameMetadata.isNotEmpty) {
      promptText.writeln(
        "4b. FRAME METADATA: Use these exact relative positions (in % of the ${isDesktopMode ? 'desktop' : 'mobile'} screen) for placing the specific elements:\n$frameMetadata",
      );
    }
    if (uploadedImages.isNotEmpty) {
      promptText.writeln(
        "5. CRITICAL: PLACED IMAGES DETECTED! There is at least one image in this sketch explicitly marked with a red tag like {IMG_0}. You absolutely MUST insert an <img> tag exactly at its position using the tag string as the src: <img src='{IMG_0}' style='width: 100%; height: 100%; object-fit: cover; border-radius: 12px;' />. IMPORTANT: ALWAYS place the image inside a visible container that has defined bounds so the image does not disappear. FAILURE to use the exact {IMG_0} tag in the src attribute is unacceptable.",
      );
    }

    if (isInitialGeneration) {
      promptText.writeln(
        "6. CLARIFICATION PHASE: You must NOT generate HTML yet. Analyze the provided wireframe/sketch. Identify any ambiguous placeholders like 'Enter text' or 'Button'. Ask about ambiguities ONE BY ONE. Identify the top 2-3 most ambiguous elements(only top 1 if you are confident about others) and ask about them first. If the sketch contains image frames with no image, you MUST include a clarification for it and set \"needsImage\" to true. If there are multiple screens, you MUST analyze how they connect. Identify interactive elements (like nav tabs or buttons) and predict which screen they should link to. For the last clarification, you MUST confirm these connections by asking a question (e.g. 'Does clicking Profile go to screen_3?'). Output ONLY a JSON object exactly like this:\n"
        '{\n'
        '  "type": "clarify",\n'
        '  "ambiguities": [\n'
        '    {\n'
        '      "question": "[Short, single concise question]",\n'
        '      "suggestion": "[Brief design suggestion]",\n'
        '      "needsImage": false\n'
        '    }\n'
        '  ]\n'
        '}\n',
      );
    } else {
      promptText.writeln(
        "6. GENERATION PHASE: The user has clarified their intent. Output ONLY the HTML code wrapped in a markdown ```html block. DO NOT use JSON. If there are multiple screens, implement interactive navigation using JavaScript so that clicking on nav tabs or buttons toggles the visibility of the target screen allowing it to function like a real app on a phone. The first defined screen is always the homepage.",
      );
    }

    try {
      String? base64Image;
      if (imageBytes.isNotEmpty) {
        base64Image = base64Encode(imageBytes);
      }

      final uri = Uri.parse(functionsApiUrl);
      final httpResponse = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'promptText': promptText.toString(),
          'base64Image': base64Image,
          'isInitialGeneration': isInitialGeneration,
        }),
      );

      String text = "";
      if (httpResponse.statusCode == 200) {
        final data = jsonDecode(httpResponse.body);
        text = data['text'] ?? "";
      } else {
        throw Exception("Failed to generate UI. Status code: ${httpResponse.statusCode}");
      }
      debugPrint(
        "========== GEMINI RAW RESPONSE ==========\n$text\n==========================================",
      );

      // Re-map images
      for (var entry in uploadedImages.entries) {
        text = text.replaceAll(entry.key, entry.value);
      }

      // Extract markdown blocks more robustly
      String cleanText = text.trim();
      final htmlBlockRegex = RegExp(
        r'```(?:html|xml)\s*([\s\S]*?)```',
        caseSensitive: false,
      );
      final genericBlockRegex = RegExp(r'```[a-zA-Z]*\s*([\s\S]*?)```');

      final htmlMatch = htmlBlockRegex.firstMatch(cleanText);
      if (htmlMatch != null) {
        cleanText = (htmlMatch.group(1) ?? cleanText).trim();
      } else {
        final genericMatch = genericBlockRegex.firstMatch(cleanText);
        if (genericMatch != null) {
          cleanText = (genericMatch.group(1) ?? cleanText).trim();
        }
      }

      // Determine if clarification was requested via JSON (or forced initial)
      if (cleanText.startsWith('{') && cleanText.contains('"clarify"')) {
        return cleanText; // Return raw JSON
      }

      // Otherwise assume the cleanText is HTML
      text = cleanText;

      // Ensure the generated html is robust to be displayed standalone and has no scrollbars
      if (!text.toLowerCase().contains('<html') &&
          !text.toLowerCase().contains('<body')) {
        text =
            '<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>::-webkit-scrollbar { display: none; } html, body { margin: 0; padding: 0; width: 100%; height: 100%; -ms-overflow-style: none; scrollbar-width: none; }</style></head><body>\n$text\n</body></html>';
      } else if (!text.contains('::-webkit-scrollbar')) {
        String styles =
            '<style>::-webkit-scrollbar { display: none; } html, body { margin: 0; padding: 0; width: 100%; height: 100%; -ms-overflow-style: none; scrollbar-width: none; }</style>';
        if (text.toLowerCase().contains('<head>')) {
          text = text.replaceFirst(
            RegExp(r'<head>', caseSensitive: false),
            '<head>\n$styles',
          );
        } else if (text.toLowerCase().contains('<body>')) {
          text = text.replaceFirst(
            RegExp(r'<body>', caseSensitive: false),
            '<body>\n$styles',
          );
        } else {
          text = styles + '\n' + text;
        }
      }

      debugPrint(
        "========== AFTER REMAPPING ==========\n$text\n==========================================",
      );

      return text;
    } catch (e) {
      return "<div style='color:red; margin:20px; font-family:sans-serif;'><b>Error:</b> Failed to generate UI.\\n$e</div>";
    }
  }

  void _setDrawingMode(DrawingMode mode) {
    setState(() {
      currentMode = mode;
      _isPopupHovered = false;
    });
    setPreviewColorPickerMode(mode == DrawingMode.colorPicker);
  }

  void _generatePreview({String? userReply}) async {
    if (points.isEmpty && !hasGenerated) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please sketch something first!")),
      );
      return;
    }

    setState(() {
      isGenerating = true;
    });

    // 1. Capture the sketch as an image
    final imageBytes = await _capturePng();
    if (imageBytes == null) {
      setState(() {
        isGenerating = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Failed to capture sketch image.")),
      );
      return;
    }

    // Calculate frame metadata
    String metadata = "";
    try {
      final frames = points.where((p) => p.type == ShapeType.frame).toList();
      if (frames.isNotEmpty) {
        for (int i = 0; i < frames.length; i++) {
          final f = frames[i];
          final fRect = Rect.fromPoints(f.point, f.secondaryPoint!);
          final String screenName = f.text ?? "screen_${i + 1}";
          metadata += "--- $screenName ---\n";
          for (var p in points) {
            if (p == f || p.type == ShapeType.line || p.type == ShapeType.frame)
              continue;

            Rect? pRect;
            if (p.secondaryPoint != null) {
              pRect = Rect.fromPoints(p.point, p.secondaryPoint!);
            } else if (p.point != Offset.infinite && p.type == ShapeType.text) {
              pRect = Rect.fromLTWH(p.point.dx, p.point.dy, 80, 20);
            }

            if (pRect != null && fRect.overlaps(pRect)) {
              final leftPct = ((pRect.left - fRect.left) / fRect.width * 100)
                  .clamp(0, 100)
                  .toStringAsFixed(1);
              final topPct = ((pRect.top - fRect.top) / fRect.height * 100)
                  .clamp(0, 100)
                  .toStringAsFixed(1);
              final widthPct = (pRect.width / fRect.width * 100)
                  .clamp(0, 100)
                  .toStringAsFixed(1);
              final heightPct = (pRect.height / fRect.height * 100)
                  .clamp(0, 100)
                  .toStringAsFixed(1);

              if (p.type == ShapeType.image) {
                metadata +=
                    "Image ${p.imageId} -> top: $topPct%, left: $leftPct%, width: $widthPct%, height: $heightPct%\n";
              } else if (p.type == ShapeType.button) {
                metadata +=
                    "Button '${p.text}' -> top: $topPct%, left: $leftPct%, width: $widthPct%, height: $heightPct%\n";
              } else if (p.type == ShapeType.text) {
                metadata +=
                    "Text '${p.text}' -> top: $topPct%, left: $leftPct%\n";
              } else if (p.type == ShapeType.rectangle) {
                metadata +=
                    "Container -> top: $topPct%, left: $leftPct%, width: $widthPct%, height: $heightPct%\n";
              }
            }
          }
          metadata += "\n";
        }
      }
    } catch (e) {
      debugPrint("Error calculating metadata: $e");
    }

    // 2. Call Gemini
    String userText = _promptController.text;
    if (userReply != null && userReply.isNotEmpty) {
      userText += "\nUser clarification reply: $userReply";
    }

    final bool isInitialGeneration = (userReply == null);

    final String htmlResponse = await _callGemini(
      imageBytes,
      userText,
      metadata,
      isInitialGeneration,
    );

    if (mounted) {
      if (htmlResponse.startsWith('{') && htmlResponse.contains('"clarify"')) {
        try {
          int start = htmlResponse.indexOf('{');
          int end = htmlResponse.lastIndexOf('}');
          if (start != -1 && end != -1 && end > start) {
            String jsonStr = htmlResponse.substring(start, end + 1);
            final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
            final list = decoded['ambiguities'] as List<dynamic>?;
            setState(() {
              if (list != null && list.isNotEmpty) {
                ambiguities = List<Map<String, dynamic>>.from(list);
              } else {
                ambiguities = [
                  {
                    "question": "I'm having trouble understanding this sketch.",
                    "suggestion":
                        "Could you add some text labels indicating what these elements are?",
                  },
                ];
              }
              currentAmbiguityIndex = 0;
              isClarifying = true;
              isGenerating = false;
            });
            return;
          }
        } catch (e) {
          debugPrint("Failed to parse clarification JSON: $e");
        }

        // Fallback catch block logic
        setState(() {
          ambiguities = [
            {
              "question": "This sketch looks a bit abstract.",
              "suggestion": "Can you describe what layout you're aiming for?",
            },
          ];
          currentAmbiguityIndex = 0;
          isClarifying = true;
          isGenerating = false;
        });
        return;
      }

      // Handle old legacy fallback just in case LLM ignored prompt
      if (htmlResponse.contains('"clarify"') &&
          htmlResponse.contains('"question"')) {
        try {
          int start = htmlResponse.indexOf('{');
          int end = htmlResponse.lastIndexOf('}');
          if (start != -1 && end != -1 && end > start) {
            String jsonStr = htmlResponse.substring(start, end + 1);
            final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
            setState(() {
              ambiguities = [
                {
                  "question":
                      decoded['question']?.toString() ??
                      "I'm having trouble understanding this sketch.",
                  "suggestion":
                      decoded['suggestion']?.toString() ??
                      "Could you add some text labels indicating what these elements are?",
                },
              ];
              currentAmbiguityIndex = 0;
              isClarifying = true;
              isGenerating = false;
            });
            return;
          }
        } catch (e) {}
      }

      setState(() {
        generatedHtml = htmlResponse.trim();
        isClarifying = false;
        isGenerating = false;
        hasGenerated = true;
      });
    }
  }

  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      final bytes = await image.readAsBytes();
      final imageId = "{IMG_${_imageCounter++}}";

      try {
        final fileName = 'upload_${DateTime.now().millisecondsSinceEpoch}.jpg';

        // Ensure you have created a public bucket named 'images' in R!
        await Supabase.instance.client.storage
            .from('images')
            .uploadBinary(
              fileName,
              bytes,
              fileOptions: const FileOptions(contentType: 'image/jpeg'),
            );

        final publicUrl = Supabase.instance.client.storage
            .from('images')
            .getPublicUrl(fileName);

        uploadedImages[imageId] = publicUrl;
        debugPrint(
          "Image uploaded successfully! mapped $imageId to $publicUrl",
        );
      } catch (e) {
        debugPrint("Failed to upload image to Supabase: $e");
        // Fallback to base64 if Supabase is not configured yet
        final base64String = base64Encode(bytes);
        uploadedImages[imageId] = "data:image/jpeg;base64,$base64String";
        debugPrint("Mapped $imageId to base64 length ${base64String.length}");
      }

      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final uiImage = frame.image;

      setState(() {
        points.add(
          DrawingPoint(
            point: const Offset(100, 150),
            secondaryPoint: const Offset(250, 300), // Default bounds
            paint: Paint(),
            type: ShapeType.image,
            image: uiImage,
            imageId: imageId,
          ),
        );
      });
    }
  }

  Future<void> _uploadSketch() async {
    final ImagePicker picker = ImagePicker();
    final List<XFile> images = await picker.pickMultiImage();
    if (images.isNotEmpty) {
      double currentOffsetX = 50.0;
      double topOffsetY = 50.0;
      double gap = 80.0;

      for (var image in images) {
        final bytes = await image.readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final uiImage = frame.image;

        setState(() {
          final sketchPoint = DrawingPoint(
            point: Offset(currentOffsetX, topOffsetY),
            secondaryPoint: Offset(currentOffsetX + uiImage.width, topOffsetY + uiImage.height),
            paint: Paint(),
            type: ShapeType.sketch,
            image: uiImage,
          );

          final framePoint = DrawingPoint(
            point: Offset(currentOffsetX - 10, topOffsetY - 10),
            secondaryPoint: Offset(currentOffsetX + uiImage.width + 10, topOffsetY + uiImage.height + 10),
            paint: Paint()
              ..color = Colors.black87
              ..strokeWidth = 2.5
              ..style = PaintingStyle.stroke,
            type: ShapeType.frame,
          );

          // Insert frame first as background, sketch above
          points.insert(0, framePoint);
          points.insert(1, sketchPoint);
        });

        currentOffsetX += uiImage.width + gap;
      }
    }
  }

  Future<void> _addTextToCanvas(Offset position) async {
    setState(() {
      final newText = DrawingPoint(
        point: position,
        secondaryPoint: Offset(position.dx + 100, position.dy + 30),
        paint: Paint()..color = Colors.black,
        type: ShapeType.text,
        text: "Enter text",
      );
      points.add(newText);
      _editingElement = newText;
      _elementTextController.text = newText.text!;
    });
  }

  void _addButtonToCanvas(Offset position) {
    setState(() {
      final newBtn = DrawingPoint(
        point: Offset(position.dx - 60, position.dy - 20),
        secondaryPoint: Offset(position.dx + 60, position.dy + 20),
        paint: Paint()
          ..color = Colors.black
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke,
        type: ShapeType.button,
        text: "Button",
      );
      points.add(newBtn);
      _editingElement = newBtn;
      _elementTextController.text = newBtn.text!;
    });
  }

  ResizeHandle _hitTestResizeHandles(Offset pos, Rect bounds) {
    const double handleSize = 20.0;
    final double intlx = bounds.left;
    final double intly = bounds.top;
    final double inbrx = bounds.right;
    final double inbry = bounds.bottom;

    if (Rect.fromCenter(
      center: Offset(intlx, intly),
      width: handleSize,
      height: handleSize,
    ).contains(pos))
      return ResizeHandle.topLeft;
    if (Rect.fromCenter(
      center: Offset(inbrx, intly),
      width: handleSize,
      height: handleSize,
    ).contains(pos))
      return ResizeHandle.topRight;
    if (Rect.fromCenter(
      center: Offset(intlx, inbry),
      width: handleSize,
      height: handleSize,
    ).contains(pos))
      return ResizeHandle.bottomLeft;
    if (Rect.fromCenter(
      center: Offset(inbrx, inbry),
      width: handleSize,
      height: handleSize,
    ).contains(pos))
      return ResizeHandle.bottomRight;

    if (Rect.fromCenter(
      center: Offset(bounds.center.dx, intly),
      width: handleSize,
      height: handleSize,
    ).contains(pos))
      return ResizeHandle.topCenter;
    if (Rect.fromCenter(
      center: Offset(bounds.center.dx, inbry),
      width: handleSize,
      height: handleSize,
    ).contains(pos))
      return ResizeHandle.bottomCenter;
    if (Rect.fromCenter(
      center: Offset(intlx, bounds.center.dy),
      width: handleSize,
      height: handleSize,
    ).contains(pos))
      return ResizeHandle.centerLeft;
    if (Rect.fromCenter(
      center: Offset(inbrx, bounds.center.dy),
      width: handleSize,
      height: handleSize,
    ).contains(pos))
      return ResizeHandle.centerRight;

    return ResizeHandle.none;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Row(
            children: [
              _buildSidebar(),
              // Left side: Drawable canvas and bottom prompt
              Expanded(
                flex: (_leftPanelFraction * 100).toInt(),
                child: Container(
                  color: isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    fit: StackFit.expand,
                    children: [
                      Stack(
                        children: [
                          // Sketch Area inside RepaintBoundary for image capture
                          InteractiveViewer(
                            transformationController: _transformationController,
                            panEnabled: currentMode == DrawingMode.select,
                            scaleEnabled: currentMode == DrawingMode.select,
                            minScale: 0.1,
                            maxScale: 4.0,
                            boundaryMargin: const EdgeInsets.all(
                              double.infinity,
                            ),
                            child: RepaintBoundary(
                              key: _canvasKey,
                              child: Container(
                                color: Colors.white,
                                width: 3000,
                                height: 3000,
                                child: MouseRegion(
                                  cursor: currentMode == DrawingMode.select
                                      ? SystemMouseCursors.move
                                      : SystemMouseCursors.basic,
                                  child: GestureDetector(
                                    onTapDown: (details) {
                                      // If editing, tapping outside closes it
                                      if (_editingElement != null) {
                                        setState(() {
                                          _editingElement!.text =
                                              _elementTextController.text;
                                          _editingElement = null;
                                        });
                                        return;
                                      }

                                      if (currentMode == DrawingMode.text) {
                                        _addTextToCanvas(details.localPosition);
                                      } else if (currentMode ==
                                          DrawingMode.button) {
                                        _addButtonToCanvas(
                                          details.localPosition,
                                        );
                                      } else if (currentMode ==
                                          DrawingMode.select) {
                                        // 1. Check if we are interacting with resize handles of the currently selected element
                                        if (_selectedFrame != null &&
                                            _selectedFrame!.secondaryPoint !=
                                                null) {
                                          Rect selectedRect = Rect.fromPoints(
                                            _selectedFrame!.point,
                                            _selectedFrame!.secondaryPoint!,
                                          );
                                          if (_selectedFrame!.type ==
                                              ShapeType.text) {
                                            selectedRect = Rect.fromLTWH(
                                              _selectedFrame!.point.dx,
                                              _selectedFrame!.point.dy,
                                              80,
                                              20,
                                            );
                                          }

                                          ResizeHandle hitHandle =
                                              _hitTestResizeHandles(
                                                details.localPosition,
                                                selectedRect,
                                              );
                                          if (hitHandle != ResizeHandle.none) {
                                            _activeResizeHandle = hitHandle;
                                            _dragStartOffset =
                                                details.localPosition;
                                            _initialFrameRect = selectedRect;

                                            // Save initial rects of all children if it's a frame
                                            _initialChildRects.clear();
                                            if (_selectedFrame!.type ==
                                                ShapeType.frame) {
                                              for (var child in _dragChildren) {
                                                if (child.secondaryPoint !=
                                                    null) {
                                                  _initialChildRects[child] =
                                                      Rect.fromPoints(
                                                        child.point,
                                                        child.secondaryPoint!,
                                                      );
                                                } else if (child.type ==
                                                    ShapeType.text) {
                                                  _initialChildRects[child] =
                                                      Rect.fromLTWH(
                                                        child.point.dx,
                                                        child.point.dy,
                                                        80,
                                                        20,
                                                      );
                                                }
                                              }
                                            }
                                            return; // Handle interacted, skip selecting new elements
                                          }
                                        }

                                        _activeResizeHandle = ResizeHandle.none;
                                        _selectedFrame = null;
                                        _dragChildren.clear();
                                        for (
                                          var i = points.length - 1;
                                          i >= 0;
                                          i--
                                        ) {
                                          var p = points[i];
                                          if (p.secondaryPoint != null &&
                                              p.type != ShapeType.line) {
                                            Rect r = Rect.fromPoints(
                                              p.point,
                                              p.secondaryPoint!,
                                            );
                                            // Make frame selection robust (only edge for frames)
                                            if (p.type == ShapeType.frame) {
                                              Rect outerR = r.inflate(20);
                                              Rect innerR = r.deflate(20);
                                              if (outerR.contains(
                                                    details.localPosition,
                                                  ) &&
                                                  !innerR.contains(
                                                    details.localPosition,
                                                  )) {
                                                _selectedFrame = p;
                                                _dragStartOffset =
                                                    details.localPosition;

                                                // Find all elements fully inside the frame
                                                for (var sibling in points) {
                                                  if (sibling != p &&
                                                      sibling.secondaryPoint !=
                                                          null &&
                                                      sibling.type !=
                                                          ShapeType.line &&
                                                      sibling.type !=
                                                          ShapeType.frame) {
                                                    Rect
                                                    sRect = Rect.fromPoints(
                                                      sibling.point,
                                                      sibling.secondaryPoint!,
                                                    );
                                                    // Only consider fully contained children, not just overlaps
                                                    if (r.intersect(sRect) ==
                                                        sRect) {
                                                      _dragChildren.add(
                                                        sibling,
                                                      );
                                                    }
                                                  } else if (sibling.type ==
                                                      ShapeType.text) {
                                                    // Approximate text rect
                                                    Rect tRect = Rect.fromLTWH(
                                                      sibling.point.dx,
                                                      sibling.point.dy,
                                                      80,
                                                      20,
                                                    );
                                                    if (r.intersect(tRect) ==
                                                        tRect) {
                                                      _dragChildren.add(
                                                        sibling,
                                                      );
                                                    }
                                                  }
                                                }
                                                break;
                                              }
                                            } else {
                                              // General drag for image, rect, button, text
                                              if (r.contains(
                                                details.localPosition,
                                              )) {
                                                _selectedFrame = p;
                                                _dragStartOffset =
                                                    details.localPosition;
                                                break;
                                              }
                                            }
                                          } else if (p.type == ShapeType.text &&
                                              p.point != Offset.infinite) {
                                            Rect r = Rect.fromLTWH(
                                              p.point.dx,
                                              p.point.dy,
                                              120,
                                              40,
                                            );
                                            if (r.contains(
                                              details.localPosition,
                                            )) {
                                              _selectedFrame = p;
                                              _dragStartOffset =
                                                  details.localPosition;
                                              break;
                                            }
                                          }
                                        }

                                        // Handle double tap to edit button/text
                                        if (_selectedFrame != null &&
                                            (_selectedFrame!.type ==
                                                    ShapeType.button ||
                                                _selectedFrame!.type ==
                                                    ShapeType.text)) {
                                          // To correctly handle double tap we would need a gesture recognizer,
                                          // but as a quick logic: if we tapped it, maybe enter edit mode?
                                          // We'll enter edit mode if they just tap without dragging (handled below).
                                        }
                                      }
                                    },
                                    onDoubleTapDown: (details) {
                                      if (currentMode == DrawingMode.select) {
                                        for (
                                          var i = points.length - 1;
                                          i >= 0;
                                          i--
                                        ) {
                                          var p = points[i];
                                          // check bounds
                                          Rect r;
                                          if (p.secondaryPoint != null) {
                                            r = Rect.fromPoints(
                                              p.point,
                                              p.secondaryPoint!,
                                            );
                                          } else {
                                            r = Rect.fromLTWH(
                                              p.point.dx,
                                              p.point.dy,
                                              120,
                                              40,
                                            );
                                          }
                                          if (r.contains(
                                                details.localPosition,
                                              ) &&
                                              (p.type == ShapeType.button ||
                                                  p.type == ShapeType.text)) {
                                            setState(() {
                                              _editingElement = p;
                                              _elementTextController.text =
                                                  p.text ?? "";
                                            });
                                            break;
                                          }
                                        }
                                      }
                                    },
                                    onPanStart: (details) {
                                      if (currentMode == DrawingMode.text ||
                                          currentMode == DrawingMode.button ||
                                          currentMode == DrawingMode.select)
                                        return;
                                      setState(() {
                                        if (currentMode == DrawingMode.pen) {
                                          points.add(
                                            DrawingPoint(
                                              point: details.localPosition,
                                              paint: Paint()
                                                ..strokeCap = StrokeCap.round
                                                ..isAntiAlias = true
                                                ..color = Colors.black
                                                ..strokeWidth = 3.0,
                                            ),
                                          );
                                        } else {
                                          points.add(
                                            DrawingPoint(
                                              point: details.localPosition,
                                              secondaryPoint:
                                                  details.localPosition,
                                              type:
                                                  currentMode ==
                                                      DrawingMode.rectangle
                                                  ? ShapeType.rectangle
                                                  : ShapeType.circle,
                                              paint: Paint()
                                                ..color = Colors.black
                                                ..strokeWidth = 3.0
                                                ..style = PaintingStyle.stroke,
                                            ),
                                          );
                                        }
                                      });
                                    },
                                    onPanUpdate: (details) {
                                      if (currentMode == DrawingMode.text ||
                                          currentMode == DrawingMode.button)
                                        return;

                                      if (currentMode == DrawingMode.select &&
                                          _selectedFrame != null &&
                                          _dragStartOffset != null) {
                                        setState(() {
                                          Offset delta =
                                              details.localPosition -
                                              _dragStartOffset!;

                                          if (_activeResizeHandle !=
                                                  ResizeHandle.none &&
                                              _initialFrameRect != null &&
                                              _selectedFrame!.secondaryPoint !=
                                                  null) {
                                            double left =
                                                _selectedFrame!.point.dx;
                                            double top =
                                                _selectedFrame!.point.dy;
                                            double right = _selectedFrame!
                                                .secondaryPoint!
                                                .dx;
                                            double bottom = _selectedFrame!
                                                .secondaryPoint!
                                                .dy;

                                            if (_activeResizeHandle ==
                                                    ResizeHandle.topLeft ||
                                                _activeResizeHandle ==
                                                    ResizeHandle.centerLeft ||
                                                _activeResizeHandle ==
                                                    ResizeHandle.bottomLeft) {
                                              left += delta.dx;
                                            }
                                            if (_activeResizeHandle ==
                                                    ResizeHandle.topRight ||
                                                _activeResizeHandle ==
                                                    ResizeHandle.centerRight ||
                                                _activeResizeHandle ==
                                                    ResizeHandle.bottomRight) {
                                              right += delta.dx;
                                            }
                                            if (_activeResizeHandle ==
                                                    ResizeHandle.topLeft ||
                                                _activeResizeHandle ==
                                                    ResizeHandle.topCenter ||
                                                _activeResizeHandle ==
                                                    ResizeHandle.topRight) {
                                              top += delta.dy;
                                            }
                                            if (_activeResizeHandle ==
                                                    ResizeHandle.bottomLeft ||
                                                _activeResizeHandle ==
                                                    ResizeHandle.bottomCenter ||
                                                _activeResizeHandle ==
                                                    ResizeHandle.bottomRight) {
                                              bottom += delta.dy;
                                            }

                                            if (right - left < 40) {
                                              if (left !=
                                                  _selectedFrame!.point.dx)
                                                left = right - 40;
                                              else
                                                right = left + 40;
                                            }
                                            if (bottom - top < 40) {
                                              if (top !=
                                                  _selectedFrame!.point.dy)
                                                top = bottom - 40;
                                              else
                                                bottom = top + 40;
                                            }

                                            _selectedFrame!.point = Offset(
                                              left,
                                              top,
                                            );
                                            _selectedFrame!.secondaryPoint =
                                                Offset(right, bottom);

                                            if (_selectedFrame!.type ==
                                                    ShapeType.frame &&
                                                _initialFrameRect!.width > 0 &&
                                                _initialFrameRect!.height > 0) {
                                              double scaleX =
                                                  (right - left) /
                                                  _initialFrameRect!.width;
                                              double scaleY =
                                                  (bottom - top) /
                                                  _initialFrameRect!.height;
                                              for (var child in _dragChildren) {
                                                if (_initialChildRects
                                                    .containsKey(child)) {
                                                  Rect initRect =
                                                      _initialChildRects[child]!;
                                                  double childLeft =
                                                      left +
                                                      (initRect.left -
                                                              _initialFrameRect!
                                                                  .left) *
                                                          scaleX;
                                                  double childTop =
                                                      top +
                                                      (initRect.top -
                                                              _initialFrameRect!
                                                                  .top) *
                                                          scaleY;
                                                  double childRight =
                                                      left +
                                                      (initRect.right -
                                                              _initialFrameRect!
                                                                  .left) *
                                                          scaleX;
                                                  double childBottom =
                                                      top +
                                                      (initRect.bottom -
                                                              _initialFrameRect!
                                                                  .top) *
                                                          scaleY;

                                                  child.point = Offset(
                                                    childLeft,
                                                    childTop,
                                                  );
                                                  if (child.secondaryPoint !=
                                                      null) {
                                                    child.secondaryPoint =
                                                        Offset(
                                                          childRight,
                                                          childBottom,
                                                        );
                                                  }
                                                }
                                              }
                                            }
                                            _dragStartOffset =
                                                details.localPosition;
                                          } else {
                                            _selectedFrame!.point += delta;
                                            if (_selectedFrame!
                                                    .secondaryPoint !=
                                                null) {
                                              _selectedFrame!.secondaryPoint =
                                                  _selectedFrame!
                                                      .secondaryPoint! +
                                                  delta;
                                            }
                                            for (var child in _dragChildren) {
                                              child.point += delta;
                                              if (child.secondaryPoint !=
                                                  null) {
                                                child.secondaryPoint =
                                                    child.secondaryPoint! +
                                                    delta;
                                              }
                                            }
                                            _dragStartOffset =
                                                details.localPosition;
                                          }
                                        });
                                        return;
                                      } else if (currentMode ==
                                          DrawingMode.select) {
                                        return;
                                      }

                                      setState(() {
                                        if (currentMode == DrawingMode.pen) {
                                          points.add(
                                            DrawingPoint(
                                              point: details.localPosition,
                                              paint: Paint()
                                                ..strokeCap = StrokeCap.round
                                                ..isAntiAlias = true
                                                ..color = Colors.black
                                                ..strokeWidth = 3.0,
                                            ),
                                          );
                                        } else if (currentMode ==
                                                DrawingMode.rectangle ||
                                            currentMode == DrawingMode.circle) {
                                          if (points.isNotEmpty &&
                                              (points.last.type ==
                                                      ShapeType.rectangle ||
                                                  points.last.type ==
                                                      ShapeType.circle)) {
                                            points.last.secondaryPoint =
                                                details.localPosition;
                                          }
                                        }
                                      });
                                    },
                                    onPanEnd: (details) async {
                                      if (currentMode == DrawingMode.text ||
                                          currentMode == DrawingMode.button)
                                        return;
                                      if (currentMode == DrawingMode.select) {
                                        _dragStartOffset = null;
                                        return;
                                      }
                                      setState(() {
                                        if (currentMode == DrawingMode.pen) {
                                          points.add(
                                            DrawingPoint(
                                              point: Offset.infinite,
                                              paint: Paint(),
                                            ),
                                          );
                                        }
                                      });
                                    },
                                    child: CustomPaint(
                                      painter: DrawingPainter(
                                        pointsList: points,
                                        selectedPoint: _selectedFrame,
                                        isDesktopMode: isDesktopMode,
                                      ),
                                      size: const Size(3000, 3000),
                                    ),
                                  ), // closes GestureDetector
                                ), // closes MouseRegion
                              ), // closes Container
                            ), // closes RepaintBoundary
                          ), // closes InteractiveViewer
                          // Floating Input field for editable text
                          if (_editingElement != null &&
                              _editingElement!.secondaryPoint != null)
                            Positioned(
                              left:
                                  _editingElement!.point.dx <
                                      _editingElement!.secondaryPoint!.dx
                                  ? _editingElement!.point.dx
                                  : _editingElement!.secondaryPoint!.dx,
                              top:
                                  _editingElement!.point.dy <
                                      _editingElement!.secondaryPoint!.dy
                                  ? _editingElement!.point.dy
                                  : _editingElement!.secondaryPoint!.dy,
                              child: Container(
                                width:
                                    (_editingElement!.secondaryPoint!.dx -
                                            _editingElement!.point.dx)
                                        .abs(),
                                height:
                                    (_editingElement!.secondaryPoint!.dy -
                                            _editingElement!.point.dy)
                                        .abs(),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.blueAccent,
                                    width: 2,
                                  ),
                                  color: Colors.white.withOpacity(0.9),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Center(
                                  child: TextField(
                                    controller: _elementTextController,
                                    autofocus: true,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      color: Colors.black,
                                    ),
                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      isDense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                    onSubmitted: (val) {
                                      setState(() {
                                        _editingElement!.text = val;
                                        _editingElement = null;
                                      });
                                    },
                                  ),
                                ),
                              ),
                            ),
                          if (_editingElement != null &&
                              _editingElement!.type == ShapeType.text)
                            Positioned(
                              left: _editingElement!.point.dx,
                              top: _editingElement!.point.dy,
                              child: Container(
                                width: 150,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.blueAccent,
                                    width: 2,
                                  ),
                                  color: Colors.white.withOpacity(0.9),
                                ),
                                child: TextField(
                                  controller: _elementTextController,
                                  autofocus: true,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    color: Colors.black,
                                  ),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    isDense: true,
                                    contentPadding: EdgeInsets.all(4),
                                  ),
                                  onSubmitted: (val) {
                                    setState(() {
                                      _editingElement!.text = val;
                                      _editingElement = null;
                                    });
                                  },
                                ),
                              ),
                            ),

                          // Top Right Action Tab (Undo & Clear)
                          Positioned(
                            top: 20,
                            right: 20,
                            child: Container(
                              height: 40,
                              decoration: BoxDecoration(
                                color: isDarkMode
                                    ? const Color(0xFF2A2A2A)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isDarkMode
                                      ? Colors.white24
                                      : Colors.grey.shade400,
                                  width: 1.0,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.08),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Tooltip(
                                    message: 'Undo',
                                    child: InkWell(
                                      onTap: () {
                                        setState(() {
                                          if (points.isNotEmpty) {
                                            points.removeLast();
                                          }
                                        });
                                      },
                                      child: Icon(
                                        Icons.undo,
                                        color: isDarkMode
                                            ? Colors.white70
                                            : Colors.black87,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Container(
                                    width: 1,
                                    height: 20,
                                    color: isDarkMode
                                        ? Colors.white24
                                        : Colors.grey.shade300,
                                  ),
                                  const SizedBox(width: 12),
                                  Tooltip(
                                    message: 'Clear Canvas',
                                    child: InkWell(
                                      onTap: () {
                                        setState(() {
                                          points.clear();
                                          hasGenerated = false;
                                          generatedHtml = "";
                                          isClarifying = false;
                                          _promptController.clear();
                                          currentMode = DrawingMode.pen;
                                          uploadedImages.clear();
                                          _imageCounter = 0;
                                          _editingElement = null;
                                          ambiguities.clear();
                                          currentAmbiguityIndex = 0;
                                        });
                                      },
                                      child: const Icon(
                                        Icons.delete_outline,
                                        color: Colors.redAccent,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),

                      // Bottom generator bar using precisely the new UI
                      Positioned(
                        bottom: 30.0,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              height: 48,
                              decoration: BoxDecoration(
                                color: isDarkMode
                                    ? const Color(0xFF2A2A2A)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isDarkMode
                                      ? Colors.white24
                                      : Colors.grey.shade400,
                                  width: 1.0,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.08),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    onEnter: (_) =>
                                        setState(() => _isAddHovered = true),
                                    onExit: (_) =>
                                        setState(() => _isAddHovered = false),
                                    child: GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          final int newFrameIndex =
                                              points
                                                  .where(
                                                    (p) =>
                                                        p.type ==
                                                        ShapeType.frame,
                                                  )
                                                  .length +
                                              1;
                                          points.add(
                                            DrawingPoint(
                                              point: const Offset(40, 40),
                                              secondaryPoint: const Offset(
                                                360,
                                                690,
                                              ),
                                              type: ShapeType.frame,
                                              text: "screen_$newFrameIndex",
                                              paint: Paint()
                                                ..color = Colors.blueAccent
                                                ..strokeWidth = 6.0
                                                ..style = PaintingStyle.stroke,
                                            ),
                                          );
                                        });
                                      },
                                      child: Icon(
                                        Icons.add,
                                        color: isDarkMode
                                            ? Colors.white
                                            : Colors.black87,
                                        size: 24,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 24),
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    onEnter: (_) =>
                                        setState(() => _isSelectHovered = true),
                                    onExit: (_) => setState(
                                      () => _isSelectHovered = false,
                                    ),
                                    child: GestureDetector(
                                      onTap: () {
                                        _setDrawingMode(DrawingMode.select);
                                      },
                                      child: Icon(
                                        Icons.pan_tool_alt_outlined,
                                        color: currentMode == DrawingMode.select
                                            ? Colors.blueAccent
                                            : (isDarkMode
                                                  ? Colors.white
                                                  : Colors.black87),
                                        size: 22,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 24),
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    onEnter: (_) =>
                                        setState(() => _isImageHovered = true),
                                    onExit: (_) =>
                                        setState(() => _isImageHovered = false),
                                    child: GestureDetector(
                                      onTap: _pickImage,
                                      child: Icon(
                                        Icons.image_outlined,
                                        color: isDarkMode
                                            ? Colors.white
                                            : Colors.black87,
                                        size: 22,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 24),
                                  Tooltip(
                                    message: "Upload Sketch (Background)",
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      onEnter: (_) => setState(
                                        () => _isSketchHovered = true,
                                      ),
                                      onExit: (_) => setState(
                                        () => _isSketchHovered = false,
                                      ),
                                      child: GestureDetector(
                                        onTap: _uploadSketch,
                                        child: Icon(
                                          Icons.cloud_upload_outlined,
                                          color: _isSketchHovered
                                              ? Colors.blueAccent
                                              : (isDarkMode
                                                    ? Colors.white
                                                    : Colors.black87),
                                          size: 22,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 24),
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    onEnter: (_) {
                                      _popupHideTimer?.cancel();
                                      setState(() => _isPencilHovered = true);
                                    },
                                    onExit: (_) {
                                      setState(() => _isPencilHovered = false);
                                      _popupHideTimer = Timer(
                                        const Duration(milliseconds: 2000),
                                        () {
                                          if (mounted) setState(() {});
                                        },
                                      );
                                    },
                                    child: GestureDetector(
                                      onTap: () {
                                        _setDrawingMode(DrawingMode.pen);
                                      },
                                      child: Icon(
                                        Icons.draw_outlined,
                                        color: currentMode == DrawingMode.pen
                                            ? Colors.blueAccent
                                            : (isDarkMode
                                                  ? Colors.white
                                                  : Colors.black87),
                                        size: 22,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 24),
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    onEnter: (_) => setState(
                                      () => _isColorPickerHovered = true,
                                    ),
                                    onExit: (_) => setState(
                                      () => _isColorPickerHovered = false,
                                    ),
                                    child: GestureDetector(
                                      onTap: () {
                                        _setDrawingMode(DrawingMode.colorPicker);
                                      },
                                      child: Icon(
                                        Icons.colorize,
                                        color: currentMode == DrawingMode.colorPicker
                                            ? Colors.blueAccent
                                            : _isColorPickerHovered ? Colors.blue : (isDarkMode
                                                  ? Colors.white
                                                  : Colors.black87),
                                        size: 22,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 24),
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    onEnter: (_) => setState(
                                      () => _isGenerateHovered = true,
                                    ),
                                    onExit: (_) => setState(
                                      () => _isGenerateHovered = false,
                                    ),
                                    child: GestureDetector(
                                      onTap: isGenerating
                                          ? null
                                          : _generatePreview,
                                      child: Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: isDarkMode
                                                ? Colors.white
                                                : Colors.black87,
                                            width: 1.2,
                                          ),
                                        ),
                                        child: isGenerating
                                            ? SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: isDarkMode
                                                          ? Colors.white
                                                          : Colors.black87,
                                                    ),
                                              )
                                            : Icon(
                                                Icons.arrow_outward,
                                                color: isDarkMode
                                                    ? Colors.white
                                                    : Colors.black87,
                                                size: 16,
                                              ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            _buildPromptField(),
                            const SizedBox(width: 16),
                            _buildDeviceToggle(),
                          ],
                        ),
                      ),
                      if (_showDrawTools)
                        Positioned(
                          bottom: 78,
                          child: MouseRegion(
                            onEnter: (_) {
                              _popupHideTimer?.cancel();
                              setState(() => _isPopupHovered = true);
                            },
                            onExit: (_) {
                              setState(() => _isPopupHovered = false);
                              _popupHideTimer = Timer(
                                const Duration(milliseconds: 2000),
                                () {
                                  if (mounted) setState(() {});
                                },
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 12.0),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: isDarkMode
                                      ? const Color(0xFF2A2A2A)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isDarkMode
                                        ? Colors.white24
                                        : Colors.grey.shade400,
                                    width: 1.0,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.08),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      hitTestBehavior: HitTestBehavior.opaque,
                                      onEnter: (_) =>
                                          setState(() => _isRectHovered = true),
                                      onExit: (_) => setState(
                                        () => _isRectHovered = false,
                                      ),
                                      child: GestureDetector(
                                        onTap: () {
                                          _setDrawingMode(DrawingMode.rectangle);
                                        },
                                        child: Icon(
                                          Icons.crop_square,
                                          size: 22,
                                          color:
                                              currentMode ==
                                                  DrawingMode.rectangle
                                              ? Colors.blue
                                              : _isRectHovered
                                              ? Colors.blueAccent
                                              : (isDarkMode
                                                    ? Colors.white
                                                    : Colors.black87),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 24),
                                    MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      hitTestBehavior: HitTestBehavior.opaque,
                                      onEnter: (_) => setState(
                                        () => _isButtonHovered = true,
                                      ),
                                      onExit: (_) => setState(
                                        () => _isButtonHovered = false,
                                      ),
                                      child: GestureDetector(
                                        onTap: () {
                                          _setDrawingMode(DrawingMode.button);
                                        },
                                        child: Icon(
                                          Icons.smart_button,
                                          size: 22,
                                          color:
                                              currentMode == DrawingMode.button
                                              ? Colors.blue
                                              : _isButtonHovered
                                              ? Colors.blueAccent
                                              : (isDarkMode
                                                    ? Colors.white
                                                    : Colors.black87),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 24),
                                    MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      hitTestBehavior: HitTestBehavior.opaque,
                                      onEnter: (_) {},
                                      onExit: (_) {},
                                      child: GestureDetector(
                                        onTap: () {
                                          _setDrawingMode(DrawingMode.text);
                                        },
                                        child: Icon(
                                          Icons.text_fields,
                                          size: 22,
                                          color: currentMode == DrawingMode.text
                                              ? Colors.blue
                                              : (isDarkMode
                                                    ? Colors.white
                                                    : Colors.black87),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (isClarifying)
                        Positioned(
                          right: 150,
                          top:
                              150, // Roughly where the drawn box is based on image context
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // A simple line pointer mimicking the image
                              Container(
                                margin: const EdgeInsets.only(top: 40),
                                width: 50,
                                height: 2,
                                color: Colors.black87,
                              ),
                              const SizedBox(width: 8),
                              _buildAIPopup(),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      double totalWidth =
                          MediaQuery.of(context).size.width - 64;
                      if (totalWidth > 0) {
                        _leftPanelFraction += details.delta.dx / totalWidth;
                        _leftPanelFraction = _leftPanelFraction.clamp(0.2, 0.8);
                      }
                    });
                  },
                  child: Container(
                    width: 4,
                    color: isDarkMode ? Colors.white24 : Colors.grey.shade300,
                  ),
                ),
              ),

              // Right Side: Website Preview in a phone frame
              Expanded(
                flex: ((1 - _leftPanelFraction) * 100).toInt(),
                child: Container(
                  color: isDarkMode
                      ? const Color(0xFF1E1E1E)
                      : const Color(
                          0xFFF0F0F0,
                        ), // Light gray in light mode, dark otherwise
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final targetDeviceWidth = isDesktopMode ? 900.0 : 320.0;
                      final targetDeviceHeight = isDesktopMode ? 600.0 : 650.0;
                      const extraHeight = 68.0;

                      double scale = 1.0;
                      if (targetDeviceWidth > constraints.maxWidth - 40) {
                        scale = (constraints.maxWidth - 40) / targetDeviceWidth;
                      }
                      if ((targetDeviceHeight * scale) + extraHeight >
                          constraints.maxHeight - 40) {
                        scale =
                            (constraints.maxHeight - 40 - extraHeight) /
                            targetDeviceHeight;
                      }
                      if (scale > 1.0) scale = 1.0;
                      if (scale < 0.2) scale = 0.2;

                      final deviceWidth = targetDeviceWidth * scale;
                      final deviceHeight = targetDeviceHeight * scale;
                      final groupHeight = deviceHeight + extraHeight;

                      final deviceTop =
                          (constraints.maxHeight - groupHeight) / 2;

                      return Stack(
                        fit: StackFit.expand,
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            left: 0,
                            right: 0,
                            top: deviceTop,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildDeviceMockup(deviceWidth, deviceHeight),
                                const SizedBox(height: 20),
                                SizedBox(
                                  width:
                                      (deviceWidth < 450.0
                                              ? 450.0
                                              : deviceWidth)
                                          .clamp(
                                            10.0,
                                            constraints.maxWidth - 40.0,
                                          )
                                          .clamp(10.0, 600.0),
                                  child: _buildGlobalPrunePrompt(),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
          if (_showPrunePopup)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() => _showPrunePopup = false);
                  setIframeInteractable(true);
                },
                child: Container(color: Colors.transparent),
              ),
            ),
          if (_showPrunePopup)
            Positioned(
              left: _prunePosition.dx.clamp(
                10.0,
                (MediaQuery.of(context).size.width - 260.0).clamp(
                  10.0,
                  double.infinity,
                ),
              ),
              top: _prunePosition.dy.clamp(
                10.0,
                (MediaQuery.of(context).size.height - 250.0).clamp(
                  10.0,
                  double.infinity,
                ),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: _buildPrunePopup(),
              ),
            ),
          if (_showColorPicker)
            Positioned(
              left: _colorPickerPosition.dx.clamp(
                10.0,
                (MediaQuery.of(context).size.width - 260.0).clamp(
                  10.0,
                  double.infinity,
                ),
              ),
              top: _colorPickerPosition.dy.clamp(
                10.0,
                (MediaQuery.of(context).size.height - 350.0).clamp(
                  10.0,
                  double.infinity,
                ),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: LiveColorPicker(
                  initialColor: _currentColor,
                  onDrag: (details) {
                    setState(() => _colorPickerPosition += details.delta);
                  },
                  onColorChanged: (newColor) {
                    setState(() => _currentColor = newColor);
                    updatePreviewColor(
                      'rgba(${(newColor.r * 255.0).round()}, ${(newColor.g * 255.0).round()}, ${(newColor.b * 255.0).round()}, ${newColor.a.toStringAsFixed(2)})',
                    );
                  },
                  onClose: () {
                    setState(() => _showColorPicker = false);
                    setIframeInteractable(true);
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPromptField() {
    return Container(
      width: 320,
      height: 48,
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF2A2A2A) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDarkMode ? Colors.white24 : Colors.grey.shade400,
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Center(
        child: TextField(
          controller: _promptController,
          decoration: InputDecoration(
            hintText: "What are we building? (e.g. A messaging app)",
            border: InputBorder.none,
            isDense: true,
            hintStyle: TextStyle(
              color: isDarkMode ? Colors.white54 : Colors.black54,
              fontSize: 14,
            ),
          ),
          style: TextStyle(
            color: isDarkMode ? Colors.white : Colors.black87,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _buildGlobalPrunePrompt() {
    return Container(
      height: 48,
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF2A2A2A) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDarkMode ? Colors.white24 : Colors.grey.shade400,
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, color: Colors.blueAccent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _globalPruneController,
              decoration: InputDecoration(
                hintText: "Make overall changes... (e.g. Use a darker theme)",
                border: InputBorder.none,
                isDense: true,
                hintStyle: TextStyle(
                  color: isDarkMode ? Colors.white54 : Colors.black54,
                  fontSize: 14,
                ),
              ),
              style: TextStyle(
                color: isDarkMode ? Colors.white : Colors.black87,
                fontSize: 14,
              ),
              onSubmitted: (_) => _sendGlobalPruneRequest(),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _sendGlobalPruneRequest,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Colors.blue,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.send, color: Colors.white, size: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendGlobalPruneRequest() async {
    if (_globalPruneController.text.trim().isEmpty) return;
    final instruction = _globalPruneController.text.trim();
    setState(() {
      isGenerating = true;
      hasGenerated = false;
    });
    setIframeInteractable(true);

    final promptText = StringBuffer();
    promptText.writeln("You are an expert AI web designer.");
    promptText.writeln(
      "The user wants to make global/overall changes to the following entire HTML design.",
    );
    promptText.writeln("User Instruction: \"$instruction\".");
    promptText.writeln(
      "Apply these overall changes perfectly across the document. CRITICAL: Output ONLY the full updated HTML structure, wrapped in a markdown ```html block. Do not use JSON or output any other text.",
    );
    promptText.writeln(
      "Here is the FULL HTML:\n\n```html\n$generatedHtml\n```",
    );

    try {
      String text = "";
      final uri = Uri.parse(functionsApiUrl);
      final httpResponse = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'promptText': promptText.toString(),
        }),
      );

      if (httpResponse.statusCode == 200) {
        final data = jsonDecode(httpResponse.body);
        text = data['text'] ?? "";
      } else {
        throw Exception("Failed to call backend. Status code: ${httpResponse.statusCode}");
      }

      if (text.isNotEmpty) {

        final htmlBlockRegex = RegExp(
          r'```(?:html|xml)\s*([\s\S]*?)```',
          caseSensitive: false,
        );
        final genericBlockRegex = RegExp(r'```[a-zA-Z]*\s*([\s\S]*?)```');
        final htmlMatch = htmlBlockRegex.firstMatch(text);
        if (htmlMatch != null) {
          text = (htmlMatch.group(1) ?? text).trim();
        } else {
          final genericMatch = genericBlockRegex.firstMatch(text);
          if (genericMatch != null) {
            text = (genericMatch.group(1) ?? text).trim();
          }
        }

        if (mounted) {
          setState(() {
            generatedHtml = text;
            hasGenerated = true;
            isGenerating = false;
            _globalPruneController.clear();
          });
        }
      }
    } catch (e) {
      debugPrint("Error applying global changes: $e");
      if (mounted) {
        setState(() {
          hasGenerated = true; // revert to false was a bad state
          isGenerating = false;
        });
      }
    }
  }

  Future<void> _uploadImageForAI() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      final bytes = await image.readAsBytes();
      final imageId = "{IMG_${_imageCounter++}}";
      
      try {
        final fileName = 'upload_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await Supabase.instance.client.storage
            .from('images')
            .uploadBinary(
              fileName,
              bytes,
              fileOptions: const FileOptions(contentType: 'image/jpeg'),
            );

        final publicUrl = Supabase.instance.client.storage
            .from('images')
            .getPublicUrl(fileName);

        setState(() {
          uploadedImages[imageId] = publicUrl;
          final answer = "I have uploaded an image. Use $imageId for this frame.";
          
          if (currentAmbiguityIndex < ambiguities.length - 1) {
             _promptController.text +=
                 "\nQ: $clarifyQuestion -> A: $answer";
             currentAmbiguityIndex++;
             _aiReplyController.clear();
          } else {
             _promptController.text +=
                 "\nQ: $clarifyQuestion -> A: $answer";
             isClarifying = false;
             _generatePreview(userReply: "All questions answered");
             _aiReplyController.clear();
          }
        });
      } catch (error) {
        final base64String = base64Encode(bytes);
        final base64Url = "data:image/jpeg;base64,$base64String";
        setState(() {
          uploadedImages[imageId] = base64Url;
          final answer = "I have uploaded an image. Use $imageId for this frame.";
          
          if (currentAmbiguityIndex < ambiguities.length - 1) {
             _promptController.text +=
                 "\nQ: $clarifyQuestion -> A: $answer";
             currentAmbiguityIndex++;
             _aiReplyController.clear();
          } else {
             _promptController.text +=
                 "\nQ: $clarifyQuestion -> A: $answer";
             isClarifying = false;
             _generatePreview(userReply: "All questions answered");
             _aiReplyController.clear();
          }
        });
      }
    }
  }

  Widget _buildAIPopup() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      width: 280,
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF2A2A2A) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 15,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        clarifyQuestion.isNotEmpty
                            ? clarifyQuestion
                            : "What's the purpose of the\nbutton at the bottom?",
                        style: TextStyle(
                          fontStyle: FontStyle.italic,
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: isDarkMode ? Colors.white : Colors.black87,
                          height: 1.2,
                        ),
                      ),
                    ),
                    if (ambiguities.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(left: 8.0),
                        child: Text(
                          "${currentAmbiguityIndex + 1}/${ambiguities.length}",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDarkMode ? Colors.white54 : Colors.black54,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                if (clarifySuggestion.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: isDarkMode
                          ? const Color(0xFF3B487A)
                          : const Color(0xFFE2E7FF),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          color: isDarkMode
                              ? Colors.white70
                              : const Color(0xFF3B487A),
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            clarifySuggestion,
                            style: TextStyle(
                              color: isDarkMode ? Colors.white : Colors.black87,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                if (clarifyNeedsImage)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDarkMode ? Colors.blueAccent : Colors.blue.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: _uploadImageForAI,
                      icon: const Icon(Icons.upload_file, size: 18),
                      label: const Text("Upload Image"),
                    ),
                  ),
                Container(
                  color: isDarkMode
                      ? const Color(0xFF3A3A3A)
                      : const Color(0xFFF7F7F7),
                  child: TextField(
                    controller: _aiReplyController,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.only(
                        top: 12,
                        bottom: 8,
                        left: 8,
                        right: 8,
                      ),
                      border: UnderlineInputBorder(
                        borderSide: BorderSide(
                          color: isDarkMode ? Colors.white54 : Colors.black38,
                        ),
                      ),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(
                          color: isDarkMode ? Colors.white54 : Colors.black38,
                        ),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(
                          color: isDarkMode ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                    style: TextStyle(
                      fontSize: 14,
                      color: isDarkMode ? Colors.white : Colors.black,
                    ),
                    onSubmitted: (val) {
                      setState(() {
                        if (currentAmbiguityIndex < ambiguities.length - 1) {
                          // save answer? We're ignoring answers temporarily or accumulating them
                          final answer = val.trim();
                          if (answer.isNotEmpty) {
                            _promptController.text +=
                                "\nQ: ${clarifyQuestion} -> A: $answer";
                          }
                          currentAmbiguityIndex++;
                          _aiReplyController.clear();
                        } else {
                          final answer = val.trim();
                          if (answer.isNotEmpty) {
                            _promptController.text +=
                                "\nQ: ${clarifyQuestion} -> A: $answer";
                          }
                          isClarifying = false;
                          _generatePreview(userReply: "All questions answered");
                          _aiReplyController.clear();
                        }
                      });
                    },
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => setState(() {
                          isClarifying = false;
                          _aiReplyController.clear();
                        }),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isDarkMode
                                  ? Colors.white54
                                  : Colors.black54,
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            Icons.close,
                            size: 20,
                            color: isDarkMode ? Colors.white70 : Colors.black54,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            if (currentAmbiguityIndex <
                                ambiguities.length - 1) {
                              final answer = _aiReplyController.text.trim();
                              if (answer.isNotEmpty) {
                                _promptController.text +=
                                    "\nQ: ${clarifyQuestion} -> A: $answer";
                              }
                              currentAmbiguityIndex++;
                              _aiReplyController.clear();
                            } else {
                              final answer = _aiReplyController.text.trim();
                              if (answer.isNotEmpty) {
                                _promptController.text +=
                                    "\nQ: ${clarifyQuestion} -> A: $answer";
                              }
                              isClarifying = false;
                              _generatePreview(
                                userReply: "All questions answered",
                              );
                              _aiReplyController.clear();
                            }
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isDarkMode
                                  ? Colors.white54
                                  : Colors.black54,
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            currentAmbiguityIndex < ambiguities.length - 1
                                ? Icons.arrow_forward
                                : Icons.check,
                            size: 20,
                            color: isDarkMode ? Colors.white70 : Colors.black54,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0xFF5A7CFF),
                borderRadius: BorderRadius.only(
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(8),
                ),
              ),
              child: Text(
                "${currentAmbiguityIndex + 1}/${ambiguities.isNotEmpty ? ambiguities.length : 1}",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrunePopup() {
    return Container(
      width: 250,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blue.shade300, width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Describe the change to make",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: Colors.black87,
                ),
              ),
              InkWell(
                onTap: () {
                  setState(() => _showPrunePopup = false);
                  setIframeInteractable(true);
                },
                child: const Icon(Icons.close, size: 16, color: Colors.black54),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 80,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Stack(
              children: [
                TextField(
                  controller: _pruneController,
                  maxLines: null,
                  style: const TextStyle(fontSize: 13, color: Colors.black54),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    hintText:
                        "Make it shorter , black outline, transparent , black text curved edges",
                    hintStyle: TextStyle(color: Colors.black38),
                  ),
                ),
                Positioned(
                  bottom: -4,
                  right: -4,
                  child: InkWell(
                    onTap: _sendPruneRequest,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.arrow_circle_right_outlined,
                        size: 24,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendPruneRequest() async {
    if (_pruneController.text.trim().isEmpty) return;
    final instruction = _pruneController.text.trim();
    setState(() {
      _showPrunePopup = false;
      isGenerating = true;
      hasGenerated = false;
    });
    setIframeInteractable(true);

    final promptText = StringBuffer();
    promptText.writeln("You are an expert AI layout editor.");
    promptText.writeln(
      "Look at the requested changes. The user has Double-Clicked a specific HTML element in the preview UI, marked with `data-ai-target=\"true\"`.",
    );
    promptText.writeln("User Instruction: \"$instruction\".");
    promptText.writeln(
      "Modify ONLY that specific targeted element to achieve the required design changes.",
    );
    promptText.writeln(
      "CRITICAL: Output ONLY the full updated HTML structure matching the user's styling request, wrapped in a markdown ```html block. Do not use JSON or output any other text.",
    );
    promptText.writeln(
      "Here is the FULL HTML. Find the element with data-ai-target='true' and modify it:\n\n```html\n$_pruneComponentHtml\n```",
    );

    try {
      String text = "";
      final uri = Uri.parse(functionsApiUrl);
      final httpResponse = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'promptText': promptText.toString(),
        }),
      );

      if (httpResponse.statusCode == 200) {
        final data = jsonDecode(httpResponse.body);
        text = data['text'] ?? "";
      } else {
        throw Exception("Failed to call backend. Status code: ${httpResponse.statusCode}");
      }

      if (text.isNotEmpty) {

        final htmlBlockRegex = RegExp(
          r'```(?:html|xml)\s*([\s\S]*?)```',
          caseSensitive: false,
        );
        final genericBlockRegex = RegExp(r'```[a-zA-Z]*\s*([\s\S]*?)```');
        final htmlMatch = htmlBlockRegex.firstMatch(text);
        if (htmlMatch != null) {
          text = (htmlMatch.group(1) ?? text).trim();
        } else {
          final genericMatch = genericBlockRegex.firstMatch(text);
          if (genericMatch != null) {
            text = (genericMatch.group(1) ?? text).trim();
          }
        }

        if (mounted) {
          setState(() {
            generatedHtml = text;
            hasGenerated = true;
            isGenerating = false;
            _pruneController.clear();
          });
        }
      }
    } catch (e) {
      debugPrint("Error updating component: $e");
    }
  }

  Widget _buildDeviceToggle() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          setState(() {
            isDesktopMode = !isDesktopMode;
          });
        },
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: isDarkMode ? const Color(0xFF2A2A2A) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDarkMode ? Colors.white24 : Colors.grey.shade400,
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Icon(
              isDesktopMode ? Icons.desktop_mac : Icons.phone_iphone,
              color: isDarkMode ? Colors.white : Colors.black87,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceMockup(double width, double height) {
    if (!isDesktopMode) return _buildPhoneMockup(width, height);

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade400, width: 2),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          // Browser Header
          Container(
            height: 30,
            decoration: BoxDecoration(
              color: isDarkMode ? Colors.grey.shade800 : Colors.grey.shade200,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(10),
              ),
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade400, width: 1),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 10),
                CircleAvatar(radius: 5, backgroundColor: Colors.red.shade400),
                const SizedBox(width: 6),
                CircleAvatar(
                  radius: 5,
                  backgroundColor: Colors.orange.shade400,
                ),
                const SizedBox(width: 6),
                CircleAvatar(radius: 5, backgroundColor: Colors.green.shade400),
              ],
            ),
          ),
          // Browser Body
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(10),
              ),
              child: Scaffold(
                backgroundColor: Colors.white,
                body: hasGenerated
                    ? _buildGeneratedContent()
                    : _buildEmptyScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneMockup(double width, double height) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(40),
        border: Border.all(color: Colors.black, width: 6),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Inner Screen
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(34),
              child: Scaffold(
                backgroundColor: Colors.white,
                body: hasGenerated
                    ? _buildGeneratedContent()
                    : _buildEmptyScreen(),
              ),
            ),
          ),
          // Dynamic Island Header
          Positioned(
            top: 10,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  height: 25,
                  width: 90,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyScreen() {
    return Center(
      child: isGenerating
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(color: Colors.blue),
                ),
                const SizedBox(height: 20),
                Text(
                  "Generating Interface with Gemini...",
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ],
            )
          : Text(
              "Preview will appear here",
              style: TextStyle(color: Colors.grey.shade400, fontSize: 16),
            ),
    );
  }

  Widget _buildGeneratedContent() {
    if (generatedHtml.isEmpty) return const SizedBox.shrink();

    String injectedHtml = generatedHtml;
    if (!injectedHtml.contains('live-color-editor-script')) {
      String script = '''
<script id="live-color-editor-script">
  (function() {
    let targetEl = null;
    let isTextTarget = false;
    let isColorPickerMode = false;

    window.addEventListener('message', function(e) {
      let data = e.data;
      if (typeof data === 'string') {
        try { data = JSON.parse(data); } catch(err) {}
      }
      if (data && data.type === 'SET_COLOR_PICKER_MODE') {
         isColorPickerMode = data.enabled;
         return;
      }
      if (data && data.type === 'UPDATE_COLOR') {
         if (targetEl) {
           if (isTextTarget) {
              targetEl.style.setProperty('color', data.color, 'important');
           } else {
             const tagName = targetEl.tagName.toUpperCase();
             if (['SVG', 'PATH', 'RECT', 'CIRCLE'].includes(tagName)) {
                targetEl.style.setProperty('fill', data.color, 'important');
             } else {
                targetEl.style.setProperty('background-color', data.color, 'important');
             }
           }
         }
      }
    });

    let clickTimer = null;
    document.addEventListener('dblclick', function(e) {
      e.preventDefault();
      e.stopPropagation();
      if (clickTimer) {
         clearTimeout(clickTimer);
         clickTimer = null;
      }
      let target = e.target;
      document.querySelectorAll('[data-ai-target]').forEach(el => delete el.dataset.aiTarget);
      target.dataset.aiTarget = "true";
      window.parent.postMessage(JSON.stringify({
        type: 'DOUBLE_CLICK_COMPONENT',
        targetHtml: target.outerHTML,
        fullHtml: document.documentElement.outerHTML,
        x: e.clientX,
        y: e.clientY
      }), '*');
    });

    document.addEventListener('click', function(e) {
      if (!isColorPickerMode) return;
      e.preventDefault();
      e.stopPropagation();

      targetEl = e.target;
      isTextTarget = false;
      const style = window.getComputedStyle(targetEl);
      let currentColor = style.backgroundColor;
      const tagName = targetEl.tagName.toUpperCase();
      const textTags = ['SPAN', 'P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'A', 'STRONG', 'EM', 'I', 'B'];
      
      if (textTags.includes(tagName) || (currentColor === 'rgba(0, 0, 0, 0)' && targetEl.childNodes.length === 1 && targetEl.firstChild.nodeType === 3)) {
         isTextTarget = true;
         currentColor = style.color;
      }

      if (clickTimer) clearTimeout(clickTimer);
      clickTimer = setTimeout(function() {
        clickTimer = null;
        window.parent.postMessage(JSON.stringify({
          type: 'OPEN_COLOR_PICKER',
          color: currentColor,
          x: e.clientX,
          y: e.clientY
        }), '*');
      }, 250);
    });
  })();
</script>
''';
      if (injectedHtml.contains('</body>')) {
        injectedHtml = injectedHtml.replaceFirst('</body>', '$script</body>');
      } else {
        injectedHtml += script;
      }
    }

    if (_cachedLivePreview == null || _lastInjectedHtml != injectedHtml) {
      _lastInjectedHtml = injectedHtml;
      _cachedLivePreview = buildLivePreview(
        injectedHtml,
        onColorRequest: (colorStr, x, y) {
          setState(() {
            _currentColor = _parseCssColor(colorStr);
            if (_iframeContainerKey.currentContext != null) {
              final box =
                  _iframeContainerKey.currentContext!.findRenderObject()
                      as RenderBox;
              final globalPos = box.localToGlobal(Offset(x, y));
              _colorPickerPosition = Offset(
                globalPos.dx + 20,
                globalPos.dy - 100,
              );
            } else {
              _colorPickerPosition = Offset(x, y);
            }
            _showColorPicker = true;
          });
          setIframeInteractable(false);
        },
        onDoubleClickComponent: (targetHtml, fullHtml, x, y) {
          setState(() {
            _pruneComponentHtml = fullHtml;
            if (_iframeContainerKey.currentContext != null) {
              final box =
                  _iframeContainerKey.currentContext!.findRenderObject()
                      as RenderBox;
              final globalPos = box.localToGlobal(Offset(x, y));
              _prunePosition = Offset(globalPos.dx - 125, globalPos.dy);
            } else {
              _prunePosition = Offset(x, y);
            }
            _showPrunePopup = true;
            _showColorPicker = false;
          });
          setIframeInteractable(false);
        },
      );
    }

    return Container(
      key: _iframeContainerKey,
      color: Colors.white,
      width: double.infinity,
      height: double.infinity,
      child: _cachedLivePreview!,
    );
  }

  Widget _buildSidebar() {
    final bgColor = isDarkMode
        ? const Color.fromARGB(255, 34, 32, 39)
        : const Color(0xFFF5F5F5);
    final textColor = isDarkMode ? Colors.white : Colors.black87;
    final iconColor = isDarkMode ? Colors.white70 : Colors.black54;
    final bottomBgColor = isDarkMode ? Colors.black : Colors.white;

    return IntrinsicWidth(
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          border: Border(
            right: BorderSide(color: Colors.grey.withOpacity(0.2)),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header (Always white bg according to the image mockup)
            Container(
              height: 80,
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: _isSidebarOpen
                    ? MainAxisAlignment.spaceBetween
                    : MainAxisAlignment.center,
                children: [
                  if (_isSidebarOpen)
                    Image.asset('assets/icon.png', height: 64),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _isSidebarOpen = !_isSidebarOpen;
                        });
                      },
                      child: const Icon(
                        Icons.view_sidebar_outlined,
                        color: Colors.black87,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Projects List
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_isSidebarOpen)
                      Text(
                        "Projects",
                        style: TextStyle(
                          color: textColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.5,
                        ),
                      ),
                    if (_isSidebarOpen) const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: _isSidebarOpen
                          ? MainAxisAlignment.start
                          : MainAxisAlignment.center,
                      children: [
                        Icon(Icons.folder_outlined, color: textColor, size: 20),
                        if (_isSidebarOpen) const SizedBox(width: 12),
                        if (_isSidebarOpen)
                          Text(
                            "Food order",
                            style: TextStyle(
                              color: textColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_isSidebarOpen)
                      _buildTreeItem("frame_1", textColor, iconColor),
                    if (_isSidebarOpen)
                      _buildTreeItem("frame_2", textColor, iconColor),
                    if (_isSidebarOpen)
                      _buildTreeItem("frame_3", textColor, iconColor),
                  ],
                ),
              ),
            ),
            // Footer Bottom Icons
            Container(
              height: 90,
              color: bottomBgColor,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isSidebarOpen)
                    Tooltip(
                      message:
                          "Keyboard Shortcuts:\nR - Draw rectangle\nB - Button\nT - Text",
                      textStyle: TextStyle(
                        color: isDarkMode ? Colors.white : Colors.black87,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: isDarkMode
                            ? const Color(0xFF2A2A2A)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isDarkMode
                              ? Colors.white24
                              : Colors.grey.shade400,
                          width: 1.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.08),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Icon(
                          Icons.keyboard_alt_outlined,
                          color: iconColor,
                          size: 20,
                        ),
                      ),
                    ),
                  if (_isSidebarOpen) const SizedBox(width: 20),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          isDarkMode = !isDarkMode;
                        });
                      },
                      child: Icon(
                        isDarkMode
                            ? Icons.nightlight_round
                            : Icons.light_mode_outlined,
                        color: iconColor,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTreeItem(String title, Color textColor, Color iconColor) {
    return Padding(
      padding: const EdgeInsets.only(left: 14, top: 10),
      child: Row(
        children: [
          Icon(Icons.insert_drive_file_outlined, color: iconColor, size: 16),
          const SizedBox(width: 10),
          Text(
            title,
            style: TextStyle(color: textColor.withOpacity(0.9), fontSize: 13),
          ),
        ],
      ),
    );
  }
}

enum DrawingMode { select, pen, rectangle, circle, text, button, colorPicker }

enum ShapeType { line, rectangle, circle, text, image, button, frame, sketch }

class DrawingPoint {
  Offset point;
  Paint paint;
  ShapeType type;
  Offset? secondaryPoint;
  String? text;
  ui.Image? image;
  String? imageId;

  DrawingPoint({
    required this.point,
    required this.paint,
    this.type = ShapeType.line,
    this.secondaryPoint,
    this.text,
    this.image,
    this.imageId,
  });
}

class DrawingPainter extends CustomPainter {
  DrawingPainter({
    required this.pointsList,
    this.selectedPoint,
    this.isDesktopMode = false,
  });
  List<DrawingPoint> pointsList;
  DrawingPoint? selectedPoint;
  bool isDesktopMode;

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < pointsList.length; i++) {
      var p = pointsList[i];
      if (p.type == ShapeType.line) {
        if (i < pointsList.length - 1 &&
            p.point != Offset.infinite &&
            pointsList[i + 1].point != Offset.infinite &&
            pointsList[i + 1].type == ShapeType.line) {
          canvas.drawLine(p.point, pointsList[i + 1].point, p.paint);
        } else if (p.point != Offset.infinite &&
            (i == pointsList.length - 1 ||
                pointsList[i + 1].point == Offset.infinite ||
                pointsList[i + 1].type != ShapeType.line)) {
          canvas.drawPoints(ui.PointMode.points, [p.point], p.paint);
        }
      } else if (p.type == ShapeType.frame && p.secondaryPoint != null) {
        // Draw frame background transparent with blue border
        canvas.drawRect(
          Rect.fromPoints(p.point, p.secondaryPoint!),
          Paint()
            ..color = Colors.blueAccent.withOpacity(0.05)
            ..style = PaintingStyle.fill,
        );
        canvas.drawRect(Rect.fromPoints(p.point, p.secondaryPoint!), p.paint);

        final textSpan = TextSpan(
          text: p.text ?? (isDesktopMode ? "Desktop Frame" : "Mobile Frame"),
          style: const TextStyle(
            color: Colors.blueAccent,
            fontSize: 14,
            fontFamily: 'sans-serif',
            fontWeight: FontWeight.bold,
          ),
        );
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(canvas, Offset(p.point.dx, p.point.dy - 20));
      } else if (p.type == ShapeType.rectangle && p.secondaryPoint != null) {
        canvas.drawRect(Rect.fromPoints(p.point, p.secondaryPoint!), p.paint);
      } else if (p.type == ShapeType.circle && p.secondaryPoint != null) {
        double radius = (p.point - p.secondaryPoint!).distance / 2;
        Offset center = Offset(
          (p.point.dx + p.secondaryPoint!.dx) / 2,
          (p.point.dy + p.secondaryPoint!.dy) / 2,
        );
        canvas.drawCircle(center, radius, p.paint);
      } else if (p.type == ShapeType.button && p.secondaryPoint != null) {
        // Only draw the background/border if it's not being actively edited
        // We still draw it to act as placeholder, but no text if it's being edited
        canvas.drawRect(Rect.fromPoints(p.point, p.secondaryPoint!), p.paint);
        // We will skip drawing the text in the CustomPainter while editing is handled via Positioned overlay
        if (p.text != null && p.text!.isNotEmpty) {
          final textSpan = TextSpan(
            text: p.text,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 16,
              fontFamily: 'sans-serif',
            ),
          );
          final textPainter = TextPainter(
            text: textSpan,
            textDirection: TextDirection.ltr,
          );
          textPainter.layout();
          Rect rect = Rect.fromPoints(p.point, p.secondaryPoint!);
          Offset centerLocation = Offset(
            rect.center.dx - textPainter.width / 2,
            rect.center.dy - textPainter.height / 2,
          );
          textPainter.paint(canvas, centerLocation);
        }
      } else if (p.type == ShapeType.text && p.text != null) {
        final textSpan = TextSpan(
          text: p.text,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 20,
            fontFamily: 'sans-serif',
          ),
        );
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(canvas, p.point);
      } else if ((p.type == ShapeType.image || p.type == ShapeType.sketch) &&
          p.image != null &&
          p.secondaryPoint != null) {
        // Draw actual image scaled
        canvas.drawImageRect(
          p.image!,
          Rect.fromLTWH(
            0,
            0,
            p.image!.width.toDouble(),
            p.image!.height.toDouble(),
          ),
          Rect.fromPoints(p.point, p.secondaryPoint!),
          p.paint,
        );
        // Draw the red tag on top for AI to recognize
        if (p.type == ShapeType.image && p.imageId != null) {
          final tagSpan = TextSpan(
            text: p.imageId,
            style: const TextStyle(
              color: Colors.red,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              backgroundColor: Colors.white,
            ),
          );
          final textPainter = TextPainter(
            text: tagSpan,
            textDirection: TextDirection.ltr,
          );
          textPainter.layout();
          textPainter.paint(canvas, p.point);
        }
      }
    }

    if (selectedPoint != null) {
      Rect? bounds;
      if (selectedPoint!.secondaryPoint != null) {
        bounds = Rect.fromPoints(
          selectedPoint!.point,
          selectedPoint!.secondaryPoint!,
        );
      } else if (selectedPoint!.type == ShapeType.text) {
        bounds = Rect.fromLTWH(
          selectedPoint!.point.dx,
          selectedPoint!.point.dy,
          80,
          20,
        );
      }

      if (bounds != null) {
        final outlinePaint = Paint()
          ..color = Colors.blueAccent
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
        canvas.drawRect(bounds, outlinePaint);

        final handlePaint = Paint()
          ..color = Colors.blue
          ..style = PaintingStyle.fill;
        final handleStroke = Paint()
          ..color = Colors.white
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke;

        final pts = [
          bounds.topLeft,
          bounds.topCenter,
          bounds.topRight,
          bounds.centerLeft,
          bounds.centerRight,
          bounds.bottomLeft,
          bounds.bottomCenter,
          bounds.bottomRight,
        ];

        for (var pt in pts) {
          final r = Rect.fromCenter(center: pt, width: 10, height: 10);
          canvas.drawRect(r, handlePaint);
          canvas.drawRect(r, handleStroke);
        }
      }
    }
  }

  @override
  bool shouldRepaint(DrawingPainter oldDelegate) => true;
}

class LiveColorPicker extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onColorChanged;
  final VoidCallback onClose;
  final GestureDragUpdateCallback? onDrag;

  const LiveColorPicker({
    super.key,
    required this.initialColor,
    required this.onColorChanged,
    required this.onClose,
    this.onDrag,
  });

  @override
  State<LiveColorPicker> createState() => _LiveColorPickerState();
}

class _LiveColorPickerState extends State<LiveColorPicker> {
  late HSVColor _hsvColor;

  @override
  void initState() {
    super.initState();
    _hsvColor = HSVColor.fromColor(widget.initialColor);
  }

  void _updateColor(HSVColor newColor) {
    setState(() {
      _hsvColor = newColor;
    });
    widget.onColorChanged(_hsvColor.toColor());
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 250,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: widget.onDrag,
            child: Container(
              color: Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "Solid (Drag to move)",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  InkWell(
                    onTap: widget.onClose,
                    child: const Icon(
                      Icons.close,
                      size: 16,
                      color: Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1, thickness: 1),
          // Canvas
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) {
              _handleCanvasDrag(details.localPosition, 250, 200);
            },
            onPanDown: (details) {
              _handleCanvasDrag(details.localPosition, 250, 200);
            },
            child: SizedBox(
              height: 200,
              width: double.infinity,
              child: Stack(
                children: [
                  Container(
                    color: HSVColor.fromAHSV(
                      1.0,
                      _hsvColor.hue,
                      1.0,
                      1.0,
                    ).toColor(),
                  ),
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.white, Colors.transparent],
                      ),
                    ),
                  ),
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black],
                      ),
                    ),
                  ),
                  Positioned(
                    left: _hsvColor.saturation * 250 - 7,
                    top: (1 - _hsvColor.value) * 200 - 7,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black45,
                            blurRadius: 2,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Sliders
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.colorize, size: 20, color: Colors.black54),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        children: [
                          _buildHueSlider(),
                          const SizedBox(height: 12),
                          _buildAlphaSlider(),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Hex",
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    Text(
                      _hsvColor
                          .toColor()
                          .value
                          .toRadixString(16)
                          .padLeft(8, '0')
                          .substring(2)
                          .toUpperCase(),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      "${(_hsvColor.alpha * 100).round()}%",
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHueSlider() {
    return GestureDetector(
      onPanUpdate: (details) => _handleHueDrag(details.localPosition.dx, 190),
      onPanDown: (details) => _handleHueDrag(details.localPosition.dx, 190),
      child: Container(
        height: 12,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          gradient: const LinearGradient(
            colors: [
              Color(0xFFFF0000),
              Color(0xFFFFFF00),
              Color(0xFF00FF00),
              Color(0xFF00FFFF),
              Color(0xFF0000FF),
              Color(0xFFFF00FF),
              Color(0xFFFF0000),
            ],
          ),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: (_hsvColor.hue / 360) * 190 - 7,
              top: -1,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(color: Colors.black26),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 2),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlphaSlider() {
    return GestureDetector(
      onPanUpdate: (details) => _handleAlphaDrag(details.localPosition.dx, 190),
      onPanDown: (details) => _handleAlphaDrag(details.localPosition.dx, 190),
      child: Container(
        height: 12,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: Colors.grey.shade300,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    _hsvColor.toColor().withOpacity(1.0),
                  ],
                ),
              ),
            ),
            Positioned(
              left: _hsvColor.alpha * 190 - 7,
              top: -1,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(color: Colors.black26),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 2),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleCanvasDrag(Offset localPosition, double width, double height) {
    double sat = (localPosition.dx / width).clamp(0.0, 1.0);
    double val = (1.0 - (localPosition.dy / height)).clamp(0.0, 1.0);
    _updateColor(_hsvColor.withSaturation(sat).withValue(val));
  }

  void _handleHueDrag(double dx, double width) {
    double hue = ((dx / width) * 360).clamp(0.0, 360.0);
    // hsv color hue clamping is 0 to 360 inclusive, but 360 is valid.
    if (hue >= 360.0) hue = 359.9;
    _updateColor(_hsvColor.withHue(hue));
  }

  void _handleAlphaDrag(double dx, double width) {
    double alpha = (dx / width).clamp(0.0, 1.0);
    _updateColor(_hsvColor.withAlpha(alpha));
  }
}

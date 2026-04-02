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

// Set this to your secure backend URL (e.g., http://localhost:3000/api/generate)
// For Android emulator, you might need http://10.0.2.2:3000/api/generate
const String backendApiUrl = 'http://localhost:3000/api/generate';

// IMPORTANT: Replace these with your Supabase credentials!
const String supabaseUrl = 'https://ldpodxtofvusyvpbxcta.supabase.co';
const String supabaseAnonKey = 'sb_publishable_jvUUEd1pCdnIrAuUsNovIA_dp-GElV-';

Future<void> main() async {
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
  List<DrawingPoint> points = [];
  bool hasGenerated = false;
  bool isGenerating = false;
  String generatedHtml = "";

  bool isClarifying = false;
  String clarifyQuestion = "";
  String clarifySuggestion = "";

  DrawingMode currentMode = DrawingMode.pen;
  bool _isPencilHovered = false;
  bool _isPopupHovered = false;
  bool _isRectHovered = false;
  bool _isButtonHovered = false;
  bool _isAddHovered = false;
  bool _isGenerateHovered = false;
  bool _isSelectHovered = false;
  bool _isImageHovered = false;
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
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _aiReplyController = TextEditingController();
  final TextEditingController _elementTextController = TextEditingController();

  DrawingPoint? _editingElement;
  List<DrawingPoint> _dragChildren = [];

  int _imageCounter = 0;
  Map<String, String> uploadedImages = {};

  bool _showColorPicker = false;
  Color _currentColor = Colors.white;
  Offset _colorPickerPosition = Offset.zero;

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
      "1. RECOGNIZE SHAPES AS UI COMPONENTS: Rectangles are typically buttons, cards, images, or input fields. Circles are usually avatars or icons. Identify the layout hierarchy and structural components the user is attempting to map out.",
    );
    promptText.writeln(
      "2. BE SMART: Ensure elements have realistic padding, margins, fonts, colors, and modern border-radii.",
    );
    promptText.writeln(
      "3. 320px MOBILE VIEWPORT RULES: The target output container is EXACTLY 320px wide and 100% height (device frame). You must aggressively constrain your HTML to prevent horizontal overflow. Rely on modern CSS.",
    );

    if (userPrompt.trim().isNotEmpty) {
      promptText.writeln(
        "4. STRICT STYLING: The user provided specific instructions below. You MUST aggressively apply their requested colors, themes, fonts, and specific styling to the components you identified.",
      );
      promptText.writeln('USER STYLE PROMPT: "$userPrompt"');
    }
    if (frameMetadata.isNotEmpty) {
      promptText.writeln(
        "4b. FRAME METADATA: Use these exact relative positions (in % of the mobile screen) for placing the specific elements:\n$frameMetadata",
      );
    }
    if (uploadedImages.isNotEmpty) {
      promptText.writeln(
        "5. CRITICAL: PLACED IMAGES DETECTED! There is at least one image in this sketch explicitly marked with a red tag like {IMG_0}. You absolutely MUST insert an <img> tag exactly at its position using the tag string as the src: <img src='{IMG_0}' style='width: 100%; object-fit: cover; border-radius: 12px; margin-bottom: 10px;' />. FAILURE to use the exact {IMG_0} tag in the src attribute is unacceptable.",
      );
    }

    if (isInitialGeneration) {
      promptText.writeln(
        "6. CLARIFICATION PHASE: You must NOT generate HTML yet. Analyze the provided wireframe/sketch. Identify any ambiguous placeholders like 'Enter text' or 'Button' and ask the user what they should be. Be extremely concise. Do not blabber. Ask exactly what you are doubtful about in 1-2 short sentences maximum. Output ONLY a JSON object exactly like this:\n"
        '{\n'
        '  "type": "clarify",\n'
        '  "question": "[Your short, concise question about your doubt]",\n'
        '  "suggestion": "[A very brief design suggestion]"\n'
        '}\n',
      );
    } else {
      promptText.writeln(
        "6. GENERATION PHASE: The user has clarified their intent. Output ONLY the HTML code wrapped in a markdown ```html block. DO NOT use JSON.",
      );
    }

    try {
      final base64Image = base64Encode(imageBytes);

      final response = await http.post(
        Uri.parse(backendApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'promptText': promptText.toString(),
          'base64Image': base64Image,
          'isInitialGeneration': isInitialGeneration,
        }),
      );

      if (response.statusCode != 200) {
        return "<div style='color:red; margin:20px; font-family:sans-serif;'><b>Error:</b> Backend returned ${response.statusCode}: ${response.body}</div>";
      }

      final jsonResponse = jsonDecode(response.body);
      String text = jsonResponse['text'] ?? "";
      debugPrint(
        "========== BACKEND RAW RESPONSE ==========\n$text\n==========================================",
      );

      // Re-map images
      for (var entry in uploadedImages.entries) {
        text = text.replaceAll(entry.key, entry.value);
      }

      // Strip any markdown code blocks completely before checking
      String cleanText = text.trim();
      final codeBlockRegex = RegExp(r'```[a-zA-Z]*\s*([\s\S]*?)```');
      final match = codeBlockRegex.firstMatch(cleanText);
      if (match != null) {
        cleanText = (match.group(1) ?? cleanText).trim();
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
            '<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>::-webkit-scrollbar { display: none; } body { -ms-overflow-style: none; scrollbar-width: none; }</style></head><body style="margin: 0; padding: 0;">\n$text\n</body></html>';
      } else if (!text.contains('::-webkit-scrollbar')) {
        text = text.replaceFirst(
          '<head>',
          '<head><style>::-webkit-scrollbar { display: none; } body { -ms-overflow-style: none; scrollbar-width: none; }</style>',
        );
      }

      debugPrint(
        "========== AFTER REMAPPING ==========\n$text\n==========================================",
      );

      return text;
    } catch (e) {
      return "<div style='color:red; margin:20px; font-family:sans-serif;'><b>Error:</b> Failed to generate UI.\\n$e</div>";
    }
  }

  void _generatePreview({String? userReply}) async {
    if (points.isEmpty && !hasGenerated) {
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
        final f = frames.last;
        final fRect = Rect.fromPoints(f.point, f.secondaryPoint!);
        for (var p in points) {
          if (p == f || p.type == ShapeType.line) continue;

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
      if (htmlResponse.contains('"clarify"') &&
          htmlResponse.contains('"question"')) {
        try {
          int start = htmlResponse.indexOf('{');
          int end = htmlResponse.lastIndexOf('}');
          if (start != -1 && end != -1 && end > start) {
            String jsonStr = htmlResponse.substring(start, end + 1);
            final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
            setState(() {
              isClarifying = true;
              clarifyQuestion =
                  decoded['question']?.toString() ??
                  "I'm having trouble understanding this sketch.";
              clarifySuggestion =
                  decoded['suggestion']?.toString() ??
                  "Could you add some text labels indicating what these elements are?";
              isGenerating = false;
            });
            return;
          }
        } catch (e) {
          debugPrint("Failed to parse clarification JSON: $e");
        }

        // Fallback catch block logic
        setState(() {
          isClarifying = true;
          clarifyQuestion = "This sketch looks a bit abstract.";
          clarifySuggestion = "Can you describe what layout you're aiming for?";
          isGenerating = false;
        });
        return;
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

      // Add image to canvas right away
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        toolbarHeight: 80,
        title: Row(
          children: [
            Image.asset('assets/1.png', height: 60),
            const SizedBox(width: 12),
            Image.asset('assets/1.jpeg', height: 45),
          ],
        ),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: Row(
        children: [
          // Left side: Drawable canvas and bottom prompt
          Expanded(
            child: Container(
              color: Colors.white,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Column(
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            // Sketch Area inside RepaintBoundary for image capture
                            InteractiveViewer(
                              transformationController:
                                  _transformationController,
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
                                                          ShapeType.line) {
                                                    Rect
                                                    sRect = Rect.fromPoints(
                                                      sibling.point,
                                                      sibling.secondaryPoint!,
                                                    );
                                                    if (r.overlaps(sRect)) {
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
                                                    if (r.overlaps(tRect)) {
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
                                          _selectedFrame!.point += delta;
                                          if (_selectedFrame!.secondaryPoint !=
                                              null) {
                                            _selectedFrame!.secondaryPoint =
                                                _selectedFrame!
                                                    .secondaryPoint! +
                                                delta;
                                          }
                                          for (var child in _dragChildren) {
                                            child.point += delta;
                                            if (child.secondaryPoint != null) {
                                              child.secondaryPoint =
                                                  child.secondaryPoint! + delta;
                                            }
                                          }
                                          _dragStartOffset =
                                              details.localPosition;
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
                                        _selectedFrame = null;
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
                                      ),
                                      size: const Size(3000, 3000),
                                    ),
                                  ),
                                ),
                              ),
                            ),

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

                            // Clear Canvas Button (top right of left area)
                            Positioned(
                              top: 20,
                              right: 20,
                              child: Tooltip(
                                message: 'Clear Canvas',
                                child: Material(
                                  elevation: 4,
                                  shape: const CircleBorder(),
                                  color: Colors.white,
                                  child: InkWell(
                                    customBorder: const CircleBorder(),
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
                                        clarifyQuestion =
                                            "Did you mean a specific layout?";
                                        clarifySuggestion =
                                            "I can provide additional variations if needed.";
                                      });
                                    },
                                    child: const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: Icon(
                                        Icons.clear,
                                        color: Colors.redAccent,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Bottom generator bar using precisely the new UI
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20.0),
                        child: Container(
                          height: 60,
                          width:
                              320, // Match the width generally seen in standard pill UI
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(30),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              MouseRegion(
                                onEnter: (_) =>
                                    setState(() => _isAddHovered = true),
                                onExit: (_) =>
                                    setState(() => _isAddHovered = false),
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      // Add a mobile frame sized rectangle
                                      points.add(
                                        DrawingPoint(
                                          point: const Offset(40, 40),
                                          secondaryPoint: const Offset(
                                            360,
                                            690,
                                          ),
                                          type: ShapeType.frame,
                                          paint: Paint()
                                            ..color = Colors.blueAccent
                                            ..strokeWidth = 6.0
                                            ..style = PaintingStyle.stroke,
                                        ),
                                      );
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: _isAddHovered
                                          ? Colors.blue.shade100
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      Icons.add_circle_outline,
                                      color: _isAddHovered
                                          ? Colors.blueAccent
                                          : Colors.black,
                                      size: 28,
                                    ),
                                  ),
                                ),
                              ),
                              MouseRegion(
                                onEnter: (_) =>
                                    setState(() => _isImageHovered = true),
                                onExit: (_) =>
                                    setState(() => _isImageHovered = false),
                                child: GestureDetector(
                                  onTap: _pickImage,
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: _isImageHovered
                                          ? Colors.blue.shade100
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      Icons.image,
                                      color: _isImageHovered
                                          ? Colors.blueAccent
                                          : Colors.black,
                                      size: 26,
                                    ),
                                  ),
                                ),
                              ),
                              MouseRegion(
                                onEnter: (_) =>
                                    setState(() => _isSelectHovered = true),
                                onExit: (_) =>
                                    setState(() => _isSelectHovered = false),
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      currentMode = DrawingMode.select;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color:
                                          _isSelectHovered ||
                                              currentMode == DrawingMode.select
                                          ? Colors.blue.shade100
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      Icons.pan_tool_alt,
                                      color:
                                          _isSelectHovered ||
                                              currentMode == DrawingMode.select
                                          ? Colors.blueAccent
                                          : Colors.black,
                                      size: 24,
                                    ),
                                  ),
                                ),
                              ),
                              MouseRegion(
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
                                    setState(() {
                                      if (currentMode != DrawingMode.pen) {
                                        currentMode = DrawingMode.pen;
                                      }
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: _isPencilHovered
                                          ? Colors.blue.shade100
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      Icons.edit,
                                      color: _isPencilHovered
                                          ? Colors.blueAccent
                                          : Colors.black,
                                      size: 24,
                                    ),
                                  ),
                                ),
                              ),
                              MouseRegion(
                                onEnter: (_) =>
                                    setState(() => _isGenerateHovered = true),
                                onExit: (_) =>
                                    setState(() => _isGenerateHovered = false),
                                child: GestureDetector(
                                  onTap: isGenerating ? null : _generatePreview,
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: _isGenerateHovered
                                          ? Colors.blue.shade100
                                          : Colors.transparent,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: _isGenerateHovered
                                            ? Colors.transparent
                                            : Colors.black54,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: isGenerating
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.black87,
                                            ),
                                          )
                                        : Icon(
                                            Icons.arrow_outward,
                                            color: _isGenerateHovered
                                                ? Colors.blueAccent
                                                : Colors.black87,
                                            size: 20,
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_showDrawTools)
                    Positioned(
                      bottom: 90,
                      child: MouseRegion(
                        onEnter: (_) {
                          _popupHideTimer?.cancel();
                          setState(() => _isPopupHovered = true);
                        },
                        onExit: (_) {
                          setState(() => _isPopupHovered = false);
                          _popupHideTimer = Timer(
                            const Duration(milliseconds: 300),
                            () {
                              if (mounted) setState(() {});
                            },
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.black12),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black12,
                                blurRadius: 10,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              MouseRegion(
                                hitTestBehavior: HitTestBehavior.opaque,
                                onEnter: (_) =>
                                    setState(() => _isRectHovered = true),
                                onExit: (_) =>
                                    setState(() => _isRectHovered = false),
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      currentMode = DrawingMode.rectangle;
                                      _isPopupHovered = false;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: _isRectHovered
                                          ? Colors.blue.shade100
                                          : Colors.transparent,
                                      border: Border.all(
                                        color:
                                            currentMode == DrawingMode.rectangle
                                            ? Colors.blue
                                            : Colors.transparent,
                                        width: 1.5,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Center(
                                      child: Icon(
                                        Icons.crop_square,
                                        size: 24,
                                        color:
                                            currentMode == DrawingMode.rectangle
                                            ? Colors.blue
                                            : _isRectHovered
                                            ? Colors.blueAccent
                                            : Colors.black87,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              MouseRegion(
                                hitTestBehavior: HitTestBehavior.opaque,
                                onEnter: (_) =>
                                    setState(() => _isButtonHovered = true),
                                onExit: (_) =>
                                    setState(() => _isButtonHovered = false),
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      currentMode = DrawingMode.button;
                                      _isPopupHovered = false;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: _isButtonHovered
                                          ? Colors.blue.shade100
                                          : Colors.transparent,
                                      border: Border.all(
                                        color: currentMode == DrawingMode.button
                                            ? Colors.blue
                                            : Colors.transparent,
                                        width: 1.5,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Center(
                                      child: Icon(
                                        Icons.smart_button,
                                        size: 24,
                                        color: currentMode == DrawingMode.button
                                            ? Colors.blue
                                            : _isButtonHovered
                                            ? Colors.blueAccent
                                            : Colors.black87,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              MouseRegion(
                                hitTestBehavior: HitTestBehavior.opaque,
                                onEnter: (_) {},
                                onExit: (_) {},
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      currentMode = DrawingMode.text;
                                      _isPopupHovered = false;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: currentMode == DrawingMode.text
                                          ? Colors.blue.shade100
                                          : Colors.transparent,
                                      border: Border.all(
                                        color: currentMode == DrawingMode.text
                                            ? Colors.blue
                                            : Colors.transparent,
                                        width: 1.5,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Center(
                                      child: Icon(
                                        Icons.text_fields,
                                        size: 24,
                                        color: currentMode == DrawingMode.text
                                            ? Colors.blue
                                            : Colors.black87,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
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

          // Right Side: Website Preview in a phone frame
          Expanded(
            child: Container(
              color: const Color(
                0xFF1E1E1E,
              ), // Dark background matching the right image
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(child: _buildPhoneMockup()),
                  if (_showColorPicker)
                    Positioned(
                      left: _colorPickerPosition.dx,
                      top: _colorPickerPosition.dy,
                      child: GestureDetector(
                        onPanUpdate: (details) {
                          setState(() {
                            _colorPickerPosition += details.delta;
                          });
                        },
                        child: LiveColorPicker(
                          initialColor: _currentColor,
                          onColorChanged: (newColor) {
                            setState(() {
                              _currentColor = newColor;
                            });
                            updatePreviewColor(
                              'rgba(${newColor.red}, ${newColor.green}, ${newColor.blue}, ${(newColor.alpha / 255.0).toStringAsFixed(2)})',
                            );
                          },
                          onClose: () {
                            setState(() => _showColorPicker = false);
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAIPopup() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      width: 280,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: Colors.blue.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  color: Colors.blueAccent,
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                "AI Assistant",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            clarifyQuestion.isNotEmpty
                ? clarifyQuestion
                : "Hmm, I'm not quite sure what you sketched here.",
            style: const TextStyle(
              color: Colors.black87,
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (clarifySuggestion.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lightbulb_outline,
                    color: Colors.amber.shade600,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      clarifySuggestion,
                      style: TextStyle(
                        color: Colors.grey.shade800,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _aiReplyController,
            decoration: InputDecoration(
              hintText: "Reply to clarify...",
              hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade500),
              filled: true,
              fillColor: Colors.grey.shade50,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade200),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.blueAccent),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
            ),
            style: const TextStyle(fontSize: 13),
            maxLines: 2,
            minLines: 1,
            textInputAction: TextInputAction.send,
            onSubmitted: (val) {
              setState(() {
                isClarifying = false;
                _generatePreview(userReply: val);
                _aiReplyController.clear();
              });
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => setState(() {
                      isClarifying = false;
                      _aiReplyController.clear();
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.red.shade100),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.close,
                            color: Colors.red.shade400,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            "Cancel",
                            style: TextStyle(
                              color: Colors.red.shade400,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        isClarifying = false;
                        _generatePreview(userReply: _aiReplyController.text);
                        _aiReplyController.clear();
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.blueAccent, Colors.blue.shade600],
                        ),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blueAccent.withOpacity(0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check, color: Colors.white, size: 18),
                          SizedBox(width: 6),
                          Text(
                            "Confirm",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneMockup() {
    return Container(
      width: 320,
      height: 650,
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

    window.addEventListener('message', function(e) {
      let data = e.data;
      if (typeof data === 'string') {
        try { data = JSON.parse(data); } catch(err) {}
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

    document.addEventListener('click', function(e) {
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

      window.parent.postMessage(JSON.stringify({
        type: 'OPEN_COLOR_PICKER',
        color: currentColor,
        x: e.clientX,
        y: e.clientY
      }), '*');
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
            // Default position outside the mockup boundaries, user can move it
            _colorPickerPosition = const Offset(40, 40);
            _showColorPicker = true;
          });
        },
      );
    }

    return Container(
      color: Colors.white,
      width: double.infinity,
      height: double.infinity,
      child: _cachedLivePreview!,
    );
  }
}

enum DrawingMode { select, pen, rectangle, circle, text, button }

enum ShapeType { line, rectangle, circle, text, image, button, frame }

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
  DrawingPainter({required this.pointsList});
  List<DrawingPoint> pointsList;

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

        // Draw simple frame header
        final textSpan = const TextSpan(
          text: "Mobile Frame",
          style: TextStyle(
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
      } else if (p.type == ShapeType.image &&
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
        if (p.imageId != null) {
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
  }

  @override
  bool shouldRepaint(DrawingPainter oldDelegate) => true;
}

class LiveColorPicker extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onColorChanged;
  final VoidCallback onClose;

  const LiveColorPicker({
    super.key,
    required this.initialColor,
    required this.onColorChanged,
    required this.onClose,
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Solid",
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
          const Divider(height: 1, thickness: 1),
          // Canvas
          GestureDetector(
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

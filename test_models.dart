import 'dart:convert';
import 'package:http/http.dart' as http;

void main() async {
  final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?key=AIzaSyBsjReuy47Xg2XjRYg4l42GITKuUohqNVI');
  final response = await http.get(url);
  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    final models = data['models'] as List;
    for (var m in models) {
      if (m['name'] != null && m['name'].toString().contains('gemini')) {
        print(m['name']);
      }
    }
  } else {
    print("Error: " + response.statusCode.toString() + " " + response.body);
  }
}

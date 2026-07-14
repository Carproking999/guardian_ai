import 'dart:convert';
import 'package:http/http.dart' as http;

const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

class AIService {
  final List<Map<String, String>> _history = [];

  Future<String> sendMessage(String message) async {
    if (geminiApiKey.isEmpty) {
      return "Gemini API key set nahi hai.";
    }

    _history.add({
      "role": "user",
      "text": message,
    });

    final contents = _history.map((msg) {
      return {
        "role": msg["role"] == "ai" ? "model" : "user",
        "parts": [
          {
            "text": msg["text"],
          }
        ],
      };
    }).toList();

    final url = Uri.parse(
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$geminiApiKey",
    );

    try {
      final response = await http.post(
        url,
        headers: {
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "systemInstruction": {
            "parts": [
              {
                "text":
                    "You are Guardian AI. Reply naturally like ChatGPT. "
                    "Be helpful, friendly and intelligent. "
                    "Reply in the same language as the user. "
                    "You can speak Hindi, Urdu and English."
              }
            ]
          },
          "contents": contents,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        final reply = data["candidates"][0]["content"]["parts"][0]["text"];

        _history.add({
          "role": "ai",
          "text": reply,
        });

        return reply;
      } else {
        return "Gemini error: ${response.statusCode}";
      }
    } catch (e) {
      return "Connection error: $e";
    }
  }

  void clearMemory() {
    _history.clear();
  }
}

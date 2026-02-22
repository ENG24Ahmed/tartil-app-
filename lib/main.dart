import 'package:flutter/material.dart';
import 'screens/quran_page_viewer.dart';
// إذا تريد النص بدل الصور، بدّل الاستيراد:
// import 'screens/quran_text_pages_view.dart';

void main() {
  runApp(const TartilApp());
}

class TartilApp extends StatelessWidget {
  const TartilApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ترتيل',
      home: QuranPageViewer(), // ← يفتح الصور

      // إذا تريد النص:
      // home: QuranTextPagesView(),
    );
  }
}

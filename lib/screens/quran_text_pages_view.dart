import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class QuranTextPagesView extends StatefulWidget {
  const QuranTextPagesView({super.key});

  @override
  State<QuranTextPagesView> createState() => _QuranTextPagesViewState();
}

class _QuranTextPagesViewState extends State<QuranTextPagesView> {
  static const int maxPage = 604;

  final Map<int, List<_Ayah>> _byPage = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadQuran();
  }

  Future<void> _loadQuran() async {
    try {
      final raw =
      await rootBundle.loadString('assets/data/hafs_smart_v8.json');
      final decoded = jsonDecode(raw);

      final List list = decoded is List
          ? decoded
          : (decoded['data'] as List? ??
          decoded['ayahs'] as List? ??
          const []);

      final all = list
          .map((e) => _Ayah.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      _byPage.clear();
      for (final a in all) {
        (_byPage[a.page] ??= []).add(a);
      }

      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        body: Center(child: Text(_error!)),
      );
    }

    return Scaffold(
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: PageView.builder(
          reverse: true,
          itemCount: maxPage,
          itemBuilder: (context, index) {
            final pageNo = index + 1;
            final ayahs = _byPage[pageNo] ?? [];

            return _PageText(pageNo: pageNo, ayahs: ayahs);
          },
        ),
      ),
    );
  }
}

class _PageText extends StatelessWidget {
  final int pageNo;
  final List<_Ayah> ayahs;

  const _PageText({required this.pageNo, required this.ayahs});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: RichText(
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.justify,
            text: TextSpan(
              style: const TextStyle(
                fontSize: 22,
                height: 1.9,
                color: Colors.black,
              ),
              children: [
                for (final a in ayahs) ...[
                  TextSpan(text: a.displayText),
                  TextSpan(
                    text: ' (${a.ayaNo}) ',
                    style: const TextStyle(
                      fontSize: 16,
                      color: Colors.green,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Ayah {
  final int suraNo;
  final int ayaNo;
  final int page;
  final String ayaText;
  final String ayaTextEmlaey;

  _Ayah({
    required this.suraNo,
    required this.ayaNo,
    required this.page,
    required this.ayaText,
    required this.ayaTextEmlaey,
  });

  String get displayText =>
      ayaTextEmlaey.isNotEmpty ? ayaTextEmlaey : ayaText;

  factory _Ayah.fromJson(Map<String, dynamic> j) {
    return _Ayah(
      suraNo: j['sura_no'] ?? 0,
      ayaNo: j['aya_no'] ?? 0,
      page: j['page'] ?? 0,
      ayaText: j['aya_text'] ?? '',
      ayaTextEmlaey: j['aya_text_emlaey'] ?? '',
    );
  }
}

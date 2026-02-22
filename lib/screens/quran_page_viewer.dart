import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class QuranPageViewer extends StatefulWidget {
  const QuranPageViewer({super.key});

  @override
  State<QuranPageViewer> createState() => _QuranPageViewerState();
}

class _QuranPageViewerState extends State<QuranPageViewer> {
  static const int totalPages = 604;

  /// أسماء الأجزاء/الأحزاب بالعربية (المصدر: hafs_smart_v8.json يُحدد رقم الجزء فقط)
  static const List<String> _juzNames = [
    'الأول',
    'الثاني',
    'الثالث',
    'الرابع',
    'الخامس',
    'السادس',
    'السابع',
    'الثامن',
    'التاسع',
    'العاشر',
    'الحادي عشر',
    'الثاني عشر',
    'الثالث عشر',
    'الرابع عشر',
    'الخامس عشر',
    'السادس عشر',
    'السابع عشر',
    'الثامن عشر',
    'التاسع عشر',
    'العشرون',
    'الحادي والعشرون',
    'الثاني والعشرون',
    'الثالث والعشرون',
    'الرابع والعشرون',
    'الخامس والعشرون',
    'السادس والعشرون',
    'السابع والعشرون',
    'الثامن والعشرون',
    'التاسع والعشرون',
    'الثلاثون',
  ];

  /// من hafs_smart_v8.json: صفحة → جزء، صفحة → اسم السورة، صفحة → حزب (1–60)
  Map<int, int> _pageToJuz = {};
  Map<int, String> _pageToSuraName = {};
  Map<int, int> _pageToHizb = {};

  /// أول صفحة لكل جزء (1–30) وللفهرس: قائمة السور مع أول صفحة
  Map<int, int> _juzStartPage = {};
  List<({int no, String nameAr, int startPage})> _suraList = [];

  /// عدد الآيات لكل سورة (مشتق من الحقل aya_no)
  Map<int, int> _suraAyahCount = {};

  /// قائمة الآيات للبحث (من hafs_smart_v8.json): صفحة، سورة، رقم آية، اسم السورة، نص الآية (إملائي)
  List<({int page, int suraNo, int ayaNo, String suraNameAr, String text})>
      _ayahList = [];

  /// نص الآيات بالحركات كما في المصحف من ملف quran.json (chapter:verse -> text)
  Map<String, String> _quranTextBySuraAya = {};

  /// التفسير الميسّر: مفتاح سورة:آية → نص التفسير
  Map<String, String> _tafseerMouaserBySuraAya = {};

  /// تفسير السعدي: مفتاح سورة:آية → نص التفسير
  Map<String, String> _tafseerSaadiBySuraAya = {};

  /// بيانات الأذكار: قائمة من الأذكار
  List<
      ({
        int id,
        String title,
        String? titleAr,
        String? audioUrl,
        List<
            ({
              int id,
              String arabicText,
              String? languageArabicTranslatedText,
              String? translatedText,
              int repeat,
              String? audio
            })> texts
      })> _azkarList = [];
  bool _loading = true;
  String? _error;

  late PageController _pageController;
  int _currentPageIndex = 0;
  /// عرض ورقتين على الشاشات العريضة (عرض >= 700)
  bool _useTwoPageLayout = false;
  bool _previousUseTwoPageLayout = false;
  bool _didInitialPageJump = false;
  Timer? _inactivityTimer;
  static const Duration _inactivityDuration = Duration(minutes: 30);

  static const _keyCurrentPage = 'current_page';
  static const _keyMainBookmark = 'main_bookmark_page';
  static const _keySavedBookmarks = 'saved_bookmarks_json';
  static const _keyKhatmaBookmark = 'khatma_bookmark_page';
  static const _keyKhatmaPlan = 'khatma_plan_json';
  static const _keyHighlights = 'highlights_json';

  int? _mainBookmarkPage;
  int? _khatmaBookmarkPage;
  List<({String name, int page})> _savedBookmarks = [];

  /// التأشير: وضع التأشير، اللون، الإظهار، والتأشيرات المحفوظة
  String? _highlightingMode; // null = إيقاف، 'draw' = تأشير، 'erase' = مسح
  bool _highlightsVisible = true;
  Color _highlightColor = Colors.green;
  // التأشيرات: صفحة → قائمة مسارات (قائمة نقاط, color)
  Map<int, List<({List<Offset> points, Color color})>> _highlights = {};

  // موقع لوحة التحكم للتأشير (أفقي وعمودي)
  double _highlightPanelX = 16;
  double _highlightPanelY = 120;

  // أثناء السحب: المسار الحالي قيد الإنشاء
  List<Offset>? _currentPathPoints;
  Color? _currentPathColor;

  /// وضع النص المكبَّر (بدل الصور)
  bool _isTextMode = false;

  /// خطة الختمة: جلسات مقسمة على الأيام
  List<
      ({
        int dayIndex,
        int sessionIndex,
        int globalIndex,
        int startPage,
        int endPage,
        String timeOfDay,
        bool completed,
      })> _khatmaPlan = [];

  /// أرقام السور المدنية حسب الترتيب (الباقي مكي)
  static const Set<int> _madaniSuras = {
    2,
    3,
    4,
    5,
    8,
    9,
    13,
    22,
    24,
    33,
    47,
    48,
    49,
    55,
    57,
    58,
    59,
    60,
    61,
    62,
    63,
    64,
    65,
    66,
    76,
    98,
    99,
    110,
  };

  /// تحويل الأرقام العادية إلى أرقام عربية ٠١٢٣٤٥٦٧٨٩ (للنص القرآني/وضع التكبير فقط)
  String _toArabicDigits(int value) {
    const western = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
    const eastern = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    final s = value.toString();
    final buffer = StringBuffer();
    for (final ch in s.split('')) {
      final index = western.indexOf(ch);
      buffer.write(index == -1 ? ch : eastern[index]);
    }
    return buffer.toString();
  }

  /// أرقام عادية (واجهة التطبيق عدا القرآن النصي/المكبّر)
  String _toNormalDigits(int value) => value.toString();

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _pageController.addListener(_onPageChanged);
    WakelockPlus.enable();
    _resetInactivityTimer();
    _loadFromJson();
  }

  /// بناء صفحة نص مكبَّر من بيانات hafs_smart_v8.json
  Widget _buildTextPage(int pageNumber) {
    final ayat =
        _ayahList.where((a) => a.page == pageNumber).toList(growable: false);

    if (ayat.isEmpty) {
      return Container(
        color: Colors.white,
        child: Center(
          child: Text(
            'لا يوجد نص لهذه الصفحة في الملف',
            style: _quranStyle(
                fontSize: 16,
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w500),
          ),
        ),
      );
    }

    // تجميع الآيات حسب السورة
    final Map<int, List> suraGroups = {};
    for (final a in ayat) {
      suraGroups.putIfAbsent(a.suraNo, () => []).add(a);
    }

    // ترتيب السور حسب ظهورها في الصفحة
    final sortedSuras = suraGroups.keys.toList()..sort();

    return Container(
      color: Colors.white,
      child: GestureDetector(
        onTapUp: (_) {
          // إظهار قائمة الخيارات حتى في وضع النص المكبَّر
          _showOptionsSheet(context, pageNumber - 1);
        },
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final suraNo in sortedSuras) ...[
                // عنوان السورة + البسملة فقط عند بداية السورة (أول آية من السورة في الصفحة)
                if ((suraGroups[suraNo]!.first as dynamic).ayaNo == 1) ...[
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F5E9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '۞ سورة ${(suraGroups[suraNo]!.first as dynamic).suraNameAr} ۞',
                        style: _quranStyle(
                          fontSize: 32,
                          color: const Color(0xFF1B5E20),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // البسملة (إلا سورة التوبة رقم 9)
                  if (suraNo != 9) ...[
                    Center(
                      child: Text(
                        _quranTextBySuraAya['1:1'] ??
                            'بِسْمِ ٱللَّهِ ٱلرَّحۡمَٰنِ ٱلرَّحِيمِ',
                        style: _quranStyle(
                          fontSize: 30,
                          color: const Color(0xFF2E7D32),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ],
                // نص الآيات
                RichText(
                  textDirection: TextDirection.rtl,
                  textAlign: TextAlign.center,
                  text: TextSpan(
                    style: _quranStyle(
                        fontSize: 32,
                        color: Colors.black87,
                        fontWeight: FontWeight.w500),
                    children: [
                      for (final a in suraGroups[suraNo]!) ...[
                        TextSpan(
                          text: (_quranTextBySuraAya[
                                      '${(a as dynamic).suraNo}:${a.ayaNo}'] ??
                                  a.text)
                              .trim(),
                        ),
                        const TextSpan(text: ' '),
                        TextSpan(
                          text: '${_toArabicDigits((a as dynamic).ayaNo)} ',
                          style: _quranStyle(
                              fontSize: 28,
                              color: const Color(0xFF2E7D32),
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ],
                  ),
                ),
                // مسافة بين السور (باستثناء آخر سورة)
                if (suraNo != sortedSuras.last) const SizedBox(height: 32),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pageController.removeListener(_onPageChanged);
    _inactivityTimer?.cancel();
    WakelockPlus.disable();
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged() {
    final raw = (_pageController.page ?? 0).round();
    final maxIndex = _useTwoPageLayout ? 301 : totalPages - 1;
    final p = raw.clamp(0, maxIndex);
    // في وضع ورقتين: المؤشر = رقم الانتشار، الصفحة المنطقية = 2 * p
    final logicalIndex = _useTwoPageLayout ? (p * 2) : p;
    if (logicalIndex != _currentPageIndex) {
      _currentPageIndex = logicalIndex;
      _saveCurrentPage(logicalIndex);
      setState(() {});
    }
  }

  /// تحويل رقم الصفحة (0-based) إلى index في PageView (وضع ورقة واحدة أو ورقتين)
  int _toPageViewIndex(int zeroBasedPage) {
    if (_useTwoPageLayout) return zeroBasedPage ~/ 2;
    return zeroBasedPage;
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final page = prefs.getInt(_keyCurrentPage);
    if (page != null && page >= 0 && page < totalPages) {
      _currentPageIndex = page;
      // القفز إلى الصفحة يتم في post-frame داخل build حسب وضع العرض (ورقة/ورقتين)
    }
    final main = prefs.getInt(_keyMainBookmark);
    if (main != null && main >= 1 && main <= totalPages) {
      _mainBookmarkPage = main;
    }
    final khatma = prefs.getInt(_keyKhatmaBookmark);
    if (khatma != null && khatma >= 1 && khatma <= totalPages) {
      _khatmaBookmarkPage = khatma;
    }
    final json = prefs.getString(_keySavedBookmarks);
    if (json != null) {
      try {
        final list = jsonDecode(json) as List;
        _savedBookmarks = list
            .map((e) => (
                  name: (e as Map)['name'] as String? ?? '',
                  page: (e['page'] as num?)?.toInt() ?? 1
                ))
            .where((e) => e.page >= 1 && e.page <= totalPages)
            .toList();
      } catch (_) {}
    }
    final planJson = prefs.getString(_keyKhatmaPlan);
    if (planJson != null) {
      try {
        final list = jsonDecode(planJson) as List;
        _khatmaPlan = list
            .map((e) => (
                  dayIndex: (e as Map)['dayIndex'] as int? ?? 0,
                  sessionIndex: e['sessionIndex'] as int? ?? 0,
                  globalIndex: e['globalIndex'] as int? ?? 0,
                  startPage: e['startPage'] as int? ?? 1,
                  endPage: e['endPage'] as int? ?? 1,
                  timeOfDay: e['timeOfDay'] as String? ?? '',
                  completed: e['completed'] as bool? ?? false,
                ))
            .toList();
        // تحديث الجدول بناءً على علامة الختمة المحفوظة
        if (_khatmaPlan.isNotEmpty && _khatmaBookmarkPage != null) {
          _recalculateKhatmaPlan();
        }
      } catch (_) {}
    }
    final highlightsJson = prefs.getString(_keyHighlights);
    if (highlightsJson != null) {
      try {
        final map = jsonDecode(highlightsJson) as Map;
        _highlights = {};
        for (final entry in map.entries) {
          final page = int.parse(entry.key);
          final list = (entry.value as List).map((e) {
            final pathData = e['path'] as List;
            final points = pathData
                .map((p) => Offset(
                      (p['x'] as num).toDouble(),
                      (p['y'] as num).toDouble(),
                    ))
                .toList();
            return (
              points: points,
              color: Color((e['color'] as num).toInt()),
            );
          }).toList();
          _highlights[page] = list;
        }
      } catch (_) {}
    }
    setState(() {});
  }

  Future<void> _saveCurrentPage(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyCurrentPage, index);
  }

  Future<void> _saveBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    if (_mainBookmarkPage != null) {
      await prefs.setInt(_keyMainBookmark, _mainBookmarkPage!);
    } else {
      await prefs.remove(_keyMainBookmark);
    }
    if (_khatmaBookmarkPage != null) {
      await prefs.setInt(_keyKhatmaBookmark, _khatmaBookmarkPage!);
    } else {
      await prefs.remove(_keyKhatmaBookmark);
    }
    await prefs.setString(
        _keySavedBookmarks,
        jsonEncode(_savedBookmarks
            .map((e) => {'name': e.name, 'page': e.page})
            .toList()));
    await prefs.setString(
        _keyKhatmaPlan,
        jsonEncode(_khatmaPlan
            .map((e) => {
                  'dayIndex': e.dayIndex,
                  'sessionIndex': e.sessionIndex,
                  'globalIndex': e.globalIndex,
                  'startPage': e.startPage,
                  'endPage': e.endPage,
                  'timeOfDay': e.timeOfDay,
                  'completed': e.completed,
                })
            .toList()));
    final highlightsMap = <String, List<Map<String, dynamic>>>{};
    for (final entry in _highlights.entries) {
      highlightsMap[entry.key.toString()] = entry.value
          .map((h) => {
                'path': h.points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
                'color': h.color.value,
              })
          .toList();
    }
    await prefs.setString(_keyHighlights, jsonEncode(highlightsMap));
  }

  /// حساب تقسيم الختمة: تقسيم الصفحات على الجلسات مع معالجة الكسور
  void _calculateKhatmaPlan({
    required int startPage,
    required int days,
    required int sessionsPerDay,
    required List<String> sessionTimes,
  }) {
    _khatmaPlan.clear();
    // دائماً نبدأ من الصفحة الأولى
    final actualStartPage = 1;
    final totalPagesToRead = totalPages - actualStartPage + 1;
    final totalSessions = days * sessionsPerDay;
    final pagesPerSession = totalPagesToRead / totalSessions;

    int currentPage = actualStartPage;
    int globalIndex = 0;
    bool useCeil = true; // نبدأ بـ ceil ثم نتبادل

    for (int day = 0; day < days; day++) {
      for (int session = 0; session < sessionsPerDay; session++) {
        final pagesInThisSession =
            useCeil ? pagesPerSession.ceil() : pagesPerSession.floor();
        final endPage =
            (currentPage + pagesInThisSession - 1).clamp(1, totalPages);
        final sessionStartPage = currentPage.clamp(1, totalPages);

        _khatmaPlan.add((
          dayIndex: day,
          sessionIndex: session,
          globalIndex: globalIndex++,
          startPage: sessionStartPage,
          endPage: endPage,
          timeOfDay: session < sessionTimes.length
              ? sessionTimes[session]
              : '${session + 1}',
          completed: false,
        ));

        currentPage = endPage + 1;
        if (currentPage > totalPages) break;
        useCeil = !useCeil; // التناوب بين ceil و floor
      }
      if (currentPage > totalPages) break;
    }
  }

  /// تحديث حالة الجلسات المكتملة بناءً على علامة الختمة
  void _updateCompletedSessionsFromBookmark() {
    if (_khatmaPlan.isEmpty || _khatmaBookmarkPage == null) return;

    final bookmarkPage = _khatmaBookmarkPage!;

    // تحديث جميع الجلسات التي تم إكمالها (نهاية الجلسة قبل علامة الختمة)
    for (int i = 0; i < _khatmaPlan.length; i++) {
      final session = _khatmaPlan[i];
      // إذا كانت نهاية الجلسة قبل علامة الختمة، فهي مكتملة
      if (session.endPage < bookmarkPage && !session.completed) {
        _khatmaPlan[i] = (
          dayIndex: session.dayIndex,
          sessionIndex: session.sessionIndex,
          globalIndex: session.globalIndex,
          startPage: session.startPage,
          endPage: session.endPage,
          timeOfDay: session.timeOfDay,
          completed: true,
        );
      }
      // إذا كانت الجلسة تبدأ بعد علامة الختمة، فهي غير مكتملة
      else if (session.startPage >= bookmarkPage && session.completed) {
        _khatmaPlan[i] = (
          dayIndex: session.dayIndex,
          sessionIndex: session.sessionIndex,
          globalIndex: session.globalIndex,
          startPage: session.startPage,
          endPage: session.endPage,
          timeOfDay: session.timeOfDay,
          completed: false,
        );
      }
    }
  }

  /// إعادة حساب الجدول بناءً على علامة الختمة الحالية
  void _recalculateKhatmaPlan() {
    if (_khatmaPlan.isEmpty || _khatmaBookmarkPage == null) return;

    final bookmarkPage = _khatmaBookmarkPage!;

    // تحديث حالة الجلسات المكتملة أولاً
    _updateCompletedSessionsFromBookmark();

    // الحصول على معلومات الجلسات الأصلية
    final sessionsPerDay = _khatmaPlan.where((s) => s.dayIndex == 0).length;
    if (sessionsPerDay == 0) return;

    // فصل الجلسات المكتملة عن المتبقية
    final remainingSessions = _khatmaPlan
        .where((s) => !s.completed && s.startPage >= bookmarkPage)
        .toList();

    if (remainingSessions.isEmpty) return;

    // حساب عدد الأيام المتبقية
    final remainingDays =
        remainingSessions.map((s) => s.dayIndex).toSet().length;

    if (remainingDays == 0) return;

    // حساب الصفحات المتبقية
    final totalPagesToRead = totalPages - bookmarkPage + 1;
    final totalRemainingSessions = remainingDays * sessionsPerDay;
    final pagesPerSession = totalPagesToRead / totalRemainingSessions;

    int currentPage = bookmarkPage;
    bool useCeil = true;

    // تحديث الجلسات المتبقية فقط
    for (var oldSession in remainingSessions) {
      final pagesInThisSession =
          useCeil ? pagesPerSession.ceil() : pagesPerSession.floor();
      final endPage =
          (currentPage + pagesInThisSession - 1).clamp(1, totalPages);
      final actualStartPage = currentPage.clamp(1, totalPages);

      final idx = _khatmaPlan
          .indexWhere((s) => s.globalIndex == oldSession.globalIndex);
      if (idx != -1) {
        _khatmaPlan[idx] = (
          dayIndex: oldSession.dayIndex,
          sessionIndex: oldSession.sessionIndex,
          globalIndex: oldSession.globalIndex,
          startPage: actualStartPage,
          endPage: endPage,
          timeOfDay: oldSession.timeOfDay,
          completed: false,
        );
      }

      currentPage = endPage + 1;
      if (currentPage > totalPages) break;
      useCeil = !useCeil;
    }
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    WakelockPlus.enable();
    _inactivityTimer = Timer(_inactivityDuration, () {
      WakelockPlus.disable();
    });
  }

  /// مسح التأشيرات التي تتقاطع مع المسار
  void _eraseHighlights(int page, List<Offset> erasePath) {
    if (!_highlights.containsKey(page)) return;

    final highlights = _highlights[page]!;
    final toRemove = <int>[];

    for (int i = 0; i < highlights.length; i++) {
      final highlight = highlights[i];
      // التحقق من التقاطع: إذا كان أي نقطة من المسار قريبة من أي نقطة في التأشير
      bool intersects = false;
      for (final erasePoint in erasePath) {
        for (final highlightPoint in highlight.points) {
          final distance = (erasePoint - highlightPoint).distance;
          if (distance < 30) {
            // مسافة التقاطع
            intersects = true;
            break;
          }
        }
        if (intersects) break;
      }
      if (intersects) {
        toRemove.add(i);
      }
    }

    // حذف التأشيرات المتقاطعة (من الأكبر للأصغر لتجنب مشاكل الفهارس)
    for (int i = toRemove.length - 1; i >= 0; i--) {
      highlights.removeAt(toRemove[i]);
    }

    if (highlights.isEmpty) {
      _highlights.remove(page);
    }

    _saveBookmarks();
  }

  TextStyle _quranStyle(
      {required double fontSize,
      required Color color,
      FontWeight fontWeight = FontWeight.w600}) {
    // خط قرآني من ملف محلي (يجب وضعه في assets/fonts/quran_uthmani.ttf)
    return TextStyle(
      fontFamily: 'QuranUthmani',
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
    );
  }

  /// تجاهل اختلاف الهمزة (أ إ آ ء) عند البحث — توحيدها إلى ا
  static String _normalizeForSearch(String s) {
    // إزالة الحركات (التشكيل)
    String normalized = s.replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '');
    // إزالة علامات التشكيل الأخرى
    normalized = normalized.replaceAll(RegExp(r'[\u0610-\u061A\u0640]'), '');
    // توحيد الهمزات
    normalized = normalized
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ء', 'ا')
        .replaceAll('ؤ', 'و')
        .replaceAll('ئ', 'ي')
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه');
    return normalized.toLowerCase();
  }

  Future<void> _loadFromJson() async {
    try {
      final raw = await rootBundle.loadString('assets/data/hafs_smart_v8.json');
      final list = jsonDecode(raw) as List;
      final Map<int, int> pageToJuz = {};
      final Map<int, String> pageToSuraName = {};
      for (final e in list) {
        final m = Map<String, dynamic>.from(e as Map);
        final page = (m['page'] as num?)?.toInt() ?? 0;
        final jozz = (m['jozz'] as num?)?.toInt() ?? 0;
        final suraAr = m['sura_name_ar'] as String?;
        if (page >= 1 && page <= totalPages && jozz >= 1 && jozz <= 30) {
          pageToJuz.putIfAbsent(page, () => jozz);
          if (suraAr != null && suraAr.isNotEmpty) {
            pageToSuraName.putIfAbsent(page, () => suraAr);
          }
        }
      }
      // الحزب 1–60 من الملف: كل جزء = حزبان، نوزع الصفحات حسب ترتيب الصفحة داخل الجزء
      final Map<int, List<int>> juzToPages = {};
      for (int p = 1; p <= totalPages; p++) {
        final j = pageToJuz[p] ?? 1;
        juzToPages.putIfAbsent(j, () => []).add(p);
      }
      for (final list in juzToPages.values) {
        list.sort();
      }
      final Map<int, int> pageToHizb = {};
      final Map<int, int> juzStartPage = {};
      for (int juz = 1; juz <= 30; juz++) {
        final pages = juzToPages[juz] ?? [];
        pages.sort();
        if (pages.isNotEmpty) juzStartPage[juz] = pages.first;
        final half = (pages.length / 2).ceil();
        for (int i = 0; i < pages.length; i++) {
          final hizb = (juz - 1) * 2 + (i < half ? 1 : 2);
          pageToHizb[pages[i]] = hizb.clamp(1, 60);
        }
      }
      // الفهرس: قائمة السور مع أول صفحة من الملف
      final Map<int, int> suraToMinPage = {};
      final Map<int, String> suraToNameAr = {};
      for (final e in list) {
        final m = Map<String, dynamic>.from(e as Map);
        final page = (m['page'] as num?)?.toInt() ?? 0;
        final suraNo = (m['sura_no'] as num?)?.toInt() ?? 0;
        final suraAr = m['sura_name_ar'] as String?;
        if (page >= 1 && page <= totalPages && suraNo >= 1 && suraNo <= 114) {
          if (!suraToMinPage.containsKey(suraNo) ||
              page < suraToMinPage[suraNo]!) {
            suraToMinPage[suraNo] = page;
            if (suraAr != null) suraToNameAr[suraNo] = suraAr;
          }
        }
      }
      final suraList = <({int no, String nameAr, int startPage})>[];
      for (int no = 1; no <= 114; no++) {
        final start = suraToMinPage[no];
        if (start != null)
          suraList
              .add((no: no, nameAr: suraToNameAr[no] ?? '', startPage: start));
      }
      // قائمة الآيات للبحث في النص (aya_text_emlaey)
      final ayahList = <({
        int page,
        int suraNo,
        int ayaNo,
        String suraNameAr,
        String text
      })>[];
      for (final e in list) {
        final m = Map<String, dynamic>.from(e as Map);
        final page = (m['page'] as num?)?.toInt() ?? 0;
        final suraNo = (m['sura_no'] as num?)?.toInt() ?? 0;
        final ayaNo = (m['aya_no'] as num?)?.toInt() ?? 0;
        final suraAr = m['sura_name_ar'] as String? ?? '';
        final emlaey =
            m['aya_text_emlaey'] as String? ?? m['aya_text'] as String? ?? '';
        if (page >= 1 && page <= totalPages && emlaey.isNotEmpty) {
          ayahList.add((
            page: page,
            suraNo: suraNo,
            ayaNo: ayaNo,
            suraNameAr: suraAr,
            text: emlaey
          ));
          if (suraNo > 0 && ayaNo > 0) {
            final prev = _suraAyahCount[suraNo] ?? 0;
            if (ayaNo > prev) _suraAyahCount[suraNo] = ayaNo;
          }
        }
      }
      // تحميل نص القرآن بالحركات من ملف quran.json
      final quranTextBySuraAya = <String, String>{};
      try {
        final qRaw = await rootBundle.loadString('assets/data/quran.json');
        final qJson = jsonDecode(qRaw) as Map<String, dynamic>;
        qJson.forEach((_, verses) {
          final listVerses = verses as List;
          for (final v in listVerses) {
            final vm = Map<String, dynamic>.from(v as Map);
            final chapter = (vm['chapter'] as num?)?.toInt() ?? 0;
            final verse = (vm['verse'] as num?)?.toInt() ?? 0;
            final text = vm['text'] as String? ?? '';
            if (chapter > 0 && verse > 0 && text.isNotEmpty) {
              quranTextBySuraAya['$chapter:$verse'] = text;
            }
          }
        });
      } catch (_) {
        // لو فشل تحميل ملف quran.json نستمر بدون تعطيل التطبيق
      }

      // تحميل التفسير الميسّر من ملف tafseerMouaser_v03.txt (مفصول بعلامة TAB)
      final tafseerMouaserBySuraAya = <String, String>{};
      try {
        final tRaw = await rootBundle
            .loadString('assets/tafseer/tafseerMouaser_v03.txt');
        final lines = const LineSplitter().convert(tRaw);
        if (lines.length > 1) {
          // السطر الأول ترويسة
          for (int i = 1; i < lines.length; i++) {
            final line = lines[i];
            if (line.trim().isEmpty) continue;
            final parts = line.split('\t');
            // التحقق من وجود عدد كافٍ من الأعمدة (12 عمود على الأقل)
            if (parts.length < 12) continue;
            final suraNo = int.tryParse(parts[3].trim()) ?? 0;
            final ayaNo = int.tryParse(parts[8].trim()) ?? 0;
            if (suraNo <= 0 || ayaNo <= 0) continue;
            var tafseer = parts.length > 11 ? parts[11].trim() : '';
            if (tafseer.isEmpty) continue;
            // إزالة رقم الآية داخل [] في بداية التفسير إن وجد
            if (tafseer.startsWith('[')) {
              final idx = tafseer.indexOf(']');
              if (idx != -1 && idx + 1 < tafseer.length) {
                tafseer = tafseer.substring(idx + 1).trim();
              }
            }
            // إزالة وسوم HTML البسيطة
            tafseer = tafseer.replaceAll(RegExp(r'<[^>]+>'), '');
            if (tafseer.isNotEmpty) {
              tafseerMouaserBySuraAya['$suraNo:$ayaNo'] = tafseer;
            }
          }
        }
      } catch (e) {
        // لو فشل تحميل ملف التفسير نستمر بدون تعطيل التطبيق
        debugPrint('خطأ في تحميل التفسير: $e');
      }

      // تحميل تفسير السعدي من ملف ar.saddi.json
      final tafseerSaadiBySuraAya = <String, String>{};
      try {
        final sRaw =
            await rootBundle.loadString('assets/tafseer/ar.saddi.json');
        final sJson = jsonDecode(sRaw) as Map<String, dynamic>;
        final all = (sJson['tafsir'] as List).cast<List>();
        for (int s = 0; s < all.length; s++) {
          final suraIndex = s + 1; // السور 1..114
          final suraList = all[s].cast<String>();
          for (int a = 0; a < suraList.length; a++) {
            final ayaIndex = a + 1;
            var text = suraList[a].trim();
            if (text.isEmpty) continue;
            text = text.replaceAll(RegExp(r'<[^>]+>'), '');
            if (text.isEmpty) continue;
            tafseerSaadiBySuraAya['$suraIndex:$ayaIndex'] = text;
          }
        }
      } catch (e) {
        debugPrint('خطأ في تحميل تفسير السعدي (JSON): $e');
      }

      // تحميل الأذكار من ملف husn_en.json
      final azkarList = <({
        int id,
        String title,
        String? titleAr,
        String? audioUrl,
        List<
            ({
              int id,
              String arabicText,
              String? languageArabicTranslatedText,
              String? translatedText,
              int repeat,
              String? audio
            })> texts
      })>[];
      try {
        final azkarRaw =
            await rootBundle.loadString('assets/azkar/husn_en.json');
        final azkarJson = jsonDecode(azkarRaw) as Map<String, dynamic>;

        if (azkarJson.containsKey('English')) {
          final englishList = azkarJson['English'] as List;
          for (final item in englishList) {
            final itemMap = Map<String, dynamic>.from(item as Map);
            final id = (itemMap['ID'] as num?)?.toInt() ?? 0;
            final title = itemMap['TITLE'] as String? ?? '';
            final titleAr = itemMap['TITLE_AR'] as String?;
            final audioUrl = itemMap['AUDIO_URL'] as String?;
            final textsList = itemMap['TEXT'] as List? ?? [];

            final texts = <({
              int id,
              String arabicText,
              String? languageArabicTranslatedText,
              String? translatedText,
              int repeat,
              String? audio
            })>[];

            for (final textItem in textsList) {
              final textMap = Map<String, dynamic>.from(textItem as Map);
              final textId = (textMap['ID'] as num?)?.toInt() ?? 0;
              final arabicText = textMap['ARABIC_TEXT'] as String? ?? '';
              final langArTranslated =
                  textMap['LANGUAGE_ARABIC_TRANSLATED_TEXT'] as String?;
              final translated = textMap['TRANSLATED_TEXT'] as String?;
              final repeat = (textMap['REPEAT'] as num?)?.toInt() ?? 1;
              final audio = textMap['AUDIO'] as String?;

              if (arabicText.isNotEmpty) {
                texts.add((
                  id: textId,
                  arabicText: arabicText,
                  languageArabicTranslatedText: langArTranslated,
                  translatedText: translated,
                  repeat: repeat,
                  audio: audio
                ));
              }
            }

            if (title.isNotEmpty && texts.isNotEmpty) {
              azkarList.add((
                id: id,
                title: title,
                titleAr: titleAr,
                audioUrl: audioUrl,
                texts: texts
              ));
            }
          }
        }
      } catch (e) {
        debugPrint('خطأ في تحميل الأذكار: $e');
      }

      setState(() {
        _pageToJuz = pageToJuz;
        _pageToSuraName = pageToSuraName;
        _pageToHizb = pageToHizb;
        _juzStartPage = juzStartPage;
        _suraList = suraList;
        _ayahList = ayahList;
        _quranTextBySuraAya = quranTextBySuraAya;
        _tafseerMouaserBySuraAya = tafseerMouaserBySuraAya;
        _tafseerSaadiBySuraAya = tafseerSaadiBySuraAya;
        _azkarList = azkarList;
        _loading = false;
        _error = null;
      });
      _loadPrefs();
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  String _path(int pageNumber) {
    return 'assets/pages/page_${pageNumber.toString().padLeft(3, '0')}.webp';
  }

  int _juzFromPage(int page) {
    return _pageToJuz[page] ?? 1;
  }

  String _juzTitle(int page) {
    final j = _juzFromPage(page);
    return 'الجزء: ${_juzNames[j - 1]}';
  }

  /// محاولة إيجاد تفسير لآية (مفتاح مباشر سورة:آية)
  String? _lookupTafseerForAyah(
      Map<String, String> sourceMap, int suraNo, int ayaNo) {
    final directKey = '$suraNo:$ayaNo';
    final direct = sourceMap[directKey];
    if (direct != null && direct.isNotEmpty) return direct;
    return null;
  }

  /// عرض الأذكار (قائمة مع إمكانية الرجوع من تفاصيل مجموعة دون إغلاق القائمة)
  void _showAzkarDialog(BuildContext context) {
    if (_azkarList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'لا توجد أذكار متاحة',
          style: _quranStyle(fontSize: 14, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF2E7D32),
      ));
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.9,
            child: _AzkarSheetContent(
              azkarList: _azkarList,
              toNormalDigits: _toNormalDigits,
              quranStyle: _quranStyle,
              arabicRegex: _arabicRegex,
              onClose: () => Navigator.pop(ctx),
            ),
          ),
        ),
      ),
    );
  }

  static final RegExp _arabicRegex = RegExp(r'[\u0600-\u06FF]');

  /// اختيار مصدر التفسير (الميسّر / السعدي)
  void _showTafseerSourceChooser(BuildContext context, int pageNumber) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text(
                  'اختر نوع التفسير',
                  style: _quranStyle(
                      fontSize: 18,
                      color: const Color(0xFF1B5E20),
                      fontWeight: FontWeight.bold),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.menu_book_outlined,
                    color: Color(0xFF2E7D32)),
                title: Text('التفسير الميسَّر',
                    style: _quranStyle(
                        fontSize: 16, color: const Color(0xFF1B5E20))),
                onTap: () {
                  Navigator.pop(ctx);
                  _showTafseerForPage(
                    context,
                    pageNumber,
                    sourceName: 'التفسير الميسَّر',
                    sourceMap: _tafseerMouaserBySuraAya,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.menu_book, color: Color(0xFF2E7D32)),
                title: Text('تفسير السعدي',
                    style: _quranStyle(
                        fontSize: 16, color: const Color(0xFF1B5E20))),
                onTap: () {
                  Navigator.pop(ctx);
                  _showTafseerForPage(
                    context,
                    pageNumber,
                    sourceName: 'تفسير السعدي',
                    sourceMap: _tafseerSaadiBySuraAya,
                  );
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  /// إظهار تفسير الآيات الموجودة في صفحة معيّنة من مصدر معيّن
  void _showTafseerForPage(
    BuildContext context,
    int pageNumber, {
    required String sourceName,
    required Map<String, String> sourceMap,
  }) {
    final ayat =
        _ayahList.where((a) => a.page == pageNumber).toList(growable: false);

    final items =
        <({int suraNo, int ayaNo, String suraNameAr, String tafseer})>[];
    final seenKeys = <String>{};

    for (final a in ayat) {
      final key = '${a.suraNo}:${a.ayaNo}';
      if (seenKeys.contains(key)) continue;
      final t = _lookupTafseerForAyah(sourceMap, a.suraNo, a.ayaNo);
      if (t != null && t.isNotEmpty) {
        seenKeys.add(key);
        items.add((
          suraNo: a.suraNo,
          ayaNo: a.ayaNo,
          suraNameAr: a.suraNameAr,
          tafseer: t,
        ));
      }
    }

    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'لا يوجد تفسير لهذه الصفحة في $sourceName',
          style: _quranStyle(fontSize: 14, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF2E7D32),
      ));
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.65,
            child: Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: Color(0xFF1B5E20)),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                      Expanded(
                        child: Text(
                          'تفسير $sourceName لصفحة ${_toNormalDigits(pageNumber)}',
                          style: _quranStyle(
                              fontSize: 18,
                              color: const Color(0xFF1B5E20),
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '${item.suraNameAr} – الآية ${_toNormalDigits(item.ayaNo)}',
                              style: _quranStyle(
                                  fontSize: 16,
                                  color: const Color(0xFF2E7D32),
                                  fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              item.tafseer,
                              style: _quranStyle(
                                  fontSize: 17,
                                  color: Colors.black87,
                                  fontWeight: FontWeight.w400),
                            ),
                          ],
                        ),
                      );
                    },
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 12),
                    itemCount: items.length,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _suraName(int page) {
    return _pageToSuraName[page] ?? '—';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white54),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Builder(
        builder: (context) {
          // مزامنة وضع العرض (ورقة/ورقتين) والقفز الأولي أو عند تغيّر العرض
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final w = MediaQuery.of(context).size.width;
            final useTwo = w >= 700;
            if (useTwo != _useTwoPageLayout) {
              _useTwoPageLayout = useTwo;
              setState(() {});
            }
            if (_pageController.hasClients) {
              final target = _toPageViewIndex(_currentPageIndex);
              if (!_didInitialPageJump) {
                _didInitialPageJump = true;
                _pageController.jumpToPage(target);
              } else if (useTwo != _previousUseTwoPageLayout) {
                _pageController.jumpToPage(target);
              }
            }
            _previousUseTwoPageLayout = useTwo;
          });
          final itemCount = _useTwoPageLayout ? 302 : totalPages;
          return Listener(
            onPointerDown: (_) => _resetInactivityTimer(),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: PageView.builder(
                physics: _highlightingMode != null
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                controller: _pageController,
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  final int pageLeft, pageRight;
                  if (_useTwoPageLayout) {
                    pageLeft = 2 * index + 2;
                    pageRight = 2 * index + 1;
                  } else {
                    pageLeft = index + 1;
                    pageRight = index + 1;
                  }
                  final pageNumber = _useTwoPageLayout ? (2 * index + 1) : (index + 1);

                  return Column(
                children: [
                  SafeArea(
                    bottom: false,
                    left: false,
                    right: false,
                    child: const SizedBox.shrink(),
                  ),
                  // شريط علوي: الجزء يمين، اسم السورة وسط، الحزب يسار
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          const Color(0xFFE8F5E9),
                          const Color(0xFFC8E6C9),
                          const Color(0xFFB2DFDB),
                        ],
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _juzTitle(pageNumber),
                          style: _quranStyle(
                              fontSize: 17, color: const Color(0xFF1B5E20)),
                        ),
                        Expanded(
                          child: Text(
                            _suraName(pageNumber),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _quranStyle(
                                fontSize: 17, color: const Color(0xFF1B5E20)),
                          ),
                        ),
                        RichText(
                          textDirection: TextDirection.rtl,
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: 'الحزب: ',
                                style: _quranStyle(
                                    fontSize: 17,
                                    color: const Color(0xFF2E7D32)),
                              ),
                              TextSpan(
                                text: _toNormalDigits(
                                    _pageToHizb[pageNumber] ?? 1),
                                style: TextStyle(
                                  fontSize: 17,
                                  color: const Color(0xFF2E7D32),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (pageNumber == _mainBookmarkPage)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(Icons.bookmark,
                                color: Colors.amber.shade700, size: 18),
                          )
                        else if (_savedBookmarks
                            .any((b) => b.page == pageNumber))
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(Icons.bookmark,
                                color: const Color(0xFF2E7D32), size: 18),
                          ),
                      ],
                    ),
                  ),
                  // محتوى الصفحة: ورقة واحدة أو ورقتين (شاشات عريضة)؛ صورة أو نص مكبَّر
                  Expanded(
                    child: _useTwoPageLayout && !_isTextMode
                        ? LayoutBuilder(
                            builder: (context, constraints) {
                              return GestureDetector(
                                onTapUp: (_) {
                                  if (_highlightingMode == null) {
                                    _showOptionsSheet(context, index * 2);
                                  }
                                },
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Image.asset(
                                            _path(pageRight),
                                            fit: BoxFit.fill,
                                            width: constraints.maxWidth / 2,
                                            height: constraints.maxHeight,
                                            filterQuality: FilterQuality.high,
                                            gaplessPlayback: true,
                                          ),
                                          if (_highlightsVisible &&
                                              _highlights.containsKey(pageRight))
                                            CustomPaint(
                                              size: Size(
                                                  constraints.maxWidth / 2,
                                                  constraints.maxHeight),
                                              painter: _HighlightsPainter(
                                                  _highlights[pageRight]!),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Image.asset(
                                            _path(pageLeft),
                                            fit: BoxFit.fill,
                                            width: constraints.maxWidth / 2,
                                            height: constraints.maxHeight,
                                            filterQuality: FilterQuality.high,
                                            gaplessPlayback: true,
                                          ),
                                          if (_highlightsVisible &&
                                              _highlights.containsKey(pageLeft))
                                            CustomPaint(
                                              size: Size(
                                                  constraints.maxWidth / 2,
                                                  constraints.maxHeight),
                                              painter: _HighlightsPainter(
                                                  _highlights[pageLeft]!),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          )
                        : _useTwoPageLayout && _isTextMode
                            ? Row(
                                children: [
                                  Expanded(
                                      child: _buildTextPage(pageRight)),
                                  Expanded(
                                      child: _buildTextPage(pageLeft)),
                                ],
                              )
                            : _isTextMode
                                ? _buildTextPage(pageNumber)
                                : LayoutBuilder(
                                    builder: (context, constraints) {
                                      return Stack(
                                        children: [
                                          // منطقة الرسم/التأشير
                                          GestureDetector(
                                            onTapUp: (details) {
                                              if (_highlightingMode != null) return;
                                              final w = constraints.maxWidth;
                                              final h = constraints.maxHeight;
                                              final x = details.localPosition.dx;
                                              final y = details.localPosition.dy;
                                              if (w > 0 &&
                                                  h > 0 &&
                                                  x >= w * 0.05 &&
                                                  x <= w * 0.95 &&
                                                  y >= h * 0.05 &&
                                                  y <= h * 0.95) {
                                                _showOptionsSheet(context, index);
                                              }
                                            },
                                    // نستخدم السحب العمودي للتأشير حتى تبقى حركة التقليب أفقية
                                    onVerticalDragStart: _highlightingMode !=
                                            null
                                        ? (details) {
                                            setState(() {
                                              _currentPathPoints = [
                                                details.localPosition
                                              ];
                                              _currentPathColor =
                                                  _highlightingMode == 'erase'
                                                      ? null
                                                      : _highlightColor;
                                            });
                                          }
                                        : null,
                                    onVerticalDragUpdate: _highlightingMode !=
                                            null
                                        ? (details) {
                                            setState(() {
                                              if (_currentPathPoints != null) {
                                                final newPoint =
                                                    details.localPosition;
                                                final lastPoint =
                                                    _currentPathPoints!.last;

                                                // نضيف نقطة جديدة فقط إذا ابتعدت مسافة كافية
                                                final distance =
                                                    (newPoint - lastPoint)
                                                        .distance;
                                                if (distance >= 6) {
                                                  _currentPathPoints!
                                                      .add(newPoint);
                                                }
                                              }
                                            });
                                          }
                                        : null,
                                    onVerticalDragEnd: _highlightingMode != null
                                        ? (details) {
                                            if (_currentPathPoints != null &&
                                                _currentPathPoints!.length >
                                                    1) {
                                              if (_highlightingMode ==
                                                  'erase') {
                                                // مسح التأشيرات التي تتقاطع مع المسار
                                                _eraseHighlights(pageNumber,
                                                    _currentPathPoints!);
                                              } else {
                                                // إضافة التأشير الجديد
                                                _highlights
                                                    .putIfAbsent(
                                                        pageNumber, () => [])
                                                    .add((
                                                  points: List.from(
                                                      _currentPathPoints!),
                                                  color: _currentPathColor!,
                                                ));
                                                _saveBookmarks();
                                              }
                                            }
                                            setState(() {
                                              _currentPathPoints = null;
                                              _currentPathColor = null;
                                            });
                                          }
                                        : null,
                                    child: Stack(
                                      children: [
                                        Image.asset(
                                          _path(pageNumber),
                                          width: constraints.maxWidth,
                                          height: constraints.maxHeight,
                                          fit: BoxFit.fill,
                                          filterQuality: FilterQuality.high,
                                          gaplessPlayback: true,
                                        ),
                                        // رسم التأشيرات المحفوظة
                                        if (_highlightsVisible &&
                                            _highlights.containsKey(pageNumber))
                                          CustomPaint(
                                            size: Size(constraints.maxWidth,
                                                constraints.maxHeight),
                                            painter: _HighlightsPainter(
                                                _highlights[pageNumber]!),
                                          ),
                                        // رسم التأشير الحالي قيد الإنشاء
                                        if (_currentPathPoints != null &&
                                            _currentPathPoints!.length > 1 &&
                                            _currentPathColor != null)
                                          CustomPaint(
                                            size: Size(constraints.maxWidth,
                                                constraints.maxHeight),
                                            painter: _CurrentPathPainter(
                                                _currentPathPoints!,
                                                _currentPathColor!),
                                          ),
                                      ],
                                    ),
                                  ),
                                  // لوحة التحكم فوق منطقة الرسم — لا تصل أحداثها إلى GestureDetector أعلاه
                                  if (_highlightingMode != null)
                                    Positioned(
                                      // نستخدم أبعاد ثابتة للوحة التحكم ونضمن عدم خروجها عن الشاشة
                                      left: _highlightPanelX.clamp(
                                          8.0, constraints.maxWidth - 247.0),
                                      top: _highlightPanelY.clamp(
                                          8.0, constraints.maxHeight - 72.0),
                                      child: GestureDetector(
                                        child: Container(
                                          width: 247,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 6),
                                          decoration: BoxDecoration(
                                            color:
                                                Colors.black.withOpacity(0.4),
                                            borderRadius:
                                                BorderRadius.circular(20),
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              // زر التحريك (+ مع أسهم) — السحب عليه يغيّر مكان اللوحة
                                              GestureDetector(
                                                onPanUpdate: (details) {
                                                  setState(() {
                                                    _highlightPanelX +=
                                                        details.delta.dx;
                                                    _highlightPanelY +=
                                                        details.delta.dy;
                                                  });
                                                },
                                                child: const Icon(
                                                  Icons.open_with,
                                                  color: Colors.white,
                                                  size: 20,
                                                ),
                                              ),
                                              // زر الرجوع خطوة (تراجع عن آخر تأشير في هذه الصفحة)
                                              IconButton(
                                                icon: const Icon(Icons.undo,
                                                    color: Colors.white,
                                                    size: 20),
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints(),
                                                onPressed: () {
                                                  setState(() {
                                                    final list =
                                                        _highlights[pageNumber];
                                                    if (list != null &&
                                                        list.isNotEmpty) {
                                                      list.removeLast();
                                                      if (list.isEmpty) {
                                                        _highlights
                                                            .remove(pageNumber);
                                                      }
                                                      _saveBookmarks();
                                                    }
                                                  });
                                                },
                                              ),
                                              // زر الحفظ (حفظ التأشيرات الحالية)
                                              IconButton(
                                                icon: const Icon(Icons.save,
                                                    color: Colors.white,
                                                    size: 20),
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints(),
                                                onPressed: () {
                                                  _saveBookmarks();
                                                  ScaffoldMessenger.of(context)
                                                      .showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        'تم حفظ التأشيرات',
                                                        style: _quranStyle(
                                                            fontSize: 14,
                                                            color: Colors.white,
                                                            fontWeight:
                                                                FontWeight
                                                                    .normal),
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                              // 3 ألوان للتأشير (أخضر، أصفر، أحمر/وردي)
                                              Row(
                                                children: [
                                                  GestureDetector(
                                                    onTap: () {
                                                      setState(() {
                                                        _highlightColor =
                                                            Colors.green;
                                                      });
                                                    },
                                                    child: Container(
                                                      width: 18,
                                                      height: 18,
                                                      margin: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 2),
                                                      decoration: BoxDecoration(
                                                        shape: BoxShape.circle,
                                                        color: Colors.green
                                                            .withOpacity(0.6),
                                                        border: Border.all(
                                                          color:
                                                              _highlightColor ==
                                                                      Colors
                                                                          .green
                                                                  ? Colors.white
                                                                  : Colors
                                                                      .black26,
                                                          width: 1.5,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  GestureDetector(
                                                    onTap: () {
                                                      setState(() {
                                                        _highlightColor =
                                                            Colors.yellow;
                                                      });
                                                    },
                                                    child: Container(
                                                      width: 18,
                                                      height: 18,
                                                      margin: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 2),
                                                      decoration: BoxDecoration(
                                                        shape: BoxShape.circle,
                                                        color: Colors.yellow
                                                            .withOpacity(0.6),
                                                        border: Border.all(
                                                          color:
                                                              _highlightColor ==
                                                                      Colors
                                                                          .yellow
                                                                  ? Colors.white
                                                                  : Colors
                                                                      .black26,
                                                          width: 1.5,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  GestureDetector(
                                                    onTap: () {
                                                      setState(() {
                                                        _highlightColor =
                                                            Colors.pinkAccent;
                                                      });
                                                    },
                                                    child: Container(
                                                      width: 18,
                                                      height: 18,
                                                      margin: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 2),
                                                      decoration: BoxDecoration(
                                                        shape: BoxShape.circle,
                                                        color: Colors.pinkAccent
                                                            .withOpacity(0.6),
                                                        border: Border.all(
                                                          color: _highlightColor ==
                                                                  Colors
                                                                      .pinkAccent
                                                              ? Colors.white
                                                              : Colors.black26,
                                                          width: 1.5,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              // زر إغلاق لوحة التحكم وإعادة تقليب الصفحات
                                              IconButton(
                                                icon: const Icon(Icons.close,
                                                    color: Colors.white,
                                                    size: 20),
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints(),
                                                onPressed: () {
                                                  setState(() {
                                                    _highlightingMode = null;
                                                    _currentPathPoints = null;
                                                    _currentPathColor = null;
                                                  });
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                  ),
                  // شريط سفلي صغير مخصص للصفحة
                  SafeArea(
                    top: false,
                    left: false,
                    right: false,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 2),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            const Color(0xFFB2DFDB),
                            const Color(0xFF80CBC4),
                          ],
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _useTwoPageLayout
                                ? 'صفحة: $pageNumber - ${pageNumber + 1}'
                                : 'صفحة: $pageNumber',
                            style: _quranStyle(
                                fontSize: 17,
                                color: const Color(0xFF00695C),
                                fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
        },
      ),
    );
  }

  void _showOptionsSheet(BuildContext context, int currentIndex) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: DraggableScrollableSheet(
          initialChildSize: 0.5,
          maxChildSize: 0.95,
          minChildSize: 0.3,
          expand: false,
          builder: (_, scrollController) => Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'القائمة',
                        style: _quranStyle(
                            fontSize: 20,
                            color: const Color(0xFF1B5E20),
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Color(0xFF1B5E20)),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding:
                      const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                  children: [
                    _buildMenuItem(
                      ctx,
                      context,
                      currentIndex,
                      icon: Icons.search,
                      title: 'بحث',
                      color: const Color(0xFF2E7D32),
                      onTap: () => _showSearchDialog(context, currentIndex),
                    ),
                    const SizedBox(height: 4),
                    _buildMenuItem(
                      ctx,
                      context,
                      currentIndex,
                      icon: Icons.list,
                      title: 'الفهرس',
                      color: const Color(0xFF2E7D32),
                      onTap: () => _showFihrist(context, currentIndex),
                    ),
                    const SizedBox(height: 4),
                    _buildMenuItem(
                      ctx,
                      context,
                      currentIndex,
                      icon: Icons.menu_book,
                      title: 'الأجزاء',
                      color: const Color(0xFF2E7D32),
                      onTap: () => _showAjza(context, currentIndex),
                    ),
                    const SizedBox(height: 4),
                    _buildMenuItem(
                      ctx,
                      context,
                      currentIndex,
                      icon: Icons.numbers,
                      title: 'الصفحات',
                      color: const Color(0xFF2E7D32),
                      onTap: () => _showPagesDialog(context, currentIndex),
                    ),
                    const SizedBox(height: 4),
                    _buildMenuItem(
                      ctx,
                      context,
                      currentIndex,
                      icon: Icons.bookmark_border,
                      title: 'حفظ علامة',
                      color: const Color(0xFF2E7D32),
                      onTap: () =>
                          _showSaveBookmarkSheet(context, currentIndex),
                    ),
                    const SizedBox(height: 4),
                    _buildMenuItem(
                      ctx,
                      context,
                      currentIndex,
                      icon: Icons.bookmark,
                      title: 'انتقال إلى علامة',
                      color: const Color(0xFF2E7D32),
                      onTap: () =>
                          _showGoToBookmarkSheet(context, currentIndex),
                    ),
                    const SizedBox(height: 4),
                    _buildMenuItem(
                      ctx,
                      context,
                      currentIndex,
                      icon: Icons.auto_stories,
                      title: 'أذكار وأدعية',
                      subtitle: 'عرض الأذكار والأدعية',
                      color: const Color(0xFF2E7D32),
                      onTap: () => _showAzkarDialog(context),
                    ),
                    const SizedBox(height: 4),
                    _buildMenuItem(
                      ctx,
                      context,
                      currentIndex,
                      icon: Icons.menu_book_outlined,
                      title: 'التفسير',
                      subtitle: 'اختيار نوع التفسير لهذه الصفحة',
                      color: const Color(0xFF2E7D32),
                      onTap: () =>
                          _showTafseerSourceChooser(context, currentIndex + 1),
                    ),
                    const SizedBox(height: 4),
                    _buildMenuItem(
                      ctx,
                      context,
                      currentIndex,
                      icon: Icons.flag_outlined,
                      title: 'تقسيم ختمة',
                      subtitle: 'إعداد خطة لختم المصحف',
                      color: const Color(0xFF2E7D32),
                      onTap: () =>
                          _showKhatmaSetupDialog(context, currentIndex),
                    ),
                    if (_khatmaPlan.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      _buildMenuItem(
                        ctx,
                        context,
                        currentIndex,
                        icon: Icons.calendar_today,
                        title: 'جدول الختمة',
                        subtitle: 'عرض جدول الختمة والجلسات',
                        color: const Color(0xFF2E7D32),
                        onTap: () => _showKhatmaSchedule(context),
                      ),
                    ],
                    const SizedBox(height: 4),
                    _buildMenuItem(
                      ctx,
                      context,
                      currentIndex,
                      icon: _isTextMode
                          ? Icons.text_snippet
                          : Icons.text_snippet_outlined,
                      title: _isTextMode
                          ? 'إيقاف وضع النص المكبَّر'
                          : 'وضع النص المكبَّر',
                      subtitle: _isTextMode
                          ? 'الرجوع إلى عرض الصور'
                          : 'عرض نص الصفحة بخط كبير وخلفية بيضاء',
                      color: const Color(0xFF2E7D32),
                      onTap: () {
                        setState(() {
                          _isTextMode = !_isTextMode;
                        });
                      },
                    ),
                    const SizedBox(height: 4),
                    // عنصر التأشير (محسن بنفس التنسيق)
                    _buildHighlightingMenuItem(
                      ctx,
                      context,
                      currentIndex,
                      highlightingMode: _highlightingMode,
                      highlightsVisible: _highlightsVisible,
                      highlightColor: _highlightColor,
                      onTap: () {
                        setState(() {
                          if (_highlightingMode == null) {
                            _highlightingMode = 'draw';
                          } else if (_highlightingMode == 'draw') {
                            _highlightingMode = 'erase';
                          } else {
                            _highlightingMode = null;
                          }
                        });
                        // عند تفعيل التأشير (رسم أو مسح) نغلق القائمة لتحرير المساحة للوحة التحكم
                        if (_highlightingMode != null && context.mounted) {
                          Navigator.pop(ctx);
                        }
                      },
                      onLongPress: () {
                        setState(() {
                          _highlightColor = _highlightColor == Colors.green
                              ? Colors.yellow
                              : Colors.green;
                        });
                        // القائمة تبقى مفتوحة ويُحدَّث لون التأشير فيها
                      },
                      onShowIndex: () {
                        // فتح قائمة التأشيرات فوق القائمة الحالية دون إغلاقها لتجنّب الشاشة البيضاء
                        _showHighlightsIndex(context);
                      },
                      onToggleVisibility: () {
                        setState(() {
                          _highlightsVisible = !_highlightsVisible;
                        });
                        // لا نغلق القائمة؛ إظهار/إخفاء التأشيرات يحدث فوراً والمستخدم يغلق القائمة يدوياً
                      },
                    ),
                    const SizedBox(height: 4),
                    _buildMenuItem(
                      ctx,
                      context,
                      currentIndex,
                      icon: Icons.info_outline,
                      title: 'حول التطبيق',
                      subtitle: 'معلومات عن التطبيق',
                      color: const Color(0xFF2E7D32),
                      onTap: () {
                        // فتح النافذة فوق القائمة دون إغلاقها لتجنّب الكراش/الشاشة السوداء
                        _showAboutDialog(context);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    // عرض النافذة في الإطار التالي لتجنّب فتحها أثناء بناء القائمة
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!context.mounted) return;
      String version = '1.0.0';
      try {
        final packageInfo = await PackageInfo.fromPlatform();
        if (context.mounted) version = packageInfo.version;
      } catch (_) {}
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: true,
        barrierColor: Colors.black54,
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            title: Text(
              'حول التطبيق',
              textAlign: TextAlign.center,
              style: _quranStyle(
                  fontSize: 22,
                  color: const Color(0xFF1B5E20),
                  fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: const Color(0xFFC8E6C9), width: 1),
                  ),
                  child: Text(
                    'ترتيل تطبيق مصحف إلكتروني يساعدك على تلاوة القرآن ومراجعته. يتضمّن: عرض المصحف بالصفحات، البحث في الآيات، حفظ العلامات والانتقال إليها، إعداد خطة ختمة وجدول للجلسات، عرض التفسير، والأذكار والأدعية.',
                    style: _quranStyle(
                        fontSize: 18,
                        color: const Color(0xFF1B5E20),
                        fontWeight: FontWeight.w500),
                    textAlign: TextAlign.center,
                    strutStyle: const StrutStyle(
                        height: 1.6, forceStrutHeight: true),
                  ),
                ),
                const SizedBox(height: 20),
                InkWell(
                  onTap: () async {
                    final uri =
                        Uri.parse('https://wa.me/9647721801124');
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                    }
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 10, horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat,
                            size: 24,
                            color: const Color(0xFF25D366)),
                        const SizedBox(width: 10),
                        Text(
                          'الواتساب: +9647721801124',
                          style: _quranStyle(
                              fontSize: 17,
                              color: const Color(0xFF2E7D32),
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Divider(height: 1, color: Color(0xFFC8E6C9)),
                const SizedBox(height: 14),
                Center(
                  child: Column(
                    children: [
                      Text(
                        'المطور: المهندس أحمد خليل',
                        style: _quranStyle(
                            fontSize: 16,
                            color: const Color(0xFF1B5E20),
                            fontWeight: FontWeight.w600),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'الإصدار: $version',
                        style: _quranStyle(
                            fontSize: 15,
                            color: Colors.grey.shade700,
                            fontWeight: FontWeight.w500),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(ctx, rootNavigator: true).pop(),
                child: Text('إغلاق',
                    style: _quranStyle(
                        fontSize: 17,
                        color: const Color(0xFF2E7D32),
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildMenuItem(
    BuildContext ctx,
    BuildContext context,
    int currentIndex, {
    required IconData icon,
    required String title,
    String? subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: _quranStyle(
                        fontSize: 18,
                        color: const Color(0xFF1B5E20),
                        fontWeight: FontWeight.w600),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: _quranStyle(
                          fontSize: 13,
                          color: Colors.grey.shade700,
                          fontWeight: FontWeight.normal),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios,
                size: 16, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  Widget _buildHighlightingMenuItem(
    BuildContext ctx,
    BuildContext context,
    int currentIndex, {
    required String? highlightingMode,
    required bool highlightsVisible,
    required Color highlightColor,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
    required VoidCallback onShowIndex,
    required VoidCallback onToggleVisibility,
  }) {
    final icon = highlightingMode == null
        ? Icons.edit_outlined
        : highlightingMode == 'draw'
            ? Icons.edit
            : Icons.auto_fix_high;
    final iconColor = highlightingMode == null
        ? const Color(0xFF2E7D32)
        : highlightingMode == 'draw'
            ? Colors.green
            : Colors.red;
    final title = highlightingMode == null
        ? 'التأشير'
        : highlightingMode == 'draw'
            ? 'التأشير (مفعل - تأشير)'
            : 'التأشير (مفعل - مسح)';
    final subtitle = highlightingMode == null
        ? 'اضغط للتفعيل: السحب للتأشير أو المسح'
        : highlightingMode == 'draw'
            ? 'السحب للتأشير باللون ${highlightColor == Colors.green ? "الأخضر" : "الأصفر"}'
            : 'السحب لمسح التأشيرات';
    final titleColor = highlightingMode == null
        ? const Color(0xFF1B5E20)
        : highlightingMode == 'draw'
            ? Colors.green.shade700
            : Colors.red.shade700;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: _quranStyle(
                        fontSize: 18,
                        color: titleColor,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: _quranStyle(
                        fontSize: 13,
                        color: Colors.grey.shade700,
                        fontWeight: FontWeight.normal),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.folder_open, size: 20),
                  color: const Color(0xFF2E7D32),
                  onPressed: () {
                    Navigator.pop(ctx);
                    onShowIndex();
                  },
                  tooltip: 'صفحات فيها تأشير',
                ),
                IconButton(
                  icon: Icon(
                    highlightsVisible ? Icons.visibility : Icons.visibility_off,
                    size: 20,
                  ),
                  color:
                      highlightsVisible ? const Color(0xFF2E7D32) : Colors.grey,
                  onPressed: () {
                    Navigator.pop(ctx);
                    onToggleVisibility();
                  },
                  tooltip:
                      highlightsVisible ? 'إخفاء التأشيرات' : 'إظهار التأشيرات',
                ),
                Icon(Icons.arrow_forward_ios,
                    size: 16, color: Colors.grey.shade400),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// قائمة بجميع الصفحات التي تحتوي على تأشيرات
  void _showHighlightsIndex(BuildContext context) {
    // جمع الصفحات التي فيها تأشيرات
    final entries = _highlights.entries
        .where((e) => e.value.isNotEmpty)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'لا توجد تأشيرات محفوظة حالياً',
            style: _quranStyle(
                fontSize: 14,
                color: Colors.white,
                fontWeight: FontWeight.normal),
          ),
        ),
      );
      return;
    }

    final textStyle = _quranStyle(fontSize: 16, color: const Color(0xFF1B5E20));
    final subStyle = _quranStyle(
        fontSize: 12, color: Colors.grey, fontWeight: FontWeight.normal);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.6,
            child: Column(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: Color(0xFF1B5E20)),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                      Expanded(
                        child: Text('صفحات فيها تأشير',
                            style: _quranStyle(
                                fontSize: 18,
                                color: const Color(0xFF1B5E20),
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(
                        vertical: 16, horizontal: 12),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final entry = entries[i];
                      final page = entry.key;
                      final count = entry.value.length;
                      final suraName = _suraName(page);

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF2E7D32),
                          child: Text(
                            '$page',
                            style: _quranStyle(
                                fontSize: 12,
                                color: Colors.white,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                        title: Text(
                          suraName,
                          style: textStyle,
                        ),
                        subtitle: Text(
                          'ص $page — $count تأشير',
                          style: subStyle,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          onPressed: () {
                            showDialog(
                              context: ctx,
                              builder: (dialogCtx) => Directionality(
                                textDirection: TextDirection.rtl,
                                child: AlertDialog(
                                  title: Text('حذف التأشيرات',
                                      style: _quranStyle(
                                          fontSize: 18,
                                          color: const Color(0xFF1B5E20))),
                                  content: Text(
                                      'هل تريد حذف جميع التأشيرات في الصفحة $page؟',
                                      style: _quranStyle(
                                          fontSize: 14,
                                          color: Colors.black87,
                                          fontWeight: FontWeight.normal)),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(dialogCtx),
                                      child: Text('إلغاء',
                                          style: _quranStyle(
                                              fontSize: 14,
                                              color: Colors.grey)),
                                    ),
                                    FilledButton(
                                      style: FilledButton.styleFrom(
                                          backgroundColor: Colors.red),
                                      onPressed: () {
                                        setState(() {
                                          _highlights.remove(page);
                                        });
                                        _saveBookmarks();
                                        Navigator.pop(dialogCtx);
                                        // إغلاق قائمة الفهرس في الإطار التالي + إعادة رسم لتجنّب الشاشة السوداء
                                        WidgetsBinding.instance.addPostFrameCallback((_) {
                                          if (!mounted) return;
                                          Navigator.pop(ctx);
                                          setState(() {});
                                        });
                                      },
                                      child: Text('حذف',
                                          style: _quranStyle(
                                              fontSize: 14,
                                              color: Colors.white)),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _pageController.animateToPage(_toPageViewIndex(page - 1),
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeInOut);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showSaveBookmarkSheet(BuildContext context, int currentIndex) {
    final currentPage = currentIndex + 1;
    final textStyle = _quranStyle(fontSize: 16, color: const Color(0xFF1B5E20));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.5,
            child: Column(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: Color(0xFF1B5E20)),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                      Expanded(
                        child: Text('حفظ العلامة',
                            style: _quranStyle(
                                fontSize: 18,
                                color: const Color(0xFF1B5E20),
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                        vertical: 16, horizontal: 12),
                    children: [
                      const SizedBox(height: 8),
                      ListTile(
                        trailing: Icon(
                          Icons.bookmark,
                          color: _mainBookmarkPage == currentPage
                              ? Colors.amber.shade700
                              : const Color(0xFF2E7D32),
                        ),
                        title: Text('العلامة الرئيسية', style: textStyle),
                        subtitle: Text(
                          _mainBookmarkPage != null
                              ? 'ص $_mainBookmarkPage'
                              : 'غير معينة — اضغط لتعيين الصفحة الحالية',
                          style: _quranStyle(
                              fontSize: 12,
                              color: Colors.grey,
                              fontWeight: FontWeight.normal),
                        ),
                        onTap: () {
                          setState(() => _mainBookmarkPage = currentPage);
                          _saveBookmarks();
                          Navigator.pop(ctx);
                        },
                      ),
                      ListTile(
                        trailing: Icon(
                          Icons.bookmark,
                          color: _khatmaBookmarkPage == currentPage
                              ? const Color(0xFF1565C0)
                              : const Color(0xFF1E88E5),
                        ),
                        title: Text('علامة الختمة', style: textStyle),
                        subtitle: Text(
                          _khatmaBookmarkPage != null
                              ? 'ص $_khatmaBookmarkPage'
                              : 'غير معينة — اضغط لتعيين الصفحة الحالية للختمة',
                          style: _quranStyle(
                              fontSize: 12,
                              color: Colors.grey,
                              fontWeight: FontWeight.normal),
                        ),
                        onTap: () {
                          setState(() {
                            _khatmaBookmarkPage = currentPage;
                            // تحديث الجدول بناءً على علامة الختمة الجديدة
                            if (_khatmaPlan.isNotEmpty) {
                              _recalculateKhatmaPlan();
                            }
                          });
                          _saveBookmarks();
                          Navigator.pop(ctx);
                        },
                      ),
                      const Divider(),
                      Text('العلامات المحفوظة',
                          style: _quranStyle(
                              fontSize: 14,
                              color: const Color(0xFF2E7D32),
                              fontWeight: FontWeight.w600)),
                      ..._savedBookmarks.map(
                        (b) => ListTile(
                          title:
                              Text('${b.name} — ص ${b.page}', style: textStyle),
                          onTap: () {
                            Navigator.pop(ctx);
                            _pageController.animateToPage(_toPageViewIndex(b.page - 1),
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut);
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      ListTile(
                        trailing: const Icon(Icons.add_circle_outline,
                            color: Color(0xFF2E7D32)),
                        title: Text('إضافة علامة جديدة', style: textStyle),
                        subtitle: Text(
                          'حفظ الصفحة الحالية (ص $currentPage) باسم',
                          style: _quranStyle(
                              fontSize: 12,
                              color: Colors.grey,
                              fontWeight: FontWeight.normal),
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showAddBookmarkDialog(context, currentPage);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showKhatmaSchedule(BuildContext context) {
    if (_khatmaPlan.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'لا توجد خطة ختمة محفوظة',
            style: _quranStyle(
                fontSize: 14,
                color: Colors.white,
                fontWeight: FontWeight.normal),
          ),
        ),
      );
      return;
    }

    // تجميع الجلسات حسب اليوم
    final daysMap = <int,
        List<
            ({
              int dayIndex,
              int sessionIndex,
              int globalIndex,
              int startPage,
              int endPage,
              String timeOfDay,
              bool completed,
            })>>{};
    for (var session in _khatmaPlan) {
      daysMap.putIfAbsent(session.dayIndex, () => []).add(session);
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.85,
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back,
                          color: Color(0xFF1B5E20)),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                    Expanded(
                      child: Text('جدول الختمة',
                          style: _quranStyle(
                              fontSize: 18,
                              color: const Color(0xFF1B5E20),
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF2E7D32),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'جدول الختمة',
                      style: _quranStyle(
                          fontSize: 20,
                          color: Colors.white,
                          fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: daysMap.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, dayIdx) {
                    final day = daysMap.keys.toList()..sort();
                    final dayNumber = day[dayIdx];
                    final sessions = daysMap[dayNumber]!
                      ..sort(
                          (a, b) => a.sessionIndex.compareTo(b.sessionIndex));
                    final isAnyCompleted = sessions.any((s) => s.completed);
                    final allCompleted = sessions.every((s) => s.completed);

                    return ExpansionTile(
                      initiallyExpanded: dayIdx == 0,
                      backgroundColor: allCompleted
                          ? const Color(0xFFC8E6C9)
                          : isAnyCompleted
                              ? const Color(0xFFE8F5E9)
                              : Colors.white,
                      collapsedBackgroundColor: allCompleted
                          ? const Color(0xFFC8E6C9)
                          : isAnyCompleted
                              ? const Color(0xFFE8F5E9)
                              : Colors.white,
                      title: Row(
                        children: [
                          Text(
                            'اليوم ${dayNumber + 1}',
                            style: _quranStyle(
                                fontSize: 18,
                                color: const Color(0xFF1B5E20),
                                fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 8),
                          if (allCompleted)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2E7D32),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'مكتمل',
                                style: _quranStyle(
                                    fontSize: 12,
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                        ],
                      ),
                      children: sessions.map((session) {
                        return ListTile(
                          dense: true,
                          leading: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: session.completed
                                  ? const Color(0xFF2E7D32)
                                  : Colors.grey.shade300,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: session.completed
                                  ? const Icon(Icons.check,
                                      color: Colors.white, size: 20)
                                  : Text(
                                      '${session.sessionIndex + 1}',
                                      style: _quranStyle(
                                          fontSize: 14,
                                          color: Colors.black87,
                                          fontWeight: FontWeight.bold),
                                    ),
                            ),
                          ),
                          title: Text(
                            session.timeOfDay,
                            style: _quranStyle(
                                fontSize: 16,
                                color: const Color(0xFF1B5E20),
                                fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            'صفحات ${session.startPage} - ${session.endPage} '
                            '(${session.endPage - session.startPage + 1} صفحة)',
                            style: _quranStyle(
                                fontSize: 13,
                                color: Colors.grey.shade700,
                                fontWeight: FontWeight.normal),
                          ),
                          trailing: session.completed
                              ? Icon(Icons.check_circle,
                                  color: const Color(0xFF2E7D32))
                              : IconButton(
                                  icon: const Icon(Icons.radio_button_unchecked,
                                      color: Colors.grey),
                                  onPressed: () {
                                    // تحديث حالة الجلسة كمكتملة
                                    setState(() {
                                      final idx = _khatmaPlan.indexWhere((s) =>
                                          s.globalIndex == session.globalIndex);
                                      if (idx != -1) {
                                        _khatmaPlan[idx] = (
                                          dayIndex: session.dayIndex,
                                          sessionIndex: session.sessionIndex,
                                          globalIndex: session.globalIndex,
                                          startPage: session.startPage,
                                          endPage: session.endPage,
                                          timeOfDay: session.timeOfDay,
                                          completed: true,
                                        );
                                        // تحديث علامة الختمة إلى نهاية هذه الجلسة
                                        _khatmaBookmarkPage =
                                            session.endPage + 1;
                                        if (_khatmaBookmarkPage! > totalPages) {
                                          _khatmaBookmarkPage = totalPages;
                                        }
                                        _saveBookmarks();
                                        // إعادة حساب الجدول
                                        _recalculateKhatmaPlan();
                                        _saveBookmarks();
                                      }
                                    });
                                    Navigator.pop(ctx);
                                    _showKhatmaSchedule(context);
                                  },
                                ),
                          onTap: () {
                            // الانتقال إلى صفحة بداية الجلسة
                            Navigator.pop(ctx);
                            _pageController.animateToPage(_toPageViewIndex(session.startPage - 1),
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut);
                          },
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAddBookmarkDialog(BuildContext context, int currentPage) {
    final nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('إضافة علامة جديدة',
              style: _quranStyle(fontSize: 18, color: const Color(0xFF1B5E20))),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(
              hintText: 'اسم العلامة (مثلاً: آخر قراءة)',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('إلغاء',
                  style: _quranStyle(fontSize: 14, color: Colors.grey)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32)),
              onPressed: () {
                final name = nameController.text.trim().isEmpty
                    ? 'علامة ص $currentPage'
                    : nameController.text.trim();
                setState(() {
                  _savedBookmarks = [
                    ..._savedBookmarks,
                    (name: name, page: currentPage)
                  ];
                });
                _saveBookmarks();
                Navigator.pop(ctx);
              },
              child: Text('حفظ',
                  style: _quranStyle(fontSize: 14, color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  void _showKhatmaSetupDialog(BuildContext context, int currentIndex) {
    final currentPage = currentIndex + 1;
    final daysController = TextEditingController(text: '30');
    final sessionsController = TextEditingController(text: '1');
    final sessionTimeControllers = <TextEditingController>[
      TextEditingController(text: 'الفجر'),
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            titlePadding: EdgeInsets.zero,
            title: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Row(
                children: [
                  IconButton(
                    icon:
                        const Icon(Icons.arrow_back, color: Color(0xFF1B5E20)),
                    onPressed: () => Navigator.pop(dialogContext),
                  ),
                  Expanded(
                    child: Text('تقسيم ختمة',
                        style: _quranStyle(
                            fontSize: 18, color: const Color(0xFF1B5E20))),
                  ),
                ],
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'سيتم تقسيم الختمة من الصفحة الأولى دائماً. حدد عدد الأيام وعدد القراءات في اليوم. '
                    'سيتم استخدام علامة الختمة لتتبع آخر صفحة وصلت إليها.',
                    style: _quranStyle(
                        fontSize: 12,
                        color: Colors.grey.shade800,
                        fontWeight: FontWeight.normal),
                  ),
                  const SizedBox(height: 12),
                  Text('عدد الأيام للختمة',
                      style: _quranStyle(
                          fontSize: 14,
                          color: const Color(0xFF1B5E20),
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: daysController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Text('عدد القراءات في اليوم',
                      style: _quranStyle(
                          fontSize: 14,
                          color: const Color(0xFF1B5E20),
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: sessionsController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      final count = int.tryParse(value) ?? 1;
                      while (sessionTimeControllers.length < count) {
                        sessionTimeControllers.add(TextEditingController(
                            text:
                                'القراءة ${sessionTimeControllers.length + 1}'));
                      }
                      while (sessionTimeControllers.length > count) {
                        sessionTimeControllers.removeLast().dispose();
                      }
                      setDialogState(() {});
                    },
                  ),
                  if (int.tryParse(sessionsController.text) != null &&
                      int.parse(sessionsController.text) > 0) ...[
                    const SizedBox(height: 12),
                    Text('أوقات القراءات',
                        style: _quranStyle(
                            fontSize: 14,
                            color: const Color(0xFF1B5E20),
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    ...List.generate(
                      int.tryParse(sessionsController.text) ?? 1,
                      (i) {
                        if (i >= sessionTimeControllers.length) {
                          sessionTimeControllers.add(
                              TextEditingController(text: 'القراءة ${i + 1}'));
                        }
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: TextField(
                            controller: sessionTimeControllers[i],
                            decoration: InputDecoration(
                              labelText: 'وقت القراءة ${i + 1}',
                              border: const OutlineInputBorder(),
                              hintText: 'مثال: الفجر، الظهر، العصر...',
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  for (var c in sessionTimeControllers) {
                    c.dispose();
                  }
                  Navigator.pop(ctx);
                },
                child: Text('إلغاء',
                    style: _quranStyle(fontSize: 14, color: Colors.grey)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32)),
                onPressed: () {
                  final days = int.tryParse(daysController.text);
                  final sessions = int.tryParse(sessionsController.text);
                  if (days == null ||
                      days < 1 ||
                      sessions == null ||
                      sessions < 1) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'يرجى إدخال أرقام صحيحة',
                          style: _quranStyle(
                              fontSize: 14,
                              color: Colors.white,
                              fontWeight: FontWeight.normal),
                        ),
                      ),
                    );
                    return;
                  }

                  final sessionTimes = sessionTimeControllers
                      .map((c) => c.text.trim().isEmpty
                          ? 'القراءة ${sessionTimeControllers.indexOf(c) + 1}'
                          : c.text.trim())
                      .toList();

                  // حساب خطة الختمة (دائماً من الصفحة الأولى)
                  _calculateKhatmaPlan(
                    startPage: 1,
                    days: days,
                    sessionsPerDay: sessions,
                    sessionTimes: sessionTimes,
                  );

                  // تعيين علامة الختمة
                  setState(() => _khatmaBookmarkPage = currentPage);
                  _saveBookmarks();

                  for (var c in sessionTimeControllers) {
                    c.dispose();
                  }
                  Navigator.pop(ctx);

                  // عرض جدول الختمة
                  _showKhatmaSchedule(context);
                },
                child: Text('حفظ وإنشاء الجدول',
                    style: _quranStyle(fontSize: 14, color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showGoToBookmarkSheet(BuildContext context, int currentIndex) {
    final textStyle = _quranStyle(fontSize: 16, color: const Color(0xFF1B5E20));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (modalCtx, setModalState) => SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.6,
              child: Column(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: Color(0xFF1B5E20)),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                        Expanded(
                          child: Text('انتقال إلى علامة',
                              style: _quranStyle(
                                  fontSize: 18,
                                  color: const Color(0xFF1B5E20),
                                  fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 12),
                      children: [
                        const SizedBox(height: 12),
                        if (_mainBookmarkPage != null)
                          ListTile(
                            trailing: Icon(Icons.bookmark,
                                color: Colors.amber.shade700, size: 22),
                            title: Text(
                                'العلامة الرئيسية — ص $_mainBookmarkPage',
                                style: textStyle),
                            onTap: () {
                              Navigator.pop(ctx);
                              _pageController.animateToPage(
                                  _toPageViewIndex(_mainBookmarkPage! - 1),
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeInOut);
                            },
                          ),
                        if (_khatmaBookmarkPage != null)
                          ListTile(
                            trailing: const Icon(Icons.bookmark,
                                color: Color(0xFF1565C0), size: 22),
                            title: Text('علامة الختمة — ص $_khatmaBookmarkPage',
                                style: textStyle),
                            onTap: () {
                              Navigator.pop(ctx);
                              _pageController.animateToPage(
                                  _toPageViewIndex(_khatmaBookmarkPage! - 1),
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeInOut);
                            },
                          ),
                        ..._savedBookmarks.asMap().entries.map((entry) {
                          final index = entry.key;
                          final b = entry.value;
                          return ListTile(
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.red, size: 22),
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (dialogContext) => Directionality(
                                    textDirection: TextDirection.rtl,
                                    child: AlertDialog(
                                      title: Text('تأكيد الحذف',
                                          style: _quranStyle(
                                              fontSize: 18,
                                              color: const Color(0xFF1B5E20))),
                                      content: Text(
                                          'هل متأكد من حذف علامة (${b.name})؟',
                                          style: _quranStyle(
                                              fontSize: 14,
                                              color: Colors.black87,
                                              fontWeight: FontWeight.normal)),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(
                                              dialogContext, false),
                                          child: Text('إلغاء',
                                              style: _quranStyle(
                                                  fontSize: 14,
                                                  color: Colors.grey)),
                                        ),
                                        FilledButton(
                                          style: FilledButton.styleFrom(
                                              backgroundColor:
                                                  const Color(0xFF2E7D32)),
                                          onPressed: () => Navigator.pop(
                                              dialogContext, true),
                                          child: Text('نعم',
                                              style: _quranStyle(
                                                  fontSize: 14,
                                                  color: Colors.white)),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                                if (confirm == true && mounted) {
                                  setState(() {
                                    final updated =
                                        List<({String name, int page})>.from(
                                            _savedBookmarks);
                                    if (index >= 0 && index < updated.length) {
                                      updated.removeAt(index);
                                    }
                                    _savedBookmarks = updated;
                                  });
                                  setModalState(() {});
                                  _saveBookmarks();
                                }
                              },
                            ),
                            title: Text('${b.name} — ص ${b.page}',
                                style: textStyle),
                            onTap: () {
                              Navigator.pop(ctx);
                              _pageController.animateToPage(_toPageViewIndex(b.page - 1),
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeInOut);
                            },
                          );
                        }),
                        if (_mainBookmarkPage == null &&
                            _savedBookmarks.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'لا توجد علامات محفوظة. استخدم "حفظ علامة" أولاً.',
                              style: _quranStyle(
                                  fontSize: 14,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.normal),
                              textAlign: TextAlign.center,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showSearchDialog(BuildContext context, int currentIndex) {
    final queryController = TextEditingController();
    final results = ValueNotifier<
        List<
            ({
              int page,
              int suraNo,
              int ayaNo,
              String suraNameAr,
              String text
            })>>([]);

    void runSearch(String q) {
      final t = q.trim();
      if (t.isEmpty) {
        results.value = [];
        return;
      }
      final normalizedQuery = _normalizeForSearch(t);
      results.value = _ayahList
          .where((a) => _normalizeForSearch(a.text).contains(normalizedQuery))
          .take(200)
          .toList();
    }

    showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          contentPadding: EdgeInsets.zero,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
          titlePadding: EdgeInsets.zero,
          title: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Color(0xFF1B5E20)),
                  onPressed: () => Navigator.pop(ctx),
                ),
                Expanded(
                  child: Text('بحث في الآيات',
                      style: _quranStyle(
                          fontSize: 20, color: const Color(0xFF1B5E20))),
                ),
              ],
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(context).size.height * 0.8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TextField(
                    controller: queryController,
                    style: _quranStyle(
                        fontSize: 18,
                        color: Colors.black87,
                        fontWeight: FontWeight.normal),
                    decoration: InputDecoration(
                      hintText: 'اكتب جزءاً من الآية...',
                      hintStyle: _quranStyle(
                          fontSize: 16,
                          color: Colors.grey,
                          fontWeight: FontWeight.normal),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                    ),
                    onChanged: runSearch,
                    autofocus: true,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ValueListenableBuilder<
                      List<
                          ({
                            int page,
                            int suraNo,
                            int ayaNo,
                            String suraNameAr,
                            String text
                          })>>(
                    valueListenable: results,
                    builder: (_, list, __) {
                      if (list.isEmpty && queryController.text.trim().isEmpty) {
                        return Center(
                          child: Text('اكتب نص الآية للبحث في الملف',
                              style: _quranStyle(
                                  fontSize: 16,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.normal)),
                        );
                      }
                      if (list.isEmpty) {
                        return Center(
                          child: Text('لا توجد نتائج',
                              style: _quranStyle(
                                  fontSize: 16,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.normal)),
                        );
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final a = list[i];
                          final snippet = a.text.length > 80
                              ? '${a.text.substring(0, 80)}...'
                              : a.text;
                          return ListTile(
                            dense: false,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 6),
                            title: Text(snippet,
                                style: _quranStyle(
                                    fontSize: 18,
                                    color: const Color(0xFF1B5E20),
                                    fontWeight: FontWeight.normal)),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                  '${a.suraNameAr} — آية ${a.ayaNo} — ص ${a.page}',
                                  style: _quranStyle(
                                      fontSize: 15,
                                      color: const Color(0xFF2E7D32),
                                      fontWeight: FontWeight.w600)),
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              _pageController.animateToPage(_toPageViewIndex(a.page - 1),
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeInOut);
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('إغلاق',
                  style: _quranStyle(fontSize: 14, color: Colors.grey)),
            ),
          ],
        ),
      ),
    );
  }

  void _showFihrist(BuildContext context, int currentIndex) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.3,
          expand: false,
          builder: (_, scrollController) => Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back,
                          color: Color(0xFF1B5E20)),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                    Expanded(
                      child: Text('الفهرس',
                          style: _quranStyle(
                              fontSize: 20, color: const Color(0xFF1B5E20))),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  itemCount: _suraList.length,
                  separatorBuilder: (_, __) => const Divider(
                    height: 0.5,
                    color: Color(0xFFBDBDBD),
                  ),
                  itemBuilder: (_, i) {
                    final s = _suraList[i];
                    final pageIndex = s.startPage - 1;
                    final suraNo = s.no;
                    final ayatCount = _suraAyahCount[suraNo] ?? 0;
                    final isMadani = _madaniSuras.contains(suraNo);
                    return InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        _pageController.animateToPage(_toPageViewIndex(pageIndex),
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 32,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  '$suraNo',
                                  style: _quranStyle(
                                      fontSize: 16,
                                      color: const Color(0xFF00695C),
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                s.nameAr,
                                style: _quranStyle(
                                    fontSize: 18,
                                    color: const Color(0xFF1B5E20),
                                    fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 80,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  'آيَاتُها $ayatCount',
                                  style: _quranStyle(
                                      fontSize: 14,
                                      color: Colors.grey.shade800,
                                      fontWeight: FontWeight.w500),
                                ),
                              ),
                            ),
                            const SizedBox(width: 2),
                            SizedBox(
                              width: 70,
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isMadani
                                        ? const Color.fromARGB(255, 50, 168, 56)
                                        : const Color.fromARGB(
                                            255, 23, 112, 153),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    isMadani ? 'مدنية' : 'مكية',
                                    style: _quranStyle(
                                        fontSize: 13,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 56,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  'ص ${s.startPage}',
                                  style: _quranStyle(
                                      fontSize: 15,
                                      color: const Color(0xFF2E7D32),
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAjza(BuildContext context, int currentIndex) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFE8F5E9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.3,
          expand: false,
          builder: (_, scrollController) => Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back,
                          color: Color(0xFF1B5E20)),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                    Expanded(
                      child: Text('الأجزاء',
                          style: _quranStyle(
                              fontSize: 20, color: const Color(0xFF1B5E20))),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  itemCount: 30,
                  separatorBuilder: (_, __) => const Divider(
                    height: 0.5,
                    color: Color(0xFFBDBDBD),
                  ),
                  itemBuilder: (_, i) {
                    final juz = i + 1;
                    final startPage = _juzStartPage[juz] ?? 1;
                    final pageIndex = startPage - 1;
                    return InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        _pageController.animateToPage(_toPageViewIndex(pageIndex),
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 60,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  _toNormalDigits(juz),
                                  style: TextStyle(
                                    fontSize: 18,
                                    color: const Color(0xFF00695C),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text('الجزء ${_juzNames[i]}',
                                  style: _quranStyle(
                                      fontSize: 18,
                                      color: const Color(0xFF1B5E20),
                                      fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 10),
                            Text('ص ${_toNormalDigits(startPage)}',
                                style: TextStyle(
                                    fontSize: 15,
                                    color: const Color(0xFF2E7D32),
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPagesDialog(BuildContext context, int currentIndex) {
    final controller = TextEditingController(text: '${currentIndex + 1}');
    showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          titlePadding: EdgeInsets.zero,
          title: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Color(0xFF1B5E20)),
                  onPressed: () => Navigator.pop(ctx),
                ),
                Expanded(
                  child: Text('انتقال إلى صفحة',
                      style: _quranStyle(
                          fontSize: 18, color: const Color(0xFF1B5E20))),
                ),
              ],
            ),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              hintText: 'رقم الصفحة (1–604)',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('إلغاء',
                  style: _quranStyle(fontSize: 14, color: Colors.grey)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32)),
              onPressed: () {
                final n = int.tryParse(controller.text);
                if (n != null && n >= 1 && n <= totalPages) {
                  Navigator.pop(ctx);
                  _pageController.animateToPage(_toPageViewIndex(n - 1),
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut);
                }
              },
              child: Text('انتقال',
                  style: _quranStyle(fontSize: 14, color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}

/// CustomPainter لرسم التأشيرات المحفوظة
class _HighlightsPainter extends CustomPainter {
  final List<({List<Offset> points, Color color})> highlights;

  _HighlightsPainter(this.highlights);

  @override
  void paint(Canvas canvas, Size size) {
    for (final highlight in highlights) {
      if (highlight.points.length < 2) continue;

      // استخدام خط عريض شفاف مثل قلم highlighter
      final paint = Paint()
        ..color = highlight.color.withOpacity(0.06)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 25.0 // خط عريض مثل قلم التأشير
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      // رسم خط بين كل نقطتين متتاليتين
      for (int i = 0; i < highlight.points.length - 1; i++) {
        canvas.drawLine(
          highlight.points[i],
          highlight.points[i + 1],
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_HighlightsPainter oldDelegate) {
    return oldDelegate.highlights != highlights;
  }
}

/// CustomPainter لرسم المسار الحالي أثناء السحب
class _CurrentPathPainter extends CustomPainter {
  final List<Offset> points;
  final Color color;

  _CurrentPathPainter(this.points, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    // استخدام خط عريض شفاف مثل قلم highlighter
    final paint = Paint()
      ..color = color.withOpacity(0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 25.0 // خط عريض مثل قلم التأشير
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // رسم خط بين كل نقطتين متتاليتين
    for (int i = 0; i < points.length - 1; i++) {
      canvas.drawLine(points[i], points[i + 1], paint);
    }
  }

  @override
  bool shouldRepaint(_CurrentPathPainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.color != color;
  }
}

/// زر عداد التكرار: عادي ثم يكبر ويصبح دائرياً عند البدء، ويرجع طبيعياً ويتوقف عند الوصول للهدف
class _AzkarCounterButton extends StatelessWidget {
  final int current;
  final int repeat;
  final String Function(int) toNormalDigits;
  final TextStyle Function(
      {required double fontSize,
      required Color color,
      FontWeight fontWeight}) quranStyle;
  final VoidCallback? onTap;

  const _AzkarCounterButton({
    required this.current,
    required this.repeat,
    required this.toNormalDigits,
    required this.quranStyle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final reached = current >= repeat;
    final counting = current > 0 && !reached;
    final isBig = counting;
    final size = isBig ? 72.0 : 44.0;
    final radius = size / 2;
    final borderRadius = BorderRadius.circular(radius);

    return Material(
      color: reached ? const Color(0xFF2E7D32) : const Color(0xFFE8F5E9),
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedRectangleBorder(borderRadius: borderRadius),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: size,
          height: size,
          alignment: Alignment.center,
          child: Text(
            toNormalDigits(current),
            style: quranStyle(
                fontSize: isBig ? 22 : 16,
                color: reached ? Colors.white : const Color(0xFF1B5E20),
                fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

/// محتوى شاشة الأذكار: قائمة + تفاصيل مع رجوع وعداد تكرار
class _AzkarSheetContent extends StatefulWidget {
  final List<
      ({
        int id,
        String title,
        String? titleAr,
        String? audioUrl,
        List<
            ({
              int id,
              String arabicText,
              String? languageArabicTranslatedText,
              String? translatedText,
              int repeat,
              String? audio
            })> texts
      })> azkarList;
  final String Function(int) toNormalDigits;
  final TextStyle Function(
      {required double fontSize,
      required Color color,
      FontWeight fontWeight}) quranStyle;
  final RegExp arabicRegex;
  final VoidCallback onClose;

  const _AzkarSheetContent({
    required this.azkarList,
    required this.toNormalDigits,
    required this.quranStyle,
    required this.arabicRegex,
    required this.onClose,
  });

  @override
  State<_AzkarSheetContent> createState() => _AzkarSheetContentState();
}

class _AzkarSheetContentState extends State<_AzkarSheetContent> {
  int? _selectedIndex;
  List<int> _counts = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matchesSearch(int index) {
    if (_searchQuery.trim().isEmpty) return true;
    final q = _normalizeForSearch(_searchQuery.trim());
    final zikr = widget.azkarList[index];
    final titleAr = _normalizeForSearch(zikr.titleAr ?? '');
    final title = _normalizeForSearch(zikr.title);
    if (titleAr.contains(q) || title.contains(q)) return true;
    for (final t in zikr.texts) {
      final arabicText = _normalizeForSearch(t.arabicText);
      final translatedText = _normalizeForSearch(t.translatedText ?? '');
      final languageArabicTranslatedText =
          _normalizeForSearch(t.languageArabicTranslatedText ?? '');
      if (arabicText.contains(q) ||
          translatedText.contains(q) ||
          languageArabicTranslatedText.contains(q)) return true;
    }
    return false;
  }

  String _normalizeForSearch(String s) {
    // إزالة الحركات (التشكيل)
    String normalized = s.replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '');
    // إزالة علامات التشكيل الأخرى
    normalized = normalized.replaceAll(RegExp(r'[\u0610-\u061A\u0640]'), '');
    // توحيد الهمزات
    normalized = normalized
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ء', 'ا')
        .replaceAll('ؤ', 'و')
        .replaceAll('ئ', 'ي')
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه');
    return normalized.toLowerCase();
  }

  void _openZikr(int index) {
    setState(() {
      _selectedIndex = index;
      _counts = List.filled(widget.azkarList[index].texts.length, 0);
    });
  }

  void _back() {
    setState(() {
      _selectedIndex = null;
      _counts = [];
    });
  }

  void _incrementCounter(int itemIndex) {
    if (_selectedIndex == null || itemIndex >= _counts.length) return;
    setState(() {
      _counts[itemIndex] = _counts[itemIndex] + 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedIndex != null) {
      return _buildDetails(context, _selectedIndex!);
    }
    return _buildList(context);
  }

  Widget _buildList(BuildContext context) {
    final list = widget.azkarList;
    final indices = List.generate(list.length, (i) => i)
        .where((i) => _matchesSearch(i))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'أذكار وأدعية',
                  style: widget.quranStyle(
                      fontSize: 20,
                      color: const Color(0xFF1B5E20),
                      fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF1B5E20)),
                onPressed: widget.onClose,
              )
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _searchQuery = v),
            decoration: InputDecoration(
              hintText: 'بحث في العناوين أو الذكر...',
              prefixIcon: const Icon(Icons.search, color: Color(0xFF2E7D32)),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            style: widget.quranStyle(
                fontSize: 16,
                color: const Color(0xFF1B5E20),
                fontWeight: FontWeight.normal),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: indices.length,
            separatorBuilder: (_, __) => const SizedBox(height: 16),
            itemBuilder: (context, listIndex) {
              final index = indices[listIndex];
              final zikr = list[index];
              return InkWell(
                onTap: () => _openZikr(index),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              zikr.titleAr ??
                                  'مجموعة أذكار ${widget.toNormalDigits(index + 1)}',
                              style: widget.quranStyle(
                                  fontSize: 18,
                                  color: const Color(0xFF1B5E20),
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          const Icon(
                            Icons.arrow_forward_ios,
                            size: 16,
                            color: Color(0xFF2E7D32),
                          ),
                        ],
                      ),
                      if (zikr.texts.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'عدد الأذكار: ${widget.toNormalDigits(zikr.texts.length)}',
                          style: widget.quranStyle(
                              fontSize: 14,
                              color: Colors.grey.shade700,
                              fontWeight: FontWeight.normal),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDetails(BuildContext context, int index) {
    final zikr = widget.azkarList[index];
    final arabicTitle =
        zikr.titleAr ?? 'مجموعة أذكار ${widget.toNormalDigits(index + 1)}';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: Color(0xFF1B5E20), size: 22),
                onPressed: _back,
              ),
              Expanded(
                child: Text(
                  arabicTitle,
                  style: widget.quranStyle(
                      fontSize: 18,
                      color: const Color(0xFF1B5E20),
                      fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF1B5E20)),
                onPressed: widget.onClose,
              )
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: zikr.texts.length,
            separatorBuilder: (_, __) => const SizedBox(height: 16),
            itemBuilder: (context, itemIndex) {
              final text = zikr.texts[itemIndex];
              final current =
                  itemIndex < _counts.length ? _counts[itemIndex] : 0;
              final reached = current >= text.repeat;
              final showLangAr = text.languageArabicTranslatedText != null &&
                  text.languageArabicTranslatedText!.isNotEmpty &&
                  widget.arabicRegex
                      .hasMatch(text.languageArabicTranslatedText!);
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text.arabicText,
                      style: widget.quranStyle(
                          fontSize: 22,
                          color: Colors.black87,
                          fontWeight: FontWeight.w500),
                      textAlign: TextAlign.right,
                    ),
                    const SizedBox(height: 12),
                    if (showLangAr) ...[
                      Text(
                        text.languageArabicTranslatedText!,
                        style: widget.quranStyle(
                            fontSize: 16,
                            color: const Color(0xFF2E7D32),
                            fontWeight: FontWeight.w600),
                        textAlign: TextAlign.right,
                      ),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      children: [
                        // الزر على اليمين (في RTL أول عنصر يكون على اليمين)
                        Tooltip(
                          message: 'اضغط عند كل مرة تقول فيها الذكر',
                          child: _AzkarCounterButton(
                            current: current,
                            repeat: text.repeat,
                            toNormalDigits: widget.toNormalDigits,
                            quranStyle: widget.quranStyle,
                            onTap: reached
                                ? null
                                : () => _incrementCounter(itemIndex),
                          ),
                        ),
                        const Spacer(),
                        // عدد المرات على اليسار
                        Text(
                          'عدد المرات: ${widget.toNormalDigits(text.repeat)}',
                          style: widget.quranStyle(
                              fontSize: 14,
                              color: const Color(0xFF2E7D32),
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'features/itinerary/itinerary_page.dart';

const _webChineseFallback = 'Noto Sans SC';

Future<void> main() async { 
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    final font = FontLoader(_webChineseFallback)
      ..addFont(rootBundle.load('assets/NotoSansSC-Subset.ttf'));
    await font.load();
  }
  runApp(const ProviderScope(child: RippleApp()));
}

class RippleApp extends StatelessWidget {
  const RippleApp({super.key});

  @override
  Widget build(BuildContext context) => DynamicColorBuilder(
    builder: (light, dark) => MaterialApp(
      title: '涟漪',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: _theme(light, Brightness.light),
      darkTheme: _theme(dark, Brightness.dark),
      home: const ItineraryPage(),
    ),
  );

  ThemeData _theme(ColorScheme? systemScheme, Brightness brightness) =>
      ThemeData(
        useMaterial3: true,
        fontFamilyFallback: kIsWeb ? const [_webChineseFallback] : null,
        colorScheme:
            systemScheme ??
            ColorScheme.fromSeed(
              seedColor: const Color(0xff145668),
              brightness: brightness,
            ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      );
}

library app;

import 'package:accessibility_tools/accessibility_tools.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_flavor/flutter_flavor.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:localization/localization.dart';
import 'package:mangabackupconverter/src/features/settings/application/settings_service.dart';
import 'package:mangabackupconverter/src/features/settings/data/dto/settings.dart';
import 'package:mangabackupconverter/src/features/settings/presentation/widgets/app_settings.dart';
import 'package:mangabackupconverter/src/routing/presentation/widgets/router_widget.dart';

/// The main app widget at the root of the widget tree.
class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // final userJohnDoe = UserAccount(
    //   name: Name(firstName: 'John', lastName: 'Doe'),
    //   email: Email('test@gmail.com'),
    //   id: Id('5646532'),
    // );
    // final userJohnDeer =
    //     userJohnDoe.copyWith(name: Name(firstName: 'John', lastName: 'Deer'));
    // userJohnDoe.mapValidity(
    //   valid: (validUser) => debugPrint(validUser.toString()),
    //   invalid: (invalidUser) => debugPrint(invalidUser.toString()),
    // );
    // userJohnDeer.mapValidity(
    //   valid: (validUser) => debugPrint(validUser.toString()),
    //   invalid: (invalidUser) => debugPrint(invalidUser.toString()),
    // );

    final Settings settings = ref.watch(settingsServiceProvider);

    final materialApp = RouterWidget(
      builder: (context, router) {
        return AppSettings(
          settings: settings,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            onGenerateTitle: (context) => context.loc.appTitle,
            routerConfig: router,
            restorationScopeId: 'app',
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            // Theme config for FlexColorScheme version 7.3.x. Make sure you use
            // same or higher package version, but still same major version. If
            // you use a lower package version, some properties may not be
            // supported. In that case remove them after copying this theme to
            // your app.
            theme: FlexThemeData.light(
              colors: settings.lightTheme.light,
              surfaceMode: FlexSurfaceMode.levelSurfacesLowScaffold,
              blendLevel: 7,
              subThemesData: const FlexSubThemesData(
                blendOnLevel: 10,
                blendOnColors: false,
                useTextTheme: true,
                useM2StyleDividerInM3: true,
                alignedDropdown: true,
                useInputDecoratorThemeInDialogs: true,
              ),
              visualDensity: FlexColorScheme.comfortablePlatformDensity,
              useMaterial3: true,
              swapLegacyOnMaterial3: true,
              // To use the Playground font, add GoogleFonts package and uncomment
              fontFamily: GoogleFonts.notoSans().fontFamily,
            ),
            darkTheme: FlexThemeData.dark(
              colors: settings.darkTheme.dark,
              surfaceMode: FlexSurfaceMode.levelSurfacesLowScaffold,
              blendLevel: 13,
              subThemesData: const FlexSubThemesData(
                blendOnLevel: 20,
                useTextTheme: true,
                useM2StyleDividerInM3: true,
                alignedDropdown: true,
                useInputDecoratorThemeInDialogs: true,
              ),
              visualDensity: FlexColorScheme.comfortablePlatformDensity,
              useMaterial3: true,
              swapLegacyOnMaterial3: true,
              // To use the Playground font, add GoogleFonts package and uncomment
              fontFamily: GoogleFonts.notoSans().fontFamily,
            ),
            themeMode: settings.themeType.toThemeMode(),
            builder: (context, child) => AccessibilityTools(child: child),
          ),
        );
      },
    );

    // avoids nullcheck error in FlavorBanner() with no child
    final showBanner = !(FlavorConfig.instance.name == null ||
        (FlavorConfig.instance.name?.isEmpty ?? true));

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        alignment: AlignmentDirectional.topEnd,
        children: [
          materialApp,
          if (settings.bannerEnabled && showBanner) const FlavorBanner(),
        ],
      ),
    );
  }
}

import 'package:constants/constants.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:mangabackupconverter/src/features/settings/data/dto/theme_type.dart';

part 'settings.g.dart';
part 'settings.mapper.dart';

@MappableClass()
@HiveType(typeId: 1)
class Settings with SettingsMappable {
  @MappableField()
  @HiveField(0, defaultValue: true)
  final bool bannerEnabled;

  @MappableField()
  @HiveField(1, defaultValue: ThemeType.system)
  final ThemeType themeType;

  @MappableField()
  @HiveField(2, defaultValue: FlexColor.flutterDash)
  final FlexSchemeData lightTheme;

  @MappableField()
  @HiveField(3, defaultValue: FlexColor.bahamaBlue)
  final FlexSchemeData darkTheme;

  @MappableField()
  @HiveField(4, defaultValue: <FlexSchemeData>[])
  final List<FlexSchemeData> customThemes;

  const Settings({
    this.bannerEnabled = true,
    this.themeType = ThemeType.system,
    this.lightTheme = FlexColor.flutterDash,
    this.darkTheme = FlexColor.bahamaBlue,
    this.customThemes = const [],
  });

  static const fromMap = SettingsMapper.fromMap;
  static const fromJson = SettingsMapper.fromJson;
}

extension SettingsExtension on Settings {
  bool get isBannerShowing => AppFlavor.isBannerEnabled && bannerEnabled;
}

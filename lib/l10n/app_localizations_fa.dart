// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Persian (`fa`).
class AppLocalizationsFa extends AppLocalizations {
  AppLocalizationsFa([String locale = 'fa']) : super(locale);

  @override
  String get appTitle => 'AsadVPN';

  @override
  String get unlimited => 'نامحدود';

  @override
  String get connecting => 'A Moment Please...';

  @override
  String get connected => 'متصل';

  @override
  String get disconnected => 'قطعه';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get connect => 'Connect';

  @override
  String get serverList => 'لیست سرورها';

  @override
  String get noServers => 'No servers available';

  @override
  String get scanningServers => 'Scanning servers...';

  @override
  String get enterSubscription => 'وارد کردن اشتراک';

  @override
  String get subscriptionExpired => 'اشتراک منقضی شده';

  @override
  String get activate => 'فعال‌سازی';

  @override
  String get getSubscription => 'دریافت اشتراک';

  @override
  String get changeSubscription => 'تغییر اشتراک';

  @override
  String get subscriptionLink => 'لینک اشتراک';

  @override
  String get invalidSubscription => 'اشتراک نامعتبر';

  @override
  String get subscriptionActivated => 'اشتراک با موفقیت فعال شد!';

  @override
  String get selectServer => 'انتخاب سرور';

  @override
  String get fastestServers => 'سریع‌ترین سرورها';

  @override
  String get protocol => 'پروتکل';

  @override
  String get ping => 'پینگ';
}

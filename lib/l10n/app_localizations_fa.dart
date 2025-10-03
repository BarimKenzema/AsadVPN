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
  String get initializing => 'در حال آماده‌سازی...';

  @override
  String get checkingSubscription => 'بررسی اشتراک...';

  @override
  String get validatingSubscription => 'اعتبارسنجی اشتراک...';

  @override
  String get readyToConnect => 'آماده اتصال';

  @override
  String get noSubscription => 'بدون اشتراک';

  @override
  String get subscriptionExpired => 'اشتراک منقضی شده';

  @override
  String get invalidSubscription => 'اشتراک نامعتبر';

  @override
  String get disconnecting => 'در حال قطع اتصال...';

  @override
  String get disconnected => 'قطعه';

  @override
  String get connected => 'متصل';

  @override
  String get connectionFailed => 'اتصال ناموفق';

  @override
  String get noServersAvailable => 'سروری در دسترس نیست';

  @override
  String get scanningMessage => 'لطفاً کمی صبر کنید...';

  @override
  String get enterSubscription => 'وارد کردن اشتراک';

  @override
  String get subscriptionExpiredTitle => 'اشتراک منقضی شده';

  @override
  String get enterSubscriptionMessage =>
      'لینک اشتراک خود را برای فعال‌سازی وارد کنید:';

  @override
  String get subscriptionExpiredMessage =>
      'اشتراک شما منقضی شده است. لطفاً لینک اشتراک جدید وارد کنید.';

  @override
  String get subscriptionLink => 'لینک اشتراک';

  @override
  String get exampleLink =>
      'مثال: https://konabalan.pythonanywhere.com/sub/YOUR_TOKEN';

  @override
  String get getSubscription => 'دریافت اشتراک';

  @override
  String get activate => 'فعال‌سازی';

  @override
  String get changeSubscription => 'تغییر اشتراک';

  @override
  String get subscriptionActivated => 'اشتراک با موفقیت فعال شد!';

  @override
  String get invalidSubscriptionLink =>
      'لینک اشتراک نامعتبر است. لطفاً بررسی کرده و دوباره امتحان کنید.';

  @override
  String get serverList => 'لیست سرورها';

  @override
  String get fastestServers => 'سریع‌ترین سرورها';

  @override
  String get protocol => 'پروتکل';

  @override
  String get ping => 'پینگ';

  @override
  String get selectServer => 'انتخاب سرور';

  @override
  String get scanning => 'در حال اسکن';

  @override
  String serversFound(int count) {
    return '$count سرور یافت شد';
  }
}

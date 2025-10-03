// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'AsadVPN';

  @override
  String get unlimited => 'UNLIMITED';

  @override
  String get connecting => 'A Moment Please...';

  @override
  String get connected => 'Connected';

  @override
  String get disconnected => 'Disconnected';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get connect => 'Connect';

  @override
  String get serverList => 'Server List';

  @override
  String get noServers => 'No servers available';

  @override
  String get scanningServers => 'Scanning servers...';

  @override
  String get enterSubscription => 'Enter Subscription';

  @override
  String get subscriptionExpired => 'Subscription Expired';

  @override
  String get activate => 'Activate';

  @override
  String get getSubscription => 'Get Subscription';

  @override
  String get changeSubscription => 'Change Subscription';

  @override
  String get subscriptionLink => 'Subscription Link';

  @override
  String get invalidSubscription => 'Invalid subscription link';

  @override
  String get subscriptionActivated => 'Subscription activated successfully!';

  @override
  String get selectServer => 'Select Server';

  @override
  String get fastestServers => 'Fastest Servers';

  @override
  String get protocol => 'Protocol';

  @override
  String get ping => 'Ping';
}

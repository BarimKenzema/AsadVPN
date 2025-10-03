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
  String get initializing => 'Initializing...';

  @override
  String get checkingSubscription => 'Checking subscription...';

  @override
  String get validatingSubscription => 'Validating subscription...';

  @override
  String get readyToConnect => 'Ready to connect';

  @override
  String get noSubscription => 'No subscription';

  @override
  String get subscriptionExpired => 'Subscription expired';

  @override
  String get invalidSubscription => 'Invalid subscription';

  @override
  String get disconnecting => 'Disconnecting...';

  @override
  String get disconnected => 'Disconnected';

  @override
  String get connected => 'Connected';

  @override
  String get connectionFailed => 'Connection failed';

  @override
  String get noServersAvailable => 'No servers available';

  @override
  String get scanningMessage => 'A Moment Please...';

  @override
  String get enterSubscription => 'Enter Subscription';

  @override
  String get subscriptionExpiredTitle => 'Subscription Expired';

  @override
  String get enterSubscriptionMessage =>
      'Enter your subscription link to activate AsadVPN:';

  @override
  String get subscriptionExpiredMessage =>
      'Your subscription has expired. Please enter a new subscription link.';

  @override
  String get subscriptionLink => 'Subscription Link';

  @override
  String get exampleLink =>
      'Example: https://konabalan.pythonanywhere.com/sub/YOUR_TOKEN';

  @override
  String get getSubscription => 'Get Subscription';

  @override
  String get activate => 'Activate';

  @override
  String get changeSubscription => 'Change Subscription';

  @override
  String get subscriptionActivated => 'Subscription activated successfully!';

  @override
  String get invalidSubscriptionLink =>
      'Invalid subscription link. Please check and try again.';

  @override
  String get serverList => 'Server List';

  @override
  String get fastestServers => 'Fastest Servers';

  @override
  String get protocol => 'Protocol';

  @override
  String get ping => 'Ping';

  @override
  String get selectServer => 'Select Server';

  @override
  String get scanning => 'Scanning';

  @override
  String serversFound(int count) {
    return '$count servers found';
  }
}

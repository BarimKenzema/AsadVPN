import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_fa.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('fa')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'AsadVPN'**
  String get appTitle;

  /// No description provided for @unlimited.
  ///
  /// In en, this message translates to:
  /// **'UNLIMITED'**
  String get unlimited;

  /// No description provided for @initializing.
  ///
  /// In en, this message translates to:
  /// **'Initializing...'**
  String get initializing;

  /// No description provided for @checkingSubscription.
  ///
  /// In en, this message translates to:
  /// **'Checking subscription...'**
  String get checkingSubscription;

  /// No description provided for @validatingSubscription.
  ///
  /// In en, this message translates to:
  /// **'Validating subscription...'**
  String get validatingSubscription;

  /// No description provided for @readyToConnect.
  ///
  /// In en, this message translates to:
  /// **'Ready to connect'**
  String get readyToConnect;

  /// No description provided for @noSubscription.
  ///
  /// In en, this message translates to:
  /// **'No subscription'**
  String get noSubscription;

  /// No description provided for @subscriptionExpired.
  ///
  /// In en, this message translates to:
  /// **'Subscription expired'**
  String get subscriptionExpired;

  /// No description provided for @invalidSubscription.
  ///
  /// In en, this message translates to:
  /// **'Invalid subscription'**
  String get invalidSubscription;

  /// No description provided for @disconnecting.
  ///
  /// In en, this message translates to:
  /// **'Disconnecting...'**
  String get disconnecting;

  /// No description provided for @disconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get disconnected;

  /// No description provided for @connected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// No description provided for @connectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get connectionFailed;

  /// No description provided for @noServersAvailable.
  ///
  /// In en, this message translates to:
  /// **'No servers available'**
  String get noServersAvailable;

  /// No description provided for @scanningMessage.
  ///
  /// In en, this message translates to:
  /// **'A Moment Please...'**
  String get scanningMessage;

  /// No description provided for @enterSubscription.
  ///
  /// In en, this message translates to:
  /// **'Enter Subscription'**
  String get enterSubscription;

  /// No description provided for @subscriptionExpiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Subscription Expired'**
  String get subscriptionExpiredTitle;

  /// No description provided for @enterSubscriptionMessage.
  ///
  /// In en, this message translates to:
  /// **'Enter your subscription link to activate AsadVPN:'**
  String get enterSubscriptionMessage;

  /// No description provided for @subscriptionExpiredMessage.
  ///
  /// In en, this message translates to:
  /// **'Your subscription has expired. Please enter a new subscription link.'**
  String get subscriptionExpiredMessage;

  /// No description provided for @subscriptionLink.
  ///
  /// In en, this message translates to:
  /// **'Subscription Link'**
  String get subscriptionLink;

  /// No description provided for @exampleLink.
  ///
  /// In en, this message translates to:
  /// **'Example: https://konabalan.pythonanywhere.com/sub/YOUR_TOKEN'**
  String get exampleLink;

  /// No description provided for @getSubscription.
  ///
  /// In en, this message translates to:
  /// **'Get Subscription'**
  String get getSubscription;

  /// No description provided for @activate.
  ///
  /// In en, this message translates to:
  /// **'Activate'**
  String get activate;

  /// No description provided for @changeSubscription.
  ///
  /// In en, this message translates to:
  /// **'Change Subscription'**
  String get changeSubscription;

  /// No description provided for @subscriptionActivated.
  ///
  /// In en, this message translates to:
  /// **'Subscription activated successfully!'**
  String get subscriptionActivated;

  /// No description provided for @invalidSubscriptionLink.
  ///
  /// In en, this message translates to:
  /// **'Invalid subscription link. Please check and try again.'**
  String get invalidSubscriptionLink;

  /// No description provided for @serverList.
  ///
  /// In en, this message translates to:
  /// **'Server List'**
  String get serverList;

  /// No description provided for @fastestServers.
  ///
  /// In en, this message translates to:
  /// **'Fastest Servers'**
  String get fastestServers;

  /// No description provided for @protocol.
  ///
  /// In en, this message translates to:
  /// **'Protocol'**
  String get protocol;

  /// No description provided for @ping.
  ///
  /// In en, this message translates to:
  /// **'Ping'**
  String get ping;

  /// No description provided for @selectServer.
  ///
  /// In en, this message translates to:
  /// **'Select Server'**
  String get selectServer;

  /// No description provided for @scanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning'**
  String get scanning;

  /// No description provided for @serversFound.
  ///
  /// In en, this message translates to:
  /// **'{count} servers found'**
  String serversFound(int count);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'fa'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'fa':
      return AppLocalizationsFa();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}

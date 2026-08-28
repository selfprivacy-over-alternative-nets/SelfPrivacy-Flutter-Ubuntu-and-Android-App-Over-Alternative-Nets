import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:selfprivacy/config/app_controller/inherited_app_controller.dart';
import 'package:selfprivacy/config/bloc_config.dart';
import 'package:selfprivacy/config/bloc_observer.dart';
import 'package:selfprivacy/config/brand_colors.dart';
import 'package:selfprivacy/config/get_it_config.dart';
import 'package:selfprivacy/config/hive_config.dart';
import 'package:selfprivacy/config/localization.dart';
import 'package:selfprivacy/config/preferences_repository/datasources/preferences_hive_datasource.dart';
import 'package:selfprivacy/config/preferences_repository/inherited_preferences_repository.dart';
import 'package:selfprivacy/logic/get_it/resources_model.dart';
import 'package:selfprivacy/logic/models/hive/server.dart';
import 'package:selfprivacy/logic/models/hive/server_details.dart';
import 'package:selfprivacy/logic/models/hive/server_domain.dart';
import 'package:selfprivacy/ui/pages/errors/failed_to_init_secure_storage.dart';
import 'package:selfprivacy/ui/router/router.dart';
import 'package:hive_ce/hive.dart';
import 'package:timezone/data/latest.dart' as tz;

/// Configure a .onion server connection in ResourcesModel and skip onboarding.
Future<void> _setupOnionServer(String onionDomain, String apiToken) async {
  final resourcesModel = getIt<ResourcesModel>();

  // A server may already be configured from a previous run (persisted in Hive). If it still matches
  // the requested onion + token, keep it (fast path). If it's STALE — e.g. the backend was
  // reinstalled and now has a different .onion — wipe it so the compile-time --dart-define values
  // win. Otherwise the app keeps dialing the dead onion and every request fails at the SOCKS layer
  // with `hostUnreachable`, which looks like a connection bug but is really stale local state.
  if (resourcesModel.servers.isNotEmpty) {
    final existing = resourcesModel.servers.first;
    final matchesCurrent = existing.domain.domainName == onionDomain &&
        existing.hostingDetails.apiToken == apiToken;
    if (matchesCurrent) {
      final appSettingsBox = Hive.box(BNames.appSettingsBox);
      await appSettingsBox.put(BNames.shouldShowOnboarding, false);
      return;
    }
    await resourcesModel.removeServer(existing); // stale — drop it, reconfigure below with current
  }

  final serverDomain = ServerDomain(
    domainName: onionDomain,
    provider: DnsProviderType.unknown,
  );
  final serverDetails = ServerHostingDetails(
    apiToken: apiToken,
    ip4: onionDomain,
    id: 0,
    createTime: null,
    startTime: null,
    provider: ServerProviderType.unknown,
    volume: ServerProviderVolume(
      id: 0,
      name: 'tor-vm',
      sizeByte: 10737418240,
      serverId: 0,
      linuxDevice: '',
    ),
  );

  await resourcesModel.addServer(Server(
    domain: serverDomain,
    hostingDetails: serverDetails,
  ));

  await getIt<WizardDataModel>().clearServerInstallation();

  final appSettingsBox = Hive.box(BNames.appSettingsBox);
  await appSettingsBox.put(BNames.shouldShowOnboarding, false);

  await getIt<ApiConnectionRepository>().init();
}

/// Show a setup screen to collect onion domain and API token at runtime.
/// Returns (domain, token) or null if the user skips.
Future<({String domain, String token})?> _showOnionSetupPrompt() async {
  final completer = Completer<({String domain, String token})?>();

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _OnionSetupScreen(
        onComplete: (domain, token) =>
            completer.complete((domain: domain, token: token)),
        onSkip: () => completer.complete(null),
      ),
    ),
  );

  return completer.future;
}

class _OnionSetupScreen extends StatefulWidget {
  const _OnionSetupScreen({required this.onComplete, required this.onSkip});

  final void Function(String domain, String token) onComplete;
  final VoidCallback onSkip;

  @override
  State<_OnionSetupScreen> createState() => _OnionSetupScreenState();
}

class _OnionSetupScreenState extends State<_OnionSetupScreen> {
  final _domainController = TextEditingController();
  final _tokenController =
      TextEditingController(text: 'test-token-for-tor-development');

  @override
  void dispose() {
    _domainController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('SelfPrivacy Tor Setup')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Enter your .onion domain and API token to connect.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _domainController,
                decoration: const InputDecoration(
                  labelText: 'Onion Domain',
                  hintText: 'abc...xyz.onion',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _tokenController,
                decoration: const InputDecoration(
                  labelText: 'API Token',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: widget.onSkip,
                    child: const Text('Skip'),
                  ),
                  const SizedBox(width: 16),
                  FilledButton(
                    onPressed: () {
                      final domain = _domainController.text.trim();
                      final token = _tokenController.text.trim();
                      if (domain.isNotEmpty && token.isNotEmpty) {
                        widget.onComplete(domain, token);
                      }
                    },
                    child: const Text('Connect'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

void main() async {
  try {
    await Future.wait(<Future<void>>[
      HiveConfig.init(),
      EasyLocalization.ensureInitialized(),
    ]);
    await getItSetup();

    // Compile-time values from --dart-define (optional)
    const compileDomain =
        String.fromEnvironment('ONION_DOMAIN', defaultValue: '');
    const compileToken =
        String.fromEnvironment('API_TOKEN', defaultValue: '');

    if (kDebugMode && compileDomain.isNotEmpty && compileToken.isNotEmpty) {
      // Auto-setup from compile-time --dart-define values
      await _setupOnionServer(compileDomain, compileToken);
    } else if (kDebugMode && getIt<ResourcesModel>().servers.isEmpty) {
      // No compile-time domain and no server configured: prompt at runtime
      final result = await _showOnionSetupPrompt();
      if (result != null) {
        await _setupOnionServer(result.domain, result.token);
      }
    }
  } on PlatformException catch (e) {
    runApp(FailedToInitSecureStorageScreen(e: e));
  }

  tz.initializeTimeZones();

  // Suppress keyboard state assertion errors on Linux desktop (debug mode only).
  // Flutter's HardwareKeyboard can desync when modifier keys are pressed during
  // focus changes, causing "KeyDownEvent is dispatched, but physical key is
  // already pressed" assertions. The actual key handling still works correctly.
  // Fixed upstream in Flutter PR #181894 (master), expected in stable ~3.44.
  if (kDebugMode) {
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (details.exceptionAsString().contains(
            'is dispatched, but the state shows that the physical key',
          )) {
        return;
      }
      originalOnError?.call(details);
    };
  }

  Bloc.observer = SimpleBlocObserver();

  runApp(
    Localization(
      child: InheritedPreferencesRepository(
        dataSource: PreferencesHiveDataSource(),
        child: const InheritedAppController(child: AppBuilder()),
      ),
    ),
  );
}

class AppBuilder extends StatelessWidget {
  const AppBuilder({super.key});

  @override
  Widget build(final BuildContext context) {
    final appController = InheritedAppController.of(context);

    if (appController.loaded) {
      return const SelfprivacyApp();
    }

    return const SplashScreen();
  }
}

/// Widget to be shown
/// until essential app initialization is completed
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(final BuildContext context) => const ColoredBox(
        color: Colors.white,
        child: Center(
          child: CircularProgressIndicator.adaptive(
            valueColor: AlwaysStoppedAnimation(BrandColors.primary),
          ),
        ),
      );
}

class SelfprivacyApp extends StatefulWidget {
  const SelfprivacyApp({super.key});

  @override
  State<SelfprivacyApp> createState() => _SelfprivacyAppState();
}

class _SelfprivacyAppState extends State<SelfprivacyApp> {
  final appKey = UniqueKey();
  final _appRouter = RootRouter(getIt.get<NavigationService>().navigatorKey);

  @override
  Widget build(final BuildContext context) {
    final appController = InheritedAppController.of(context);

    return BlocAndProviderConfig(
      child: MaterialApp.router(
        key: appKey,
        title: 'SelfPrivacy',
        // routing
        routeInformationParser: _appRouter.defaultRouteParser(),
        routerDelegate: _appRouter.delegate(),
        scaffoldMessengerKey:
            getIt.get<NavigationService>().scaffoldMessengerKey,
        // localization settings
        locale: context.locale,
        supportedLocales: context.supportedLocales,
        localizationsDelegates: context.localizationDelegates,
        // theme settings
        themeMode: appController.themeMode,
        theme: appController.lightTheme,
        darkTheme: appController.darkTheme,
        // other preferences
        debugShowCheckedModeBanner: false,
        scrollBehavior: const MaterialScrollBehavior().copyWith(
          scrollbars: false,
        ),
        builder: _builder,
      ),
    );
  }

  Widget _builder(final BuildContext context, final Widget? widget) {
    Widget error = const Center(child: Text('...rendering error...'));
    if (widget is Scaffold || widget is Navigator) {
      error = Scaffold(body: error);
    }
    ErrorWidget.builder = (final FlutterErrorDetails errorDetails) => error;

    return widget ?? error;
  }
}

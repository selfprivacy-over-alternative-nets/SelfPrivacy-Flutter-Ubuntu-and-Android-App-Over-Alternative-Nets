import 'dart:convert';
import 'dart:io';

import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/io_client.dart';
import 'package:selfprivacy/config/get_it_config.dart';
import 'package:selfprivacy/logic/api_maps/tls_options.dart';
import 'package:selfprivacy/logic/get_it/resources_model.dart';
import 'package:selfprivacy/logic/models/console_log.dart';
import 'package:selfprivacy/utils/app_logger.dart';
import 'package:socks5_proxy/socks_client.dart';

void _addConsoleLog(final ConsoleLog message) =>
    getIt.get<ConsoleModel>().log(message);

class RequestLoggingLink extends Link {
  @override
  Stream<Response> request(
    final Request request, [
    final NextLink? forward,
  ]) async* {
    _addConsoleLog(
      GraphQlRequestConsoleLog(
        operationType: request.type.name,
        operation: request.operation,
        variables: request.variables,
      ),
    );
    yield* forward!(request);
  }
}

class ResponseLoggingParser extends ResponseParser {
  @override
  Response parseResponse(final Map<String, dynamic> body) {
    final response = super.parseResponse(body);
    _addConsoleLog(
      GraphQlResponseConsoleLog(
        data: response.data,
        errors: response.errors,
        rawResponse: jsonEncode(response.response),
      ),
    );
    return response;
  }

  @override
  GraphQLError parseError(final Map<String, dynamic> error) {
    final graphQlError = super.parseError(error);
    _addConsoleLog(
      ManualConsoleLog.warning(
        customTitle: 'GraphQL Error',
        content: graphQlError.toString(),
      ),
    );
    return graphQlError;
  }
}

/// Retries transient network failures on the HTTP query path (e.g. Tor SOCKS
/// `ttlExpired` / connection timeouts on a cold circuit). Used ONLY for `.onion`
/// connections — clearnet requests never go through this link. It does not retry
/// once any data has been emitted (avoids duplicate responses), and never
/// retries GraphQL-level errors (those are yielded by HttpLink, not thrown).
class _OnionRetryLink extends Link {
  static const int _maxAttempts = 3;
  static const Duration _delay = Duration(seconds: 2);

  @override
  Stream<Response> request(
    final Request request, [
    final NextLink? forward,
  ]) async* {
    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
      bool emitted = false;
      try {
        await for (final Response response in forward!(request)) {
          emitted = true;
          yield response;
        }
        return; // completed successfully
      } catch (_) {
        // Don't retry after emitting data, or once attempts are exhausted;
        // rethrow preserves the original exception type + stack trace.
        if (emitted || attempt >= _maxAttempts) {
          rethrow;
        }
        await Future<void>.delayed(_delay);
      }
    }
  }
}

abstract class GraphQLApiMap {
  void Function(String, {Object? error, StackTrace? stackTrace}) get logger =>
      const AppLogger(name: 'graphql_map').log;

  // A warm, reused Tor-backed HTTP client per onion address. The first request
  // over Tor pays the (slow, flaky) circuit-build cost; later requests reuse the
  // same warm circuit instead of building a new one for every query — which is
  // what caused the intermittent `ttlExpired` / 5s timeouts. Non-onion (nominal)
  // requests do NOT use this; they keep a fresh client per call, unchanged.
  static IOClient? _onionClient;
  static String? _onionClientAddress;

  Future<GraphQLClient> getClient() async {
    final bool isOnion = (rootAddress ?? '').endsWith('.onion');

    final IOClient ioClient;
    if (isOnion) {
      // Reuse a warm SOCKS5/Tor client for this onion (self-signed cert trusted).
      // Linux: Tor daemon on 9050 / Android: Orbot on 9050.
      if (_onionClient == null || _onionClientAddress != rootAddress) {
        _onionClient?.close();
        final HttpClient base = HttpClient()
          ..connectionTimeout = const Duration(seconds: 30)
          ..badCertificateCallback =
              (final X509Certificate cert, final String host, final int port) =>
                  true;
        SocksTCPClient.assignToHttpClientWithSecureOptions(base, [
          ProxySettings(InternetAddress.loopbackIPv4,
              const int.fromEnvironment('SOCKS_PORT', defaultValue: 9050)),
        ],
          onBadCertificate: (final X509Certificate certificate) => true,
        );
        _onionClient = IOClient(base);
        _onionClientAddress = rootAddress;
      }
      ioClient = _onionClient!;
    } else {
      // Nominal path (clearnet HTTPS) — a fresh client per call.
      //
      // DEV over a REAL domain with a REAL cert (--dart-define=HTTPS_CA=/path/to/rootCA.pem):
      // actually VALIDATE the server certificate against the given CA (e.g. the local mkcert root
      // that signs https://theory7.weersurf.nl). No blind trust — a wrong/expired/missing cert then
      // fails the TLS handshake, so the `https` transport genuinely exercises certificate validation.
      const String httpsCa = String.fromEnvironment('HTTPS_CA', defaultValue: '');
      final HttpClient baseHttpClient;
      if (httpsCa.isNotEmpty) {
        // withTrustedRoots:FALSE — trust ONLY this CA, not the OS/built-in roots. (On Linux the
        // built-in roots also consult the system store, where a mkcert CA is installed, so
        // withTrustedRoots:true would accept the cert even against a wrong --dart-define=HTTPS_CA,
        // defeating the check. false makes it strict: a cert not signed by exactly this CA fails.)
        final SecurityContext ctx = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(httpsCa);
        baseHttpClient = HttpClient(context: ctx);
      } else {
        // DEV self-signed fallback (--dart-define=HTTPS_DOMAIN without HTTPS_CA): trust it.
        // `server_installation_repository` sets `verifyCertificate = !isOnion` when it loads a saved
        // server, flipping to TRUE for a clearnet dev domain AFTER boot — so early queries succeed
        // (cert trusted) but later mutations/apply would fail with CERTIFICATE_VERIFY_FAILED. When
        // built with the compile-time HTTPS_DOMAIN dev define we always trust the self-signed cert
        // (dev-only; production builds carry no such define).
        const bool devHttps = bool.hasEnvironment('HTTPS_DOMAIN');
        baseHttpClient = HttpClient();
        if (devHttps || TlsOptions.stagingAcme || !TlsOptions.verifyCertificate) {
          baseHttpClient.badCertificateCallback =
              (final X509Certificate cert, final String host, final int port) =>
                  true;
        }
      }
      ioClient = IOClient(baseHttpClient);
    }

    // Clearnet normally targets api.<domain>. DEV (--dart-define=HTTPS_APEX=1) targets the domain
    // as-is (no `api.` prefix) — used for a trusted local reverse-proxy name like theory7.weersurf.nl.
    const bool httpsApex = bool.hasEnvironment('HTTPS_APEX');
    final String clearHost = httpsApex ? (rootAddress ?? '') : 'api.$rootAddress';
    final String httpUri =
        isOnion ? 'https://$rootAddress/graphql' : 'https://$clearHost/graphql';
    final httpLink = HttpLink(
      httpUri,
      httpClient: ioClient,
      parser: ResponseLoggingParser(),
      defaultHeaders: {'Accept-Language': _locale},
    );

    // Onion circuits are slow/flaky when cold; retry transient network failures
    // so a warmed-up retry succeeds. The nominal path gets NO retry link —
    // identical behaviour to before.
    final Link transport =
        isOnion ? _OnionRetryLink().concat(httpLink) : httpLink;

    final Link graphQLLink = RequestLoggingLink().concat(
      isWithToken
          ? AuthLink(
              getToken: () => customToken == '' ? 'Bearer $_token' : customToken,
            ).concat(transport)
          : transport,
    );

    // Every request goes through either chain:
    // 1. RequestLoggingLink -> AuthLink -> [_OnionRetryLink ->] HttpLink
    // 2. RequestLoggingLink -> [_OnionRetryLink ->] HttpLink

    return GraphQLClient(
      cache: GraphQLCache(),
      link: graphQLLink,
      // Onion (Tor) circuits routinely take 5-15s to build on a cold start. The
      // graphql default queryRequestTimeout is only 5s, so the very first request
      // (getApiVersion in ApiConnectionRepository.init) would time out with
      // "TimeoutException after 5s: No stream event" and drop the whole app to
      // "offline" — no services, endless loading — until a lucky warm retry.
      // Give onion requests real headroom; clearnet keeps the 5s default so the
      // nominal (non-Tor) path is unchanged.
      queryRequestTimeout:
          isOnion ? const Duration(seconds: 30) : const Duration(seconds: 5),
    );
  }

  Future<GraphQLClient> getSubscriptionClient({
    final Future<Duration?>? Function(int?, String?)? onConnectionLost,
  }) async {
    final bool isOnion = (rootAddress ?? '').endsWith('.onion');
    // Note: WebSocket over Tor may be unreliable; higher layer may fall back to polling.
    const bool httpsApex = bool.hasEnvironment('HTTPS_APEX');
    final String clearHost = httpsApex ? (rootAddress ?? '') : 'api.$rootAddress';
    // Clearnet subscriptions MUST use wss:// (TLS on :443). Plain ws:// targets :80,
    // which SelfPrivacy backends don't serve (only :443) — the socket never connects,
    // autoReconnect spins, and job/log tabs hang. Onion already uses wss://.
    final String wsUri =
        isOnion ? 'wss://$rootAddress/graphql' : 'wss://$clearHost/graphql';
    final WebSocketLink webSocketLink = WebSocketLink(
      wsUri,
      // Only [GraphQLProtocol.graphqlTransportWs] supports automatic pings, so we don't disconnect when nothing happens.
      subProtocol: GraphQLProtocol.graphqlTransportWs,
      config: SocketClientConfig(
        onConnectionLost: onConnectionLost,
        autoReconnect: true,
        initialPayload:
            _token.isEmpty ? null : {'Authorization': 'Bearer $_token'},
        headers: _token.isEmpty
            ? null
            : {
                'Authorization': 'Bearer $_token',
                'Accept-Language': _locale,
              },
      ),
    );

    return GraphQLClient(cache: GraphQLCache(), link: webSocketLink);
  }

  String get _locale => getIt.get<ApiConfigModel>().localeCode;

  String get _token {
    String token = '';
    final serverDetails = getIt<ResourcesModel>().serverDetails;
    if (serverDetails != null) {
      token = serverDetails.apiToken;
    }

    return token;
  }

  abstract final String? rootAddress;
  abstract final bool hasLogger;
  abstract final bool isWithToken;
  abstract final String customToken;
}

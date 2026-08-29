import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:selfprivacy/config/get_it_config.dart';
import 'package:selfprivacy/logic/models/console_log.dart';
import 'package:selfprivacy/utils/app_logger.dart';
import 'package:socks5_proxy/socks_client.dart';

abstract class RestApiMap {
  static final logger = const AppLogger(name: 'rest_api_map').log;

  Future<Dio> getClient({final BaseOptions? customOptions}) async {
    final Dio dio = Dio(customOptions ?? (await options));
    dio.interceptors.add(ConsoleInterceptor());
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final bool isOnion = rootAddress.endsWith('.onion');
        final HttpClient client = HttpClient();
        client.badCertificateCallback = (
          final X509Certificate cert,
          final String host,
          final int port,
        ) => true;
        if (isOnion) {
          // Use SOCKS5 proxy for .onion domains
          // Linux: Tor daemon on 9050
          // Android: Orbot on 9050
          SocksTCPClient.assignToHttpClientWithSecureOptions(client, [
            ProxySettings(InternetAddress.loopbackIPv4,
                const int.fromEnvironment('SOCKS_PORT', defaultValue: 9050)),
          ],
            onBadCertificate: (final X509Certificate certificate) => true,
          );
        }
        return client;
      },
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (
          final DioException exception,
          final ErrorInterceptorHandler handler,
        ) {
          logger('got dio exception:', error: exception);

          return handler.next(exception);
        },
      ),
    );
    return dio;
  }

  FutureOr<BaseOptions> get options;

  String get rootAddress;

  abstract final bool hasLogger;
  abstract final bool isWithToken;

  ValidateStatus? validateStatus;

  void close(final Dio client) {
    client.close();
    validateStatus = null;
  }
}

class ConsoleInterceptor extends InterceptorsWrapper {
  void addConsoleLog(final ConsoleLog message) {
    getIt.get<ConsoleModel>().log(message);
  }

  @override
  Future<void> onRequest(
    final RequestOptions options,
    final RequestInterceptorHandler handler,
  ) async {
    addConsoleLog(
      RestApiRequestConsoleLog(
        uri: options.uri,
        method: options.method,
        headers: options.headers,
        data: jsonEncode(options.data),
      ),
    );
    return super.onRequest(options, handler);
  }

  @override
  Future<void> onResponse(
    final Response response,
    final ResponseInterceptorHandler handler,
  ) async {
    addConsoleLog(
      RestApiResponseConsoleLog(
        uri: response.realUri,
        method: response.requestOptions.method,
        statusCode: response.statusCode,
        data: jsonEncode(response.data),
      ),
    );
    return super.onResponse(response, handler);
  }

  @override
  Future<void> onError(
    final DioException err,
    final ErrorInterceptorHandler handler,
  ) async {
    final Response? response = err.response;

    String responseEncoded = '';
    try {
      responseEncoded = jsonEncode(response);
    } catch (e) {
      responseEncoded = response?.statusMessage ?? responseEncoded;
    }

    addConsoleLog(
      ManualConsoleLog.warning(
        customTitle: 'RestAPI error',
        content:
            '"uri": "${response?.realUri}",\n'
            '"status_code": ${response?.statusCode},\n'
            '"response": $responseEncoded',
      ),
    );
    return super.onError(err, handler);
  }
}

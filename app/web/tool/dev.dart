import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 39241 : int.parse(args.first);
  final output = Directory('build/web')..createSync(recursive: true);
  Future<bool> compile() async {
    stdout.writeln('Compiling Jaspr client...');
    final process = await Process.start(Platform.resolvedExecutable, [
      '--suppress-analytics',
      'compile',
      'js',
      '-O1',
      'web/main.dart',
      '-o',
      '${output.path}/main.dart.js',
    ]);
    await Future.wait([
      stdout.addStream(process.stdout),
      stderr.addStream(process.stderr),
    ]);
    return await process.exitCode == 0;
  }

  if (!await compile()) exit(1);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('sky_ui Local: http://127.0.0.1:$port');
  stdout.writeln(
    'Press Ctrl+C to stop. Dart source changes trigger a rebuild; refresh the browser afterwards.',
  );
  var compiling = false;
  Timer? debounce;
  final watchers = <StreamSubscription<FileSystemEvent>>[];
  for (final path in ['lib', 'web', '../shared/lib']) {
    watchers.add(
      Directory(path).watch(recursive: true).listen((event) {
        if (!event.path.endsWith('.dart')) return;
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 500), () async {
          if (compiling) return;
          compiling = true;
          await compile();
          compiling = false;
        });
      }),
    );
  }
  server.listen((request) async {
    try {
      final route = request.uri.path;
      if (route.startsWith('/api/') || route.startsWith('/s/')) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 2);
        client.findProxy = (_) => 'DIRECT';
        try {
          final forwarded = await client.openUrl(
            request.method,
            Uri.parse('http://127.0.0.1:39242${request.uri}'),
          );
          forwarded.followRedirects = false;
          for (final name in [
            'content-type',
            'origin',
            'sec-fetch-site',
            'cookie',
            'x-sky-ui-csrf',
            'user-agent',
          ]) {
            final value = request.headers.value(name);
            if (value != null) forwarded.headers.set(name, value);
          }
          await forwarded.addStream(request);
          final response = await forwarded.close().timeout(
            const Duration(seconds: 95),
          );
          request.response.statusCode = response.statusCode;
          response.headers.forEach((name, values) {
            if (![
              'connection',
              'transfer-encoding',
              'content-length',
            ].contains(name))
              request.response.headers.set(name, values);
          });
          if (response.headers.contentType?.mimeType == 'text/event-stream')
            request.response.bufferOutput = false;
          await request.response.addStream(response);
        } on Object {
          request.response.statusCode = HttpStatus.badGateway;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'error': {'code': 'api_unavailable'},
            }),
          );
        } finally {
          client.close(force: true);
          await request.response.close();
        }
        return;
      }
      final file = switch (route) {
        '/' || '/index.html' => File('web/index.html'),
        '/styles.css' => File('web/styles.css'),
        '/fonts/PxPlus_IBM_VGA8.ttf' => File('web/fonts/PxPlus_IBM_VGA8.ttf'),
        '/fonts/LICENSE-IBM-VGA.txt' => File('web/fonts/LICENSE-IBM-VGA.txt'),
        '/fonts/ATTRIBUTION.txt' => File('web/fonts/ATTRIBUTION.txt'),
        '/main.dart.js' => File('${output.path}/main.dart.js'),
        '/main.dart.js.map' => File('${output.path}/main.dart.js.map'),
        _ => null,
      };
      if (file == null || !await file.exists()) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.headers.set(
          HttpHeaders.cacheControlHeader,
          'no-store',
        );
        request.response.headers.contentType = route.endsWith('.ttf')
            ? ContentType('font', 'ttf')
            : route.endsWith('.txt')
            ? ContentType.text
            : route.endsWith('.css')
            ? ContentType('text', 'css', charset: 'utf-8')
            : route.endsWith('.js')
            ? ContentType('application', 'javascript', charset: 'utf-8')
            : route.endsWith('.map')
            ? ContentType.json
            : ContentType.html;
        await request.response.addStream(file.openRead());
      }
      await request.response.close();
    } catch (error) {
      stderr.writeln(error);
      await request.response.close();
    }
  });
}

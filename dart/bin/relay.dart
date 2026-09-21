import 'dart:async';
import 'dart:io';

import 'package:namida_party_relay/namida_party_relay.dart';

const String _usage = '''
namida party relay

usage: relay [options]

  --port <n>             listen port (env PORT, default 8787)
  --host <addr>          bind address (env HOST, default 0.0.0.0)
  --create-password <s>  require this password to create rooms (env CREATE_PASSWORD)
  --max-members <n>      members per room (env MAX_MEMBERS, default 100)
  --max-rooms <n>        open rooms on this relay (env MAX_ROOMS, default unlimited)
  --trust-proxy          read the client ip from X-Forwarded-For / CF-Connecting-IP (env TRUST_PROXY_HEADERS)
  --no-directory         stop serving GET /v1/rooms, public rooms are not browsable (env DIRECTORY=false)
  -h, --help             this text

timers can be overridden for tests: HOST_GRACE_MS, PENDING_TIMEOUT_MS, JOIN_TIMEOUT_MS, IDLE_TIMEOUT_MS,
ROOM_LIFETIME_MS, RATE_DROP_CLOSE, DIRECTORY_REFRESH_MS, DIRECTORY_TTL_MS, LIST_LIMIT, LIST_WINDOW_MS.
''';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final flags = <String, String>{};
  final booleans = <String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--') && arg != '-h') {
      stderr.writeln('unexpected argument: $arg');
      exitCode = 64;
      return;
    }
    if (arg == '-h' || arg == '--help') {
      stdout.write(_usage);
      return;
    }
    final equals = arg.indexOf('=');
    if (equals > 0) {
      flags[arg.substring(2, equals)] = arg.substring(equals + 1);
    } else if (arg == '--trust-proxy' || arg == '--no-directory') {
      booleans.add(arg.substring(2));
    } else if (i + 1 < args.length) {
      flags[arg.substring(2)] = args[++i];
    } else {
      stderr.writeln('missing value for $arg');
      exitCode = 64;
      return;
    }
  }

  var config = PartyRelayConfig.fromEnvironment(env);
  final createPassword = flags['create-password'];
  final maxMembers = int.tryParse(flags['max-members'] ?? '');
  final maxRooms = int.tryParse(flags['max-rooms'] ?? '');
  config = config.copyWith(
    createPassword: createPassword != null && createPassword.isNotEmpty ? createPassword : null,
    maxMembers: maxMembers != null && maxMembers > 0 ? maxMembers : null,
    maxRoomsTotal: maxRooms != null && maxRooms > 0 ? maxRooms : null,
    trustProxyHeaders: booleans.contains('trust-proxy') ? true : null,
    directoryEnabled: booleans.contains('no-directory') ? false : null,
  );

  final host = flags['host'] ?? env['HOST'] ?? '0.0.0.0';
  final port = int.tryParse(flags['port'] ?? env['PORT'] ?? '') ?? 8787;

  final PartyRelayServer server;
  try {
    server = await PartyRelayServer.start(address: host, port: port, config: config);
  } catch (e) {
    stderr.writeln('failed to bind $host:$port -> $e');
    exitCode = 70;
    return;
  }

  stdout.writeln('namida party relay listening on http://$host:${server.port} (max ${config.maxMembers} members/room, '
      'rooms ${config.maxRoomsTotal ?? 'unlimited'}, create password ${config.createPassword != null}, directory ${config.directoryEnabled})');

  final done = Completer<void>();
  void stop(ProcessSignal _) {
    if (!done.isCompleted) done.complete();
  }

  ProcessSignal.sigint.watch().listen(stop);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(stop);
  await done.future;
  await server.close();
}

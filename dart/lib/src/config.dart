/// every tunable of the relay. all durations are configurable so tests can use tiny values.
class PartyRelayConfig {
  const PartyRelayConfig({
    this.hostGrace = const Duration(seconds: 60),
    this.pendingTimeout = const Duration(seconds: 120),
    this.joinTimeout = const Duration(seconds: 10),
    this.idleTimeout = const Duration(minutes: 10),
    this.roomLifetime = const Duration(hours: 24),
    this.maxMembers = 100,
    this.maxRoomsTotal,
    this.createPassword,
    this.maxTextFrameBytes = 2 * 1024,
    this.maxGuestFrameBytes = 16 * 1024,
    this.maxHostFrameBytes = 1024 * 1024,
    this.maxCreateBodyBytes = 4 * 1024,
    this.guestBurst = 40,
    this.guestRefillPerSecond = 4,
    this.hostBurst = 400,
    this.hostRefillPerSecond = 60,
    this.rateDropClose = 200,
    this.rateDropWindow = const Duration(minutes: 1),
    this.rateErrorInterval = const Duration(seconds: 1),
    this.createLimit = 10,
    this.createWindow = const Duration(minutes: 10),
    this.joinLimit = 20,
    this.joinWindow = const Duration(minutes: 1),
    this.maxPendingPerRoom = 20,
    this.maxBansPerRoom = 500,
    this.maxRetainedMembers = 200,
    this.maxSuccessors = 32,
    this.trustProxyHeaders = false,
    this.pruneInterval = const Duration(minutes: 5),
  });

  /// how long a dropped host may resume with its token before someone else is promoted.
  final Duration hostGrace;

  /// how long a join awaiting approval stays pending.
  final Duration pendingTimeout;

  /// how long a fresh socket has to send its `join` frame.
  final Duration joinTimeout;

  /// room is closed with `idle` after this long without any connected member.
  final Duration idleTimeout;

  /// room is closed with `expired` this long after creation.
  final Duration roomLifetime;

  final int maxMembers;

  /// null = unlimited.
  final int? maxRoomsTotal;

  /// when set, `POST /v1/rooms` needs `auth: {"kind":"password","password":"..."}`.
  final String? createPassword;

  final int maxTextFrameBytes;
  final int maxGuestFrameBytes;
  final int maxHostFrameBytes;
  final int maxCreateBodyBytes;

  final int guestBurst;
  final double guestRefillPerSecond;
  final int hostBurst;
  final double hostRefillPerSecond;

  /// dropped frames within [rateDropWindow] that close the socket with a fatal `rate_limited`.
  final int rateDropClose;
  final Duration rateDropWindow;

  /// at most one non fatal `rate_limited` per this interval.
  final Duration rateErrorInterval;

  final int createLimit;
  final Duration createWindow;
  final int joinLimit;
  final Duration joinWindow;

  final int maxPendingPerRoom;
  final int maxBansPerRoom;

  /// disconnected members kept around for token resume, oldest are dropped past this.
  final int maxRetainedMembers;
  final int maxSuccessors;

  /// read the client ip from `X-Forwarded-For` / `CF-Connecting-IP` instead of the socket.
  final bool trustProxyHeaders;

  final Duration pruneInterval;

  /// membership proofs are not implemented by the dart relay.
  bool get membership => false;

  String get tier => 'selfhost';

  /// env overrides, used by `bin/relay.dart` and by conformance targets.
  factory PartyRelayConfig.fromEnvironment([Map<String, String>? environment]) {
    final env = environment ?? const <String, String>{};
    Duration ms(String key, Duration fallback) {
      final v = int.tryParse(env[key] ?? '');
      return v == null || v < 0 ? fallback : Duration(milliseconds: v);
    }

    int count(String key, int fallback) => int.tryParse(env[key] ?? '') ?? fallback;

    const def = PartyRelayConfig();
    final password = env['CREATE_PASSWORD'];
    final maxRooms = int.tryParse(env['MAX_ROOMS'] ?? '');
    return PartyRelayConfig(
      hostGrace: ms('HOST_GRACE_MS', def.hostGrace),
      pendingTimeout: ms('PENDING_TIMEOUT_MS', def.pendingTimeout),
      joinTimeout: ms('JOIN_TIMEOUT_MS', def.joinTimeout),
      idleTimeout: ms('IDLE_TIMEOUT_MS', def.idleTimeout),
      roomLifetime: ms('ROOM_LIFETIME_MS', def.roomLifetime),
      maxMembers: count('MAX_MEMBERS', def.maxMembers),
      maxRoomsTotal: maxRooms != null && maxRooms > 0 ? maxRooms : null,
      createPassword: password != null && password.isNotEmpty ? password : null,
      createLimit: count('CREATE_LIMIT', def.createLimit),
      joinLimit: count('JOIN_LIMIT', def.joinLimit),
      rateDropClose: count('RATE_DROP_CLOSE', def.rateDropClose),
      trustProxyHeaders: env['TRUST_PROXY_HEADERS'] == 'true' || env['TRUST_PROXY_HEADERS'] == '1',
    );
  }

  /// null keeps the current value.
  PartyRelayConfig copyWith({
    Duration? hostGrace,
    Duration? pendingTimeout,
    Duration? joinTimeout,
    Duration? idleTimeout,
    Duration? roomLifetime,
    int? maxMembers,
    int? maxRoomsTotal,
    String? createPassword,
    int? maxTextFrameBytes,
    int? maxGuestFrameBytes,
    int? maxHostFrameBytes,
    int? maxCreateBodyBytes,
    int? guestBurst,
    double? guestRefillPerSecond,
    int? hostBurst,
    double? hostRefillPerSecond,
    int? rateDropClose,
    Duration? rateDropWindow,
    Duration? rateErrorInterval,
    int? createLimit,
    Duration? createWindow,
    int? joinLimit,
    Duration? joinWindow,
    int? maxPendingPerRoom,
    int? maxBansPerRoom,
    int? maxRetainedMembers,
    int? maxSuccessors,
    bool? trustProxyHeaders,
    Duration? pruneInterval,
  }) {
    return PartyRelayConfig(
      hostGrace: hostGrace ?? this.hostGrace,
      pendingTimeout: pendingTimeout ?? this.pendingTimeout,
      joinTimeout: joinTimeout ?? this.joinTimeout,
      idleTimeout: idleTimeout ?? this.idleTimeout,
      roomLifetime: roomLifetime ?? this.roomLifetime,
      maxMembers: maxMembers ?? this.maxMembers,
      maxRoomsTotal: maxRoomsTotal ?? this.maxRoomsTotal,
      createPassword: createPassword ?? this.createPassword,
      maxTextFrameBytes: maxTextFrameBytes ?? this.maxTextFrameBytes,
      maxGuestFrameBytes: maxGuestFrameBytes ?? this.maxGuestFrameBytes,
      maxHostFrameBytes: maxHostFrameBytes ?? this.maxHostFrameBytes,
      maxCreateBodyBytes: maxCreateBodyBytes ?? this.maxCreateBodyBytes,
      guestBurst: guestBurst ?? this.guestBurst,
      guestRefillPerSecond: guestRefillPerSecond ?? this.guestRefillPerSecond,
      hostBurst: hostBurst ?? this.hostBurst,
      hostRefillPerSecond: hostRefillPerSecond ?? this.hostRefillPerSecond,
      rateDropClose: rateDropClose ?? this.rateDropClose,
      rateDropWindow: rateDropWindow ?? this.rateDropWindow,
      rateErrorInterval: rateErrorInterval ?? this.rateErrorInterval,
      createLimit: createLimit ?? this.createLimit,
      createWindow: createWindow ?? this.createWindow,
      joinLimit: joinLimit ?? this.joinLimit,
      joinWindow: joinWindow ?? this.joinWindow,
      maxPendingPerRoom: maxPendingPerRoom ?? this.maxPendingPerRoom,
      maxBansPerRoom: maxBansPerRoom ?? this.maxBansPerRoom,
      maxRetainedMembers: maxRetainedMembers ?? this.maxRetainedMembers,
      maxSuccessors: maxSuccessors ?? this.maxSuccessors,
      trustProxyHeaders: trustProxyHeaders ?? this.trustProxyHeaders,
      pruneInterval: pruneInterval ?? this.pruneInterval,
    );
  }
}

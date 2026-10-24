import 'dart:convert';
import 'dart:io';

import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'conformance/harness.dart';

void main() {
  test('programmatic createRoom hosts a room without http', () async {
    final relay = await RelayTarget.start(local: true);
    addTearDown(relay.dispose);
    final created = relay.server!.createRoom(name: '  in app host  ', did: 'device-1', approval: true, maxMembers: 3);
    expect(normalizeRoomCode(created.code), created.code);
    expect(created.token, isNotEmpty);
    expect(created.max, 3);
    expect(created.tier, RelayTier.selfhost);

    final host = await relay.join(created.code, name: 'in app host', token: created.token);
    expect(host.n, 1);
    expect(host.welcome!['host'], 1);
    expect(host.welcome!['max'], 3);
    expect(host.welcome!['opts'], {'approval': true, 'password': false, 'locked': false, 'public': false});

    expect(() => relay.server!.createRoom(name: '', did: 'd'), throwsArgumentError);
    expect(() => relay.server!.createRoom(name: 'ok', did: ''), throwsArgumentError);
    expect(() => relay.server!.createRoom(name: 'ok', did: 'd', pv: 0), throwsArgumentError);
    expect(() => relay.server!.createRoom(name: 'ok', did: 'd', password: ''), throwsArgumentError);
  });

  test('create password gates http creation', () async {
    final relay = await RelayTarget.start(config: const PartyRelayConfig(createPassword: 'let-me-in'), local: true);
    addTearDown(relay.dispose);

    expect((await relay.getInfo()).body['createPassword'], true);
    expect((await relay.getInfo()).body['membership'], false);

    Map<String, Object?> body(Object? auth) => {'pv': 1, 'name': 'host', 'did': 'd', if (auth != null) 'auth': auth};

    var result = await relay.postRoom(body(null));
    expect(result.status, 401);
    expect(result.error, RelayErrors.membershipRequired);

    result = await relay.postRoom(body({'kind': AuthKind.patreon, 'token': 'whatever'}));
    expect(result.status, 401);
    expect(result.error, RelayErrors.membershipRequired);

    result = await relay.postRoom(body({'kind': AuthKind.password, 'password': 'nope'}));
    expect(result.status, 403);
    expect(result.error, RelayErrors.badPassword);

    result = await relay.postRoom(body({'kind': AuthKind.password, 'password': 'let-me-in'}));
    expect(result.status, 200);
    expect(result.body['tier'], RelayTier.selfhost);
  });

  test('membership auth kinds are ignored when no password is set', () async {
    final relay = await RelayTarget.start(local: true);
    addTearDown(relay.dispose);
    final auth = {'kind': AuthKind.supabase, 'id': 'x', 'email': 'y'};
    final result = await relay.postRoom({'pv': 1, 'name': 'host', 'did': 'd', 'auth': auth});
    expect(result.status, 200);
  });

  test('the total rooms cap is enforced', () async {
    final relay = await RelayTarget.start(config: const PartyRelayConfig(maxRoomsTotal: 2), local: true);
    addTearDown(relay.dispose);
    await relay.createRoom();
    await relay.createRoom();
    final result = await relay.postRoom({'pv': 1, 'name': 'host', 'did': 'd'});
    expect(result.status, 429);
    expect(result.error, RelayErrors.roomsLimit);
    expect(() => relay.server!.createRoom(name: 'host', did: 'd'), throwsStateError);
  });

  test('create is rate limited per ip', () async {
    final relay = await RelayTarget.start(config: const PartyRelayConfig(createLimit: 3), local: true);
    addTearDown(relay.dispose);
    for (var i = 0; i < 3; i++) {
      expect((await relay.postRoom({'pv': 1, 'name': 'host', 'did': 'd'})).status, 200);
    }
    final result = await relay.postRoom({'pv': 1, 'name': 'host', 'did': 'd'});
    expect(result.status, 429);
    expect(result.error, RelayErrors.rateLimited);
  });

  test('a trusted proxy ip is the last forwarded entry, else cloudflare', () async {
    final relay = await RelayTarget.start(config: const PartyRelayConfig(createLimit: 1, trustProxyHeaders: true), local: true);
    addTearDown(relay.dispose);
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    Future<int> createFrom(Map<String, String> headers) async {
      final req = await http.postUrl(relay.base.replace(path: '/v1/rooms'));
      for (final header in headers.entries) {
        req.headers.set(header.key, header.value);
      }
      req.write(jsonEncode({'pv': 1, 'name': 'host', 'did': 'd'}));
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }

    expect(await createFrom({'x-forwarded-for': '1.1.1.1, 10.0.0.1'}), 200);
    expect(await createFrom({'x-forwarded-for': '2.2.2.2, 10.0.0.1'}), 429, reason: 'the client written entry must not pick the ip');
    expect(await createFrom({'cf-connecting-ip': '1.1.1.1', 'x-forwarded-for': '10.0.0.3'}), 200, reason: 'a client written cloudflare header must not pick the ip');
    expect(await createFrom({'x-forwarded-for': '10.0.0.3'}), 429);
    expect(await createFrom({'cf-connecting-ip': '10.0.0.4'}), 200);
    expect(await createFrom({'cf-connecting-ip': '10.0.0.4'}), 429);
  });

  test('join is rate limited per ip', () async {
    final relay = await RelayTarget.start(config: const PartyRelayConfig(joinLimit: 2), local: true);
    addTearDown(relay.dispose);
    final room = await relay.createRoom();
    await relay.join(room.code, name: 'host', token: room.token);
    await relay.join(room.code, name: 'a');
    final third = await relay.connect(room.code);
    third.send({'t': Ctrl.join, 'pv': 1, 'name': 'c', 'did': 'did-c'});
    await third.expectFatal(RelayErrors.rateLimited);
  });

  test('programmatic rooms can be public', () async {
    final relay = await RelayTarget.start(local: true);
    addTearDown(relay.dispose);
    final created = relay.server!.createRoom(name: 'in app host', did: 'device-1', public: true);
    final host = await relay.join(created.code, name: 'in app host', token: created.token);
    expect((host.welcome!['opts'] as Map<String, dynamic>)['public'], true);

    host.send({'t': Ctrl.summary, 'name': 'lan party'});
    await host.roundTrip();
    final entry = (await relay.getRooms()).find(created.code);
    expect(entry, isNotNull);
    expect(entry!['name'], 'lan party');
    expect(entry['members'], 1);
  });

  test('a hid secret keeps creator ids across restarts', () async {
    Future<String> hidOn(PartyRelayConfig config) async {
      final relay = await RelayTarget.start(config: config, local: true);
      addTearDown(relay.dispose);
      final created = relay.server!.createRoom(name: 'host', did: 'did-creator', public: true);
      final host = await relay.join(created.code, name: 'host', token: created.token);
      host.send({'t': Ctrl.summary, 'name': 'party'});
      await host.roundTrip();
      final entry = (await relay.getRooms()).find(created.code);
      return entry!['hid'] as String;
    }

    final keyed = conformanceConfig().copyWith(hidSecret: 'stable');
    final hid = await hidOn(keyed);
    expect(await hidOn(keyed), hid, reason: 'same secret, same id after a restart');
    expect(await hidOn(conformanceConfig()), isNot(hid), reason: 'no secret, a random key per start');
    expect(PartyRelayConfig.fromEnvironment(const {'HID_SECRET': 'stable'}).hidSecret, 'stable');
    expect(PartyRelayConfig.fromEnvironment(const {'HID_SECRET': ''}).hidSecret, isNull);
  });

  test('a directory entry refreshes at most once per interval', () async {
    final relay = await RelayTarget.start(config: conformanceConfig().copyWith(directoryRefreshInterval: const Duration(milliseconds: 400)), local: true);
    addTearDown(relay.dispose);
    final room = await relay.createRoom(public: true);
    final host = await relay.join(room.code, name: 'host', token: room.token);
    host.send({'t': Ctrl.summary, 'name': 'one'});
    await host.roundTrip();

    var entry = (await relay.getRooms()).find(room.code);
    expect(entry, isNotNull);
    expect(entry!['members'], 1);
    final firstAt = entry['at'] as int;

    await relay.join(room.code, name: 'guest');
    host.send({'t': Ctrl.summary, 'name': 'two'});
    await host.roundTrip();
    entry = (await relay.getRooms()).find(room.code);
    expect(entry!['name'], 'one', reason: 'still the throttled snapshot');
    expect(entry['members'], 1);
    expect(entry['at'], firstAt);

    await Future<void>.delayed(const Duration(milliseconds: 450));
    entry = (await relay.getRooms()).find(room.code);
    expect(entry!['name'], 'two');
    expect(entry['members'], 2);
    expect(entry['at'], greaterThan(firstAt));
  });

  test('a directory entry expires when it stops being refreshed', () async {
    final config = conformanceConfig().copyWith(directoryRefreshInterval: const Duration(seconds: 10), directoryEntryTtl: const Duration(milliseconds: 200));
    final relay = await RelayTarget.start(config: config, local: true);
    addTearDown(relay.dispose);
    final room = await relay.createRoom(public: true);
    final host = await relay.join(room.code, name: 'host', token: room.token);
    host.send({'t': Ctrl.summary, 'name': 'ghost'});
    await host.roundTrip();
    expect((await relay.getRooms()).find(room.code), isNotNull);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect((await relay.getRooms()).find(room.code), isNull, reason: 'the entry went stale');
  });

  test('the listing is rate limited per ip', () async {
    final relay = await RelayTarget.start(config: const PartyRelayConfig(listLimit: 2), local: true);
    addTearDown(relay.dispose);
    expect((await relay.getRoomsRaw()).status, 200);
    expect((await relay.getRoomsRaw()).status, 200);
    final result = await relay.getRoomsRaw();
    expect(result.status, 429);
    expect(result.error, RelayErrors.rateLimited);
  });

  test('the directory is configured from the environment', () {
    final config =
        PartyRelayConfig.fromEnvironment(const {'DIRECTORY': 'false', 'DIRECTORY_REFRESH_MS': '250', 'DIRECTORY_TTL_MS': '1000', 'LIST_LIMIT': '7', 'LIST_WINDOW_MS': '5000'});
    expect(config.directoryEnabled, false);
    expect(config.directoryRefreshInterval, const Duration(milliseconds: 250));
    expect(config.directoryEntryTtl, const Duration(seconds: 1));
    expect(config.listLimit, 7);
    expect(config.listWindow, const Duration(seconds: 5));
    expect(PartyRelayConfig.fromEnvironment(const {}).directoryEnabled, true);
    expect(PartyRelayConfig.fromEnvironment(const {'DIRECTORY': '0'}).directoryEnabled, false);
  });
}

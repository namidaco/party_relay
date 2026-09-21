import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

import 'harness.dart';

final RegExp _hid = RegExp(r'^[0-9a-f]{8}$');

void main() {
  late RelayTarget relay;

  setUpAll(() async => relay = await RelayTarget.start());
  tearDownAll(() async => relay.dispose());

  /// every page, so a room is found whatever else the relay is holding.
  Future<List<Map<String, dynamic>>> allRooms() async {
    final all = <Map<String, dynamic>>[];
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final listing = await relay.getRooms(limit: 50, after: cursor);
      expect(listing.status, 200, reason: 'listing failed');
      all.addAll(listing.rooms);
      cursor = listing.next;
      if (cursor == null) break;
    }
    return all;
  }

  Future<Map<String, dynamic>?> entryOf(String code) async {
    for (final room in await allRooms()) {
      if (room['code'] == code) return room;
    }
    return null;
  }

  // -- a relay may publish its entries asynchronously, so changes are waited for instead of asserted at once
  Future<Map<String, dynamic>?> waitEntry(String code, bool Function(Map<String, dynamic>? entry) ready, {String reason = ''}) async {
    Map<String, dynamic>? entry;
    for (var attempt = 0; attempt < 20; attempt++) {
      entry = await entryOf(code);
      if (ready(entry)) return entry;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('directory never settled for $code ($reason), last entry: $entry');
  }

  Future<(CreatedRoom, TestClient)> publicRoom({String name = 'chill', String? did, bool approval = false, String? password, bool public = true}) async {
    final room = await relay.createRoom(did: did, approval: approval, password: password, public: public);
    final host = await relay.join(room.code, name: 'host', token: room.token);
    host.send({'t': Ctrl.summary, 'name': name});
    await host.roundTrip();
    return (room, host);
  }

  test('info advertises the directory', () async {
    final result = await relay.getInfo();
    expect(result.status, 200);
    expect(result.body['directory'], true);
  });

  test('a room shows up only once it is public and summarised', () async {
    final room = await relay.createRoom();
    final host = await relay.join(room.code, name: 'host', token: room.token);
    expect((host.welcome!['opts'] as Map<String, dynamic>)['public'], false);
    expect(await entryOf(room.code), isNull, reason: 'private and unsummarised');

    host.send({'t': Ctrl.summary, 'name': 'chill'});
    await host.roundTrip();
    expect(await entryOf(room.code), isNull, reason: 'summarised but private');

    host.send({'t': Ctrl.opts, 'public': true});
    expect((await host.expectFrame(Ctrl.opts))['public'], true);
    final entry = await waitEntry(room.code, (e) => e != null, reason: 'public');
    expect(entry!['name'], 'chill');
    await host.close();
  });

  test('a public room without a summary stays invisible', () async {
    final room = await relay.createRoom(public: true);
    final host = await relay.join(room.code, name: 'host', token: room.token);
    expect((host.welcome!['opts'] as Map<String, dynamic>)['public'], true);
    expect(await entryOf(room.code), isNull);
    host.send({'t': Ctrl.summary, 'name': 'now listed'});
    await host.roundTrip();
    expect((await waitEntry(room.code, (e) => e != null))!['name'], 'now listed');
    await host.close();
  });

  test('unlisted rooms never appear', () async {
    final (hidden, hiddenHost) = await publicRoom(name: 'secret', public: false);
    expect(await entryOf(hidden.code), isNull);

    final (open, openHost) = await publicRoom(name: 'open');
    await waitEntry(open.code, (e) => e != null);
    openHost.send({'t': Ctrl.opts, 'public': false});
    expect((await openHost.expectFrame(Ctrl.opts))['public'], false);
    await waitEntry(open.code, (e) => e == null, reason: 'unlisted');
    await hiddenHost.close();
    await openHost.close();
  });

  test('summary is host only', () async {
    final (room, host) = await publicRoom(name: 'chill');
    final guest = await relay.join(room.code, name: 'guest');
    await host.expectFrame(Ctrl.joined);
    guest.send({'t': Ctrl.summary, 'name': 'hijacked'});
    await guest.expectError(RelayErrors.forbidden, fatal: false);
    final entry = await waitEntry(room.code, (e) => e?['members'] == 2, reason: 'guest joined');
    expect(entry!['name'], 'chill');
    await guest.close();
    await host.close();
  });

  test('summary validation', () async {
    final (room, host) = await publicRoom(name: 'chill');
    Future<void> rejects(Map<String, Object?> frame, String reason) async {
      host.send({'t': Ctrl.summary, ...frame});
      await host.expectError(RelayErrors.badRequest, fatal: false);
      expect(reason, isNotEmpty);
    }

    await rejects({}, 'missing name');
    await rejects({'name': null}, 'null name');
    await rejects({'name': 7}, 'name type');
    await rejects({'name': ''}, 'empty name');
    await rejects({'name': '   '}, 'blank name');
    await rejects({'name': '\u0001\u0002'}, 'control only name');
    await rejects({'name': 'x' * 49}, 'long name');
    await rejects({'name': 'ok', 'title': 't' * 81}, 'long title');
    await rejects({'name': 'ok', 'artist': 'a' * 81}, 'long artist');
    await rejects({'name': 'ok', 'title': 5}, 'title type');
    await rejects({'name': 'ok', 'artist': true}, 'artist type');
    expect((await waitEntry(room.code, (e) => e != null))!['name'], 'chill', reason: 'a rejected summary changes nothing');

    host.send({'t': Ctrl.summary, 'name': '  ne\u0001on  ', 'title': ' song \u0007', 'artist': 'a' * 80});
    await host.roundTrip();
    final entry = await waitEntry(room.code, (e) => e?['name'] == 'neon', reason: 'trimmed and stripped');
    expect(entry!['title'], 'song');
    expect(entry['artist'], 'a' * 80);

    host.send({'t': Ctrl.summary, 'name': 'n' * 48});
    await host.roundTrip();
    await waitEntry(room.code, (e) => e?['name'] == 'n' * 48, reason: '48 chars fit');
    await host.close();
  });

  test('title and artist are cleared by an empty string, null or absence', () async {
    final (room, host) = await publicRoom();
    host.send({'t': Ctrl.summary, 'name': 'chill', 'title': 'Song title', 'artist': 'Artist'});
    await host.roundTrip();
    expect((await waitEntry(room.code, (e) => e?['title'] == 'Song title'))!['artist'], 'Artist');

    host.send({'t': Ctrl.summary, 'name': 'chill', 'title': '', 'artist': null});
    await host.roundTrip();
    var entry = await waitEntry(room.code, (e) => e != null && !e.containsKey('title'), reason: 'cleared');
    expect(entry!.containsKey('artist'), isFalse);

    host.send({'t': Ctrl.summary, 'name': 'chill', 'title': 'Back'});
    await host.roundTrip();
    entry = await waitEntry(room.code, (e) => e?['title'] == 'Back');
    expect(entry!.containsKey('artist'), isFalse, reason: 'an absent field clears too, the summary is the whole snapshot');
    await host.close();
  });

  test('an entry carries the room fields', () async {
    final room = await relay.createRoom(pv: 3, approval: true, password: 'secret', public: true);
    final host = await relay.join(room.code, name: 'host', token: room.token, pv: 3);
    host.send({'t': Ctrl.summary, 'name': 'fields'});
    await host.roundTrip();
    final entry = await waitEntry(room.code, (e) => e != null);
    expect(entry!['code'], room.code);
    expect(entry['name'], 'fields');
    expect(entry['pv'], 3);
    expect(entry['max'], room.max);
    expect(entry['members'], 1);
    expect(entry['approval'], true);
    expect(entry['password'], true);
    expect(entry['hid'], matches(_hid));
    expect(entry['at'], isA<int>());
    expect(entry['at'], greaterThan(1600000000000));
    expect(entry.containsKey('title'), isFalse);
    await host.close();
  });

  test('a locked room drops out and comes back', () async {
    final (room, host) = await publicRoom(name: 'lockable');
    await waitEntry(room.code, (e) => e != null);
    host.send({'t': Ctrl.opts, 'locked': true});
    expect((await host.expectFrame(Ctrl.opts))['locked'], true);
    await waitEntry(room.code, (e) => e == null, reason: 'locked');

    host.send({'t': Ctrl.opts, 'locked': false});
    expect((await host.expectFrame(Ctrl.opts))['locked'], false);
    await waitEntry(room.code, (e) => e != null, reason: 'unlocked');
    await host.close();
  });

  test('a room with nobody connected is not listed', () async {
    final (room, host) = await publicRoom(name: 'empty');
    await waitEntry(room.code, (e) => e != null);
    await host.close();
    await waitEntry(room.code, (e) => e == null, reason: 'host gone');

    final back = await relay.join(room.code, name: 'host', token: room.token);
    final entry = await waitEntry(room.code, (e) => e != null, reason: 'host back');
    expect(entry!['name'], 'empty', reason: 'the summary outlives the host socket');
    expect(entry['members'], 1);
    await back.close();
  });

  test('order is by member count', () async {
    final (big, bigHost) = await publicRoom(name: 'big');
    final (small, smallHost) = await publicRoom(name: 'small');
    final guests = <TestClient>[];
    for (var i = 0; i < 2; i++) {
      guests.add(await relay.join(big.code, name: 'g$i'));
    }
    await waitEntry(big.code, (e) => e?['members'] == 3, reason: 'guests joined');

    final rooms = await allRooms();
    final bigIndex = rooms.indexWhere((r) => r['code'] == big.code);
    final smallIndex = rooms.indexWhere((r) => r['code'] == small.code);
    expect(bigIndex, greaterThanOrEqualTo(0));
    expect(smallIndex, greaterThan(bigIndex), reason: 'more members come first');

    for (final guest in guests) {
      await guest.close();
    }
    await bigHost.close();
    await smallHost.close();
  });

  test('limit bounds and after paging', () async {
    final hosts = <TestClient>[];
    final codes = <String>[];
    for (var i = 0; i < 3; i++) {
      final (room, host) = await publicRoom(name: 'page $i');
      codes.add(room.code);
      hosts.add(host);
      await waitEntry(room.code, (e) => e != null);
    }

    final first = await relay.getRooms(limit: 1);
    expect(first.status, 200);
    expect(first.rooms, hasLength(1));
    expect(first.next, isNotNull, reason: 'more rooms are left');

    final seen = <String>[];
    String? cursor;
    for (var page = 0; page < 60; page++) {
      final listing = await relay.getRooms(limit: 1, after: cursor);
      expect(listing.status, 200);
      expect(listing.rooms.length, lessThanOrEqualTo(1));
      for (final room in listing.rooms) {
        seen.add(room['code'] as String);
      }
      cursor = listing.next;
      if (cursor == null) break;
    }
    expect(cursor, isNull, reason: 'paging never ended');
    for (final code in codes) {
      expect(seen.where((c) => c == code), hasLength(1), reason: '$code once across pages');
    }

    for (final limit in <Object>[0, -5, 999, 'abc']) {
      final listing = await relay.getRooms(limit: limit);
      expect(listing.status, 200, reason: 'limit $limit');
      expect(listing.rooms, isNotEmpty, reason: 'limit $limit');
      expect(listing.rooms.length, lessThanOrEqualTo(50), reason: 'limit $limit');
    }

    final junk = await relay.getRooms(after: 'not-a-cursor');
    expect(junk.status, 200);

    for (final host in hosts) {
      await host.close();
    }
  });

  test('hid is per creator identity', () async {
    final (one, oneHost) = await publicRoom(name: 'one', did: 'did-creator-a');
    final (two, twoHost) = await publicRoom(name: 'two', did: 'did-creator-a');
    final (three, threeHost) = await publicRoom(name: 'three', did: 'did-creator-b');
    for (final code in [one.code, two.code, three.code]) {
      await waitEntry(code, (e) => e != null);
    }
    final rooms = await allRooms();
    String hidOf(String code) => rooms.firstWhere((r) => r['code'] == code)['hid'] as String;

    expect(hidOf(one.code), matches(_hid));
    expect(hidOf(one.code), hidOf(two.code), reason: 'same creator');
    expect(hidOf(one.code), isNot(hidOf(three.code)), reason: 'another creator');

    await oneHost.close();
    await twoHost.close();
    await threeHost.close();
  });

  test('the listing is gone when the directory is off', () async {
    final off = await RelayTarget.start(config: conformanceConfig().copyWith(directoryEnabled: false), local: true);
    addTearDown(off.dispose);
    expect((await off.getInfo()).body['directory'], false);

    var result = await off.getRoomsRaw();
    expect(result.status, 404);
    expect(result.error, RelayErrors.notFound);

    final room = await off.createRoom(public: true);
    final host = await off.join(room.code, name: 'host', token: room.token);
    host.send({'t': Ctrl.summary, 'name': 'hidden'});
    await host.roundTrip();
    result = await off.getRoomsRaw(limit: 10);
    expect(result.status, 404, reason: 'creating and summarising still work, only browsing is gone');
  });
}

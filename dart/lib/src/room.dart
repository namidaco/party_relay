import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'config.dart';
import 'directory.dart';
import 'envelope.dart';
import 'ids.dart';
import 'member.dart';

typedef RoomGone = void Function(RelayRoom room);

class RelayRoom implements DirectoryRoom {
  RelayRoom({
    required this.code,
    required this.pv,
    required this.max,
    required this.config,
    required this.onGone,
    required String hostName,
    required String hostDid,
    required String hostIp,
    required this.approval,
    required this.password,
    required this.public,
  })  : createdAtMs = DateTime.now().millisecondsSinceEpoch,
        hid = identityHid(hostDid) {
    _members[1] = RelayMember(n: 1, name: hostName, did: hostDid, ip: hostIp, token: newToken());
    hostN = 1;
    _lifeTimer = Timer(config.roomLifetime, () => closeRoom(ClosedReason.expired));
    _startGrace();
    _armIdle();
  }

  final String code;
  final int pv;
  final int max;
  final PartyRelayConfig config;
  final RoomGone onGone;
  final int createdAtMs;

  /// first 8 hex of sha-256 over the creator identity, shown in the directory.
  final String hid;

  bool approval;
  String? password;
  bool locked = false;
  bool public;
  int? hostN;
  List<int> successors = const [];

  final Map<int, RelayMember> _members = {};

  /// connected members only, so broadcasts never walk the retained ones.
  final List<RelayMember> _connected = [];
  final Map<String, PendingJoin> _pending = {};
  final List<BanEntry> _bans = [];

  String? _summaryName;
  String? _summaryTitle;
  String? _summaryArtist;
  DirectoryEntry? _entry;

  int _lastN = 1;
  bool _gone = false;
  Timer? _graceTimer;
  Timer? _idleTimer;
  Timer? _lifeTimer;

  bool get gone => _gone;
  String get hostToken => _members[1]!.token;

  RelaySocket? get _hostSock {
    final n = hostN;
    return n == null ? null : _members[n]?.sock;
  }

  bool get _hostOnline => _hostSock != null;

  int get connectedCount => _connected.length;

  void _connect(RelayMember member, RelaySocket s) {
    if (member.sock == null) _connected.add(member);
    member.sock = s;
  }

  void _disconnect(RelayMember member) {
    if (member.sock == null) return;
    member.sock = null;
    _connected.remove(member);
  }

  void join(RelaySocket s, Map<String, Object?> msg) {
    final joinPv = msg['pv'];
    final rawName = msg['name'];
    final did = msg['did'];
    final token = msg['token'];
    final password = msg['password'];
    if (joinPv is! int || joinPv < 1) return s.fatal(RelayErrors.badRequest);
    if (rawName is! String || did is! String || did.isEmpty || did.length > kMaxDidLength) return s.fatal(RelayErrors.badRequest);
    if (token != null && (token is! String || token.length > kMaxTokenLength)) return s.fatal(RelayErrors.badRequest);
    if (password != null && (password is! String || password.length > kMaxPasswordLength)) return s.fatal(RelayErrors.badRequest);
    final name = sanitizeName(rawName);
    if (name == null) return s.fatal(RelayErrors.badRequest);
    if (joinPv != pv) return s.fatal(RelayErrors.versionMismatch, {'pv': pv});

    // -- a valid token resumes, bans/locked/password/full/approval only gate new members
    final resumed = token is String ? _memberByToken(token) : null;
    if (resumed != null) return _attach(s, resumed, name);

    if (_isBanned(did, s.ip)) return s.fatal(RelayErrors.banned);
    if (locked) return s.fatal(RelayErrors.locked);
    final roomPassword = this.password;
    if (roomPassword != null && (password is! String || !constantTimeEquals(roomPassword, password))) return s.fatal(RelayErrors.badPassword);
    if (connectedCount >= max) return s.fatal(RelayErrors.full);

    if (approval) {
      final host = _hostSock;
      if (host == null) return s.fatal(RelayErrors.hostOffline);
      if (_pending.length >= config.maxPendingPerRoom) return s.fatal(RelayErrors.rateLimited);
      final request = PendingJoin(id: newShortId(), sock: s, name: name, did: did);
      request.timer = Timer(config.pendingTimeout, () => _dropPending(request, RelayErrors.timeout));
      _pending[request.id] = request;
      s.pending = request;
      s.sendText(jsonEncode({'t': Ctrl.pending}));
      host.sendText(jsonEncode({'t': Ctrl.joinreq, 'r': request.id, 'name': name, 'did': did}));
      return;
    }
    _admit(s, name, did);
  }

  RelayMember? _memberByToken(String token) {
    if (token.isEmpty) return null;
    for (final m in _members.values) {
      if (constantTimeEquals(m.token, token)) return m;
    }
    return null;
  }

  void _admit(RelaySocket s, String name, String did) {
    final member = RelayMember(n: ++_lastN, name: name, did: did, ip: s.ip, token: newToken());
    _members[member.n] = member;
    _trimRetained();
    _attach(s, member, name);
  }

  void _attach(RelaySocket s, RelayMember member, String name) {
    final previous = member.sock;
    if (previous != null && !identical(previous, s)) {
      previous.member = null;
      previous.sendText(jsonEncode({'t': Ctrl.left, 'n': member.n, 'r': LeftReason.replaced}));
      previous.closeNow();
    }
    final hostWasOffline = !_hostOnline;
    member.name = name;
    _connect(member, s);
    s.member = member;
    s.room = this;
    s.joinTimer?.cancel();
    s.joinTimer = null;
    _armIdle();

    if (hostN == null || !_members.containsKey(hostN)) {
      hostN = member.n;
      successors = const [];
    }
    final isHost = member.n == hostN;
    if (isHost) {
      _graceTimer?.cancel();
      _graceTimer = null;
      s.bucket.reconfigure(config.hostBurst, config.hostRefillPerSecond);
    }

    s.sendText(_welcomeJson(member));
    if (previous == null) _broadcast(_joinedJson(member), skip: member.n);
    // -- the joiner already learned the host from its welcome
    if (isHost && hostWasOffline) _broadcast(_hostJson(), skip: member.n);
    if (isHost && _bans.isNotEmpty) s.sendText(_bansJson());
  }

  void handleControl(RelaySocket s, Map<String, Object?> msg) {
    final type = msg['t'];
    if (type is! String) return s.sendError(RelayErrors.badRequest);
    switch (type) {
      case Ctrl.ping:
        final c = msg['c'];
        s.sendText(jsonEncode({'t': Ctrl.pong, 'c': c is num ? c : null, 's': DateTime.now().millisecondsSinceEpoch}));
      case Ctrl.leave:
        _leave(s);
      case Ctrl.kick:
      case Ctrl.unban:
      case Ctrl.approve:
      case Ctrl.transfer:
      case Ctrl.successors:
      case Ctrl.opts:
      case Ctrl.close:
      case Ctrl.summary:
        final me = s.member;
        if (me == null || me.n != hostN) return s.sendError(RelayErrors.forbidden);
        _handleHostControl(s, type, msg);
      default:
        s.sendError(RelayErrors.badRequest);
    }
  }

  void _handleHostControl(RelaySocket s, String type, Map<String, Object?> msg) {
    switch (type) {
      case Ctrl.kick:
        _kick(s, msg);
      case Ctrl.unban:
        _unban(s, msg);
      case Ctrl.approve:
        _approve(s, msg);
      case Ctrl.transfer:
        _transfer(s, msg);
      case Ctrl.successors:
        _successors(s, msg);
      case Ctrl.opts:
        _opts(s, msg);
      case Ctrl.close:
        closeRoom(ClosedReason.host);
      case Ctrl.summary:
        _summary(s, msg);
    }
  }

  void _leave(RelaySocket s) {
    final me = s.member;
    if (me != null && identical(me.sock, s)) {
      _disconnect(me);
      s.member = null;
      _broadcast(_leftJson(me.n, LeftReason.leave), skip: me.n);
      if (me.n == hostN) {
        _broadcast(_hostJson());
        _startGrace();
      }
      _armIdle();
    }
    s.closeNow();
  }

  void _kick(RelaySocket s, Map<String, Object?> msg) {
    final n = msg['n'];
    final ban = msg['ban'];
    if (n is! int || (ban != null && ban is! bool)) return s.sendError(RelayErrors.badRequest);
    final target = _members[n];
    if (target == null || n == hostN) return s.sendError(RelayErrors.badRequest);
    final banned = ban == true;
    _members.remove(n);
    final targetSock = target.sock;
    _disconnect(target);
    target.token = '';
    targetSock?.member = null;
    if (banned) _addBan(target);
    _broadcast(_leftJson(n, banned ? LeftReason.ban : LeftReason.kick));
    targetSock?.fatal(banned ? RelayErrors.banned : RelayErrors.kicked);
    if (banned) s.sendText(_bansJson());
    _armIdle();
  }

  void _unban(RelaySocket s, Map<String, Object?> msg) {
    final id = msg['id'];
    if (id is! String) return s.sendError(RelayErrors.badRequest);
    _bans.removeWhere((b) => b.id == id);
    s.sendText(_bansJson());
  }

  void _approve(RelaySocket s, Map<String, Object?> msg) {
    final id = msg['r'];
    final ok = msg['ok'];
    if (id is! String || ok is! bool) return s.sendError(RelayErrors.badRequest);
    final request = _pending.remove(id);
    if (request == null) return;
    request.timer?.cancel();
    final sock = request.sock;
    sock.pending = null;
    if (sock.closed) return;
    if (!ok) return sock.fatal(RelayErrors.rejected);
    if (connectedCount >= max) return sock.fatal(RelayErrors.full);
    _admit(sock, request.name, request.did);
  }

  void _transfer(RelaySocket s, Map<String, Object?> msg) {
    final n = msg['n'];
    if (n is! int) return s.sendError(RelayErrors.badRequest);
    final target = _members[n];
    if (target == null || !target.connected) return s.sendError(RelayErrors.badRequest);
    if (n == hostN) return;
    s.bucket.reconfigure(config.guestBurst, config.guestRefillPerSecond);
    target.sock!.bucket.reconfigure(config.hostBurst, config.hostRefillPerSecond);
    hostN = n;
    successors = const [];
    _graceTimer?.cancel();
    _graceTimer = null;
    _broadcast(_hostJson());
  }

  void _successors(RelaySocket s, Map<String, Object?> msg) {
    final ns = msg['ns'];
    if (ns is! List) return s.sendError(RelayErrors.badRequest);
    final ordered = <int>[];
    for (final n in ns) {
      if (n is! int) return s.sendError(RelayErrors.badRequest);
      if (ordered.length >= config.maxSuccessors) break;
      ordered.add(n);
    }
    successors = ordered;
  }

  void _opts(RelaySocket s, Map<String, Object?> msg) {
    final hasApproval = msg.containsKey('approval');
    final hasLocked = msg.containsKey('locked');
    final hasPassword = msg.containsKey('password');
    final hasPublic = msg.containsKey('public');
    final newApproval = msg['approval'];
    final newLocked = msg['locked'];
    final newPassword = msg['password'];
    final newPublic = msg['public'];
    if (hasApproval && newApproval is! bool) return s.sendError(RelayErrors.badRequest);
    if (hasLocked && newLocked is! bool) return s.sendError(RelayErrors.badRequest);
    if (hasPublic && newPublic is! bool) return s.sendError(RelayErrors.badRequest);
    final badPassword = newPassword is! String || newPassword.isEmpty || newPassword.length > kMaxPasswordLength;
    if (hasPassword && newPassword != null && badPassword) return s.sendError(RelayErrors.badRequest);
    if (hasApproval) approval = newApproval! as bool;
    if (hasLocked) locked = newLocked! as bool;
    if (hasPassword) password = newPassword as String?;
    if (hasPublic) public = newPublic! as bool;
    _broadcast(_optsJson());
  }

  /// nothing is broadcast, the summary only feeds the directory.
  void _summary(RelaySocket s, Map<String, Object?> msg) {
    final rawName = msg['name'];
    final rawTitle = msg['title'];
    final rawArtist = msg['artist'];
    if (rawName is! String) return s.sendError(RelayErrors.badRequest);
    if (rawTitle != null && rawTitle is! String) return s.sendError(RelayErrors.badRequest);
    if (rawArtist != null && rawArtist is! String) return s.sendError(RelayErrors.badRequest);
    final name = sanitizeName(rawName, max: kMaxSummaryNameLength);
    if (name == null) return s.sendError(RelayErrors.badRequest);
    final title = rawTitle is String ? sanitizeText(rawTitle, kMaxSummaryTextLength) : null;
    final artist = rawArtist is String ? sanitizeText(rawArtist, kMaxSummaryTextLength) : null;
    if (rawTitle is String && title == null) return s.sendError(RelayErrors.badRequest);
    if (rawArtist is String && artist == null) return s.sendError(RelayErrors.badRequest);
    _summaryName = name;
    _summaryTitle = title == null || title.isEmpty ? null : title;
    _summaryArtist = artist == null || artist.isEmpty ? null : artist;
  }

  @override
  DirectoryEntry? get directoryEntry => _entry;

  /// the summary is kept at once, the entry it feeds refreshes at most once per interval.
  @override
  bool refreshDirectory(int nowMs) {
    final entry = _entry;
    final name = _summaryName;
    if (_gone || !public || name == null) {
      if (entry == null) return false;
      _entry = null;
      return true;
    }
    if (entry != null && nowMs - entry.atMs < config.directoryRefreshInterval.inMilliseconds) return false;
    final fresh = entry ?? DirectoryEntry(code: code, hid: hid, max: max, pv: pv);
    fresh.name = name;
    fresh.title = _summaryTitle;
    fresh.artist = _summaryArtist;
    fresh.members = connectedCount;
    fresh.approval = approval;
    fresh.password = password != null;
    fresh.locked = locked;
    fresh.atMs = nowMs;
    _entry = fresh;
    return true;
  }

  void handleData(RelaySocket s, Uint8List frame) {
    final me = s.member;
    if (me == null) return;
    final isHost = me.n == hostN;
    if (frame.length > (isHost ? config.maxHostFrameBytes : config.maxGuestFrameBytes)) return s.sendError(RelayErrors.tooLarge);
    if (frame.length < kDataHeaderSize) return s.sendError(RelayErrors.badRequest);
    switch (frame[0]) {
      case DataRoute.host:
        if (isHost) return;
        final host = _hostSock;
        if (host == null) return;
        writeDataFrameN(frame, me.n);
        host.sendBytes(frame);
      case DataRoute.broadcast:
        if (!isHost) return s.sendError(RelayErrors.forbidden);
        final skip = dataFrameN(frame);
        writeDataFrameN(frame, me.n);
        for (final m in _connected) {
          if (m.n == me.n || m.n == skip) continue;
          m.sock!.sendBytes(frame);
        }
      case DataRoute.member:
        if (!isHost) return s.sendError(RelayErrors.forbidden);
        final target = _members[dataFrameN(frame)];
        if (target == null || target.n == me.n) return;
        writeDataFrameN(frame, me.n);
        target.sock?.sendBytes(frame);
      default:
        s.sendError(RelayErrors.badRequest);
    }
  }

  void onSocketClosed(RelaySocket s) {
    final request = s.pending;
    if (request != null) {
      s.pending = null;
      if (identical(_pending[request.id], request)) {
        _pending.remove(request.id);
        request.timer?.cancel();
        _hostSock?.sendText(_joinreqGoneJson(request.id));
      }
    }
    final me = s.member;
    if (me == null || !identical(me.sock, s)) return;
    _disconnect(me);
    s.member = null;
    _broadcast(_leftJson(me.n, LeftReason.lost), skip: me.n);
    if (me.n == hostN) {
      _broadcast(_hostJson());
      _startGrace();
    }
    _armIdle();
  }

  void _dropPending(PendingJoin request, String code) {
    if (!identical(_pending[request.id], request)) return;
    _pending.remove(request.id);
    request.timer?.cancel();
    request.sock.pending = null;
    _hostSock?.sendText(_joinreqGoneJson(request.id));
    request.sock.fatal(code);
  }

  void _startGrace() {
    _graceTimer?.cancel();
    _graceTimer = Timer(config.hostGrace, _promote);
  }

  void _promote() {
    _graceTimer = null;
    if (_gone || _hostOnline) return;
    RelayMember? next;
    for (final n in successors) {
      final candidate = _members[n];
      if (candidate != null && candidate.connected) {
        next = candidate;
        break;
      }
    }
    if (next == null) {
      for (final m in _connected) {
        if (next == null || m.n < next.n) next = m;
      }
    }
    successors = const [];
    hostN = next?.n;
    if (next == null) return;
    next.sock!.bucket.reconfigure(config.hostBurst, config.hostRefillPerSecond);
    _broadcast(_hostJson());
    if (_bans.isNotEmpty) next.sock!.sendText(_bansJson());
  }

  void _armIdle() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_gone || connectedCount > 0) return;
    _idleTimer = Timer(config.idleTimeout, () => closeRoom(ClosedReason.idle));
  }

  void closeRoom(String reason) {
    if (_gone) return;
    _gone = true;
    _entry = null;
    _graceTimer?.cancel();
    _idleTimer?.cancel();
    _lifeTimer?.cancel();
    final message = jsonEncode({'t': Ctrl.closed, 'r': reason});
    for (final request in _pending.values) {
      request.timer?.cancel();
      request.sock.pending = null;
      request.sock.sendText(message);
      request.sock.closeNow();
    }
    for (final m in _connected) {
      final sock = m.sock!;
      m.sock = null;
      sock.member = null;
      sock.sendText(message);
      sock.closeNow();
    }
    _pending.clear();
    _members.clear();
    _connected.clear();
    onGone(this);
  }

  /// drops the socket of every member without notifying, used on server shutdown.
  void dispose() {
    _gone = true;
    _entry = null;
    _graceTimer?.cancel();
    _idleTimer?.cancel();
    _lifeTimer?.cancel();
    for (final request in _pending.values) {
      request.timer?.cancel();
      request.sock.closeNow();
    }
    for (final m in _connected) {
      m.sock?.closeNow();
      m.sock = null;
    }
    _pending.clear();
    _members.clear();
    _connected.clear();
  }

  bool _isBanned(String did, String ip) {
    for (final b in _bans) {
      if (b.did == did || (ip.isNotEmpty && b.ip == ip)) return true;
    }
    return false;
  }

  void _addBan(RelayMember member) {
    for (final b in _bans) {
      if (b.did == member.did) return;
    }
    if (_bans.length >= config.maxBansPerRoom) _bans.removeAt(0);
    _bans.add(BanEntry(id: newShortId(), name: member.name, did: member.did, ip: member.ip));
  }

  /// disconnected members are kept for token resume, oldest first out.
  void _trimRetained() {
    var extra = _members.length - config.maxRetainedMembers;
    if (extra <= 0) return;
    final drop = <int>[];
    for (final m in _members.values) {
      if (m.connected || m.n == hostN) continue;
      drop.add(m.n);
      if (--extra <= 0) break;
    }
    for (final n in drop) {
      _members.remove(n);
    }
  }

  void _broadcast(String message, {int? skip}) {
    for (final m in _connected) {
      if (m.n == skip) continue;
      m.sock!.sendText(message);
    }
  }

  String _welcomeJson(RelayMember me) {
    return jsonEncode({
      't': Ctrl.welcome,
      'n': me.n,
      'token': me.token,
      'host': hostN,
      'hostOnline': _hostOnline,
      'pv': pv,
      'max': max,
      'now': DateTime.now().millisecondsSinceEpoch,
      'opts': _optsMap(),
      'members': [
        for (final m in _members.values)
          if (m.connected) {'n': m.n, 'name': m.name},
      ],
    });
  }

  Map<String, Object?> _optsMap() => {'approval': approval, 'password': password != null, 'locked': locked, 'public': public};

  String _optsJson() => jsonEncode({'t': Ctrl.opts, ..._optsMap()});

  String _joinedJson(RelayMember m) => jsonEncode({'t': Ctrl.joined, 'n': m.n, 'name': m.name});

  String _leftJson(int n, String reason) => jsonEncode({'t': Ctrl.left, 'n': n, 'r': reason});

  String _hostJson() => jsonEncode({'t': Ctrl.host, 'n': hostN, 'online': _hostOnline});

  String _joinreqGoneJson(String id) => jsonEncode({'t': Ctrl.joinreqgone, 'r': id});

  String _bansJson() => jsonEncode({
        't': Ctrl.bans,
        'list': [
          for (final b in _bans) {'id': b.id, 'name': b.name},
        ],
      });
}

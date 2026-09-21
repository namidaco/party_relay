/// per socket token bucket, no timers, refilled lazily on use.
class TokenBucket {
  TokenBucket(this._burst, this._refillPerSecond, int nowMs)
      : _tokens = _burst.toDouble(),
        _lastMs = nowMs;

  int _burst;
  double _refillPerSecond;
  double _tokens;
  int _lastMs;

  void reconfigure(int burst, double refillPerSecond) {
    _burst = burst;
    _refillPerSecond = refillPerSecond;
    if (_tokens > burst) _tokens = burst.toDouble();
  }

  bool take(int nowMs) {
    final elapsed = nowMs - _lastMs;
    if (elapsed > 0) {
      _lastMs = nowMs;
      final refilled = _tokens + elapsed * _refillPerSecond / 1000;
      _tokens = refilled > _burst ? _burst.toDouble() : refilled;
    }
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }
}

/// fixed window counter per ip, pruned so the map can not grow without bound.
class IpRateLimiter {
  IpRateLimiter(this.limit, this.window, {this.maxEntries = 4096});

  final int limit;
  final Duration window;
  final int maxEntries;
  final Map<String, _IpWindow> _windows = {};

  bool allow(String ip, int nowMs) {
    if (_windows.length >= maxEntries) prune(nowMs);
    final windowMs = window.inMilliseconds;
    final current = _windows[ip];
    if (current == null || nowMs - current.startMs >= windowMs) {
      if (_windows.length >= maxEntries) return false;
      _windows[ip] = _IpWindow(nowMs);
      return true;
    }
    if (current.count >= limit) return false;
    current.count++;
    return true;
  }

  void prune(int nowMs) {
    final windowMs = window.inMilliseconds;
    _windows.removeWhere((_, w) => nowMs - w.startMs >= windowMs);
  }
}

class _IpWindow {
  _IpWindow(this.startMs);
  final int startMs;
  int count = 1;
}

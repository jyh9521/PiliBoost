import 'dart:async';

/// Serial source ownership. Superseded queued loads never open a player.
class SourceTransitionQueue {
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  SourceTransitionTicket enqueue() {
    final release = Completer<void>();
    final ticket = SourceTransitionTicket._(
      this,
      ++_generation,
      _tail,
      release,
    );
    _tail = release.future;
    return ticket;
  }

  void invalidate() {
    _generation++;
  }
}

class SourceTransitionTicket {
  SourceTransitionTicket._(
    this._owner,
    this._generation,
    this.ready,
    this._release,
  );
  final SourceTransitionQueue _owner;
  final int _generation;
  final Future<void> ready;
  final Completer<void> _release;
  bool get isCurrent => _generation == _owner._generation;
  void finish() {
    if (!_release.isCompleted) _release.complete();
  }
}

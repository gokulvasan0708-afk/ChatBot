import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

// ==========================================================
// RINGTONE SERVICE
// ----------------------------------------------------------
// Owns a dedicated `just_audio` AudioPlayer instance for call ringing
// only. This is deliberately separate from whatever player
// VoiceMessageService / chat_screen.dart use to play back recorded
// voice messages, so:
//   - a ringing call never stops/pauses a voice message someone is
//     listening to, and vice versa
//   - stopping a voice message never leaves a ringtone playing
//
// Requires two bundled audio assets (see pubspec.yaml `assets:`):
//   assets/audio/call_incoming_ringtone.mp3
//   assets/audio/call_outgoing_ringback.mp3
// If those files aren't present yet, playback fails silently (caught
// below) so a missing asset can never crash or block the call flow --
// only the audible ringtone is lost, not the call itself.
// ==========================================================

class RingtoneService {
  RingtoneService._();
  static final RingtoneService instance = RingtoneService._();

  static const String _incomingAsset =
      'assets/audio/call_incoming_ringtone.mp3';
  static const String _outgoingAsset =
      'assets/audio/call_outgoing_ringback.mp3';

  final AudioPlayer _player = AudioPlayer();
  Timer? _vibrateTimer;
  bool _playing = false;

  Future<void> _playLoop(String assetPath) async {
    await stop();
    try {
      await _player.setAsset(assetPath);
      await _player.setLoopMode(LoopMode.all);
      await _player.play();
      _playing = true;
    } catch (e) {
      // Missing/unplayable asset -- never let this break the call.
      debugPrint('RingtoneService: could not play $assetPath ($e)');
      _playing = false;
    }
  }

  /// Loops the incoming-call ringtone and (by default) vibrates
  /// continuously alongside it. Safe to call repeatedly -- always
  /// stops whatever was playing first so there is never more than one
  /// ringtone instance active at a time.
  Future<void> playIncoming({bool vibrate = true}) async {
    await _playLoop(_incomingAsset);
    if (vibrate) _startVibration();
  }

  /// Loops the outgoing ringback tone the caller hears while waiting.
  Future<void> playOutgoing() async {
    await _playLoop(_outgoingAsset);
  }

  void _startVibration() {
    _vibrateTimer?.cancel();
    // HapticFeedback.vibrate() only fires a single short pulse per
    // call, so it's re-triggered on an interval to approximate a
    // continuous incoming-call buzz without adding a new dependency
    // just for vibration patterns. Swap in the `vibration` package
    // here later if a stronger/patterned buzz is wanted.
    _vibrateTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      HapticFeedback.vibrate();
    });
    HapticFeedback.vibrate();
  }

  void _stopVibration() {
    _vibrateTimer?.cancel();
    _vibrateTimer = null;
  }

  /// Stops any ringtone/vibration currently active. Safe to call any
  /// number of times, including when nothing is playing -- every call
  /// site in CallService calls this defensively rather than tracking
  /// "was it playing" itself.
  Future<void> stop() async {
    _stopVibration();
    _playing = false;
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }
}

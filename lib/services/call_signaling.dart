import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// ==========================================================
// CALL SIGNALING
// ----------------------------------------------------------
// Low-level WebRTC + Firestore-signaling helper for a single active
// 1-to-1 voice OR video call. One instance is created per call and
// thrown away when the call ends -- it owns exactly one
// RTCPeerConnection and the two Firestore ICE-candidate listeners
// tied to that call's document.
//
// This class knows nothing about call *screens* or the call's overall
// status (ringing/declined/missed/etc.) -- that's CallService's job.
// It only knows how to grab a microphone (and, for video calls, a
// camera) track, exchange SDP/ICE through `calls/{callId}` (+ its
// `callerCandidates`/`calleeCandidates` subcollections), and hand back
// a connected remote stream.
//
// [isVideo] controls whether a camera track is ever requested, sent,
// or negotiated -- when false this stays exactly as before: audio
// only. Actual voice/video packets never touch Firestore; only the
// small SDP/ICE signaling messages needed to open the peer-to-peer
// connection do.
// ==========================================================

class CallSignaling {
  CallSignaling({
    required this.callId,
    required this.isCaller,
    this.isVideo = false,
    this.initialLocalStream,
  });

  final String callId;
  final bool isCaller;
  final bool isVideo;

  /// A mic(+camera) stream already acquired by OutgoingCallScreen /
  /// IncomingCallScreen's local preview (CallPreviewCamera) while the
  /// call was still ringing. When provided, [initialize] reuses it
  /// instead of calling getUserMedia again -- so the camera is never
  /// re-opened and the user is never asked for permission twice.
  final MediaStream? initialLocalStream;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callDocSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _remoteCandidatesSub;

  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  bool _disposed = false;

  /// Fires once the remote party's audio track starts flowing.
  final _onRemoteStreamController =
      StreamController<MediaStream>.broadcast();
  Stream<MediaStream> get onRemoteStream => _onRemoteStreamController.stream;

  /// Fires on every RTCPeerConnection state change so the UI can react
  /// (e.g. treat "failed"/"disconnected" as a dropped call).
  final _onConnectionStateController =
      StreamController<RTCPeerConnectionState>.broadcast();
  Stream<RTCPeerConnectionState> get onConnectionState =>
      _onConnectionStateController.stream;

  DocumentReference<Map<String, dynamic>> get _callRef =>
      FirebaseFirestore.instance.collection('calls').doc(callId);

  CollectionReference<Map<String, dynamic>> get _callerCandidates =>
      _callRef.collection('callerCandidates');

  CollectionReference<Map<String, dynamic>> get _calleeCandidates =>
      _callRef.collection('calleeCandidates');

  // STUN discovers each phone's public address but can't relay media
  // through it -- it only works when at least one side has a directly
  // reachable address. Indian mobile carriers (Jio/Airtel/Vi etc.)
  // almost always put phones behind carrier-grade NAT (CGNAT) on
  // cellular data, which STUN-only setups frequently can't punch
  // through -- exactly what the "Old state: have-local-offer New
  // state: closed" / all-zero call-stats symptom is: both sides
  // gathered candidates, but neither could actually reach the other,
  // so the call sat there and then got torn down.
  //
  // A TURN server relays the media instead of connecting P2P, and
  // fixes this reliably. Get free/low-cost TURN credentials from a
  // provider (e.g. https://www.metered.ca/tools/openrelay/,
  // Twilio Network Traversal Service, Xirsys) or run your own
  // (coturn), then fill in the three fields below -- leave them
  // blank/as-is and only STUN is used (current behaviour).
  static const String _turnUrl = ''; // e.g. 'turn:relay.example.com:3478'
  static const String _turnUsername = '';
  static const String _turnCredential = '';

  static Map<String, dynamic> get _iceServersConfig {
    final servers = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ];
    if (_turnUrl.isNotEmpty) {
      servers.add({
        'urls': _turnUrl,
        'username': _turnUsername,
        'credential': _turnCredential,
      });
    }
    return {'iceServers': servers};
  }

  bool _muted = false;
  bool get isMuted => _muted;

  bool _speakerOn = true;
  bool get isSpeakerOn => _speakerOn;

  bool _cameraOff = false;
  bool get isCameraOff => _cameraOff;

  /// The local mic (+ camera, for video calls) stream -- exposed so
  /// ActiveCallScreen can attach it to a local RTCVideoRenderer for
  /// the self-preview. Null until [initialize] completes.
  MediaStream? get localStream => _localStream;

  /// Grabs the microphone (and, for video calls, the front camera) and
  /// sets up the peer connection + local/remote track wiring. Throws
  /// if the OS denies microphone/camera permission, so the caller
  /// (CallService/ActiveCallScreen) can show a clear message and end
  /// the call cleanly instead of hanging.
  Future<void> initialize() async {
    _localStream = initialLocalStream ??
        await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': isVideo ? {'facingMode': 'user'} : false,
        });

    _peerConnection = await createPeerConnection(_iceServersConfig);

    for (final track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        _onRemoteStreamController.add(event.streams.first);
      }
    };

    _peerConnection!.onConnectionState = (state) {
      _onConnectionStateController.add(state);
    };

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      final target = isCaller ? _callerCandidates : _calleeCandidates;
      target.add({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
        'createdAt': FieldValue.serverTimestamp(),
      });
    };

    // Listen for the *other* side's ICE candidates only.
    final remoteCandidates = isCaller ? _calleeCandidates : _callerCandidates;
    _remoteCandidatesSub = remoteCandidates.snapshots().listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type != DocumentChangeType.added) continue;
        final data = change.doc.data();
        if (data == null) continue;

        final candidate = RTCIceCandidate(
          (data['candidate'] ?? '').toString(),
          data['sdpMid'] as String?,
          (data['sdpMLineIndex'] as num?)?.toInt(),
        );

        if (_remoteDescriptionSet) {
          _peerConnection?.addCandidate(candidate);
        } else {
          _pendingRemoteCandidates.add(candidate);
        }
      }
    });
  }

  /// Caller side: creates the SDP offer, writes it to the call doc,
  /// then watches that same doc for the callee's answer.
  ///
  /// Guarded against `dispose()` running concurrently (e.g. the other
  /// side ends/declines the call while this is still awaiting a step)
  /// -- without the `_disposed` checks below, a `setLocalDescription`
  /// or Firestore write could land on an already-closed
  /// RTCPeerConnection and throw a noisy native
  /// "Called in wrong state: closed" error. That race is expected
  /// during teardown, so it's swallowed here rather than surfaced to
  /// ActiveCallScreen as a call failure.
  Future<void> createOffer() async {
    if (_disposed || _peerConnection == null) return;
    late final RTCSessionDescription offer;
    try {
      offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': isVideo ? 1 : 0,
      });
      if (_disposed || _peerConnection == null) return;
      await _peerConnection!.setLocalDescription(offer);
    } catch (e) {
      if (_disposed) return;
      rethrow;
    }
    if (_disposed) return;

    try {
      await _callRef.update({
        'offer': {'type': offer.type, 'sdp': offer.sdp},
      });
    } catch (e) {
      if (_disposed) return;
      rethrow;
    }
    if (_disposed) return;

    _callDocSub = _callRef.snapshots().listen((snapshot) async {
      if (_remoteDescriptionSet || _disposed) return;
      final data = snapshot.data();
      final answer = data?['answer'];
      if (answer is Map && (answer['sdp'] ?? '').toString().isNotEmpty) {
        await _setRemoteDescription(
          RTCSessionDescription(
            (answer['sdp'] ?? '').toString(),
            (answer['type'] ?? 'answer').toString(),
          ),
        );
      }
    });
  }

  /// Callee side: reads the caller's offer already on the call doc,
  /// creates the SDP answer, and writes it back. Guarded the same way
  /// as [createOffer] above.
  Future<void> createAnswer() async {
    if (_disposed || _peerConnection == null) return;
    final snapshot = await _callRef.get();
    if (_disposed || _peerConnection == null) return;
    final offer = snapshot.data()?['offer'];

    if (offer is! Map || (offer['sdp'] ?? '').toString().isEmpty) {
      throw StateError('Call offer is missing -- cannot answer.');
    }

    await _setRemoteDescription(
      RTCSessionDescription(
        (offer['sdp'] ?? '').toString(),
        (offer['type'] ?? 'offer').toString(),
      ),
    );
    if (_disposed || _peerConnection == null) return;

    late final RTCSessionDescription answer;
    try {
      answer = await _peerConnection!.createAnswer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': isVideo ? 1 : 0,
      });
      if (_disposed || _peerConnection == null) return;
      await _peerConnection!.setLocalDescription(answer);
    } catch (e) {
      if (_disposed) return;
      rethrow;
    }
    if (_disposed) return;

    try {
      await _callRef.update({
        'answer': {'type': answer.type, 'sdp': answer.sdp},
      });
    } catch (e) {
      if (_disposed) return;
      rethrow;
    }
  }

  Future<void> _setRemoteDescription(
    RTCSessionDescription description,
  ) async {
    if (_disposed || _peerConnection == null) return;
    try {
      await _peerConnection?.setRemoteDescription(description);
    } catch (e) {
      if (_disposed) return;
      rethrow;
    }
    if (_disposed) return;
    _remoteDescriptionSet = true;

    for (final candidate in _pendingRemoteCandidates) {
      if (_disposed) return;
      try {
        await _peerConnection?.addCandidate(candidate);
      } catch (e) {
        if (_disposed) return;
        rethrow;
      }
    }
    _pendingRemoteCandidates.clear();
  }

  void setMuted(bool muted) {
    _muted = muted;
    for (final track in _localStream?.getAudioTracks() ?? const []) {
      track.enabled = !muted;
    }
  }

  /// Turns THIS device's outgoing camera track on/off. Disabling it
  /// (rather than stopping/removing the track) keeps the video m-line
  /// negotiated so nothing needs to renegotiate -- it just makes this
  /// side send a blank/no video, so the OTHER member's screen shows no
  /// video for ME while I keep receiving and can keep seeing THEIR
  /// video normally. Only ever affects the local outgoing track; the
  /// remote stream/renderer is completely untouched by this.
  void setCameraEnabled(bool enabled) {
    if (!isVideo) return;
    _cameraOff = !enabled;
    for (final track in _localStream?.getVideoTracks() ?? const []) {
      track.enabled = enabled;
    }
  }

  /// Flips the outgoing camera track between front/back. No-op for a
  /// voice call or once the camera's been turned off via
  /// [setCameraEnabled].
  Future<void> switchCamera() async {
    if (!isVideo) return;
    final tracks = _localStream?.getVideoTracks() ?? const [];
    if (tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
    } catch (e) {
      debugPrint('CallSignaling.switchCamera error: $e');
    }
  }

  Future<void> setSpeakerOn(bool on) async {
    _speakerOn = on;
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (e) {
      debugPrint('CallSignaling.setSpeakerOn error: $e');
    }
  }

  /// Tears down everything this instance owns: local mic track, peer
  /// connection, both Firestore listeners, and both stream
  /// controllers. Safe to call more than once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await _callDocSub?.cancel();
    _callDocSub = null;

    await _remoteCandidatesSub?.cancel();
    _remoteCandidatesSub = null;

    for (final track in _localStream?.getTracks() ?? const []) {
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;

    try {
      await _peerConnection?.close();
    } catch (_) {}
    try {
      await _peerConnection?.dispose();
    } catch (_) {}
    _peerConnection = null;

    await _onRemoteStreamController.close();
    await _onConnectionStateController.close();
  }
}
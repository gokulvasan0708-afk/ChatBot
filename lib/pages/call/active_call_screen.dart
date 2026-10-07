import '../../features/ai_assistant/ai_launcher.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../services/call_service.dart';
import '../../services/call_signaling.dart';
import 'call_widgets.dart';

import '../../widgets/top_alert.dart';
// NOTE ON [initialLocalStream]:
// When this screen is reached from OutgoingCallScreen/IncomingCallScreen,
// the caller's/receiver's front camera was already turned on and shown
// full-screen while the call was still ringing (see CallPreviewCamera in
// call_widgets.dart). That already-open MediaStream is passed in here via
// [initialLocalStream] and handed straight to CallSignaling so the camera
// is never re-requested/re-opened and the user is never asked for camera
// permission a second time. It stays null (and behaviour is completely
// unchanged) for a voice call, or if this screen is ever reached some
// other way.

// ==========================================================
// ACTIVE CALL SCREEN
// ----------------------------------------------------------
// Reached once the receiver accepts (OutgoingCallScreen ->
// ActiveCallScreen) or the moment the receiver taps Accept
// (IncomingCallScreen -> ActiveCallScreen). This screen is what
// actually stands up the WebRTC connection: it owns the one
// CallSignaling instance for the call, requests the microphone (and,
// for a video call, the camera), exchanges the offer/answer, and
// renders the connected-call UI (timer, mute, speaker/camera, end
// call) once media is flowing.
//
// [callType] is 'voice' or 'video'. Voice calls keep the exact same
// avatar-based layout as before. Video calls additionally render the
// remote video full-screen with a small local self-preview, and swap
// the Speaker button for a Camera on/off toggle.
// ==========================================================

class ActiveCallScreen extends StatefulWidget {
  final String callId;
  final bool isCaller;
  final String otherUserId;
  final String otherUserName;
  final String otherUserImage;
  final String callType;
  final MediaStream? initialLocalStream;

  const ActiveCallScreen({
    super.key,
    required this.callId,
    required this.isCaller,
    required this.otherUserId,
    required this.otherUserName,
    required this.otherUserImage,
    this.callType = 'voice',
    this.initialLocalStream,
  });

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen> with AiLauncherHide {
  late final CallSignaling _signaling;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callSub;
  StreamSubscription<RTCPeerConnectionState>? _connectionSub;
  StreamSubscription<MediaStream>? _remoteStreamSub;

  Timer? _durationTimer;
  Duration _elapsed = Duration.zero;

  bool _connected = false;
  bool _muted = false;
  bool _speakerOn = true;
  bool _cameraOff = false;
  bool _finished = false;
  String _statusLabel = 'Connecting…';

  bool get _isVideo => widget.callType == 'video';

  // Only created/initialized/disposed for video calls -- a voice call
  // never touches these, so its behaviour is unchanged.
  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;
  bool _renderersReady = false;

  @override
  void initState() {
    super.initState();
    _signaling = CallSignaling(
      callId: widget.callId,
      isCaller: widget.isCaller,
      isVideo: _isVideo,
      initialLocalStream: widget.initialLocalStream,
    );
    CallService.instance.attachSignaling(widget.callId, _signaling);
    _connectionSub = _signaling.onConnectionState.listen(_onConnectionState);

    if (_isVideo) {
      _localRenderer = RTCVideoRenderer();
      _remoteRenderer = RTCVideoRenderer();
      _remoteStreamSub = _signaling.onRemoteStream.listen((stream) {
        _remoteRenderer?.srcObject = stream;
        if (mounted) setState(() {});
      });
    }

    _startWebRtc();

    _callSub = FirebaseFirestore.instance
        .collection('calls')
        .doc(widget.callId)
        .snapshots()
        .listen(_onCallDocChanged);
  }

  Future<void> _startWebRtc() async {
    try {
      if (_isVideo) {
        await _localRenderer!.initialize();
        await _remoteRenderer!.initialize();
        if (mounted) setState(() => _renderersReady = true);
      }

      await _signaling.initialize();
      await _signaling.setSpeakerOn(_speakerOn);

      if (_isVideo) {
        _localRenderer?.srcObject = _signaling.localStream;
        if (mounted) setState(() {});
      }

      if (widget.isCaller) {
        await _signaling.createOffer();
      } else {
        await _signaling.createAnswer();
      }
    } catch (e) {
      // Covers a denied microphone/camera permission (getUserMedia
      // throws) as well as any other setup failure -- terminate the
      // call cleanly instead of leaving it stuck on "Connecting...".
      await _fail(_isVideo
          ? 'Couldn\'t start the call: camera/microphone unavailable.'
          : 'Couldn\'t start the call: microphone unavailable.');
    }
  }

  void _onConnectionState(RTCPeerConnectionState state) {
    if (_finished || !mounted) return;

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
        !_connected) {
      _connected = true;
      CallService.instance.markConnected(widget.callId);
      setState(() => _statusLabel = '');
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsed += const Duration(seconds: 1));
      });
    } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      _fail('Call connection failed.');
    }
  }

  void _onCallDocChanged(DocumentSnapshot<Map<String, dynamic>> snapshot) {
    if (_finished || !mounted) return;
    final status = (snapshot.data()?['status'] ?? '').toString();

    // The other side pressed End Call (or their connection failed) --
    // this device didn't cause it, so clean up locally only.
    if (status == CallStatus.ended ||
        status == CallStatus.failed ||
        status == CallStatus.declined ||
        status == CallStatus.cancelled) {
      _leave(
        cleanup: () => CallService.instance.handleRemoteTermination(widget.callId),
      );
    }
  }

  Future<void> _fail(String message) async {
    if (_finished) return;
    await CallService.instance.markFailed(widget.callId);
    await _leave(
      cleanup: () async {},
      message: message,
    );
  }

  Future<void> _endCall() async {
    if (_finished) return;
    await _leave(cleanup: () => CallService.instance.endCall(widget.callId));
  }

  Future<void> _leave({
    required Future<void> Function() cleanup,
    String? message,
  }) async {
    if (_finished) return;
    _finished = true;
    _durationTimer?.cancel();
    await cleanup();
    if (!mounted) return;
    if (message != null) {
      showTopAlert(context, message);
    }
    Navigator.of(context).pop();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _signaling.setMuted(_muted);
  }

  void _toggleSpeaker() {
    setState(() => _speakerOn = !_speakerOn);
    _signaling.setSpeakerOn(_speakerOn);
  }

  // Disables only MY outgoing camera track -- the other member's
  // screen stops showing my video, but I keep receiving and can keep
  // seeing THEIR video normally (see CallSignaling.setCameraEnabled).
  void _toggleCamera() {
    setState(() => _cameraOff = !_cameraOff);
    _signaling.setCameraEnabled(!_cameraOff);
  }

  String _formatElapsed(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _callSub?.cancel();
    _connectionSub?.cancel();
    _remoteStreamSub?.cancel();
    _durationTimer?.cancel();
    _localRenderer?.dispose();
    _remoteRenderer?.dispose();
    // NOTE: _signaling itself is disposed by CallService (via
    // endCall/handleRemoteTermination/markFailed above, all of which
    // dispose the ActiveCall's attached signaling) rather than here --
    // this keeps exactly one owner responsible for tearing down the
    // peer connection regardless of which path ended the call.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF18181F),
        body: SafeArea(
          child: _isVideo ? _buildVideoBody() : _buildVoiceBody(),
        ),
      ),
    );
  }

  // ==========================================================
  // VOICE CALL UI (unchanged from before video calling existed)
  // ==========================================================

  Widget _buildVoiceBody() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        children: [
          const SizedBox(height: 40),
          const Spacer(),
          CallAvatar(imagePath: widget.otherUserImage, radius: 70),
          const SizedBox(height: 24),
          Text(
            widget.otherUserName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            _connected ? _formatElapsed(_elapsed) : _statusLabel,
            style: const TextStyle(color: Colors.white54, fontSize: 15),
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              CallActionButton(
                color: const Color(0xFF7C3AED),
                icon: _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                label: _muted ? 'Unmute' : 'Mute',
                onTap: _toggleMute,
                selected: _muted,
              ),
              CallActionButton(
                color: Color(0xFFEF4444),
                icon: Icons.call_end_rounded,
                label: 'End',
                onTap: _endCall,
              ),
              CallActionButton(
                color: const Color(0xFF7C3AED),
                icon: _speakerOn
                    ? Icons.volume_up_rounded
                    : Icons.hearing_rounded,
                label: 'Speaker',
                onTap: _toggleSpeaker,
                selected: _speakerOn,
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ==========================================================
  // VIDEO CALL UI
  // ----------------------------------------------------------
  // Remote video fills the screen (or a person icon while it hasn't
  // arrived/is off on their end); my own preview sits in a small
  // corner box, showing a camera-off placeholder instead of a black
  // box when I've disabled my camera.
  // ==========================================================

  Widget _buildVideoBody() {
    final hasRemoteVideo = _renderersReady &&
        _remoteRenderer != null &&
        _remoteRenderer!.srcObject != null;

    return Stack(
      children: [
        Positioned.fill(
          child: hasRemoteVideo
              ? RTCVideoView(
                  _remoteRenderer!,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : Container(
                  color: const Color(0xFF18181F),
                  child: Center(
                    child: CallAvatar(
                      imagePath: widget.otherUserImage,
                      radius: 70,
                    ),
                  ),
                ),
        ),

        // Name + status/timer, top of screen.
        Positioned(
          top: 16,
          left: 0,
          right: 0,
          child: Column(
            children: [
              Text(
                widget.otherUserName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                _connected ? _formatElapsed(_elapsed) : _statusLabel,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                ),
              ),
            ],
          ),
        ),

        // My own self-preview, small corner box.
        Positioned(
          top: 16,
          right: 16,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 100,
              height: 140,
              color: const Color(0xFF20202A),
              child: (_renderersReady && !_cameraOff && _localRenderer != null)
                  ? RTCVideoView(
                      _localRenderer!,
                      mirror: true,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : const Center(
                      child: Icon(Icons.videocam_off_rounded,
                          color: Colors.white54, size: 28),
                    ),
            ),
          ),
        ),

        // Action buttons, bottom of screen over a soft gradient so
        // they stay legible over bright video.
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.55),
                  Colors.transparent,
                ],
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                CallActionButton(
                  color: const Color(0xFF7C3AED),
                  icon: _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                  label: _muted ? 'Unmute' : 'Mute',
                  onTap: _toggleMute,
                  selected: _muted,
                ),
                CallActionButton(
                  color: const Color(0xFF7C3AED),
                  icon: _cameraOff
                      ? Icons.videocam_off_rounded
                      : Icons.videocam_rounded,
                  label: _cameraOff ? 'Camera off' : 'Camera',
                  onTap: _toggleCamera,
                  selected: _cameraOff,
                ),
                CallActionButton(
                  color: Color(0xFFEF4444),
                  icon: Icons.call_end_rounded,
                  label: 'End',
                  onTap: _endCall,
                ),
                CallActionButton(
                  color: const Color(0xFF7C3AED),
                  icon: _speakerOn
                      ? Icons.volume_up_rounded
                      : Icons.hearing_rounded,
                  label: 'Speaker',
                  onTap: _toggleSpeaker,
                  selected: _speakerOn,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
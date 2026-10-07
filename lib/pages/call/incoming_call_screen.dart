import '../../features/ai_assistant/ai_launcher.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../services/call_service.dart';
import 'active_call_screen.dart';
import 'call_widgets.dart';

import '../../widgets/top_alert.dart';
// ==========================================================
// INCOMING CALL SCREEN
// ----------------------------------------------------------
// Shown by CallService (over whatever the app currently has on
// screen) the instant a new `calls/{callId}` document arrives for the
// signed-in user with status == 'ringing'. Purely presentational plus
// Accept/Decline wiring -- all Firestore writes and ringtone control
// live in CallService so this screen can be popped/replaced freely
// without leaking either.
//
// For a VIDEO call, this screen now also turns the receiver's own
// front camera on immediately (while it's still ringing, before
// Accept/Decline is chosen) and shows it full-screen as the
// background, with a switch-camera button -- matching
// OutgoingCallScreen. See CallPreviewCamera in call_widgets.dart for
// how the stream is acquired and later handed off to ActiveCallScreen
// with no second permission prompt / camera re-open.
// ==========================================================

class IncomingCallScreen extends StatefulWidget {
  final String callId;
  final String callerId;
  final String callerName;
  final String callerImage;
  final String callType;

  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.callerId,
    required this.callerName,
    required this.callerImage,
    this.callType = 'voice',
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> with AiLauncherHide {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callSub;
  bool _resolving = false;
  bool _finished = false;

  bool get _isVideo => widget.callType == 'video';

  // Only created for video calls -- a voice call keeps its original
  // avatar-only layout untouched.
  CallPreviewCamera? _preview;

  @override
  void initState() {
    super.initState();
    _callSub = FirebaseFirestore.instance
        .collection('calls')
        .doc(widget.callId)
        .snapshots()
        .listen(_onCallDocChanged);

    if (_isVideo) {
      _preview = CallPreviewCamera();
      _preview!.start().then((_) {
        if (mounted) setState(() {});
      }).catchError((e) {
        // Camera/mic permission denied (or no camera) -- fall back to
        // the plain avatar layout below; ActiveCallScreen will still
        // try again (and surface its own clear failure) if Accept is
        // tapped.
        debugPrint('IncomingCallScreen: camera preview unavailable ($e)');
      });
    }
  }

  @override
  void dispose() {
    _callSub?.cancel();
    _preview?.dispose();
    super.dispose();
  }

  void _onCallDocChanged(DocumentSnapshot<Map<String, dynamic>> snapshot) {
    if (_finished || !mounted) return;
    final status = (snapshot.data()?['status'] ?? '').toString();

    // Any terminal status this screen didn't itself cause (caller
    // cancelled, or the ring timer on the caller's device already
    // marked this missed) means the call is over -- stop ringing and
    // get this screen off-screen without touching Firestore again.
    if (status == CallStatus.cancelled || status == CallStatus.missed) {
      _finish(() => CallService.instance.handleRemoteTermination(widget.callId));
    }
  }

  Future<void> _finish(Future<void> Function() cleanup) async {
    if (_finished) return;
    _finished = true;
    await cleanup();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _accept() async {
    if (_resolving || _finished) return;
    setState(() => _resolving = true);

    final accepted = await CallService.instance.acceptCall(widget.callId);

    if (!mounted) return;

    if (!accepted) {
      _finished = true;
      showTopAlert(context, 'This call already ended.');
      Navigator.of(context).pop();
      return;
    }

    _finished = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ActiveCallScreen(
          callId: widget.callId,
          isCaller: false,
          otherUserId: widget.callerId,
          otherUserName: widget.callerName,
          otherUserImage: widget.callerImage,
          callType: widget.callType,
          // Hand off the already-running camera preview so the active
          // call reuses the same stream instead of re-requesting the
          // camera.
          initialLocalStream: _preview?.handOff(),
        ),
      ),
    );
  }

  Future<void> _decline() async {
    if (_resolving || _finished) return;
    _finish(() => CallService.instance.declineCall(widget.callId));
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
          const Text(
            'Incoming voice call',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const Spacer(),
          CallAvatar(imagePath: widget.callerImage, radius: 70),
          const SizedBox(height: 24),
          Text(
            widget.callerName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Incoming voice call…',
            style: TextStyle(color: Colors.white54, fontSize: 15),
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              CallActionButton(
                color: Color(0xFFEF4444),
                icon: Icons.call_end_rounded,
                label: 'Decline',
                onTap: _decline,
              ),
              CallActionButton(
                color: Color(0xFF10B981),
                icon: Icons.call_rounded,
                label: 'Accept',
                onTap: _accept,
                loading: _resolving,
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
  // Receiver's own front camera fills the background the whole time
  // it's ringing. Caller's name/photo shows as a small badge up top,
  // and a switch-camera button sits top-right once the preview is
  // ready.
  // ==========================================================

  Widget _buildVideoBody() {
    final previewReady = _preview?.isReady ?? false;

    return Stack(
      children: [
        Positioned.fill(
          child: previewReady
              ? RTCVideoView(
                  _preview!.renderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : Container(color: const Color(0xFF18181F)),
        ),

        if (!previewReady)
          Center(
            child: CallAvatar(imagePath: widget.callerImage, radius: 70),
          ),

        // Caller name/status badge, top of screen.
        Positioned(
          top: 16,
          left: 0,
          right: 0,
          child: Column(
            children: [
              const Text(
                'Incoming video call',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CallAvatar(imagePath: widget.callerImage, radius: 16),
                  const SizedBox(width: 8),
                  Text(
                    widget.callerName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Switch-camera button, top-right, once the preview is live.
        if (previewReady)
          Positioned(
            top: 16,
            right: 16,
            child: CameraSwitchButton(onTap: () => _preview!.switchCamera()),
          ),

        // Accept/Decline buttons, bottom of screen over a soft
        // gradient so they stay legible over the camera preview.
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
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
                  color: Color(0xFFEF4444),
                  icon: Icons.call_end_rounded,
                  label: 'Decline',
                  onTap: _decline,
                ),
                CallActionButton(
                  color: Color(0xFF10B981),
                  icon: Icons.call_rounded,
                  label: 'Accept',
                  onTap: _accept,
                  loading: _resolving,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
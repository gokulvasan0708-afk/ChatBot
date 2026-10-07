import '../../features/ai_assistant/ai_launcher.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../services/call_service.dart';
import 'active_call_screen.dart';
import 'call_widgets.dart';

// ==========================================================
// OUTGOING CALL SCREEN
// ----------------------------------------------------------
// Shown the instant CallService.startCall() writes the 'ringing' call
// document. Watches that same document so it can react the moment the
// receiver answers, declines, or the ring timer marks it missed --
// all of which are Firestore writes made elsewhere (CallService /
// the receiver's own device), never by this screen directly, except
// for the End Call / cancel button.
//
// For a VIDEO call, this screen now also turns the caller's own front
// camera on immediately (while still ringing) and shows it full-screen
// as the background, with a switch-camera button -- it no longer waits
// until the receiver accepts to reveal any camera preview. See
// CallPreviewCamera in call_widgets.dart for how the stream is
// acquired and later handed off to ActiveCallScreen with no second
// permission prompt / camera re-open.
// ==========================================================

class OutgoingCallScreen extends StatefulWidget {
  final String callId;
  final String receiverId;
  final String receiverName;
  final String receiverImage;
  final String callType;

  const OutgoingCallScreen({
    super.key,
    required this.callId,
    required this.receiverId,
    required this.receiverName,
    required this.receiverImage,
    this.callType = 'voice',
  });

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> with AiLauncherHide {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callSub;
  String _statusLabel = 'Calling…';
  bool _finished = false;
  bool _cancelling = false;

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
        // try again (and surface its own clear failure) once/if the
        // call is accepted.
        debugPrint('OutgoingCallScreen: camera preview unavailable ($e)');
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

    switch (status) {
      case CallStatus.ringing:
        setState(() => _statusLabel = 'Ringing…');
        break;

      case CallStatus.accepted:
        _finished = true;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ActiveCallScreen(
              callId: widget.callId,
              isCaller: true,
              otherUserId: widget.receiverId,
              otherUserName: widget.receiverName,
              otherUserImage: widget.receiverImage,
              callType: widget.callType,
              // Hand off the already-running camera preview so the
              // active call reuses the same stream instead of
              // re-requesting the camera.
              initialLocalStream: _preview?.handOff(),
            ),
          ),
        );
        break;

      case CallStatus.declined:
        _endWithMessage(
          'Call declined',
          () => CallService.instance.handleRemoteTermination(widget.callId),
        );
        break;

      case CallStatus.missed:
        // This device's own ring timer is what set 'missed' (see
        // CallService._expireIfStillRinging), which already logged
        // the history and tore everything down -- this is purely
        // getting the UI off-screen.
        _endWithMessage(
          'No answer',
          () => CallService.instance.handleRemoteTermination(widget.callId),
        );
        break;

      case CallStatus.cancelled:
      case CallStatus.ended:
      case CallStatus.failed:
        _endWithMessage(
          'Call ended',
          () => CallService.instance.handleRemoteTermination(widget.callId),
        );
        break;
    }
  }

  Future<void> _endWithMessage(
    String message,
    Future<void> Function() cleanup,
  ) async {
    if (_finished) return;
    _finished = true;
    await cleanup();
    if (!mounted) return;
    setState(() => _statusLabel = message);
    await Future.delayed(const Duration(milliseconds: 900));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _cancel() async {
    if (_cancelling || _finished) return;
    setState(() => _cancelling = true);
    _finished = true;
    await CallService.instance.cancelCall(widget.callId);
    if (mounted) Navigator.of(context).pop();
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
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 40),
          const Text(
            'Voice call',
            style: TextStyle(color: Colors.white70, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const Spacer(),
          CallAvatar(imagePath: widget.receiverImage, radius: 70),
          const SizedBox(height: 24),
          Text(
            widget.receiverName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            _statusLabel,
            style: const TextStyle(color: Colors.white54, fontSize: 15),
          ),
          const Spacer(),
          Center(
            child: CallActionButton(
              color: Color(0xFFEF4444),
              icon: Icons.call_end_rounded,
              label: 'Cancel',
              onTap: _cancel,
              loading: _cancelling,
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ==========================================================
  // VIDEO CALL UI
  // ----------------------------------------------------------
  // Caller's own front camera fills the background the whole time
  // it's ringing. Receiver's name/photo shows as a small badge up
  // top (there's no remote video to show yet -- they haven't
  // answered), and a switch-camera button sits top-right once the
  // preview is ready.
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
            child: CallAvatar(imagePath: widget.receiverImage, radius: 70),
          ),

        // Receiver name/status badge, top of screen.
        Positioned(
          top: 16,
          left: 0,
          right: 0,
          child: Column(
            children: [
              const Text(
                'Video call',
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
                  CallAvatar(imagePath: widget.receiverImage, radius: 16),
                  const SizedBox(width: 8),
                  Text(
                    widget.receiverName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _statusLabel,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                ),
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

        // Cancel button, bottom of screen over a soft gradient so it
        // stays legible over the camera preview.
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
            child: Center(
              child: CallActionButton(
                color: Color(0xFFEF4444),
                icon: Icons.call_end_rounded,
                label: 'Cancel',
                onTap: _cancel,
                loading: _cancelling,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
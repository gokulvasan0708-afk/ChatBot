import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// ==========================================================
// SHARED ROUND CALL ACTION BUTTON
// ----------------------------------------------------------
// Used by IncomingCallScreen (Accept/Decline), OutgoingCallScreen
// (Cancel), and ActiveCallScreen (Mute/Speaker/End Call) so all three
// call screens share one consistent look instead of each redefining
// their own button.
// ==========================================================

class CallActionButton extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool loading;
  final bool selected;

  const CallActionButton({
    super.key,
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
    this.loading = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(36),
          onTap: loading ? null : onTap,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: selected ? Colors.white : color,
              shape: BoxShape.circle,
              border: selected ? Border.all(color: color, width: 2) : null,
            ),
            child: loading
                ? const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2.5,
                    ),
                  )
                : Icon(
                    icon,
                    color: selected ? color : Colors.white,
                    size: 28,
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ],
    );
  }
}

// ==========================================================
// CALL PROFILE IMAGE PROVIDER
// ----------------------------------------------------------
// Public/private profile pictures are either a real Cloudinary
// https:// URL, OR one of the bundled default-avatar picks from Me
// Page's "Choose Profile Image" sheet (a plain bundled-asset path like
// 'assets/images/profile/profile1.jpg', with NO scheme). The three
// call screens used to always wrap whatever string they were given in
// NetworkImage(...) unconditionally -- for anyone using a default
// avatar, that fed a bare asset path to the network image loader,
// which can't resolve a host from it and threw
// "Invalid argument(s): No host specified in URI" on every single
// build (flooding the console the whole time a call screen was on
// screen). Mirrors the same http/https-prefix check chat_page.dart /
// chat_screen.dart / private_chat_screen.dart already use for exactly
// this reason.
// ==========================================================

ImageProvider? callProfileImageProvider(String path) {
  final value = path.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return NetworkImage(value);
  }
  return AssetImage(value);
}

/// Small circular photo used on the call screens, with the same
/// person-icon fallback as before -- now routed through
/// [callProfileImageProvider] so a default bundled avatar renders
/// correctly instead of throwing.
class CallAvatar extends StatelessWidget {
  final String imagePath;
  final double radius;

  const CallAvatar({super.key, required this.imagePath, this.radius = 70});

  @override
  Widget build(BuildContext context) {
    final provider = callProfileImageProvider(imagePath);
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFF2A1B0E),
      backgroundImage: provider,
      child: provider == null
          ? Icon(Icons.person_rounded,
              color: Colors.white70, size: radius * 0.9)
          : null,
    );
  }
}

// ==========================================================
// LOCAL CAMERA PREVIEW CONTROLLER
// ----------------------------------------------------------
// Grabs the mic + front camera up front, on the ringing screens
// themselves (OutgoingCallScreen / IncomingCallScreen), instead of
// waiting until the call is accepted. This is what makes the caller's
// (and now the receiver's) own front camera turn on and show as the
// screen background while a video call is still ringing, and is also
// what a switch-camera button operates on.
//
// The same MediaStream this acquires is handed off to ActiveCallScreen
// (via its `initialLocalStream` param -> CallSignaling) once the call
// connects, so the camera is never re-requested / re-opened and the
// user is never prompted for camera permission twice. Ownership only
// transfers on a successful hand-off (see `handOff()`); every other
// outcome (declined/cancelled/missed/ended/failed) disposes the
// stream itself via [dispose].
// ==========================================================

class CallPreviewCamera {
  final RTCVideoRenderer renderer = RTCVideoRenderer();
  MediaStream? stream;
  bool _rendererInitialized = false;
  bool _handedOff = false;
  bool _disposed = false;

  bool get isReady => stream != null && _rendererInitialized;

  /// Requests the mic + front camera and starts rendering the preview.
  /// Throws if the OS denies camera/microphone permission -- callers
  /// should catch this and simply fall back to the non-preview layout
  /// (exactly like ActiveCallScreen already does for the main call).
  Future<void> start() async {
    await renderer.initialize();
    _rendererInitialized = true;
    if (_disposed) return;
    stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {'facingMode': 'user'},
    });
    if (_disposed) {
      // start() lost a race with an early dispose() (e.g. the caller
      // cancelled while permission dialog was up) -- don't leak it.
      for (final track in stream?.getTracks() ?? const []) {
        try {
          await track.stop();
        } catch (_) {}
      }
      try {
        await stream?.dispose();
      } catch (_) {}
      stream = null;
      return;
    }
    renderer.srcObject = stream;
  }

  /// Flips between front/back camera on the live preview track.
  Future<void> switchCamera() async {
    final tracks = stream?.getVideoTracks() ?? const [];
    if (tracks.isEmpty) return;
    final track = tracks.first;
    try {
      await Helper.switchCamera(track);
    } catch (_) {
      // No second camera / OEM refused the switch -- keep current one.
    }
  }

  /// Marks the stream as transferred to the active call so [dispose]
  /// won't stop its tracks. Only the renderer (which ActiveCallScreen
  /// never reuses -- it builds its own) is torn down here.
  MediaStream? handOff() {
    _handedOff = true;
    return stream;
  }

  Future<void> dispose() async {
    _disposed = true;
    if (!_handedOff) {
      for (final track in stream?.getTracks() ?? const []) {
        try {
          await track.stop();
        } catch (_) {}
      }
      try {
        await stream?.dispose();
      } catch (_) {}
    }
    stream = null;
    try {
      await renderer.dispose();
    } catch (_) {}
  }
}

/// Small round flip-camera button, positioned by the caller. Shared by
/// OutgoingCallScreen and IncomingCallScreen (both only show it once
/// their [CallPreviewCamera] is ready).
class CameraSwitchButton extends StatelessWidget {
  final VoidCallback onTap;

  const CameraSwitchButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Icon(
            Icons.cameraswitch_rounded,
            color: Colors.white,
            size: 24,
          ),
        ),
      ),
    );
  }
}
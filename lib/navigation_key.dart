import 'package:flutter/material.dart';

// ==========================================================
// ROOT NAVIGATOR KEY
// ----------------------------------------------------------
// Lives in its own file (instead of inline in main.dart, where it
// used to be declared) purely so services like CallService can push
// call screens over whatever the app is currently showing without
// creating a circular import between main.dart and services/*.dart.
// Behavior is unchanged -- main.dart just imports this file now and
// hands the same key to MaterialApp(navigatorKey: ...) as before.
// ==========================================================

final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>();

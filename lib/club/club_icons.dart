import 'package:flutter/material.dart';

/// One place for the icon that means "Club".
///
/// Community uses `Icons.public_rounded`, Groups use their own icons in
/// groupstab.dart, and the Club Leader / Owner badges inside a club use
/// `Icons.shield_rounded`. `interests_rounded` is not used anywhere else in
/// the app, so a Club can never be mistaken for a Community, a Group or a
/// role badge. Every Club surface (Hubs tab, create dialog, club header,
/// ...) must read its icon from here instead of hard-coding one.
class ClubIcons {
  ClubIcons._();

  static const IconData club = Icons.interests_rounded;
}

# Club Phase 6

Added:
- Moderator/owner moderation screen
- Report review: pending / reviewed / dismissed
- Remove reported discussion posts
- Warn members
- Temporary mute: 1 hour / 24 hours / 7 days
- Moderator-only moderation entry point
- Club moderation Firestore data
- Firestore security-rule merge reference in `firestore_club_rules.txt`

The app UI checks the club owner/moderator/leader role before exposing moderation controls. Firestore rules must also be merged into the project's main `firestore.rules`; client-side checks are not a security boundary.

# Club Module

A Club is a **standalone** entity. It does not belong to a Community and it is
not a Group. Community, Club and Group each have their own UI, icon and data.

## Structure

- `club/club_icons.dart` — the one icon that means "Club". Use `ClubIcons.club`
  everywhere; never hard-code a Community/Group icon on a Club surface.
- `club/models/club_model.dart` — Firestore data model.
- `club/pages/club_home_page.dart` — Club Home (header shows the Club ID) +
  section navigation shell.
- `club/widgets/club_section_nav.dart` — Home/Discussions/Members/Polls/
  Activities/Watchlist/Notifications/Rules navigation.
- `club/services/club_service.dart` — module entry-point export for the shared
  `ClubService`.
- `services/club_service.dart` — the implementation (create, join/leave,
  roles, recruitment).
- `pages/create_club_dialog.dart` — Create Club dialog (no community needed).
- `pages/community_page.dart` (Hubs → Clubs tab) — lists the clubs the signed-in
  user is a member of, straight from the `clubs` collection.
- `club/migration/migrate_legacy_clubs.js` — one-off script for clubs created
  before clubs became standalone.

## Club ID

Same rule as a Group ID: `@<club name>-<first 4 chars of creator's Account ID>`,
e.g. `@Coding Club-A1B2`. The Account ID is `users/{uid}.userId`.
`ClubService.buildClubId()` is used by both the live preview in the create
dialog and by `createClub()`, so the ID the user sees is the ID that is stored.
`createClub()` checks the `clubId` field first (older clubs), then claims
`clubIds/{clubId}` and writes the club in ONE transaction, so two clubs can never
get the same ID even if created at the same moment.

## Firestore

Collection: `clubs/{docId}`

Fields: `clubId`, `name`, `category`, `description`, `about`, `rules`,
`avatarUrl`, `logoUrl`, `bannerUrl`, `ownerUid`, `ownerAccountId`, `createdBy`,
`moderators`, `leaders`, `members`, `membersCount`, `pendingRequests`,
`openPositions`, `joinMode`, `createdAt`, `updatedAt`.

`clubIds/{encodedClubId}` — one small reservation doc per Club ID.

Recruitment applications live in `clubApplications` (`clubDocId`, `positionId`,
`applicantUid`, `status`, ...).

There is **no** `communityDocId` on clubs any more, and nothing in the app
reads it. Community screens (polls, search, contributions, activities, the
"This week" digest, the feed) do not query clubs.

### Older clubs

Clubs created before this change may still carry a `communityDocId` field and
have no `clubId`:

- `communityDocId` is ignored everywhere, so it is harmless to leave it.
- Without a `clubId` the Club ID chip is simply not shown in the header.
  Run `migration/migrate_legacy_clubs.js` (dry-run by default) to backfill
  `clubId`, and optionally to delete the stale `communityDocId`.
- Old polls with `scope: 'club'` in `communityPolls` are hidden from every
  Community poll list. Clubs keep their own polls (`club_polls_page.dart`).

Security rules: see `firestore_club_rules.txt` (reference to merge into the
project's main `firestore.rules`).

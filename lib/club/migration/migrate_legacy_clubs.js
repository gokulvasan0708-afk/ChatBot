/**
 * One-off migration for clubs created before clubs became standalone.
 *
 *   1. Backfills `clubId` ("@<name>-<first 4 of owner's Account ID>") -- the
 *      same rule as ClubService.buildClubId() in the app.
 *   2. Creates the `clubIds/{clubId}` reservation doc for every club, so the
 *      app's atomic uniqueness check also protects older clubs.
 *   3. Optionally removes the stale `communityDocId` field (--remove-community-id).
 *
 * Usage (from a folder with `npm i firebase-admin`):
 *   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
 *   node migrate_legacy_clubs.js                          # dry run, changes nothing
 *   node migrate_legacy_clubs.js --apply                  # backfill clubId
 *   node migrate_legacy_clubs.js --apply --remove-community-id
 *
 * Clubs whose generated ID is already taken (or whose owner has no Account ID)
 * are skipped and listed at the end so you can fix them by hand.
 */
const admin = require('firebase-admin');

const APPLY = process.argv.includes('--apply');
const REMOVE_COMMUNITY_ID = process.argv.includes('--remove-community-id');

admin.initializeApp();
const db = admin.firestore();

function buildClubId(name, accountId) {
  const trimmed = (name || '').trim();
  if (!trimmed) return '';
  const suffix = accountId.length >= 4 ? accountId.substring(0, 4) : accountId;
  return `@${trimmed}-${suffix}`;
}

async function main() {
  const snap = await db.collection('clubs').get();
  const taken = new Set(
    snap.docs.map((d) => d.data().clubId).filter((x) => typeof x === 'string' && x)
  );

  const key = (clubId) => encodeURIComponent(clubId); // same as ClubService._clubIdKey
  const skipped = [];
  let reserved = 0;
  let backfilled = 0;
  let cleaned = 0;

  for (const doc of snap.docs) {
    const data = doc.data();
    const update = {};

    if (!data.clubId) {
      const ownerUid =
        data.ownerUid || data.createdBy ||
        (Array.isArray(data.leaders) ? data.leaders[0] : '');
      let accountId = '';
      if (ownerUid) {
        const user = await db.collection('users').doc(ownerUid).get();
        accountId = String((user.data() || {}).userId || '');
      }
      const clubId = accountId ? buildClubId(data.name, accountId) : '';

      if (!clubId) {
        skipped.push(`${doc.id} (${data.name}): no owner Account ID / name`);
      } else if (taken.has(clubId)) {
        skipped.push(`${doc.id} (${data.name}): ${clubId} is already taken`);
      } else {
        update.clubId = clubId;
        if (!data.ownerAccountId) update.ownerAccountId = accountId;
        taken.add(clubId);
        backfilled++;
      }
    }

    const finalClubId = update.clubId || data.clubId;
    if (finalClubId) {
      const idRef = db.collection('clubIds').doc(key(finalClubId));
      if (!(await idRef.get()).exists) {
        reserved++;
        console.log(`${APPLY ? 'RESERVE' : 'would reserve'} ${finalClubId}`);
        if (APPLY) {
          await idRef.set({
            clubId: finalClubId,
            clubDocId: doc.id,
            ownerUid: data.ownerUid || data.createdBy || '',
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }
      }
    }

    if (REMOVE_COMMUNITY_ID && 'communityDocId' in data) {
      update.communityDocId = admin.firestore.FieldValue.delete();
      cleaned++;
    }

    if (Object.keys(update).length === 0) continue;
    console.log(`${APPLY ? 'UPDATE' : 'would update'} ${doc.id} (${data.name})`,
      Object.keys(update).join(', '));
    if (APPLY) await doc.ref.update(update);
  }

  console.log(`\n${APPLY ? 'Applied' : 'Dry run'}: ${backfilled} clubId backfilled, ${reserved} ID reservations, ` +
    `${cleaned} communityDocId removed, ${skipped.length} skipped.`);
  skipped.forEach((s) => console.log('  SKIPPED', s));
  if (!APPLY) console.log('Re-run with --apply to write these changes.');
}

main().catch((e) => { console.error(e); process.exit(1); });

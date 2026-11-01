// One-time backfill for existing users. Use Application Default Credentials.
// Run from backend/functions after npm install:
// node ../assign_existing_users.js
const admin = require('./functions/node_modules/firebase-admin');
admin.initializeApp({credential: admin.credential.applicationDefault()});
(async () => {
  let nextPageToken;
  let total = 0;
  do {
    const page = await admin.auth().listUsers(1000, nextPageToken);
    for (const user of page.users) {
      await admin.auth().setCustomUserClaims(user.uid, {
        ...(user.customClaims || {}), role: 'authenticated',
      });
      total++;
    }
    nextPageToken = page.pageToken;
  } while (nextPageToken);
  console.log(`Updated ${total} Firebase users. Sign out/in to refresh tokens.`);
})().catch((error) => {console.error(error); process.exitCode = 1;});

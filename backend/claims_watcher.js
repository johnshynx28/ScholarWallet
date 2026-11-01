// LIBRE ALTERNATIVE sa Cloud Function (walang Blaze plan).
// Patakbuhin habang ginagamit ang app. Bawat 3 segundo, nilalagyan nito ng
// role: 'authenticated' ang bawat Firebase user na wala pa nito.
//
// Setup (isang beses):
//  1. Firebase Console > Project settings > Service accounts >
//     "Generate new private key" > i-save bilang backend/serviceAccountKey.json
//  2. Ilagay sa PAREHONG folder ng file na ito (backend/claims_watcher.js)
//  3. Run:  node claims_watcher.js   (mula sa backend folder)
//
// HUWAG i-commit o ibigay kahit kanino ang serviceAccountKey.json.
const admin = require('./functions/node_modules/firebase-admin');
const key = require('./serviceAccountKey.json');

admin.initializeApp({ credential: admin.credential.cert(key) });

let running = false;

async function sweep() {
  if (running) return;
  running = true;
  try {
    let pageToken;
    do {
      const page = await admin.auth().listUsers(1000, pageToken);
      for (const user of page.users) {
        const claims = user.customClaims || {};
        if (claims.role !== 'authenticated') {
          await admin.auth().setCustomUserClaims(user.uid, {
            ...claims,
            role: 'authenticated',
          });
          console.log(new Date().toLocaleTimeString(), 'claim set:', user.email || user.uid);
        }
      }
      pageToken = page.pageToken;
    } while (pageToken);
  } catch (e) {
    console.error('Error:', e.message);
  } finally {
    running = false;
  }
}

console.log('Claims watcher running. Press Ctrl+C to stop.');
sweep();
setInterval(sweep, 3000);

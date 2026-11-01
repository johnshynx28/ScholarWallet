// Deploy in your OWN Firebase project. Never put service account keys in Flutter.
const functions = require('firebase-functions/v1');
const admin = require('firebase-admin');
admin.initializeApp();

// This claim allows a Firebase JWT to use Supabase's authenticated DB role.
// It does NOT make anyone a Scholar Wallet administrator.
exports.assignSupabaseRole = functions.auth.user().onCreate(async (user) => {
  const current = await admin.auth().getUser(user.uid);
  await admin.auth().setCustomUserClaims(user.uid, {
    ...(current.customClaims || {}),
    role: 'authenticated',
  });
});

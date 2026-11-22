// =====================================================================
// Massage Buddy settings. This is the ONLY file you need to edit, bro.
//
// 1. SUPABASE (required)
//    Supabase > your project > Project Settings > API
//      "Project URL"            -> supabaseUrl
//      "anon public" key        -> supabaseAnonKey   (this key is safe to be public)
//    NEVER put the "service_role" key here.
//
// 2. FIREBASE (optional, for phone notifications)
//    Leave firebase: null until you set it up. The apps still work and
//    still show notifications inside the app (the bell).
//    Firebase console > Project settings > General > Your apps > Web app
//      copy apiKey, authDomain, projectId, messagingSenderId, appId
//    Firebase console > Project settings > Cloud Messaging > Web Push certificates
//      "Key pair"               -> vapidKey
// =====================================================================
self.MB_CONFIG = {
  appVersion: "1.00",
  supabaseUrl: "https://YOUR-PROJECT.supabase.co",
  supabaseAnonKey: "YOUR-ANON-PUBLIC-KEY",

  firebase: null
  // firebase: {
  //   apiKey: "....",
  //   authDomain: "....firebaseapp.com",
  //   projectId: "....",
  //   messagingSenderId: "....",
  //   appId: "....",
  //   vapidKey: "...."
  // }
};

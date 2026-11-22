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
  appVersion: "1.10",
  supabaseUrl: "https://ffzkblztfmdzdycndyaz.supabase.co",
  supabaseAnonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZmemtibHp0Zm1kemR5Y25keWF6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTUzNTE0NTUsImV4cCI6MjExMDkyNzQ1NX0.UTILgHBB9N2kCwdW0egXJqC5VqM8atG1iHqI1xH00v8",

  // Firebase project "massagebuddy" (public web config + Web Push key; safe to be public)
  firebase: {
    apiKey: "AIzaSyD3TOYCs1HEfgUj53-Plg4zNac2Z2oDrOQ",
    authDomain: "massagebuddy.firebaseapp.com",
    projectId: "massagebuddy",
    storageBucket: "massagebuddy.firebasestorage.app",
    messagingSenderId: "128507808042",
    appId: "1:128507808042:web:b7478750911749d1973653",
    vapidKey: "BIEYCVBTUKsuOXNj-4dyemQUwkGExM_txDtfWGmbsSTcmU2prTgk-MZ3QVAJN30hsiTqvH8msOb0QIPhYI8ptr4"
  }
};

// Buddy POS configuration.
// Fill in from Supabase > Project Settings > API (these two values are public by design;
// the data is protected by the Row Level Security rules in setup.sql).
window.POS_CONFIG = {
  supabaseUrl: "",        // e.g. "https://abcdefghijklmnop.supabase.co"
  supabaseAnonKey: "",    // the "anon public" key
  appName: "Buddy POS",   // your platform name (shown before a seller has a store)
  brandedApps: false      // set to true after deploying the "pos-manifest" Edge Function
};

# Massage Buddy – setup steps (v1.00)

Web addresses once uploaded:
- Customers: `https://pasuyobuddy.com/massage/`
- Therapists: `https://pasuyobuddy.com/massage/therapist.html`
- Admin (you): `https://pasuyobuddy.com/massage/admin.html`

---

## Part A – Database (Supabase) ~10 minutes

1. Go to **supabase.com** → **New project** (top right).
   - Name: `massagebuddy`, Region: **Singapore**, make a strong database password (keep it safe).
   - Use a NEW project (not the PasuyoBuddy one), so login emails say Massage Buddy, not PasuyoBuddy.
2. Wait until the project is ready (about 2 minutes).
3. Left menu → **SQL Editor** → **New query**.
4. Open `massage/sql/massagebuddy_setup_v1.00_20261122.sql`, copy **everything**, paste, press **Run**.
   - At the bottom you should see **ok = 1**.
5. Left menu → **Project Settings** (gear) → **API**. Copy:
   - **Project URL**
   - **anon public** key (NOT the service_role key)
6. Open `massage/config.js` and paste them into `supabaseUrl` and `supabaseAnonKey`.
7. Left menu → **Authentication** → **URL Configuration**:
   - Site URL: `https://pasuyobuddy.com/massage/`
   - Redirect URLs → Add: `https://pasuyobuddy.com/massage/**`

## Part B – Upload to the website

Upload the whole `massage` folder into the `pasuyobuddy.github.io` repo (keep the folder name `massage`).
Commit changes → wait 1–10 minutes → open `pasuyobuddy.com/massage/`.

## Part C – Make yourself admin

1. Open `pasuyobuddy.com/massage/admin.html` → **Create an account** with your email.
2. The page shows a small SQL with your email. Copy it → Supabase → **SQL Editor** → **Run**.
3. Refresh the admin page. Done.

## Part D – Test it (5 minutes)

1. On your phone open `.../massage/therapist.html` → create a therapist account → fill profile, photo, ID → **Submit**.
2. Set **Services** (turn on + price) and **Schedule** (days + hours).
3. Admin → **Therapists** → **Approve**.
4. Another phone/browser: `.../massage/` → choose therapist → massage → date/time → address → **Confirm booking**.
5. Therapist → **Accept**. Customer sees **Confirmed**.

---

## Optional

### Google login
Supabase → **Authentication** → **Sign In / Providers** → **Google** → turn on.
Needs a Google Cloud "OAuth client" (Client ID + Secret). Ask Claude for click-by-click steps when ready.

### Phone (SMS code) login
Supabase → **Authentication** → **Sign In / Providers** → **Phone** → needs an SMS provider (e.g. Twilio, Semaphore via Twilio-compatible). SMS costs money per message. Email login works without it.

### Phone notifications (Firebase, free)
The app already shows notifications inside the app (bell icon). Phone pop-up alerts need:
1. **console.firebase.google.com** → Add project `massagebuddy` (Analytics off).
2. Project settings (gear) → General → **Your apps** → Web `</>` → register → copy the config values into `config.js` → `firebase: { ... }`.
3. Project settings → **Cloud Messaging** → Web Push certificates → **Generate key pair** → copy into `vapidKey`.
4. Project settings → **Service accounts** → **Generate new private key** → downloads a JSON file. **Keep it secret, never upload it to GitHub.**
5. Supabase → **Edge Functions** → **Deploy a new function** → **Via Editor** → name `mb-push` → paste `massage/supabase/functions/mb-push/index.ts` → Deploy.
6. Supabase → **Edge Functions** → **Secrets** → add `FIREBASE_SERVICE_ACCOUNT` = paste the whole JSON file content yourself.
7. Supabase → **Database** → **Webhooks** → **Create** → table `mb_notifications`, event **Insert**, type **Supabase Edge Functions**, function `mb-push` → turn on "Add auth header with service key" → Create.
8. Upload the new `config.js`. Users tap **Turn on notifications** in the app.

iPhone: works only after the customer taps Share → **Add to Home Screen** (iOS 16.4+).

---

## Settings you can change (Admin → Settings)
Commission % (default 20), travel time between bookings (30 min), minimum notice (120 min),
accept time limit (60 min), customer cancel limit (3 hours), days ahead (14), support GCash number & email.

## How money works (v1 = cash)
Customer pays the therapist cash after the massage → therapist owes Massage Buddy the commission →
therapist sends it by GCash → you record it in Admin → **Money** → **Record payment**.
Online payment (GCash / card) can be added in version 2.

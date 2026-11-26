# Buddy POS – setup guide (about 15 minutes, one time)

Buddy POS is a subscription point-of-sale platform. Each seller signs up, creates
their store (name + logo), gets a free trial, then pays you monthly or yearly by
GCash/bank. You approve payments in the Admin dashboard.

It works on **Android, iPhone/iPad, Windows PC and Mac** (installable app, works offline).

## 1. Create the database (Supabase, free)
1. Go to https://supabase.com, then **New project**, name it e.g. `buddy-pos`.
2. Open **SQL Editor**, paste all of [`setup.sql`](setup.sql), and click **Run**.
3. Go to **Authentication › URL Configuration** and set **Site URL** to
   `https://pasuyobuddy.com/pos/`. Under **Redirect URLs** add `https://pasuyobuddy.com/pos/*`.

## 2. Connect the app
Open **Project Settings › API** and copy the **Project URL** and the **anon public**
key into [`config.js`](config.js) (or send them to Claude to do it).

## 3. Make yourself the admin
Open `https://pasuyobuddy.com/pos/`, create an account, then run this in the **SQL Editor**:

```sql
insert into public.pos_admins(user_id)
select id from auth.users where email = 'YOUR-EMAIL@example.com'
on conflict do nothing;
```

Open `https://pasuyobuddy.com/pos/admin.html` and go to **Prices & payment details**.
Set your monthly/yearly price, free-trial days, GCash number/name, upload your GCash
QR, and add a support contact.

## 4. (Recommended) Each store's own app name & icon
1. In Supabase, go to **Edge Functions › Deploy a new function › Via editor**, and name it **`pos-manifest`**.
2. Paste [`supabase/functions/pos-manifest/index.ts`](supabase/functions/pos-manifest/index.ts) and click **Deploy**.
3. In the function's **Details / Settings**, turn **Verify JWT** **off**.
4. In `config.js`, set `brandedApps: true`.

Now, when a seller installs their link (`…/pos/?s=their-store`), the home screen or
desktop shows **their** store name and logo. On iPhone this already works without
the function.

## Daily use
| Who | What |
|---|---|
| **Seller (owner)** | Open `…/pos/`, then **Create your store**, then sell. **Settings › Subscription › Subscribe now**: pay, attach the screenshot, and submit. **Settings › Staff › Invite a cashier** gives a 6-letter code. |
| **Cashier** | Open the store link, then **Create account**, enter the invite code, then sell. |
| **You (admin)** | `…/pos/admin.html`. **Payments**: check that the money arrived, then **Approve & extend**. **Subscribers**: see every store, gift months, suspend, change the staff limit. |

## How subscriptions work
- A new store gets the free trial (default 14 days, set in Admin).
- Approving a monthly or yearly payment extends from the later of today or the current end date.
- When it expires, there is a 3-day grace period, then **selling is locked** until renewal.
  Sellers can still see their products and sales.
- Sellers can never change their own plan; the database blocks it.

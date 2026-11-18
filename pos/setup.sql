-- =====================================================================
-- Buddy POS – database setup (v2: subscriptions, staff, branded apps)
-- Run in Supabase > SQL Editor of the POS project. Safe to run again.
--
--  * Sellers sign up, create a store (name, logo, link like ?s=my-store)
--    and get a free trial. After that they pay monthly/yearly by GCash or
--    bank; the platform admin approves the payment and the plan extends.
--  * Each store has one owner and can invite cashiers with a code.
--  * Row Level Security: users only ever see their own store's data.
--
-- After running this, make yourself the platform admin (replace email):
--   insert into public.pos_admins(user_id)
--   select id from auth.users where email = 'you@example.com'
--   on conflict do nothing;
-- =====================================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------- platform settings
create table if not exists public.pos_settings (
  id              int primary key default 1 check (id = 1),
  app_name        text not null default 'Buddy POS',
  trial_days      int  not null default 14 check (trial_days between 0 and 365),
  price_monthly   numeric(10,2) not null default 299 check (price_monthly >= 0),
  price_yearly    numeric(10,2) not null default 2990 check (price_yearly >= 0),
  gcash_name      text,
  gcash_number    text,
  gcash_qr        text,            -- QR image as data URL
  bank_details    text,
  support_contact text,
  updated_at      timestamptz not null default now()
);
insert into public.pos_settings(id) values (1) on conflict (id) do nothing;

create table if not exists public.pos_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

-- ---------------------------------------------------------------- stores
create table if not exists public.pos_stores (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null unique default auth.uid() references auth.users(id) on delete cascade,
  slug           text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{2,39}$'),
  name           text not null check (char_length(name) between 1 and 80),
  logo           text,                       -- square image data URL (also used as the app icon)
  address        text,
  phone          text,
  receipt_footer text default 'Thank you, come again!',
  currency       text not null default '₱',
  theme_color    text not null default '#1E3A8A',
  plan           text not null default 'trial' check (plan in ('trial','pro','suspended')),
  trial_ends_at  timestamptz,
  paid_until     timestamptz,
  max_staff      int not null default 5,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint pos_stores_logo_size check (logo is null or char_length(logo) <= 400000)
);

-- ------------------------------------------------------- members (staff)
create table if not exists public.pos_members (
  store_id   uuid not null references public.pos_stores(id) on delete cascade,
  user_id    uuid not null unique references auth.users(id) on delete cascade,  -- one store per login
  role       text not null check (role in ('owner','cashier')),
  name       text,
  email      text,
  created_at timestamptz not null default now(),
  primary key (store_id, user_id)
);

create table if not exists public.pos_invites (
  code        text primary key,
  store_id    uuid not null references public.pos_stores(id) on delete cascade,
  role        text not null default 'cashier' check (role in ('cashier')),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '7 days',
  used_by     uuid references auth.users(id) on delete set null,
  used_at     timestamptz
);

-- -------------------------------------------------------------- products
create table if not exists public.pos_products (
  id          uuid primary key,
  store_id    uuid not null references public.pos_stores(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 120),
  price       numeric(12,2) not null default 0 check (price >= 0),
  category    text,
  barcode     text,
  deleted     boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists pos_products_store_updated on public.pos_products(store_id, updated_at);

-- ----------------------------------------------------------------- sales
create table if not exists public.pos_sales (
  id              uuid primary key,
  store_id        uuid not null references public.pos_stores(id) on delete cascade,
  receipt_no      text not null,
  items           jsonb not null default '[]'::jsonb,
  subtotal        numeric(12,2) not null default 0,
  discount        numeric(12,2) not null default 0,
  total           numeric(12,2) not null default 0,
  payment_method  text not null default 'cash',
  cash_received   numeric(12,2),
  change_due      numeric(12,2),
  cashier         text,
  cashier_id      uuid default auth.uid(),
  device          text,
  sold_at         timestamptz not null,
  voided          boolean not null default false,
  voided_at       timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists pos_sales_store_updated on public.pos_sales(store_id, updated_at);
create index if not exists pos_sales_store_sold on public.pos_sales(store_id, sold_at);

-- ------------------------------------------------- subscription payments
create table if not exists public.pos_payments (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null references public.pos_stores(id) on delete cascade,
  period       text not null check (period in ('monthly','yearly')),
  months       int  not null default 1,
  amount       numeric(10,2) not null default 0,
  method       text not null default 'gcash' check (method in ('gcash','bank','other')),
  reference    text check (char_length(reference) <= 80),
  proof        text,                       -- screenshot as data URL
  status       text not null default 'pending' check (status in ('pending','approved','rejected')),
  note         text,
  submitted_by uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  reviewed_at  timestamptz,
  constraint pos_payments_proof_size check (proof is null or char_length(proof) <= 700000)
);
create index if not exists pos_payments_status on public.pos_payments(status, created_at);

-- ================================================================ helpers
create or replace function public.pos_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pos_admins where user_id = auth.uid());
$$;

create or replace function public.pos_is_member(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pos_members m where m.store_id = sid and m.user_id = auth.uid());
$$;

create or replace function public.pos_is_owner(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pos_members m where m.store_id = sid and m.user_id = auth.uid() and m.role = 'owner');
$$;

-- Active = trial or paid period not over (+3 days grace so offline sales can still upload).
create or replace function public.pos_store_active(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.pos_stores s
    where s.id = sid and s.plan <> 'suspended'
      and greatest(coalesce(s.trial_ends_at, '-infinity'), coalesce(s.paid_until, '-infinity')) > now() - interval '3 days');
$$;

-- updated_at is always server time
create or replace function public.pos_touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists pos_stores_touch on public.pos_stores;
create trigger pos_stores_touch before insert or update on public.pos_stores
  for each row execute function public.pos_touch_updated_at();
drop trigger if exists pos_products_touch on public.pos_products;
create trigger pos_products_touch before insert or update on public.pos_products
  for each row execute function public.pos_touch_updated_at();
drop trigger if exists pos_sales_touch on public.pos_sales;
create trigger pos_sales_touch before insert or update on public.pos_sales
  for each row execute function public.pos_touch_updated_at();

-- New store: start the free trial; sellers can never change their own plan/dates.
-- (runs with the caller's own role so it can tell a seller from the SQL editor/admin)
create or replace function public.pos_store_guard() returns trigger
language plpgsql security invoker set search_path = public as $$
-- privileged = SQL editor / service key / platform admin (not a normal signed-in seller)
declare privileged boolean := current_user not in ('authenticated', 'anon')
                              or coalesce(auth.role(), '') = 'service_role' or public.pos_is_admin();
begin
  new.slug := lower(new.slug);
  if tg_op = 'INSERT' then
    if not privileged then
      new.owner_id := auth.uid();
      new.plan := 'trial';
      new.paid_until := null;
      new.max_staff := 5;
      new.trial_ends_at := now() + make_interval(days => (select trial_days from public.pos_settings where id = 1));
    end if;
  elsif not privileged then
    new.owner_id := old.owner_id;
    new.plan := old.plan;
    new.trial_ends_at := old.trial_ends_at;
    new.paid_until := old.paid_until;
    new.max_staff := old.max_staff;
  end if;
  return new;
end $$;
drop trigger if exists pos_stores_plan on public.pos_stores;   -- v1 trigger name
drop trigger if exists pos_stores_guard on public.pos_stores;
create trigger pos_stores_guard before insert or update on public.pos_stores
  for each row execute function public.pos_store_guard();

-- The owner automatically becomes a member of the new store.
create or replace function public.pos_store_add_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.pos_members(store_id, user_id, role, name, email)
  select new.id, new.owner_id, 'owner', split_part(u.email, '@', 1), u.email
  from auth.users u where u.id = new.owner_id
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists pos_stores_owner on public.pos_stores;
create trigger pos_stores_owner after insert on public.pos_stores
  for each row execute function public.pos_store_add_owner();

-- Payment amount is always computed from the current prices (never trusted from the app).
create or replace function public.pos_payment_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare st public.pos_settings;
begin
  select * into st from public.pos_settings where id = 1;
  new.months := case when new.period = 'yearly' then 12 else 1 end;
  new.amount := case when new.period = 'yearly' then st.price_yearly else st.price_monthly end;
  new.status := 'pending';
  new.note := null;
  new.reviewed_at := null;
  new.submitted_by := auth.uid();
  return new;
end $$;
drop trigger if exists pos_payments_guard on public.pos_payments;
create trigger pos_payments_guard before insert on public.pos_payments
  for each row execute function public.pos_payment_guard();

-- ============================================================ RLS policies
alter table public.pos_settings enable row level security;
alter table public.pos_admins   enable row level security;
alter table public.pos_stores   enable row level security;
alter table public.pos_members  enable row level security;
alter table public.pos_invites  enable row level security;
alter table public.pos_products enable row level security;
alter table public.pos_sales    enable row level security;
alter table public.pos_payments enable row level security;

-- settings: everyone can read prices / GCash details, only admins change them
drop policy if exists "read settings" on public.pos_settings;
create policy "read settings" on public.pos_settings for select to anon, authenticated using (true);
drop policy if exists "admin settings" on public.pos_settings;
create policy "admin settings" on public.pos_settings for update to authenticated
  using (public.pos_is_admin()) with check (public.pos_is_admin());

drop policy if exists "admins see admins" on public.pos_admins;
create policy "admins see admins" on public.pos_admins for select to authenticated using (user_id = auth.uid() or public.pos_is_admin());

-- stores
drop policy if exists "own store" on public.pos_stores;      -- v1 policy
drop policy if exists "store read" on public.pos_stores;
create policy "store read" on public.pos_stores for select to authenticated
  using (owner_id = auth.uid() or public.pos_is_member(id) or public.pos_is_admin());
drop policy if exists "store create" on public.pos_stores;
create policy "store create" on public.pos_stores for insert to authenticated
  with check (owner_id = auth.uid() and not exists (select 1 from public.pos_members m where m.user_id = auth.uid()));
drop policy if exists "store update" on public.pos_stores;
create policy "store update" on public.pos_stores for update to authenticated
  using (public.pos_is_owner(id) or public.pos_is_admin())
  with check (public.pos_is_owner(id) or public.pos_is_admin());

-- members
drop policy if exists "members read" on public.pos_members;
create policy "members read" on public.pos_members for select to authenticated
  using (user_id = auth.uid() or public.pos_is_member(store_id) or public.pos_is_admin());
drop policy if exists "owner removes cashier" on public.pos_members;
create policy "owner removes cashier" on public.pos_members for delete to authenticated
  using (role = 'cashier' and public.pos_is_owner(store_id));

-- invites
drop policy if exists "owner invites" on public.pos_invites;
create policy "owner invites" on public.pos_invites for select to authenticated using (public.pos_is_owner(store_id));
drop policy if exists "owner deletes invites" on public.pos_invites;
create policy "owner deletes invites" on public.pos_invites for delete to authenticated using (public.pos_is_owner(store_id));

-- products: all staff read, only the owner edits
drop policy if exists "own products" on public.pos_products;  -- v1 policy
drop policy if exists "products read" on public.pos_products;
create policy "products read" on public.pos_products for select to authenticated using (public.pos_is_member(store_id));
drop policy if exists "products insert" on public.pos_products;
create policy "products insert" on public.pos_products for insert to authenticated with check (public.pos_is_owner(store_id));
drop policy if exists "products update" on public.pos_products;
create policy "products update" on public.pos_products for update to authenticated
  using (public.pos_is_owner(store_id)) with check (public.pos_is_owner(store_id));

-- sales: staff sell while the subscription is active; only the owner can void
drop policy if exists "own sales" on public.pos_sales;        -- v1 policy
drop policy if exists "sales read" on public.pos_sales;
create policy "sales read" on public.pos_sales for select to authenticated using (public.pos_is_member(store_id));
drop policy if exists "sales insert" on public.pos_sales;
create policy "sales insert" on public.pos_sales for insert to authenticated
  with check (public.pos_is_member(store_id) and public.pos_store_active(store_id) and voided = false);
drop policy if exists "sales void" on public.pos_sales;
create policy "sales void" on public.pos_sales for update to authenticated
  using (public.pos_is_owner(store_id)) with check (public.pos_is_owner(store_id));

-- payments: owner submits and sees own; admin sees all (reviews via function)
drop policy if exists "payments read" on public.pos_payments;
create policy "payments read" on public.pos_payments for select to authenticated
  using (public.pos_is_owner(store_id) or public.pos_is_admin());
drop policy if exists "payments submit" on public.pos_payments;
create policy "payments submit" on public.pos_payments for insert to authenticated
  with check (public.pos_is_owner(store_id));

grant select on public.pos_settings to anon, authenticated;
grant update on public.pos_settings to authenticated;
grant select on public.pos_admins to authenticated;
grant select, insert, update on public.pos_stores to authenticated;
grant select, delete on public.pos_members, public.pos_invites to authenticated;
grant select, insert, update on public.pos_products, public.pos_sales to authenticated;
grant select, insert on public.pos_payments to authenticated;

-- ============================================================ functions
-- Owner creates a one-time invite code for a cashier (valid 7 days).
create or replace function public.pos_create_invite() returns text
language plpgsql security definer set search_path = public as $$
declare sid uuid; c text; n int; lim int;
begin
  select m.store_id into sid from public.pos_members m where m.user_id = auth.uid() and m.role = 'owner';
  if sid is null then raise exception 'Only the store owner can invite staff'; end if;
  select count(*) into n from public.pos_members where store_id = sid;
  select max_staff into lim from public.pos_stores where id = sid;
  if n >= lim then raise exception 'Staff limit reached (% people)', lim; end if;
  loop
    c := upper(substr(translate(encode(gen_random_bytes(8), 'base64'), '+/=0O1IL', ''), 1, 6));
    exit when char_length(c) = 6 and not exists (select 1 from public.pos_invites where code = c);
  end loop;
  insert into public.pos_invites(code, store_id) values (c, sid);
  return c;
end $$;

-- A new user joins a store with an invite code.
create or replace function public.pos_accept_invite(p_code text, p_name text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare inv public.pos_invites; n int; lim int; em text;
begin
  if auth.uid() is null then raise exception 'Please sign in first'; end if;
  if exists (select 1 from public.pos_members where user_id = auth.uid()) then
    raise exception 'This account already belongs to a store';
  end if;
  select * into inv from public.pos_invites where code = upper(trim(p_code)) for update;
  if inv.code is null or inv.used_by is not null or inv.expires_at < now() then
    raise exception 'Invite code is invalid or expired';
  end if;
  select count(*) into n from public.pos_members where store_id = inv.store_id;
  select max_staff into lim from public.pos_stores where id = inv.store_id;
  if n >= lim then raise exception 'This store has reached its staff limit'; end if;
  select email into em from auth.users where id = auth.uid();
  insert into public.pos_members(store_id, user_id, role, name, email)
  values (inv.store_id, auth.uid(), inv.role, coalesce(nullif(trim(p_name), ''), split_part(em, '@', 1)), em);
  update public.pos_invites set used_by = auth.uid(), used_at = now() where code = inv.code;
  return inv.store_id;
end $$;

-- Public branding for a store link (?s=slug): shown on the login screen and used for the app icon.
create or replace function public.pos_public_brand(p_slug text)
returns table (name text, logo text, theme_color text, slug text)
language sql stable security definer set search_path = public as $$
  select s.name, s.logo, s.theme_color, s.slug from public.pos_stores s where s.slug = lower(p_slug);
$$;

-- Is a store link name still free?
create or replace function public.pos_slug_available(p_slug text) returns boolean
language sql stable security definer set search_path = public as $$
  select lower(p_slug) ~ '^[a-z0-9][a-z0-9-]{2,39}$'
     and not exists (select 1 from public.pos_stores where slug = lower(p_slug));
$$;

-- Admin: approve or reject a payment. Approving extends the plan from the later of
-- now / current paid date / end of trial.
create or replace function public.pos_admin_review_payment(p_id uuid, p_approve boolean, p_note text default null)
returns public.pos_stores
language plpgsql security definer set search_path = public as $$
declare pay public.pos_payments; st public.pos_stores;
begin
  if not public.pos_is_admin() then raise exception 'Admins only'; end if;
  select * into pay from public.pos_payments where id = p_id for update;
  if pay.id is null then raise exception 'Payment not found'; end if;
  if pay.status <> 'pending' then raise exception 'This payment was already reviewed'; end if;
  update public.pos_payments set status = case when p_approve then 'approved' else 'rejected' end,
         note = p_note, reviewed_at = now() where id = p_id;
  if p_approve then
    update public.pos_stores
       set plan = 'pro',
           paid_until = greatest(now(), coalesce(paid_until, now()), coalesce(trial_ends_at, now()))
                        + make_interval(months => pay.months)
     where id = pay.store_id
     returning * into st;
  else
    select * into st from public.pos_stores where id = pay.store_id;
  end if;
  return st;
end $$;

-- Admin: set a store's plan manually (gift months, suspend, fix mistakes).
create or replace function public.pos_admin_set_plan(p_store uuid, p_plan text, p_paid_until timestamptz, p_max_staff int default null)
returns public.pos_stores
language plpgsql security definer set search_path = public as $$
declare st public.pos_stores;
begin
  if not public.pos_is_admin() then raise exception 'Admins only'; end if;
  update public.pos_stores set plan = p_plan, paid_until = p_paid_until,
         max_staff = coalesce(p_max_staff, max_staff)
   where id = p_store returning * into st;
  return st;
end $$;

-- Admin: overview of all stores.
create or replace function public.pos_admin_stores()
returns table (id uuid, slug text, name text, logo text, plan text, trial_ends_at timestamptz, paid_until timestamptz,
               max_staff int, created_at timestamptz, owner_email text, staff int, last_sale_at timestamptz, sales_30d numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.pos_is_admin() then raise exception 'Admins only'; end if;
  return query
  select s.id, s.slug, s.name, s.logo, s.plan, s.trial_ends_at, s.paid_until, s.max_staff, s.created_at,
         (select u.email::text from auth.users u where u.id = s.owner_id),
         (select count(*)::int from public.pos_members m where m.store_id = s.id),
         (select max(x.sold_at) from public.pos_sales x where x.store_id = s.id),
         (select coalesce(sum(x.total), 0) from public.pos_sales x
           where x.store_id = s.id and not x.voided and x.sold_at > now() - interval '30 days')
  from public.pos_stores s order by s.created_at desc;
end $$;

revoke all on function public.pos_is_admin(), public.pos_is_member(uuid), public.pos_is_owner(uuid),
  public.pos_store_active(uuid), public.pos_create_invite(), public.pos_accept_invite(text, text),
  public.pos_admin_review_payment(uuid, boolean, text), public.pos_admin_set_plan(uuid, text, timestamptz, int),
  public.pos_admin_stores(), public.pos_public_brand(text), public.pos_slug_available(text) from public;
grant execute on function public.pos_is_admin(), public.pos_is_member(uuid), public.pos_is_owner(uuid),
  public.pos_store_active(uuid), public.pos_create_invite(), public.pos_accept_invite(text, text),
  public.pos_admin_review_payment(uuid, boolean, text), public.pos_admin_set_plan(uuid, text, timestamptz, int),
  public.pos_admin_stores(), public.pos_slug_available(text) to authenticated;
grant execute on function public.pos_public_brand(text) to anon, authenticated;

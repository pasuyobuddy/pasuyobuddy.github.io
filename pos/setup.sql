-- =====================================================================
-- Buddy POS – database setup (v1)
-- Run once in Supabase > SQL Editor of the POS project. Safe to run again.
--
--  * Every seller signs up with email + password and owns ONE store.
--  * Each store has its own name, logo, colors and receipt text.
--  * Row Level Security: a seller can only ever see their own store,
--    products and sales.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- stores
create table if not exists public.pos_stores (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null unique default auth.uid() references auth.users(id) on delete cascade,
  name           text not null check (char_length(name) between 1 and 80),
  logo           text,                       -- small PNG/JPEG data URL (resized in the app, max ~200 KB)
  address        text,
  phone          text,
  receipt_footer text default 'Thank you, come again!',
  currency       text not null default '₱',
  theme_color    text not null default '#1E3A8A',
  plan           text not null default 'free',  -- for future subscriptions
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint pos_stores_logo_size check (logo is null or char_length(logo) <= 300000)
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
  items           jsonb not null default '[]'::jsonb,   -- [{product_id,name,price,qty}]
  subtotal        numeric(12,2) not null default 0,
  discount        numeric(12,2) not null default 0,
  total           numeric(12,2) not null default 0,
  payment_method  text not null default 'cash',
  cash_received   numeric(12,2),
  change_due      numeric(12,2),
  cashier         text,
  device          text,
  sold_at         timestamptz not null,               -- time on the device when the sale was made
  voided          boolean not null default false,
  voided_at       timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists pos_sales_store_updated on public.pos_sales(store_id, updated_at);
create index if not exists pos_sales_store_sold on public.pos_sales(store_id, sold_at);

-- ------------------------------------------- updated_at is always server time
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

-- ------------------------------------------------------------ security (RLS)
create or replace function public.pos_owns_store(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pos_stores s where s.id = sid and s.owner_id = auth.uid());
$$;
revoke all on function public.pos_owns_store(uuid) from public;
grant execute on function public.pos_owns_store(uuid) to authenticated;

alter table public.pos_stores   enable row level security;
alter table public.pos_products enable row level security;
alter table public.pos_sales    enable row level security;

drop policy if exists "own store" on public.pos_stores;
create policy "own store" on public.pos_stores
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

drop policy if exists "own products" on public.pos_products;
create policy "own products" on public.pos_products
  for all to authenticated
  using (public.pos_owns_store(store_id))
  with check (public.pos_owns_store(store_id));

drop policy if exists "own sales" on public.pos_sales;
create policy "own sales" on public.pos_sales
  for all to authenticated
  using (public.pos_owns_store(store_id))
  with check (public.pos_owns_store(store_id));

-- Sellers may not change their own plan (reserved for subscriptions/admin).
create or replace function public.pos_protect_plan() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.plan := 'free';
  elsif new.plan is distinct from old.plan and coalesce(auth.role(), '') <> 'service_role' then
    new.plan := old.plan;
  end if;
  return new;
end $$;
drop trigger if exists pos_stores_plan on public.pos_stores;
create trigger pos_stores_plan before insert or update on public.pos_stores
  for each row execute function public.pos_protect_plan();

grant select, insert, update, delete on public.pos_stores, public.pos_products, public.pos_sales to authenticated;

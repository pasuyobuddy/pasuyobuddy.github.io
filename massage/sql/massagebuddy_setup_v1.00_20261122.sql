-- =====================================================================
-- Massage Buddy - database setup v1.00 (2026-11-22)
--
-- What it does:
--   Creates everything the Massage Buddy apps need:
--   customers, therapists, services & prices, weekly schedule,
--   bookings (automatic time slots), reviews, notifications,
--   push-notification tokens, commission settlements, settings,
--   photo/document storage, and automatic reminders.
--
-- How to run:
--   Supabase > SQL Editor > New query > paste ALL of this > Run.
--   This is the first Massage Buddy SQL. Safe to run again.
--
-- All tables start with "mb_" so they never clash with other apps.
-- Apps only talk to the database through the functions below
-- (security-definer RPCs). Tables are locked (RLS on, no direct access).
-- =====================================================================

set lock_timeout = '15s';

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------
create table if not exists public.mb_profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  phone       text not null default '',
  email       text not null default '',
  address     text not null default '',
  area        text not null default '',
  blocked     boolean not null default false,
  created_at  timestamptz not null default now()
);

create table if not exists public.mb_admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);

create table if not exists public.mb_therapists (
  id               uuid primary key references public.mb_profiles(id) on delete cascade,
  display_name     text not null default '',
  bio              text not null default '',
  gender           text not null default 'female' check (gender in ('female','male','other')),
  area             text not null default '',
  experience_years int  not null default 0 check (experience_years between 0 and 60),
  photo_url        text not null default '',
  photos           text[] not null default '{}',
  id_doc_path      text not null default '',
  cert_doc_path    text not null default '',
  status           text not null default 'pending' check (status in ('pending','approved','suspended')),
  admin_note       text not null default '',
  rating_avg       numeric(3,2) not null default 0,
  rating_count     int not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table if not exists public.mb_massage_types (
  id          serial primary key,
  name        text not null unique,
  description text not null default '',
  active      boolean not null default true,
  sort        int not null default 0
);

create table if not exists public.mb_services (
  id            bigserial primary key,
  therapist_id  uuid not null references public.mb_therapists(id) on delete cascade,
  type_id       int  not null references public.mb_massage_types(id),
  duration_min  int  not null check (duration_min in (60,90,120)),
  price         numeric(10,2) not null check (price >= 100 and price <= 50000),
  active        boolean not null default true,
  unique (therapist_id, type_id, duration_min)
);

create table if not exists public.mb_availability (
  id            bigserial primary key,
  therapist_id  uuid not null references public.mb_therapists(id) on delete cascade,
  weekday       int  not null check (weekday between 0 and 6),   -- 0 = Sunday
  start_time    time not null,
  end_time      time not null,
  check (end_time > start_time)
);

create table if not exists public.mb_blocked_dates (
  id            bigserial primary key,
  therapist_id  uuid not null references public.mb_therapists(id) on delete cascade,
  day           date not null,
  reason        text not null default '',
  unique (therapist_id, day)
);

create table if not exists public.mb_bookings (
  id                bigserial primary key,
  customer_id       uuid not null references public.mb_profiles(id),
  therapist_id      uuid not null references public.mb_therapists(id),
  service_id        bigint references public.mb_services(id) on delete set null,
  type_name         text not null,
  duration_min      int  not null,
  start_at          timestamptz not null,
  end_at            timestamptz not null,
  address           text not null,
  area              text not null default '',
  contact_phone     text not null default '',
  notes             text not null default '',
  price             numeric(10,2) not null,
  commission        numeric(10,2) not null,
  therapist_earning numeric(10,2) not null,
  payment_method    text not null default 'cash' check (payment_method in ('cash','gcash','card')),
  payment_status    text not null default 'unpaid' check (payment_status in ('unpaid','paid','refunded')),
  status            text not null default 'pending'
                    check (status in ('pending','confirmed','on_the_way','in_progress','completed','cancelled','declined')),
  cancel_reason     text not null default '',
  cancelled_by      text not null default '',
  reminded_24h      boolean not null default false,
  reminded_1h       boolean not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists mb_bookings_therapist_start on public.mb_bookings (therapist_id, start_at);
create index if not exists mb_bookings_customer_start  on public.mb_bookings (customer_id, start_at);
create index if not exists mb_bookings_status          on public.mb_bookings (status);

create table if not exists public.mb_reviews (
  id            bigserial primary key,
  booking_id    bigint not null unique references public.mb_bookings(id) on delete cascade,
  customer_id   uuid not null references public.mb_profiles(id),
  therapist_id  uuid not null references public.mb_therapists(id),
  stars         int  not null check (stars between 1 and 5),
  comment       text not null default '',
  hidden        boolean not null default false,
  created_at    timestamptz not null default now()
);

create table if not exists public.mb_notifications (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  title       text not null,
  body        text not null default '',
  link        text not null default '',
  read        boolean not null default false,
  push_sent   boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists mb_notifications_user on public.mb_notifications (user_id, created_at desc);

create table if not exists public.mb_push_tokens (
  token       text primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  platform    text not null default 'web',
  updated_at  timestamptz not null default now()
);

-- Money between therapist and Massage Buddy (cash bookings: therapist pays the commission)
create table if not exists public.mb_settlements (
  id            bigserial primary key,
  therapist_id  uuid not null references public.mb_therapists(id) on delete cascade,
  amount        numeric(10,2) not null check (amount > 0),
  reference     text not null default '',
  note          text not null default '',
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now()
);

create table if not exists public.mb_settings (
  key    text primary key,
  value  text not null
);

-- Lock every table: the apps use the functions below instead.
alter table public.mb_profiles       enable row level security;
alter table public.mb_admins         enable row level security;
alter table public.mb_therapists     enable row level security;
alter table public.mb_massage_types  enable row level security;
alter table public.mb_services       enable row level security;
alter table public.mb_availability   enable row level security;
alter table public.mb_blocked_dates  enable row level security;
alter table public.mb_bookings       enable row level security;
alter table public.mb_reviews        enable row level security;
alter table public.mb_notifications  enable row level security;
alter table public.mb_push_tokens    enable row level security;
alter table public.mb_settlements    enable row level security;
alter table public.mb_settings       enable row level security;

revoke all on public.mb_profiles, public.mb_admins, public.mb_therapists, public.mb_massage_types,
  public.mb_services, public.mb_availability, public.mb_blocked_dates, public.mb_bookings,
  public.mb_reviews, public.mb_notifications, public.mb_push_tokens, public.mb_settlements,
  public.mb_settings from anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Default data
-- ---------------------------------------------------------------------
insert into public.mb_settings (key, value) values
  ('commission_pct', '20'),     -- % Massage Buddy keeps from each booking
  ('buffer_min',     '30'),     -- travel/rest minutes between bookings
  ('lead_min',       '120'),    -- book at least this many minutes ahead
  ('slot_step_min',  '30'),     -- time slots every 30 minutes
  ('accept_min',     '60'),     -- therapist must accept within 60 min or it auto-declines
  ('cancel_hours',   '3'),      -- customer can cancel online until 3 hours before
  ('booking_days',   '14'),     -- customers can book up to 14 days ahead
  ('support_phone',  ''),
  ('support_email',  '')
on conflict (key) do nothing;

insert into public.mb_massage_types (name, description, sort) values
  ('Swedish',     'Relaxing full-body massage with long, gentle strokes.', 1),
  ('Shiatsu',     'Japanese finger-pressure massage for energy and balance.', 2),
  ('Thai',        'Stretching and pressure, done on a mat with light clothing.', 3),
  ('Deep Tissue', 'Firm pressure for tight muscles and knots.', 4),
  ('Hilot',       'Traditional Filipino healing massage.', 5),
  ('Foot Reflexology', 'Pressure points on the feet for whole-body relief.', 6)
on conflict (name) do nothing;

-- ---------------------------------------------------------------------
-- 3. Helper functions
-- ---------------------------------------------------------------------
create or replace function public.mb_setting_int(p_key text, p_default int)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select nullif(value,'')::int from mb_settings where key = p_key), p_default);
$$;

create or replace function public.mb_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from mb_admins where user_id = auth.uid());
$$;

create or replace function public.mb_require_login()
returns uuid language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please log in first.'; end if;
  return auth.uid();
end $$;

create or replace function public.mb_require_admin()
returns uuid language plpgsql stable security definer set search_path = public as $$
begin
  if not mb_is_admin() then raise exception 'Admins only.'; end if;
  return auth.uid();
end $$;

create or replace function public.mb_notify(p_user uuid, p_title text, p_body text, p_link text)
returns void language sql security definer set search_path = public as $$
  insert into mb_notifications (user_id, title, body, link) values (p_user, p_title, coalesce(p_body,''), coalesce(p_link,''));
$$;

-- Manila time label, e.g. "Mon 24 Nov, 2:30 PM"
create or replace function public.mb_when(p_ts timestamptz)
returns text language sql immutable as $$
  select trim(to_char(p_ts at time zone 'Asia/Manila', 'Dy DD Mon, FMHH12:MI AM'));
$$;

create or replace function public.mb_recalc_rating(p_therapist uuid)
returns void language sql security definer set search_path = public as $$
  update mb_therapists t set
    rating_avg   = coalesce((select round(avg(stars)::numeric, 2) from mb_reviews r where r.therapist_id = t.id and not r.hidden), 0),
    rating_count = (select count(*) from mb_reviews r where r.therapist_id = t.id and not r.hidden)
  where t.id = p_therapist;
$$;

-- Is a booking "holding" its time slot?
create or replace function public.mb_booking_active(p_status text, p_created timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select p_status in ('confirmed','on_the_way','in_progress')
      or (p_status = 'pending' and p_created > now() - make_interval(mins => mb_setting_int('accept_min', 60)));
$$;

-- Ensure the caller has a profile row (created on first login)
create or replace function public.mb_ensure_profile()
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_login(); u record;
begin
  if not exists (select 1 from mb_profiles where id = v_uid) then
    select email, phone, raw_user_meta_data as meta into u from auth.users where id = v_uid;
    insert into mb_profiles (id, full_name, phone, email)
    values (v_uid,
            coalesce(u.meta->>'full_name', u.meta->>'name', ''),
            coalesce(nullif(u.meta->>'phone',''), u.phone, ''),
            coalesce(u.email, ''))
    on conflict (id) do nothing;
  end if;
  return v_uid;
end $$;

-- ---------------------------------------------------------------------
-- 4. Public functions (anyone can browse, even before login)
-- ---------------------------------------------------------------------
create or replace function public.mb_massage_types()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'description', description) order by sort, name), '[]')
  from mb_massage_types where active;
$$;

create or replace function public.mb_public_settings()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'booking_days',  mb_setting_int('booking_days', 14),
    'lead_min',      mb_setting_int('lead_min', 120),
    'cancel_hours',  mb_setting_int('cancel_hours', 3),
    'accept_min',    mb_setting_int('accept_min', 60),
    'support_phone', coalesce((select value from mb_settings where key='support_phone'), ''),
    'support_email', coalesce((select value from mb_settings where key='support_email'), ''));
$$;

create or replace function public.mb_list_therapists(p_type int default null, p_gender text default null,
                                                     p_area text default null, p_sort text default 'rating')
returns jsonb language sql stable security definer set search_path = public as $$
  with t as (
    select th.*,
      (select min(price) from mb_services s join mb_massage_types mt on mt.id = s.type_id and mt.active
        where s.therapist_id = th.id and s.active and (p_type is null or s.type_id = p_type)) as min_price,
      (select coalesce(jsonb_agg(distinct mt.name), '[]') from mb_services s join mb_massage_types mt on mt.id = s.type_id and mt.active
        where s.therapist_id = th.id and s.active) as types
    from mb_therapists th
    where th.status = 'approved'
      and (p_gender is null or p_gender = '' or th.gender = p_gender)
      and (p_area is null or p_area = '' or th.area = p_area)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'display_name', display_name, 'gender', gender, 'area', area,
      'photo_url', photo_url, 'rating_avg', rating_avg, 'rating_count', rating_count,
      'experience_years', experience_years, 'min_price', min_price, 'types', types,
      'bio', left(bio, 140))
    order by
      case when p_sort = 'price' then min_price end asc nulls last,
      case when p_sort <> 'price' then rating_avg end desc nulls last,
      rating_count desc, display_name), '[]')
  from t where min_price is not null;
$$;

create or replace function public.mb_get_therapist(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', th.id, 'display_name', th.display_name, 'gender', th.gender, 'area', th.area,
    'bio', th.bio, 'experience_years', th.experience_years, 'photo_url', th.photo_url,
    'photos', to_jsonb(th.photos), 'rating_avg', th.rating_avg, 'rating_count', th.rating_count,
    'services', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', s.id, 'type_id', s.type_id, 'type_name', mt.name, 'type_description', mt.description,
          'duration_min', s.duration_min, 'price', s.price) order by mt.sort, mt.name, s.duration_min), '[]')
        from mb_services s join mb_massage_types mt on mt.id = s.type_id and mt.active
        where s.therapist_id = th.id and s.active),
    'availability', (select coalesce(jsonb_agg(jsonb_build_object(
          'weekday', a.weekday, 'start', to_char(a.start_time,'HH24:MI'), 'end', to_char(a.end_time,'HH24:MI'))
          order by a.weekday, a.start_time), '[]')
        from mb_availability a where a.therapist_id = th.id),
    'reviews', (select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]') from (
        select jsonb_build_object('stars', r.stars, 'comment', r.comment, 'created_at', r.created_at,
               'name', coalesce(nullif(split_part(p.full_name, ' ', 1), ''), 'Customer')) as x
        from mb_reviews r join mb_profiles p on p.id = r.customer_id
        where r.therapist_id = th.id and not r.hidden
        order by r.created_at desc limit 20) z))
  from mb_therapists th
  where th.id = p_id and (th.status = 'approved' or th.id = auth.uid() or mb_is_admin());
$$;

-- Free start times for one therapist, one day (Manila time), one duration
create or replace function public.mb_get_slots(p_therapist uuid, p_date date, p_duration int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_step   int := mb_setting_int('slot_step_min', 30);
  v_buffer int := mb_setting_int('buffer_min', 30);
  v_lead   int := mb_setting_int('lead_min', 120);
  v_days   int := mb_setting_int('booking_days', 14);
  v_today  date := (now() at time zone 'Asia/Manila')::date;
  v_out    jsonb;
begin
  if p_date < v_today or p_date > v_today + v_days then return '[]'::jsonb; end if;
  if not exists (select 1 from mb_therapists where id = p_therapist and status = 'approved') then return '[]'::jsonb; end if;
  if exists (select 1 from mb_blocked_dates where therapist_id = p_therapist and day = p_date) then return '[]'::jsonb; end if;

  select coalesce(jsonb_agg(to_char(s.slot at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') order by s.slot), '[]')
  into v_out
  from (
    select distinct g.slot
    from mb_availability a,
         lateral generate_series(
           (p_date + a.start_time) at time zone 'Asia/Manila',
           ((p_date + a.end_time) at time zone 'Asia/Manila') - make_interval(mins => p_duration),
           make_interval(mins => v_step)) as g(slot)
    where a.therapist_id = p_therapist
      and a.weekday = extract(dow from p_date)::int
      and g.slot >= now() + make_interval(mins => v_lead)
      and not exists (
        select 1 from mb_bookings b
        where b.therapist_id = p_therapist
          and mb_booking_active(b.status, b.created_at)
          and b.start_at < g.slot + make_interval(mins => p_duration + v_buffer)
          and b.end_at + make_interval(mins => v_buffer) > g.slot)
  ) s;
  return v_out;
end $$;

-- ---------------------------------------------------------------------
-- 5. Logged-in user functions (customers and therapists)
-- ---------------------------------------------------------------------
create or replace function public.mb_me()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_ensure_profile();
begin
  return (select jsonb_build_object(
      'id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'email', p.email,
      'address', p.address, 'area', p.area, 'blocked', p.blocked,
      'is_admin', mb_is_admin(),
      'therapist_status', (select status from mb_therapists where id = p.id),
      'unread', (select count(*) from mb_notifications n where n.user_id = p.id and not n.read))
    from mb_profiles p where p.id = v_uid);
end $$;

create or replace function public.mb_save_profile(p_name text, p_phone text, p_address text default null, p_area text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_ensure_profile();
begin
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'Please enter your name.'; end if;
  if length(regexp_replace(coalesce(p_phone,''), '\D', '', 'g')) < 10 then raise exception 'Please enter a valid mobile number.'; end if;
  update mb_profiles set
    full_name = left(trim(p_name), 80),
    phone     = left(trim(p_phone), 20),
    address   = coalesce(left(trim(p_address), 300), address),
    area      = coalesce(left(trim(p_area), 60), area)
  where id = v_uid;
  return mb_me();
end $$;

create or replace function public.mb_create_booking(p_service bigint, p_start timestamptz, p_address text,
                                                    p_area text, p_phone text, p_notes text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := mb_ensure_profile();
  v_s    record;
  v_end  timestamptz;
  v_pct  int := mb_setting_int('commission_pct', 20);
  v_comm numeric;
  v_id   bigint;
  v_slots jsonb;
  v_name text;
begin
  if (select blocked from mb_profiles where id = v_uid) then
    raise exception 'Your account cannot make bookings. Please contact support.';
  end if;
  if length(trim(coalesce(p_address,''))) < 8 then raise exception 'Please enter your full address.'; end if;
  if length(regexp_replace(coalesce(p_phone,''), '\D', '', 'g')) < 10 then raise exception 'Please enter a valid mobile number.'; end if;

  select s.*, mt.name as type_name into v_s
  from mb_services s join mb_massage_types mt on mt.id = s.type_id
  join mb_therapists th on th.id = s.therapist_id
  where s.id = p_service and s.active and mt.active and th.status = 'approved';
  if not found then raise exception 'This service is no longer available.'; end if;
  if v_s.therapist_id = v_uid then raise exception 'You cannot book yourself.'; end if;

  -- one booking at a time per therapist (stops two people taking the same slot)
  perform pg_advisory_xact_lock(hashtext('mb_booking_' || v_s.therapist_id::text));

  v_slots := mb_get_slots(v_s.therapist_id, (p_start at time zone 'Asia/Manila')::date, v_s.duration_min);
  if not (v_slots @> to_jsonb(array[to_char(p_start at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')])) then
    raise exception 'Sorry, this time was just taken. Please choose another time.';
  end if;

  v_end := p_start + make_interval(mins => v_s.duration_min);
  if exists (select 1 from mb_bookings b where b.customer_id = v_uid and mb_booking_active(b.status, b.created_at)
             and b.start_at < v_end and b.end_at > p_start) then
    raise exception 'You already have a booking at this time.';
  end if;

  v_comm := round(v_s.price * v_pct / 100.0);
  insert into mb_bookings (customer_id, therapist_id, service_id, type_name, duration_min, start_at, end_at,
                           address, area, contact_phone, notes, price, commission, therapist_earning)
  values (v_uid, v_s.therapist_id, v_s.id, v_s.type_name, v_s.duration_min, p_start, v_end,
          left(trim(p_address), 300), left(coalesce(p_area,''), 60), left(trim(p_phone), 20),
          left(coalesce(p_notes,''), 500), v_s.price, v_comm, v_s.price - v_comm)
  returning id into v_id;

  -- remember address/phone for next time
  update mb_profiles set address = left(trim(p_address), 300), area = left(coalesce(p_area,''), 60),
         phone = case when phone = '' then left(trim(p_phone), 20) else phone end
  where id = v_uid;

  select full_name into v_name from mb_profiles where id = v_uid;
  perform mb_notify(v_s.therapist_id, 'New booking request',
    coalesce(nullif(v_name,''),'A customer') || ' booked ' || v_s.type_name || ' ' || v_s.duration_min || ' min on ' || mb_when(p_start) || '. Please accept.',
    'therapist.html#bookings');

  return jsonb_build_object('id', v_id, 'start_at', p_start, 'price', v_s.price, 'status', 'pending');
end $$;

create or replace function public.mb_booking_json(b public.mb_bookings, p_as text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', b.id, 'type_name', b.type_name, 'duration_min', b.duration_min,
    'start_at', b.start_at, 'end_at', b.end_at, 'address', b.address, 'area', b.area,
    'notes', b.notes, 'price', b.price, 'commission', b.commission, 'therapist_earning', b.therapist_earning,
    'payment_method', b.payment_method, 'payment_status', b.payment_status,
    'status', case when b.status = 'pending' and not mb_booking_active(b.status, b.created_at) then 'declined' else b.status end,
    'cancel_reason', b.cancel_reason, 'cancelled_by', b.cancelled_by, 'created_at', b.created_at,
    'reviewed', exists (select 1 from mb_reviews r where r.booking_id = b.id),
    'therapist', (select jsonb_build_object('id', t.id, 'name', t.display_name, 'photo_url', t.photo_url,
                    'phone', case when p_as in ('customer','admin') and b.status in ('confirmed','on_the_way','in_progress') then tp.phone else null end)
                  from mb_therapists t join mb_profiles tp on tp.id = t.id where t.id = b.therapist_id),
    'customer', (select jsonb_build_object('id', c.id, 'name', c.full_name,
                    'phone', case when p_as = 'admin' or b.status in ('pending','confirmed','on_the_way','in_progress') then b.contact_phone else null end)
                 from mb_profiles c where c.id = b.customer_id));
$$;

create or replace function public.mb_my_bookings(p_as text default 'customer')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_ensure_profile();
begin
  if p_as = 'therapist' then
    if not exists (select 1 from mb_therapists where id = v_uid) then raise exception 'Therapists only.'; end if;
    return (select coalesce(jsonb_agg(mb_booking_json(b, 'therapist') order by b.start_at desc), '[]')
            from mb_bookings b where b.therapist_id = v_uid and b.start_at > now() - interval '120 days');
  end if;
  return (select coalesce(jsonb_agg(mb_booking_json(b, 'customer') order by b.start_at desc), '[]')
          from mb_bookings b where b.customer_id = v_uid and b.start_at > now() - interval '365 days');
end $$;

create or replace function public.mb_cancel_booking(p_booking bigint, p_reason text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := mb_require_login();
  b mb_bookings;
  v_who text;
  v_hours int := mb_setting_int('cancel_hours', 3);
begin
  select * into b from mb_bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  if b.customer_id = v_uid then v_who := 'customer';
  elsif b.therapist_id = v_uid then v_who := 'therapist';
  elsif mb_is_admin() then v_who := 'admin';
  else raise exception 'Booking not found.'; end if;

  if b.status not in ('pending','confirmed','on_the_way') then
    raise exception 'This booking can no longer be cancelled.';
  end if;
  if v_who = 'customer' and b.status <> 'pending' and b.start_at < now() + make_interval(hours => v_hours) then
    raise exception 'It is less than % hours before your massage. Please call your therapist to cancel.', v_hours;
  end if;
  if v_who = 'therapist' and length(trim(coalesce(p_reason,''))) < 3 then
    raise exception 'Please write a short reason for the customer.';
  end if;

  update mb_bookings set status = 'cancelled', cancelled_by = v_who, cancel_reason = left(coalesce(p_reason,''), 300),
         updated_at = now() where id = b.id;

  if v_who <> 'customer' then
    perform mb_notify(b.customer_id, 'Booking cancelled',
      'Your ' || b.type_name || ' on ' || mb_when(b.start_at) || ' was cancelled' ||
      case when coalesce(p_reason,'') <> '' then ': ' || p_reason else '.' end, 'index.html#bookings');
  end if;
  if v_who <> 'therapist' then
    perform mb_notify(b.therapist_id, 'Booking cancelled',
      'The ' || b.type_name || ' on ' || mb_when(b.start_at) || ' was cancelled by the ' || v_who || '.', 'therapist.html#bookings');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.mb_submit_review(p_booking bigint, p_stars int, p_comment text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_login(); b mb_bookings;
begin
  select * into b from mb_bookings where id = p_booking and customer_id = v_uid;
  if not found then raise exception 'Booking not found.'; end if;
  if b.status <> 'completed' then raise exception 'You can rate after the massage is completed.'; end if;
  if p_stars not between 1 and 5 then raise exception 'Please choose 1 to 5 stars.'; end if;
  insert into mb_reviews (booking_id, customer_id, therapist_id, stars, comment)
  values (b.id, v_uid, b.therapist_id, p_stars, left(coalesce(p_comment,''), 600))
  on conflict (booking_id) do nothing;
  if not found then raise exception 'You already rated this booking.'; end if;
  perform mb_recalc_rating(b.therapist_id);
  perform mb_notify(b.therapist_id, 'New review: ' || repeat('★', p_stars), left(coalesce(p_comment,''), 120), 'therapist.html#profile');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.mb_my_notifications()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_login();
begin
  return jsonb_build_object(
    'unread', (select count(*) from mb_notifications where user_id = v_uid and not read),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'body', body, 'link', link,
                     'read', read, 'created_at', created_at) order by created_at desc), '[]')
              from (select * from mb_notifications where user_id = v_uid order by created_at desc limit 40) n));
end $$;

create or replace function public.mb_mark_notifications_read()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_login();
begin
  update mb_notifications set read = true where user_id = v_uid and not read;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.mb_save_push_token(p_token text, p_platform text default 'web')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_login();
begin
  if length(coalesce(p_token,'')) < 20 then raise exception 'Invalid token.'; end if;
  insert into mb_push_tokens (token, user_id, platform, updated_at) values (p_token, v_uid, left(coalesce(p_platform,'web'),20), now())
  on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
  -- keep at most 5 phones per person
  delete from mb_push_tokens where user_id = v_uid and token not in
    (select token from mb_push_tokens where user_id = v_uid order by updated_at desc limit 5);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.mb_delete_push_token(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  delete from mb_push_tokens where token = p_token and user_id = auth.uid();
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 6. Therapist functions
-- ---------------------------------------------------------------------
create or replace function public.mb_require_therapist()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := mb_require_login();
begin
  if not exists (select 1 from mb_therapists where id = v_uid) then raise exception 'Please complete your therapist application first.'; end if;
  if (select status from mb_therapists where id = v_uid) = 'suspended' then raise exception 'Your therapist account is suspended. Please contact support.'; end if;
  return v_uid;
end $$;

create or replace function public.mb_save_therapist(p_display_name text, p_gender text, p_area text, p_experience int,
                                                    p_bio text, p_photo_url text, p_photos text[],
                                                    p_id_doc text, p_cert_doc text, p_phone text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_ensure_profile(); v_new boolean;
begin
  if length(trim(coalesce(p_display_name,''))) < 2 then raise exception 'Please enter your name.'; end if;
  if length(regexp_replace(coalesce(p_phone,''), '\D', '', 'g')) < 10 then raise exception 'Please enter a valid mobile number.'; end if;
  if coalesce(p_area,'') = '' then raise exception 'Please choose your area.'; end if;
  if coalesce(p_photo_url,'') = '' then raise exception 'Please add a profile photo.'; end if;
  if (select status from mb_therapists where id = v_uid) = 'suspended' then raise exception 'Your therapist account is suspended. Please contact support.'; end if;

  v_new := not exists (select 1 from mb_therapists where id = v_uid);
  if v_new and coalesce(p_id_doc,'') = '' then raise exception 'Please upload a photo of your valid ID.'; end if;

  update mb_profiles set phone = left(trim(p_phone), 20),
         full_name = case when full_name = '' then left(trim(p_display_name), 80) else full_name end
  where id = v_uid;

  insert into mb_therapists (id, display_name, gender, area, experience_years, bio, photo_url, photos, id_doc_path, cert_doc_path)
  values (v_uid, left(trim(p_display_name),60), coalesce(nullif(p_gender,''),'female'), left(p_area,60),
          greatest(0, least(60, coalesce(p_experience,0))), left(coalesce(p_bio,''),1200),
          p_photo_url, coalesce(p_photos[1:6], '{}'), coalesce(p_id_doc,''), coalesce(p_cert_doc,''))
  on conflict (id) do update set
    display_name = excluded.display_name, gender = excluded.gender, area = excluded.area,
    experience_years = excluded.experience_years, bio = excluded.bio, photo_url = excluded.photo_url,
    photos = excluded.photos,
    id_doc_path   = case when excluded.id_doc_path   <> '' then excluded.id_doc_path   else mb_therapists.id_doc_path end,
    cert_doc_path = case when excluded.cert_doc_path <> '' then excluded.cert_doc_path else mb_therapists.cert_doc_path end,
    updated_at = now();

  if v_new then
    perform mb_notify(a.user_id, 'New therapist application', trim(p_display_name) || ' (' || p_area || ') is waiting for approval.', 'admin.html#therapists')
    from mb_admins a;
  end if;
  return mb_my_therapist();
end $$;

create or replace function public.mb_my_therapist()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_ensure_profile();
begin
  if not exists (select 1 from mb_therapists where id = v_uid) then return null; end if;
  return (select jsonb_build_object(
    'id', t.id, 'display_name', t.display_name, 'gender', t.gender, 'area', t.area,
    'experience_years', t.experience_years, 'bio', t.bio, 'photo_url', t.photo_url, 'photos', to_jsonb(t.photos),
    'has_id_doc', t.id_doc_path <> '', 'has_cert_doc', t.cert_doc_path <> '',
    'status', t.status, 'admin_note', t.admin_note, 'rating_avg', t.rating_avg, 'rating_count', t.rating_count,
    'phone', p.phone,
    'services', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'type_id', s.type_id, 'type_name', mt.name,
                   'duration_min', s.duration_min, 'price', s.price, 'active', s.active) order by mt.sort, s.duration_min), '[]')
                 from mb_services s join mb_massage_types mt on mt.id = s.type_id where s.therapist_id = t.id),
    'availability', (select coalesce(jsonb_agg(jsonb_build_object('weekday', a.weekday,
                   'start', to_char(a.start_time,'HH24:MI'), 'end', to_char(a.end_time,'HH24:MI')) order by a.weekday, a.start_time), '[]')
                 from mb_availability a where a.therapist_id = t.id),
    'blocked_dates', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'day', d.day, 'reason', d.reason) order by d.day), '[]')
                 from mb_blocked_dates d where d.therapist_id = t.id and d.day >= (now() at time zone 'Asia/Manila')::date))
    from mb_therapists t join mb_profiles p on p.id = t.id where t.id = v_uid);
end $$;

create or replace function public.mb_save_service(p_type int, p_duration int, p_price numeric, p_active boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_therapist();
begin
  if p_duration not in (60,90,120) then raise exception 'Duration must be 60, 90 or 120 minutes.'; end if;
  if p_price is null or p_price < 100 or p_price > 50000 then raise exception 'Price must be between ₱100 and ₱50,000.'; end if;
  if not exists (select 1 from mb_massage_types where id = p_type and active) then raise exception 'Unknown massage type.'; end if;
  insert into mb_services (therapist_id, type_id, duration_min, price, active)
  values (v_uid, p_type, p_duration, round(p_price), coalesce(p_active, true))
  on conflict (therapist_id, type_id, duration_min) do update set price = excluded.price, active = excluded.active;
  return mb_my_therapist();
end $$;

create or replace function public.mb_delete_service(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_therapist();
begin
  delete from mb_services where id = p_id and therapist_id = v_uid;
  return mb_my_therapist();
end $$;

-- p_rows = [{"weekday":1,"start":"09:00","end":"18:00"}, ...]  (replaces the whole weekly schedule)
create or replace function public.mb_save_availability(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_therapist(); r jsonb;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 30 then raise exception 'Invalid schedule.'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    if (r->>'weekday')::int not between 0 and 6 or (r->>'end')::time <= (r->>'start')::time then
      raise exception 'Each time range must end after it starts.';
    end if;
  end loop;
  delete from mb_availability where therapist_id = v_uid;
  insert into mb_availability (therapist_id, weekday, start_time, end_time)
  select v_uid, (x->>'weekday')::int, (x->>'start')::time, (x->>'end')::time from jsonb_array_elements(p_rows) x;
  return mb_my_therapist();
end $$;

create or replace function public.mb_add_blocked_date(p_day date, p_reason text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_therapist();
begin
  if p_day < (now() at time zone 'Asia/Manila')::date then raise exception 'Please choose a future date.'; end if;
  insert into mb_blocked_dates (therapist_id, day, reason) values (v_uid, p_day, left(coalesce(p_reason,''),120))
  on conflict (therapist_id, day) do update set reason = excluded.reason;
  return mb_my_therapist();
end $$;

create or replace function public.mb_remove_blocked_date(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_therapist();
begin
  delete from mb_blocked_dates where id = p_id and therapist_id = v_uid;
  return mb_my_therapist();
end $$;

-- Therapist moves a booking forward: accept / decline / on the way / start / complete
create or replace function public.mb_set_booking_status(p_booking bigint, p_status text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := mb_require_therapist();
  b mb_bookings;
  v_ok boolean;
  v_title text; v_body text;
begin
  select * into b from mb_bookings where id = p_booking and therapist_id = v_uid for update;
  if not found then raise exception 'Booking not found.'; end if;
  if b.status = 'pending' and not mb_booking_active(b.status, b.created_at) then
    raise exception 'This request expired. The customer was told to choose another time.';
  end if;

  v_ok := (b.status = 'pending'     and p_status in ('confirmed','declined'))
       or (b.status = 'confirmed'   and p_status in ('on_the_way','in_progress'))
       or (b.status = 'on_the_way'  and p_status = 'in_progress')
       or (b.status = 'in_progress' and p_status = 'completed');
  if not v_ok then raise exception 'This step is not allowed right now.'; end if;
  if p_status = 'confirmed' and b.start_at < now() then raise exception 'This booking time has already passed.'; end if;
  if p_status = 'in_progress' and b.start_at > now() + interval '2 hours' then raise exception 'You can start the massage closer to the booking time.'; end if;

  update mb_bookings set status = p_status, updated_at = now(),
         payment_status = case when p_status = 'completed' then 'paid' else payment_status end,
         cancelled_by = case when p_status = 'declined' then 'therapist' else cancelled_by end
  where id = b.id;

  v_title := case p_status
    when 'confirmed'   then 'Booking confirmed ✅'
    when 'declined'    then 'Booking not accepted'
    when 'on_the_way'  then 'Your therapist is on the way'
    when 'in_progress' then 'Massage started'
    when 'completed'   then 'Massage completed - please rate' end;
  v_body := case p_status
    when 'confirmed'   then 'Your ' || b.type_name || ' is confirmed for ' || mb_when(b.start_at) || '. Please prepare ₱' || to_char(b.price,'FM999,999') || ' cash.'
    when 'declined'    then 'The therapist is not available for ' || mb_when(b.start_at) || '. Please choose another time or therapist.'
    when 'on_the_way'  then 'Your therapist is heading to your address now.'
    when 'in_progress' then 'Enjoy your massage!'
    when 'completed'   then 'Thank you! Tap to rate your therapist.' end;
  perform mb_notify(b.customer_id, v_title, v_body, 'index.html#bookings');
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;

create or replace function public.mb_my_earnings()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := mb_require_therapist();
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_due numeric; v_paid numeric;
begin
  select coalesce(sum(commission),0) into v_due from mb_bookings where therapist_id = v_uid and status = 'completed' and payment_method = 'cash';
  select coalesce(sum(amount),0) into v_paid from mb_settlements where therapist_id = v_uid;
  return jsonb_build_object(
    'today', (select jsonb_build_object('count', count(*), 'gross', coalesce(sum(price),0), 'net', coalesce(sum(therapist_earning),0))
              from mb_bookings where therapist_id = v_uid and status = 'completed' and (start_at at time zone 'Asia/Manila')::date = v_today),
    'week',  (select jsonb_build_object('count', count(*), 'gross', coalesce(sum(price),0), 'net', coalesce(sum(therapist_earning),0))
              from mb_bookings where therapist_id = v_uid and status = 'completed' and (start_at at time zone 'Asia/Manila')::date > v_today - 7),
    'month', (select jsonb_build_object('count', count(*), 'gross', coalesce(sum(price),0), 'net', coalesce(sum(therapist_earning),0))
              from mb_bookings where therapist_id = v_uid and status = 'completed' and (start_at at time zone 'Asia/Manila')::date > v_today - 30),
    'commission_due', v_due, 'commission_paid', v_paid, 'balance', v_due - v_paid,
    'commission_pct', mb_setting_int('commission_pct', 20),
    'settlements', (select coalesce(jsonb_agg(jsonb_build_object('amount', amount, 'reference', reference, 'note', note, 'created_at', created_at) order by created_at desc), '[]')
                    from (select * from mb_settlements where therapist_id = v_uid order by created_at desc limit 30) s));
end $$;

-- ---------------------------------------------------------------------
-- 7. Admin functions
-- ---------------------------------------------------------------------
create or replace function public.mb_admin_check()
returns boolean language sql stable security definer set search_path = public as $$
  select mb_is_admin();
$$;

create or replace function public.mb_admin_dashboard()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  perform mb_require_admin();
  return jsonb_build_object(
    'bookings_today', (select count(*) from mb_bookings where (start_at at time zone 'Asia/Manila')::date = v_today and status not in ('cancelled','declined')),
    'pending', (select count(*) from mb_bookings where status = 'pending' and mb_booking_active(status, created_at)),
    'upcoming', (select count(*) from mb_bookings where status in ('confirmed','on_the_way') and start_at > now()),
    'completed_30d', (select count(*) from mb_bookings where status = 'completed' and start_at > now() - interval '30 days'),
    'revenue_30d', (select coalesce(sum(price),0) from mb_bookings where status = 'completed' and start_at > now() - interval '30 days'),
    'commission_30d', (select coalesce(sum(commission),0) from mb_bookings where status = 'completed' and start_at > now() - interval '30 days'),
    'therapists_pending', (select count(*) from mb_therapists where status = 'pending'),
    'therapists_approved', (select count(*) from mb_therapists where status = 'approved'),
    'customers', (select count(*) from mb_profiles p where not exists (select 1 from mb_therapists t where t.id = p.id)),
    'commission_unpaid', (select coalesce(sum(commission),0) from mb_bookings where status = 'completed' and payment_method = 'cash')
                         - (select coalesce(sum(amount),0) from mb_settlements));
end $$;

create or replace function public.mb_admin_therapists(p_status text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id, 'display_name', t.display_name, 'gender', t.gender, 'area', t.area,
      'experience_years', t.experience_years, 'bio', t.bio, 'photo_url', t.photo_url, 'photos', to_jsonb(t.photos),
      'id_doc_path', t.id_doc_path, 'cert_doc_path', t.cert_doc_path, 'status', t.status, 'admin_note', t.admin_note,
      'rating_avg', t.rating_avg, 'rating_count', t.rating_count, 'created_at', t.created_at,
      'email', p.email, 'phone', p.phone, 'full_name', p.full_name,
      'services', (select count(*) from mb_services s where s.therapist_id = t.id and s.active),
      'has_schedule', exists (select 1 from mb_availability a where a.therapist_id = t.id),
      'completed', (select count(*) from mb_bookings b where b.therapist_id = t.id and b.status = 'completed'))
      order by case t.status when 'pending' then 0 when 'approved' then 1 else 2 end, t.created_at desc), '[]')
    from mb_therapists t join mb_profiles p on p.id = t.id
    where p_status is null or p_status = '' or t.status = p_status);
end $$;

create or replace function public.mb_admin_set_therapist_status(p_id uuid, p_status text, p_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  if p_status not in ('pending','approved','suspended') then raise exception 'Unknown status.'; end if;
  update mb_therapists set status = p_status, admin_note = left(coalesce(p_note,''),300), updated_at = now() where id = p_id;
  if not found then raise exception 'Therapist not found.'; end if;
  perform mb_notify(p_id,
    case p_status when 'approved' then 'You are approved! 🎉' when 'suspended' then 'Account suspended' else 'Application update' end,
    case p_status when 'approved' then 'Customers can now find and book you. Make sure your services and schedule are set.'
                  else coalesce(nullif(p_note,''), 'Please check the app for details.') end,
    'therapist.html#home');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.mb_admin_bookings(p_status text default null, p_limit int default 200)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  return (select coalesce(jsonb_agg(mb_booking_json(b, 'admin') order by b.start_at desc), '[]')
          from (select * from mb_bookings
                where p_status is null or p_status = '' or status = p_status
                order by start_at desc limit least(coalesce(p_limit,200), 500)) b);
end $$;

create or replace function public.mb_admin_customers(p_search text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'email', p.email, 'area', p.area,
      'blocked', p.blocked, 'created_at', p.created_at,
      'is_therapist', exists (select 1 from mb_therapists t where t.id = p.id),
      'bookings', (select count(*) from mb_bookings b where b.customer_id = p.id),
      'cancelled', (select count(*) from mb_bookings b where b.customer_id = p.id and b.status = 'cancelled' and b.cancelled_by = 'customer'))
      order by p.created_at desc), '[]')
    from (select * from mb_profiles
          where coalesce(p_search,'') = '' or full_name ilike '%'||p_search||'%' or phone ilike '%'||p_search||'%' or email ilike '%'||p_search||'%'
          order by created_at desc limit 300) p);
end $$;

create or replace function public.mb_admin_set_blocked(p_user uuid, p_blocked boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  update mb_profiles set blocked = coalesce(p_blocked,false) where id = p_user;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.mb_admin_balances()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  return (select coalesce(jsonb_agg(x order by (x->>'balance')::numeric desc), '[]') from (
    select jsonb_build_object('id', t.id, 'display_name', t.display_name, 'phone', p.phone,
      'completed', (select count(*) from mb_bookings b where b.therapist_id = t.id and b.status = 'completed'),
      'gross', (select coalesce(sum(price),0) from mb_bookings b where b.therapist_id = t.id and b.status = 'completed'),
      'due',  (select coalesce(sum(commission),0) from mb_bookings b where b.therapist_id = t.id and b.status = 'completed' and b.payment_method = 'cash'),
      'paid', (select coalesce(sum(amount),0) from mb_settlements s where s.therapist_id = t.id),
      'balance', (select coalesce(sum(commission),0) from mb_bookings b where b.therapist_id = t.id and b.status = 'completed' and b.payment_method = 'cash')
               - (select coalesce(sum(amount),0) from mb_settlements s where s.therapist_id = t.id)) as x
    from mb_therapists t join mb_profiles p on p.id = t.id) z);
end $$;

create or replace function public.mb_admin_add_settlement(p_therapist uuid, p_amount numeric, p_reference text default '', p_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_admin();
begin
  if p_amount is null or p_amount <= 0 then raise exception 'Enter an amount above zero.'; end if;
  insert into mb_settlements (therapist_id, amount, reference, note, created_by)
  values (p_therapist, round(p_amount, 2), left(coalesce(p_reference,''),80), left(coalesce(p_note,''),200), v_uid);
  perform mb_notify(p_therapist, 'Commission payment received', 'Thank you! We received ₱' || to_char(p_amount,'FM999,999.00') || '.', 'therapist.html#earnings');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.mb_admin_reviews()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'stars', r.stars, 'comment', r.comment, 'hidden', r.hidden,
      'created_at', r.created_at, 'customer', p.full_name, 'therapist', t.display_name) order by r.created_at desc), '[]')
    from (select * from mb_reviews order by created_at desc limit 300) r
    join mb_profiles p on p.id = r.customer_id join mb_therapists t on t.id = r.therapist_id);
end $$;

create or replace function public.mb_admin_set_review_hidden(p_id bigint, p_hidden boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t uuid;
begin
  perform mb_require_admin();
  update mb_reviews set hidden = coalesce(p_hidden,false) where id = p_id returning therapist_id into v_t;
  if v_t is not null then perform mb_recalc_rating(v_t); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.mb_admin_settings()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  return jsonb_build_object(
    'settings', (select coalesce(jsonb_object_agg(key, value), '{}') from mb_settings),
    'types', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'description', description, 'active', active, 'sort', sort) order by sort, name), '[]') from mb_massage_types));
end $$;

create or replace function public.mb_admin_save_setting(p_key text, p_value text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  if p_key not in ('commission_pct','buffer_min','lead_min','slot_step_min','accept_min','cancel_hours','booking_days','support_phone','support_email') then
    raise exception 'Unknown setting.';
  end if;
  if p_key not in ('support_phone','support_email') and (p_value !~ '^\d{1,4}$') then raise exception 'Please enter a whole number.'; end if;
  if p_key = 'commission_pct' and p_value::int > 90 then raise exception 'Commission must be 0 to 90%%.'; end if;
  if p_key = 'slot_step_min' and p_value::int not in (15,30,60) then raise exception 'Slot step must be 15, 30 or 60.'; end if;
  insert into mb_settings (key, value) values (p_key, trim(p_value)) on conflict (key) do update set value = excluded.value;
  return mb_admin_settings();
end $$;

create or replace function public.mb_admin_save_type(p_id int, p_name text, p_description text, p_active boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'Please enter a name.'; end if;
  if p_id is null then
    insert into mb_massage_types (name, description, active, sort)
    values (trim(p_name), coalesce(p_description,''), coalesce(p_active,true), (select coalesce(max(sort),0)+1 from mb_massage_types));
  else
    update mb_massage_types set name = trim(p_name), description = coalesce(p_description,''), active = coalesce(p_active,true) where id = p_id;
  end if;
  return mb_admin_settings();
end $$;

-- ---------------------------------------------------------------------
-- 8. Automatic jobs: expire unanswered requests + reminders (every 10 minutes)
-- ---------------------------------------------------------------------
create or replace function public.mb_run_jobs()
returns int language plpgsql security definer set search_path = public as $$
declare b record; n int := 0;
begin
  for b in select * from mb_bookings where status = 'pending' and not mb_booking_active(status, created_at) for update skip locked loop
    update mb_bookings set status = 'declined', cancelled_by = 'system', cancel_reason = 'Not accepted in time', updated_at = now() where id = b.id;
    perform mb_notify(b.customer_id, 'Booking not accepted', 'The therapist did not answer in time for ' || mb_when(b.start_at) || '. Please choose another therapist or time.', 'index.html');
    n := n + 1;
  end loop;
  for b in select * from mb_bookings where status = 'confirmed' and not reminded_24h
             and start_at between now() + interval '1 hour' and now() + interval '24 hours' for update skip locked loop
    update mb_bookings set reminded_24h = true where id = b.id;
    if b.start_at > now() + interval '20 hours' then
      perform mb_notify(b.customer_id, 'Reminder: massage tomorrow', b.type_name || ' at ' || mb_when(b.start_at) || '.', 'index.html#bookings');
      perform mb_notify(b.therapist_id, 'Reminder: booking tomorrow', b.type_name || ' at ' || mb_when(b.start_at) || ', ' || b.area || '.', 'therapist.html#bookings');
    end if;
    n := n + 1;
  end loop;
  for b in select * from mb_bookings where status = 'confirmed' and not reminded_1h
             and start_at between now() and now() + interval '70 minutes' for update skip locked loop
    update mb_bookings set reminded_1h = true, reminded_24h = true where id = b.id;
    perform mb_notify(b.customer_id, 'Your massage is in 1 hour', b.type_name || ' at ' || mb_when(b.start_at) || '. Please prepare ₱' || to_char(b.price,'FM999,999') || ' cash.', 'index.html#bookings');
    perform mb_notify(b.therapist_id, 'Booking in 1 hour', b.type_name || ' at ' || b.address, 'therapist.html#bookings');
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule(jobid) from cron.job where jobname = 'mb_jobs';
  perform cron.schedule('mb_jobs', '*/10 * * * *', 'select public.mb_run_jobs()');
exception when others then
  raise notice 'pg_cron not available (%). Reminders will not run automatically; everything else works.', sqlerrm;
end $$;

-- ---------------------------------------------------------------------
-- 9. Who may call which function
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'mb\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname in ('mb_massage_types','mb_public_settings','mb_list_therapists','mb_get_therapist','mb_get_slots') then
      execute format('grant execute on function %s to anon, authenticated', f.sig);
    elsif f.proname in ('mb_me','mb_save_profile','mb_create_booking','mb_my_bookings','mb_cancel_booking','mb_submit_review',
                        'mb_my_notifications','mb_mark_notifications_read','mb_save_push_token','mb_delete_push_token',
                        'mb_save_therapist','mb_my_therapist','mb_save_service','mb_delete_service','mb_save_availability',
                        'mb_add_blocked_date','mb_remove_blocked_date','mb_set_booking_status','mb_my_earnings',
                        'mb_admin_check','mb_admin_dashboard','mb_admin_therapists','mb_admin_set_therapist_status',
                        'mb_admin_bookings','mb_admin_customers','mb_admin_set_blocked','mb_admin_balances',
                        'mb_admin_add_settlement','mb_admin_reviews','mb_admin_set_review_hidden','mb_admin_settings',
                        'mb_admin_save_setting','mb_admin_save_type') then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
    -- helpers (mb_notify, mb_run_jobs, mb_is_admin, ...) stay private
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 10. Photo & document storage
--   mb-photos : public (therapist profile photos)
--   mb-docs   : private (IDs and certificates, only owner + admin)
--   Each person can only upload into a folder named with their own user id.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('mb-photos', 'mb-photos', true)  on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('mb-docs',   'mb-docs',   false) on conflict (id) do nothing;

drop policy if exists "mb photos upload own" on storage.objects;
create policy "mb photos upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'mb-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "mb photos update own" on storage.objects;
create policy "mb photos update own" on storage.objects for update to authenticated
  using (bucket_id = 'mb-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "mb photos delete own" on storage.objects;
create policy "mb photos delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'mb-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "mb docs upload own" on storage.objects;
create policy "mb docs upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'mb-docs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "mb docs read own or admin" on storage.objects;
create policy "mb docs read own or admin" on storage.objects for select to authenticated
  using (bucket_id = 'mb-docs' and ((storage.foldername(name))[1] = auth.uid()::text or public.mb_is_admin()));

grant execute on function public.mb_is_admin() to authenticated;   -- needed by the storage policy above

-- ---------------------------------------------------------------------
-- 11. Check (should show ok = 1)
-- ---------------------------------------------------------------------
select case when
    (select count(*) from information_schema.tables where table_schema = 'public' and table_name like 'mb\_%') >= 13
    and (select count(*) from mb_massage_types) >= 1
    and (select count(*) from mb_settings) >= 7
    and exists (select 1 from storage.buckets where id = 'mb-docs')
  then 1 else 0 end as ok;

-- =====================================================================
-- AFTER RUNNING: make yourself admin (do this once, after you sign up
-- in the Massage Buddy app with your email). Change the email, then run:
--
--   insert into public.mb_admins (user_id)
--   select id from auth.users where email = 'YOUR-EMAIL@gmail.com'
--   on conflict do nothing;
-- =====================================================================

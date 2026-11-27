-- =====================================================================
-- Massage Buddy - online payments (GCash via PayMongo) update v1.13 (2026-11-27)
--
-- What it does:
--   * Customers can pay with GCash (PayMongo) when booking, or pay cash.
--   * A GCash booking waits for payment (slot held 15 minutes); the
--     therapist is told only after it is paid.
--   * Automatic refunds for GCash bookings:
--       therapist declines / does not answer / cancels      -> 100%
--       customer cancels before the therapist accepts        -> 100%
--       customer cancels after accept (not yet on the way)   -> 80% (fee 20%)
--       customer cancels when the therapist is on the way    -> 50% (fee 50%)
--     The fee goes 80% to the therapist and 20% to Massage Buddy.
--   * Earnings and admin balances include online payments, fee shares
--     and payouts to therapists.
--
-- How to run:
--   Supabase > SQL Editor > New query > paste ALL of this > Run.
--   Run it AFTER v1.00, v1.10, v1.11, v1.12. Safe to run again.
--   The app keeps working (cash only) until this is run.
-- =====================================================================

set lock_timeout = '15s';

-- 1. Booking columns + new status 'awaiting_payment' ---------------------
alter table public.mb_bookings add column if not exists paymongo_session_id text not null default '';
alter table public.mb_bookings add column if not exists paymongo_payment_id text not null default '';
alter table public.mb_bookings add column if not exists paid_at             timestamptz;
alter table public.mb_bookings add column if not exists refund_amount       numeric(10,2) not null default 0;
alter table public.mb_bookings add column if not exists refund_status       text not null default '';
alter table public.mb_bookings add column if not exists cancel_fee          numeric(10,2) not null default 0;
alter table public.mb_bookings add column if not exists therapist_fee_share numeric(10,2) not null default 0;

do $$
declare c record;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.mb_bookings'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%status%' and pg_get_constraintdef(oid) like '%in_progress%'
             and pg_get_constraintdef(oid) not like '%payment_status%' loop
    execute format('alter table public.mb_bookings drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.mb_bookings add constraint mb_bookings_status_check
  check (status in ('awaiting_payment','pending','confirmed','on_the_way','in_progress','completed','cancelled','declined'));

-- 2. Refunds queue + private settings ---------------------------------------
create table if not exists public.mb_refunds (
  id                 bigserial primary key,
  booking_id         bigint not null references public.mb_bookings(id) on delete cascade,
  amount             numeric(10,2) not null check (amount > 0),
  payment_id         text not null,
  reason             text not null default '',
  status             text not null default 'pending' check (status in ('pending','processing','sent','failed','retried')),
  paymongo_refund_id text not null default '',
  error              text not null default '',
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists mb_refunds_booking on public.mb_refunds (booking_id);

create table if not exists public.mb_private_settings (
  key   text primary key,
  value text not null
);

alter table public.mb_refunds enable row level security;
alter table public.mb_private_settings enable row level security;
revoke all on public.mb_refunds, public.mb_private_settings from anon, authenticated;

-- settlements can now go both ways (therapist -> Massage Buddy, Massage Buddy -> therapist)
alter table public.mb_settlements add column if not exists direction text not null default 'to_platform';
do $$ begin
  alter table public.mb_settlements add constraint mb_settlements_direction_check check (direction in ('to_platform','to_therapist'));
exception when duplicate_object then null; end $$;

-- the Edge Functions use the service_role key; make sure it can reach these tables
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant select, insert, update on public.mb_refunds, public.mb_private_settings, public.mb_bookings to service_role;
    grant usage, select on sequence public.mb_refunds_id_seq to service_role;
  end if;
end $$;

insert into public.mb_settings (key, value) values ('online_payments', 'test') on conflict (key) do nothing;
insert into public.mb_settings (key, value) values ('pay_minutes', '15') on conflict (key) do nothing;

-- 3. Slot holding: unpaid GCash bookings hold the slot for 15 minutes -------
create or replace function public.mb_booking_active(p_status text, p_created timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select p_status in ('confirmed','on_the_way','in_progress')
      or (p_status = 'pending' and p_created > now() - make_interval(mins => mb_setting_int('accept_min', 60)))
      or (p_status = 'awaiting_payment' and p_created > now() - make_interval(mins => mb_setting_int('pay_minutes', 15)));
$$;

create or replace function public.mb_public_settings()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'booking_days',    mb_setting_int('booking_days', 14),
    'lead_min',        mb_setting_int('lead_min', 120),
    'cancel_hours',    mb_setting_int('cancel_hours', 3),
    'accept_min',      mb_setting_int('accept_min', 60),
    'pay_minutes',     mb_setting_int('pay_minutes', 15),
    'online_payments', coalesce((select value from mb_settings where key='online_payments'), ''),
    'support_phone',   coalesce((select value from mb_settings where key='support_phone'), ''),
    'support_email',   coalesce((select value from mb_settings where key='support_email'), ''));
$$;

-- 4. Create a booking with a payment method ('cash' or 'gcash') ------------
create or replace function public.mb_create_booking_v2(p_service bigint, p_start timestamptz, p_address text,
                                                       p_area text, p_phone text, p_notes text default '',
                                                       p_payment text default 'cash')
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
  v_pay  text := coalesce(nullif(p_payment, ''), 'cash');
begin
  if v_pay not in ('cash','gcash') then raise exception 'Unknown payment method.'; end if;
  if v_pay = 'gcash' and coalesce((select value from mb_settings where key = 'online_payments'), '') not in ('test','live') then
    raise exception 'GCash payment is not available yet. Please choose cash.';
  end if;
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
                           address, area, contact_phone, notes, price, commission, therapist_earning,
                           payment_method, status)
  values (v_uid, v_s.therapist_id, v_s.id, v_s.type_name, v_s.duration_min, p_start, v_end,
          left(trim(p_address), 300), left(coalesce(p_area,''), 60), left(trim(p_phone), 20),
          left(coalesce(p_notes,''), 500), v_s.price, v_comm, v_s.price - v_comm,
          v_pay, case when v_pay = 'gcash' then 'awaiting_payment' else 'pending' end)
  returning id into v_id;

  update mb_profiles set address = left(trim(p_address), 300), area = left(coalesce(p_area,''), 60),
         phone = case when phone = '' then left(trim(p_phone), 20) else phone end
  where id = v_uid;

  if v_pay = 'cash' then
    select full_name into v_name from mb_profiles where id = v_uid;
    perform mb_notify(v_s.therapist_id, 'New booking request',
      coalesce(nullif(v_name,''),'A customer') || ' booked ' || v_s.type_name || ' ' || v_s.duration_min || ' min on ' || mb_when(p_start) || '. Please accept.',
      'therapist.html#bookings');
  end if;

  return jsonb_build_object('id', v_id, 'start_at', p_start, 'price', v_s.price, 'payment_method', v_pay,
                            'status', case when v_pay = 'gcash' then 'awaiting_payment' else 'pending' end);
end $$;

-- the old function (used by older app versions) now books cash through v2
create or replace function public.mb_create_booking(p_service bigint, p_start timestamptz, p_address text,
                                                    p_area text, p_phone text, p_notes text default '')
returns jsonb language sql security definer set search_path = public as $$
  select mb_create_booking_v2(p_service, p_start, p_address, p_area, p_phone, p_notes, 'cash');
$$;

-- 5. Refund helper (GCash only). p_pct = % of the price given back. ---------
create or replace function public.mb_queue_refund(p_booking bigint, p_pct numeric, p_reason text, p_fee_to_therapist boolean)
returns numeric language plpgsql security definer set search_path = public as $$
declare b mb_bookings; v_amount numeric; v_fee numeric;
begin
  select * into b from mb_bookings where id = p_booking for update;
  if not found or b.payment_method <> 'gcash' or b.payment_status <> 'paid' or b.refund_status <> '' then
    return 0;
  end if;
  v_amount := round(b.price * greatest(0, least(100, p_pct)) / 100.0, 2);
  v_fee := b.price - v_amount;
  update mb_bookings set
    refund_amount = v_amount,
    refund_status = case when v_amount > 0 then 'pending' else 'none' end,
    cancel_fee = v_fee,
    therapist_fee_share = case when p_fee_to_therapist then round(v_fee * 0.8, 2) else 0 end
  where id = b.id;
  if v_amount > 0 then
    insert into mb_refunds (booking_id, amount, payment_id, reason) values (b.id, v_amount, b.paymongo_payment_id, left(coalesce(p_reason,''), 200));
    perform mb_notify(b.customer_id, 'Refund on the way ↩️',
      'We are sending back ₱' || to_char(v_amount, 'FM999,999.00') || ' to your GCash for your ' || b.type_name || ' booking.' ||
      case when v_fee > 0 then ' Cancellation fee: ₱' || to_char(v_fee, 'FM999,999.00') || '.' else '' end,
      'index.html#bookings');
  end if;
  return v_amount;
end $$;

-- 6. Payment received (called by the PayMongo webhook Edge Function only) ---
create or replace function public.mb_mark_paid(p_booking bigint, p_session text, p_payment_id text, p_amount_centavos bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b mb_bookings; v_name text;
begin
  select * into b from mb_bookings where id = p_booking for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'booking not found'); end if;
  if b.payment_status = 'paid' then return jsonb_build_object('ok', true, 'already', true); end if;
  if b.payment_method <> 'gcash' then return jsonb_build_object('ok', false, 'reason', 'not a gcash booking'); end if;
  if p_amount_centavos <> round(b.price * 100) then
    return jsonb_build_object('ok', false, 'reason', 'amount mismatch', 'expected', round(b.price * 100), 'got', p_amount_centavos);
  end if;

  update mb_bookings set payment_status = 'paid', paid_at = now(),
         paymongo_payment_id = coalesce(nullif(p_payment_id, ''), paymongo_payment_id),
         paymongo_session_id = coalesce(nullif(p_session, ''), paymongo_session_id),
         updated_at = now()
  where id = b.id;

  if b.status = 'awaiting_payment' then
    -- the therapist's answer time starts now
    update mb_bookings set status = 'pending', created_at = now() where id = b.id;
    select full_name into v_name from mb_profiles where id = b.customer_id;
    perform mb_notify(b.therapist_id, 'New booking request 💙 paid',
      coalesce(nullif(v_name,''),'A customer') || ' booked and paid ' || b.type_name || ' ' || b.duration_min || ' min on ' || mb_when(b.start_at) || '. Please accept.',
      'therapist.html#bookings');
    perform mb_notify(b.customer_id, 'Payment received ✅',
      'Thank you! ₱' || to_char(b.price, 'FM999,999') || ' paid by GCash. Waiting for your therapist to accept.', 'index.html#bookings');
  else
    -- paid after the booking already expired or was cancelled: give everything back
    perform mb_queue_refund(b.id, 100, 'Paid after the booking expired', false);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 7. Refund result (called by the refund Edge Function only) -----------------
create or replace function public.mb_refund_result(p_refund bigint, p_ok boolean, p_paymongo_refund_id text, p_error text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r mb_refunds; b mb_bookings;
begin
  select * into r from mb_refunds where id = p_refund for update;
  if not found then return jsonb_build_object('ok', false); end if;
  update mb_refunds set status = case when p_ok then 'sent' else 'failed' end,
         paymongo_refund_id = coalesce(p_paymongo_refund_id, ''), error = left(coalesce(p_error, ''), 500), updated_at = now()
  where id = r.id;
  select * into b from mb_bookings where id = r.booking_id;
  update mb_bookings set refund_status = case when p_ok then 'sent' else 'failed' end,
         payment_status = case when p_ok and r.amount >= b.price then 'refunded' else payment_status end
  where id = r.booking_id;
  if p_ok then
    perform mb_notify(b.customer_id, 'Refund sent ✅',
      '₱' || to_char(r.amount, 'FM999,999.00') || ' was sent back to your GCash. It may take a few days to show.', 'index.html#bookings');
  else
    perform mb_notify(a.user_id, 'Refund failed ⚠️', 'Booking #' || r.booking_id || ': ' || left(coalesce(p_error,''), 120), 'admin.html#bookings')
    from mb_admins a;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 8. Cancel (customer / therapist / admin) with GCash refunds ----------------
create or replace function public.mb_cancel_booking(p_booking bigint, p_reason text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := mb_require_login();
  b mb_bookings;
  v_who text;
  v_hours int := mb_setting_int('cancel_hours', 3);
  v_pct numeric := 100;
begin
  select * into b from mb_bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  if b.customer_id = v_uid then v_who := 'customer';
  elsif b.therapist_id = v_uid then v_who := 'therapist';
  elsif mb_is_admin() then v_who := 'admin';
  else raise exception 'Booking not found.'; end if;

  if b.status = 'awaiting_payment' then
    if v_who = 'therapist' then raise exception 'Booking not found.'; end if;
    update mb_bookings set status = 'cancelled', cancelled_by = v_who, cancel_reason = left(coalesce(nullif(p_reason,''), 'Payment not completed'), 300),
           updated_at = now() where id = b.id;
    return jsonb_build_object('ok', true);
  end if;

  if b.status not in ('pending','confirmed','on_the_way') then
    raise exception 'This booking can no longer be cancelled.';
  end if;
  -- cash bookings: late cancels must be done by phone (no way to charge a fee)
  if v_who = 'customer' and b.payment_method = 'cash' and b.status <> 'pending' and b.start_at < now() + make_interval(hours => v_hours) then
    raise exception 'It is less than % hours before your massage. Please call your therapist to cancel.', v_hours;
  end if;
  if v_who = 'therapist' and length(trim(coalesce(p_reason,''))) < 3 then
    raise exception 'Please write a short reason for the customer.';
  end if;

  update mb_bookings set status = 'cancelled', cancelled_by = v_who, cancel_reason = left(coalesce(p_reason,''), 300),
         updated_at = now() where id = b.id;

  -- GCash refund rules (from the Refund & Cancellation Policy)
  if v_who = 'customer' then
    v_pct := case b.status when 'pending' then 100 when 'confirmed' then 80 when 'on_the_way' then 50 else 100 end;
  end if;
  perform mb_queue_refund(b.id, v_pct, 'Cancelled by ' || v_who, v_who = 'customer' and v_pct < 100);

  if v_who <> 'customer' then
    perform mb_notify(b.customer_id, 'Booking cancelled',
      'Your ' || b.type_name || ' on ' || mb_when(b.start_at) || ' was cancelled' ||
      case when coalesce(p_reason,'') <> '' then ': ' || p_reason else '.' end, 'index.html#bookings');
  end if;
  if v_who <> 'therapist' then
    perform mb_notify(b.therapist_id, 'Booking cancelled',
      'The ' || b.type_name || ' on ' || mb_when(b.start_at) || ' was cancelled by the ' || v_who || '.' ||
      case when v_who = 'customer' and v_pct < 100 and b.payment_method = 'gcash'
           then ' You get ₱' || to_char(round(b.price * (100 - v_pct) / 100.0 * 0.8, 2), 'FM999,999.00') || ' from the cancellation fee.' else '' end,
      'therapist.html#bookings');
  end if;
  return jsonb_build_object('ok', true, 'refund_pct', case when b.payment_method = 'gcash' then v_pct else null end);
end $$;

-- 9. Therapist steps (decline refunds GCash; messages say "paid" instead of "prepare cash")
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
         payment_status = case when p_status = 'completed' and payment_method = 'cash' then 'paid' else payment_status end,
         cancelled_by = case when p_status = 'declined' then 'therapist' else cancelled_by end
  where id = b.id;

  if p_status = 'declined' then perform mb_queue_refund(b.id, 100, 'Therapist declined', false); end if;

  v_title := case p_status
    when 'confirmed'   then 'Booking confirmed ✅'
    when 'declined'    then 'Booking not accepted'
    when 'on_the_way'  then 'Your therapist is on the way'
    when 'in_progress' then 'Massage started'
    when 'completed'   then 'Massage completed - please rate' end;
  v_body := case p_status
    when 'confirmed'   then 'Your ' || b.type_name || ' is confirmed for ' || mb_when(b.start_at) || '. ' ||
                            case when b.payment_method = 'gcash' then 'Already paid by GCash ✅' else 'Please prepare ₱' || to_char(b.price,'FM999,999') || ' cash.' end
    when 'declined'    then 'The therapist is not available for ' || mb_when(b.start_at) || '. Please choose another time or therapist.' ||
                            case when b.payment_method = 'gcash' and b.payment_status = 'paid' then ' Your GCash payment will be fully refunded.' else '' end
    when 'on_the_way'  then 'Your therapist is heading to your address now.'
    when 'in_progress' then 'Enjoy your massage!'
    when 'completed'   then 'Thank you! Tap to rate your therapist.' end;
  perform mb_notify(b.customer_id, v_title, v_body, 'index.html#bookings');
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;

-- 10. Automatic jobs: + expire unpaid GCash bookings, + refund unanswered paid ones
create or replace function public.mb_run_jobs()
returns int language plpgsql security definer set search_path = public as $$
declare b record; n int := 0;
begin
  for b in select * from mb_bookings where status = 'awaiting_payment' and not mb_booking_active(status, created_at) for update skip locked loop
    update mb_bookings set status = 'cancelled', cancelled_by = 'system', cancel_reason = 'Payment not completed', updated_at = now() where id = b.id;
    n := n + 1;
  end loop;
  for b in select * from mb_bookings where status = 'pending' and not mb_booking_active(status, created_at) for update skip locked loop
    update mb_bookings set status = 'declined', cancelled_by = 'system', cancel_reason = 'Not accepted in time', updated_at = now() where id = b.id;
    perform mb_queue_refund(b.id, 100, 'Not accepted in time', false);
    perform mb_notify(b.customer_id, 'Booking not accepted', 'The therapist did not answer in time for ' || mb_when(b.start_at) || '. Please choose another therapist or time.' ||
      case when b.payment_method = 'gcash' and b.payment_status = 'paid' then ' Your GCash payment will be fully refunded.' else '' end, 'index.html');
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
    perform mb_notify(b.customer_id, 'Your massage is in 1 hour', b.type_name || ' at ' || mb_when(b.start_at) || '. ' ||
      case when b.payment_method = 'gcash' then 'Already paid by GCash ✅' else 'Please prepare ₱' || to_char(b.price,'FM999,999') || ' cash.' end, 'index.html#bookings');
    perform mb_notify(b.therapist_id, 'Booking in 1 hour', b.type_name || ' at ' || b.address, 'therapist.html#bookings');
    n := n + 1;
  end loop;
  return n;
end $$;

-- 11. Booking details include payment / refund info ---------------------------
create or replace function public.mb_booking_json(b public.mb_bookings, p_as text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', b.id, 'type_name', b.type_name, 'duration_min', b.duration_min,
    'start_at', b.start_at, 'end_at', b.end_at, 'address', b.address, 'area', b.area,
    'notes', b.notes, 'price', b.price, 'commission', b.commission, 'therapist_earning', b.therapist_earning,
    'payment_method', b.payment_method, 'payment_status', b.payment_status, 'paid_at', b.paid_at,
    'refund_amount', b.refund_amount, 'refund_status', b.refund_status,
    'cancel_fee', b.cancel_fee, 'therapist_fee_share', b.therapist_fee_share,
    'status', case when b.status in ('pending','awaiting_payment') and not mb_booking_active(b.status, b.created_at)
                   then case when b.status = 'awaiting_payment' then 'cancelled' else 'declined' end else b.status end,
    'pay_deadline', case when b.status = 'awaiting_payment' then b.created_at + make_interval(mins => mb_setting_int('pay_minutes', 15)) end,
    'cancel_reason', b.cancel_reason, 'cancelled_by', b.cancelled_by, 'created_at', b.created_at,
    'reviewed', exists (select 1 from mb_reviews r where r.booking_id = b.id),
    'therapist', (select jsonb_build_object('id', t.id, 'name', t.display_name, 'photo_url', t.photo_url,
                    'phone', case when p_as in ('customer','admin') and b.status in ('confirmed','on_the_way','in_progress') then tp.phone else null end)
                  from mb_therapists t join mb_profiles tp on tp.id = t.id where t.id = b.therapist_id),
    'customer', (select jsonb_build_object('id', c.id, 'name', c.full_name,
                    'phone', case when p_as = 'admin' or b.status in ('pending','confirmed','on_the_way','in_progress') then b.contact_phone else null end)
                 from mb_profiles c where c.id = b.customer_id));
$$;

-- therapists never see unpaid GCash bookings
create or replace function public.mb_my_bookings(p_as text default 'customer')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_ensure_profile();
begin
  if p_as = 'therapist' then
    if not exists (select 1 from mb_therapists where id = v_uid) then raise exception 'Therapists only.'; end if;
    return (select coalesce(jsonb_agg(mb_booking_json(b, 'therapist') order by b.start_at desc), '[]')
            from mb_bookings b where b.therapist_id = v_uid and b.status <> 'awaiting_payment'
              and not (b.status = 'cancelled' and b.cancel_reason = 'Payment not completed')
              and b.start_at > now() - interval '120 days');
  end if;
  return (select coalesce(jsonb_agg(mb_booking_json(b, 'customer') order by b.start_at desc), '[]')
          from mb_bookings b where b.customer_id = v_uid and b.start_at > now() - interval '365 days');
end $$;

-- 12. Money: one balance per therapist (positive = therapist owes Massage Buddy)
create or replace function public.mb_therapist_money(p_therapist uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with x as (
    select
      (select coalesce(sum(commission),0) from mb_bookings where therapist_id = p_therapist and status = 'completed' and payment_method = 'cash') as cash_comm,
      (select coalesce(sum(therapist_earning),0) from mb_bookings where therapist_id = p_therapist and status = 'completed' and payment_method = 'gcash' and payment_status = 'paid') as online_owed,
      (select coalesce(sum(therapist_fee_share),0) from mb_bookings where therapist_id = p_therapist and payment_method = 'gcash' and therapist_fee_share > 0) as fee_owed,
      (select coalesce(sum(amount),0) from mb_settlements where therapist_id = p_therapist and direction = 'to_platform') as paid_in,
      (select coalesce(sum(amount),0) from mb_settlements where therapist_id = p_therapist and direction = 'to_therapist') as paid_out)
  select jsonb_build_object('cash_commission_due', cash_comm, 'online_earnings_owed', online_owed, 'fee_share_owed', fee_owed,
    'paid_to_platform', paid_in, 'paid_to_therapist', paid_out,
    'balance', cash_comm - online_owed - fee_owed - paid_in + paid_out) from x;
$$;

create or replace function public.mb_my_earnings()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := mb_require_therapist();
  v_today date := (now() at time zone 'Asia/Manila')::date;
  m jsonb := mb_therapist_money(v_uid);
begin
  return jsonb_build_object(
    'today', (select jsonb_build_object('count', count(*), 'gross', coalesce(sum(price),0), 'net', coalesce(sum(therapist_earning),0))
              from mb_bookings where therapist_id = v_uid and status = 'completed' and (start_at at time zone 'Asia/Manila')::date = v_today),
    'week',  (select jsonb_build_object('count', count(*), 'gross', coalesce(sum(price),0), 'net', coalesce(sum(therapist_earning),0))
              from mb_bookings where therapist_id = v_uid and status = 'completed' and (start_at at time zone 'Asia/Manila')::date > v_today - 7),
    'month', (select jsonb_build_object('count', count(*), 'gross', coalesce(sum(price),0), 'net', coalesce(sum(therapist_earning),0))
              from mb_bookings where therapist_id = v_uid and status = 'completed' and (start_at at time zone 'Asia/Manila')::date > v_today - 30),
    -- kept for older app versions
    'commission_due', (m->>'cash_commission_due')::numeric, 'commission_paid', (m->>'paid_to_platform')::numeric,
    'money', m, 'balance', (m->>'balance')::numeric,
    'commission_pct', mb_setting_int('commission_pct', 20),
    'settlements', (select coalesce(jsonb_agg(jsonb_build_object('amount', amount, 'reference', reference, 'note', note,
                      'direction', direction, 'created_at', created_at) order by created_at desc), '[]')
                    from (select * from mb_settlements where therapist_id = v_uid order by created_at desc limit 30) s));
end $$;

create or replace function public.mb_admin_balances()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  return (select coalesce(jsonb_agg(x order by abs((x->>'balance')::numeric) desc), '[]') from (
    select jsonb_build_object('id', t.id, 'display_name', t.display_name, 'phone', p.phone,
      'completed', (select count(*) from mb_bookings b where b.therapist_id = t.id and b.status = 'completed'),
      'gross', (select coalesce(sum(price),0) from mb_bookings b where b.therapist_id = t.id and b.status = 'completed'),
      'due', (m->>'cash_commission_due')::numeric, 'paid', (m->>'paid_to_platform')::numeric,
      'online_owed', (m->>'online_earnings_owed')::numeric, 'fee_owed', (m->>'fee_share_owed')::numeric,
      'paid_out', (m->>'paid_to_therapist')::numeric, 'balance', (m->>'balance')::numeric) as x
    from mb_therapists t join mb_profiles p on p.id = t.id
    cross join lateral (select mb_therapist_money(t.id) as m) mm) z);
end $$;

-- record money moving either way
create or replace function public.mb_admin_record_money(p_therapist uuid, p_amount numeric, p_direction text,
                                                        p_reference text default '', p_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_admin();
begin
  if p_amount is null or p_amount <= 0 then raise exception 'Enter an amount above zero.'; end if;
  if p_direction not in ('to_platform','to_therapist') then raise exception 'Unknown direction.'; end if;
  insert into mb_settlements (therapist_id, amount, reference, note, created_by, direction)
  values (p_therapist, round(p_amount, 2), left(coalesce(p_reference,''),80), left(coalesce(p_note,''),200), v_uid, p_direction);
  perform mb_notify(p_therapist,
    case when p_direction = 'to_therapist' then 'Payout sent 💸' else 'Commission payment received' end,
    case when p_direction = 'to_therapist' then 'Massage Buddy sent you ₱' else 'Thank you! We received ₱' end || to_char(p_amount,'FM999,999.00') || '.',
    'therapist.html#earnings');
  return jsonb_build_object('ok', true);
end $$;

-- refunds list + retry for admin
create or replace function public.mb_admin_refunds()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'booking_id', r.booking_id, 'amount', r.amount, 'status', r.status,
            'reason', r.reason, 'error', r.error, 'created_at', r.created_at, 'customer', p.full_name) order by r.created_at desc), '[]')
          from (select * from mb_refunds order by created_at desc limit 200) r
          join mb_bookings b on b.id = r.booking_id join mb_profiles p on p.id = b.customer_id);
end $$;

create or replace function public.mb_admin_retry_refund(p_refund bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r mb_refunds;
begin
  perform mb_require_admin();
  select * into r from mb_refunds where id = p_refund for update;
  if not found or r.status <> 'failed' then raise exception 'Only failed refunds can be retried.'; end if;
  update mb_refunds set status = 'retried', updated_at = now() where id = r.id;
  insert into mb_refunds (booking_id, amount, payment_id, reason) values (r.booking_id, r.amount, r.payment_id, r.reason);
  update mb_bookings set refund_status = 'pending' where id = r.booking_id;
  return jsonb_build_object('ok', true);
end $$;

-- admin can switch GCash off / test / live and change the payment time limit
create or replace function public.mb_admin_save_setting(p_key text, p_value text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  if p_key not in ('commission_pct','buffer_min','lead_min','slot_step_min','accept_min','cancel_hours','booking_days',
                   'support_phone','support_email','online_payments','pay_minutes') then
    raise exception 'Unknown setting.';
  end if;
  if p_key = 'online_payments' then
    if coalesce(p_value,'') not in ('','test','live') then raise exception 'Choose off, test or live.'; end if;
  elsif p_key not in ('support_phone','support_email') and (p_value !~ '^\d{1,4}$') then raise exception 'Please enter a whole number.';
  end if;
  if p_key = 'commission_pct' and p_value::int > 90 then raise exception 'Commission must be 0 to 90%%.'; end if;
  if p_key = 'slot_step_min' and p_value::int not in (15,30,60) then raise exception 'Slot step must be 15, 30 or 60.'; end if;
  if p_key = 'pay_minutes' and p_value::int not between 5 and 60 then raise exception 'Payment time must be 5 to 60 minutes.'; end if;
  insert into mb_settings (key, value) values (p_key, trim(coalesce(p_value,''))) on conflict (key) do update set value = excluded.value;
  return mb_admin_settings();
end $$;

-- 13. Permissions ---------------------------------------------------------------
revoke all on function public.mb_create_booking_v2(bigint, timestamptz, text, text, text, text, text) from public, anon;
grant execute on function public.mb_create_booking_v2(bigint, timestamptz, text, text, text, text, text) to authenticated;
revoke all on function public.mb_create_booking(bigint, timestamptz, text, text, text, text) from public, anon;
grant execute on function public.mb_create_booking(bigint, timestamptz, text, text, text, text) to authenticated;
revoke all on function public.mb_queue_refund(bigint, numeric, text, boolean) from public, anon, authenticated;
revoke all on function public.mb_therapist_money(uuid) from public, anon, authenticated;
revoke all on function public.mb_mark_paid(bigint, text, text, bigint) from public, anon, authenticated;
revoke all on function public.mb_refund_result(bigint, boolean, text, text) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.mb_mark_paid(bigint, text, text, bigint) to service_role;
    grant execute on function public.mb_refund_result(bigint, boolean, text, text) to service_role;
  end if;
end $$;
revoke all on function public.mb_admin_record_money(uuid, numeric, text, text, text) from public, anon;
grant execute on function public.mb_admin_record_money(uuid, numeric, text, text, text) to authenticated;
revoke all on function public.mb_admin_refunds() from public, anon;
grant execute on function public.mb_admin_refunds() to authenticated;
revoke all on function public.mb_admin_retry_refund(bigint) from public, anon;
grant execute on function public.mb_admin_retry_refund(bigint) to authenticated;
grant execute on function public.mb_public_settings() to anon, authenticated;

-- 14. Check (should show ok = 1) ---------------------------------------------------
select case when
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'mb_bookings'
      and column_name in ('paymongo_session_id','paymongo_payment_id','paid_at','refund_amount','refund_status','cancel_fee','therapist_fee_share')) = 7
    and exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'mb_refunds')
    and exists (select 1 from pg_proc where proname = 'mb_create_booking_v2')
    and exists (select 1 from pg_proc where proname = 'mb_mark_paid')
    and (select value from mb_settings where key = 'online_payments') in ('test','live')
  then 1 else 0 end as ok;

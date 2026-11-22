-- =====================================================================
-- Massage Buddy - booking chat update v1.11 (2026-11-22)
--
-- What it does:
--   Customer and therapist can chat inside a booking once the
--   therapist has accepted it (confirmed / on the way / in progress,
--   and up to 3 hours after the booking ends). The other side gets a
--   notification. Admin can read a booking's chat for complaints.
--
-- How to run:
--   Supabase > SQL Editor > New query > paste ALL of this > Run.
--   Run it AFTER v1.00 (and v1.10). Safe to run again.
-- =====================================================================

set lock_timeout = '15s';

-- 1. Messages table (locked: apps use the functions below) ---------------
create table if not exists public.mb_messages (
  id          bigserial primary key,
  booking_id  bigint not null references public.mb_bookings(id) on delete cascade,
  sender_id   uuid not null references auth.users(id) on delete cascade,
  body        text not null check (length(body) between 1 and 1000),
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists mb_messages_booking on public.mb_messages (booking_id, id);
alter table public.mb_messages enable row level security;
revoke all on public.mb_messages from anon, authenticated;

-- 2. Can this booking chat right now? -------------------------------------
create or replace function public.mb_chat_open(b public.mb_bookings)
returns boolean language sql stable security definer set search_path = public as $$
  select b.status in ('confirmed','on_the_way','in_progress')
      or (b.status = 'completed' and b.end_at > now() - interval '3 hours');
$$;

-- 3. Read a booking's chat (customer, therapist or admin) -----------------
create or replace function public.mb_booking_messages(p_booking bigint, p_after bigint default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_login(); b mb_bookings; v_admin boolean := mb_is_admin();
begin
  select * into b from mb_bookings where id = p_booking;
  if not found or (b.customer_id <> v_uid and b.therapist_id <> v_uid and not v_admin) then
    raise exception 'Booking not found.';
  end if;
  -- mark the other person's messages as read (not when admin is only looking)
  if b.customer_id = v_uid or b.therapist_id = v_uid then
    update mb_messages set read_at = now()
    where booking_id = b.id and sender_id <> v_uid and read_at is null;
  end if;
  return jsonb_build_object(
    'can_send', (b.customer_id = v_uid or b.therapist_id = v_uid) and mb_chat_open(b),
    'status', b.status,
    'me', v_uid,
    'customer_id', b.customer_id, 'therapist_id', b.therapist_id,
    'customer_name', (select full_name from mb_profiles where id = b.customer_id),
    'therapist_name', (select display_name from mb_therapists where id = b.therapist_id),
    'messages', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'body', m.body,
                   'created_at', m.created_at, 'read', m.read_at is not null) order by m.id), '[]')
                 from mb_messages m where m.booking_id = b.id and m.id > coalesce(p_after, 0)));
end $$;

-- 4. Send a message ------------------------------------------------------
create or replace function public.mb_send_message(p_booking bigint, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := mb_require_login();
  b mb_bookings;
  v_to uuid; v_name text; v_link text; v_body text := trim(coalesce(p_body, ''));
  v_id bigint;
begin
  select * into b from mb_bookings where id = p_booking;
  if not found or (b.customer_id <> v_uid and b.therapist_id <> v_uid) then raise exception 'Booking not found.'; end if;
  if not mb_chat_open(b) then raise exception 'Chat is closed for this booking.'; end if;
  if v_body = '' then raise exception 'Please type a message.'; end if;
  if length(v_body) > 1000 then raise exception 'Message is too long (max 1000 characters).'; end if;
  -- simple anti-spam: max 20 messages per minute per person
  if (select count(*) from mb_messages where sender_id = v_uid and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'You are sending messages too fast. Please wait a moment.';
  end if;

  -- notify only if the receiver has no unread message in this chat yet (no spam)
  if b.customer_id = v_uid then
    v_to := b.therapist_id; v_link := 'therapist.html#chat/' || b.id;
    select coalesce(nullif(split_part(full_name, ' ', 1), ''), 'Customer') into v_name from mb_profiles where id = v_uid;
  else
    v_to := b.customer_id; v_link := 'index.html#chat/' || b.id;
    select display_name into v_name from mb_therapists where id = v_uid;
  end if;
  if not exists (select 1 from mb_messages where booking_id = b.id and sender_id = v_uid and read_at is null) then
    perform mb_notify(v_to, '💬 New message from ' || coalesce(v_name, 'Massage Buddy'), left(v_body, 120), v_link);
  end if;

  insert into mb_messages (booking_id, sender_id, body) values (b.id, v_uid, v_body) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 5. Unread counts per booking for the bookings list ----------------------
create or replace function public.mb_my_unread_chats()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_login();
begin
  return (select coalesce(jsonb_object_agg(x.booking_id::text, x.n), '{}') from (
    select m.booking_id, count(*) as n
    from mb_messages m join mb_bookings b on b.id = m.booking_id
    where (b.customer_id = v_uid or b.therapist_id = v_uid) and m.sender_id <> v_uid and m.read_at is null
    group by m.booking_id) x);
end $$;

-- 6. Permissions ---------------------------------------------------------
revoke all on function public.mb_chat_open(public.mb_bookings) from public, anon, authenticated;
revoke all on function public.mb_booking_messages(bigint, bigint) from public, anon;
grant execute on function public.mb_booking_messages(bigint, bigint) to authenticated;
revoke all on function public.mb_send_message(bigint, text) from public, anon;
grant execute on function public.mb_send_message(bigint, text) to authenticated;
revoke all on function public.mb_my_unread_chats() from public, anon;
grant execute on function public.mb_my_unread_chats() to authenticated;

-- 7. Check (should show ok = 1) --------------------------------------------
select case when
    exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'mb_messages')
    and exists (select 1 from pg_proc where proname = 'mb_send_message')
    and exists (select 1 from pg_proc where proname = 'mb_my_unread_chats')
  then 1 else 0 end as ok;

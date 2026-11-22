-- =====================================================================
-- Massage Buddy - customer Terms agreement update v1.12 (2026-11-23)
--
-- What it does:
--   Every account must agree to the Terms & Conditions, Privacy Policy
--   and Refund & Cancellation Policy. The date/time of agreement is
--   saved on the account. A booking cannot be made without it.
--   - New sign-ups tick "I agree" (saved automatically on first login)
--   - Google / phone / older accounts get an "Accept the Terms" popup
--
-- How to run:
--   Supabase > SQL Editor > New query > paste ALL of this > Run.
--   Run it AFTER v1.00, v1.10, v1.11. Safe to run again.
-- =====================================================================

set lock_timeout = '15s';

-- 1. New columns ---------------------------------------------------------
alter table public.mb_profiles add column if not exists terms_accepted_at timestamptz;
alter table public.mb_profiles add column if not exists terms_version     text not null default '';

-- 2. Accept the Terms (from the popup) -------------------------------------
create or replace function public.mb_accept_terms(p_version text default '2026-11-22')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_ensure_profile();
begin
  update mb_profiles
     set terms_accepted_at = coalesce(terms_accepted_at, now()),
         terms_version = left(coalesce(nullif(p_version, ''), '2026-11-22'), 20)
   where id = v_uid;
  return mb_me();
end $$;

-- 3. mb_me: also returns terms_accepted (same signature as v1.00) ---------
--    A ticked box at sign-up is stored in the sign-up data and saved here on first login.
create or replace function public.mb_me()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_ensure_profile();
begin
  update mb_profiles p set terms_accepted_at = now(), terms_version = '2026-11-22'
   where p.id = v_uid and p.terms_accepted_at is null
     and exists (select 1 from auth.users u where u.id = v_uid and u.raw_user_meta_data->>'terms_accepted' = 'true');
  return (select jsonb_build_object(
      'id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'email', p.email,
      'address', p.address, 'area', p.area, 'blocked', p.blocked,
      'is_admin', mb_is_admin(),
      'terms_accepted', p.terms_accepted_at is not null, 'terms_accepted_at', p.terms_accepted_at,
      'therapist_status', (select status from mb_therapists where id = p.id),
      'unread', (select count(*) from mb_notifications n where n.user_id = p.id and not n.read))
    from mb_profiles p where p.id = v_uid);
end $$;

-- 4. Therapists who ticked the box in their application count as accepted --
update public.mb_profiles p set terms_accepted_at = t.terms_accepted_at, terms_version = '2026-11-22'
  from public.mb_therapists t
 where t.id = p.id and p.terms_accepted_at is null and t.terms_accepted_at is not null;

-- 5. No booking without agreeing to the Terms ------------------------------
create or replace function public.mb_bookings_require_terms()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from mb_profiles where id = new.customer_id and terms_accepted_at is not null) then
    raise exception 'Please accept the Terms & Conditions, Privacy Policy and Refund Policy before booking.';
  end if;
  return new;
end $$;
drop trigger if exists mb_bookings_require_terms on public.mb_bookings;
create trigger mb_bookings_require_terms before insert on public.mb_bookings
  for each row execute function public.mb_bookings_require_terms();

-- 6. Admin customers list shows the agreement date ---------------------------
create or replace function public.mb_admin_customers(p_search text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'email', p.email, 'area', p.area,
      'blocked', p.blocked, 'created_at', p.created_at, 'terms_accepted_at', p.terms_accepted_at,
      'is_therapist', exists (select 1 from mb_therapists t where t.id = p.id),
      'bookings', (select count(*) from mb_bookings b where b.customer_id = p.id),
      'cancelled', (select count(*) from mb_bookings b where b.customer_id = p.id and b.status = 'cancelled' and b.cancelled_by = 'customer'))
      order by p.created_at desc), '[]')
    from (select * from mb_profiles
          where coalesce(p_search,'') = '' or full_name ilike '%'||p_search||'%' or phone ilike '%'||p_search||'%' or email ilike '%'||p_search||'%'
          order by created_at desc limit 300) p);
end $$;

-- 7. Permissions -------------------------------------------------------------
revoke all on function public.mb_accept_terms(text) from public, anon;
grant execute on function public.mb_accept_terms(text) to authenticated;
revoke all on function public.mb_me() from public, anon;
grant execute on function public.mb_me() to authenticated;
revoke all on function public.mb_admin_customers(text) from public, anon;
grant execute on function public.mb_admin_customers(text) to authenticated;
revoke all on function public.mb_bookings_require_terms() from public, anon, authenticated;

-- 8. Check (should show ok = 1) ----------------------------------------------
select case when
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'mb_profiles'
      and column_name in ('terms_accepted_at','terms_version')) = 2
    and exists (select 1 from pg_proc where proname = 'mb_accept_terms')
    and exists (select 1 from pg_trigger where tgname = 'mb_bookings_require_terms')
  then 1 else 0 end as ok;

-- =====================================================================
-- PasuyoBuddy: grey out vehicles that have no approved rider yet (v2.60)
-- Run in Supabase > SQL Editor, after v2.59. Safe to run again.
--
--  * New function vehicle_availability(): for each vehicle type, how many
--    APPROVED riders exist (only the count, no names or details).
--  * The customer app uses it to grey out "No riders yet" vehicles.
-- No existing data is changed.
-- =====================================================================
set lock_timeout = '15s';

create or replace function public.vehicle_availability()
returns table (vehicle_type_id smallint, riders int)
language sql stable security definer set search_path = public as $$
  select v.id::smallint, count(r.profile_id)::int
    from public.vehicle_types v
    left join public.riders r on r.vehicle_type_id = v.id and r.status = 'approved'
   group by v.id
$$;
revoke all on function public.vehicle_availability() from public;
grant execute on function public.vehicle_availability() to authenticated;

-- Check: should show ok = 1
select (exists (select 1 from pg_proc where proname = 'vehicle_availability'))::int as ok;

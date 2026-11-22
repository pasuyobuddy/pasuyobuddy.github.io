-- =====================================================================
-- Massage Buddy - therapist documents update v1.10 (2026-11-22)
--
-- What it does:
--   Therapists can upload more documents: NBI Clearance, selfie holding
--   their ID, signed Letter of Intent, Barangay Clearance (optional),
--   and must accept the Terms & Privacy Policy.
--   Admin cannot approve a therapist until the required documents
--   (valid ID, NBI, selfie with ID, Letter of Intent, terms accepted)
--   are complete.
--
-- How to run:
--   Supabase > SQL Editor > New query > paste ALL of this > Run.
--   Run it AFTER massagebuddy_setup_v1.00. Safe to run again.
-- =====================================================================

set lock_timeout = '15s';

-- 1. New columns -------------------------------------------------------
alter table public.mb_therapists add column if not exists nbi_doc_path      text not null default '';
alter table public.mb_therapists add column if not exists selfie_doc_path   text not null default '';
alter table public.mb_therapists add column if not exists loi_doc_path      text not null default '';
alter table public.mb_therapists add column if not exists barangay_doc_path text not null default '';
alter table public.mb_therapists add column if not exists terms_accepted_at timestamptz;

-- 2. Therapist saves extra documents ------------------------------------
-- Empty values keep the existing file. p_accept_terms = true records the time once.
create or replace function public.mb_save_therapist_docs(p_nbi text default '', p_selfie text default '',
                                                         p_loi text default '', p_barangay text default '',
                                                         p_accept_terms boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_require_login();
begin
  if not exists (select 1 from mb_therapists where id = v_uid) then
    raise exception 'Please save your therapist profile first.';
  end if;
  if (select status from mb_therapists where id = v_uid) = 'suspended' then
    raise exception 'Your therapist account is suspended. Please contact support.';
  end if;
  -- files must be inside the therapist's own folder
  if (coalesce(p_nbi,'') <> '' and split_part(p_nbi,'/',1) <> v_uid::text)
     or (coalesce(p_selfie,'') <> '' and split_part(p_selfie,'/',1) <> v_uid::text)
     or (coalesce(p_loi,'') <> '' and split_part(p_loi,'/',1) <> v_uid::text)
     or (coalesce(p_barangay,'') <> '' and split_part(p_barangay,'/',1) <> v_uid::text) then
    raise exception 'Invalid document.';
  end if;
  update mb_therapists set
    nbi_doc_path      = case when coalesce(p_nbi,'')      <> '' then p_nbi      else nbi_doc_path end,
    selfie_doc_path   = case when coalesce(p_selfie,'')   <> '' then p_selfie   else selfie_doc_path end,
    loi_doc_path      = case when coalesce(p_loi,'')      <> '' then p_loi      else loi_doc_path end,
    barangay_doc_path = case when coalesce(p_barangay,'') <> '' then p_barangay else barangay_doc_path end,
    terms_accepted_at = case when p_accept_terms and terms_accepted_at is null then now() else terms_accepted_at end,
    updated_at = now()
  where id = v_uid;
  return mb_my_therapist();
end $$;

-- 3. Show document status to the therapist (same signature as v1.00) ----
create or replace function public.mb_my_therapist()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := mb_ensure_profile();
begin
  if not exists (select 1 from mb_therapists where id = v_uid) then return null; end if;
  return (select jsonb_build_object(
    'id', t.id, 'display_name', t.display_name, 'gender', t.gender, 'area', t.area,
    'experience_years', t.experience_years, 'bio', t.bio, 'photo_url', t.photo_url, 'photos', to_jsonb(t.photos),
    'has_id_doc', t.id_doc_path <> '', 'has_cert_doc', t.cert_doc_path <> '',
    'has_nbi_doc', t.nbi_doc_path <> '', 'has_selfie_doc', t.selfie_doc_path <> '',
    'has_loi_doc', t.loi_doc_path <> '', 'has_barangay_doc', t.barangay_doc_path <> '',
    'terms_accepted', t.terms_accepted_at is not null, 'docs_v2', true,
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

-- 4. Admin list includes the new documents (same signature as v1.00) -----
create or replace function public.mb_admin_therapists(p_status text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform mb_require_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id, 'display_name', t.display_name, 'gender', t.gender, 'area', t.area,
      'experience_years', t.experience_years, 'bio', t.bio, 'photo_url', t.photo_url, 'photos', to_jsonb(t.photos),
      'id_doc_path', t.id_doc_path, 'cert_doc_path', t.cert_doc_path,
      'nbi_doc_path', t.nbi_doc_path, 'selfie_doc_path', t.selfie_doc_path,
      'loi_doc_path', t.loi_doc_path, 'barangay_doc_path', t.barangay_doc_path,
      'terms_accepted_at', t.terms_accepted_at,
      'docs_complete', (t.id_doc_path <> '' and t.nbi_doc_path <> '' and t.selfie_doc_path <> ''
                        and t.loi_doc_path <> '' and t.terms_accepted_at is not null),
      'status', t.status, 'admin_note', t.admin_note,
      'rating_avg', t.rating_avg, 'rating_count', t.rating_count, 'created_at', t.created_at,
      'email', p.email, 'phone', p.phone, 'full_name', p.full_name,
      'services', (select count(*) from mb_services s where s.therapist_id = t.id and s.active),
      'has_schedule', exists (select 1 from mb_availability a where a.therapist_id = t.id),
      'completed', (select count(*) from mb_bookings b where b.therapist_id = t.id and b.status = 'completed'))
      order by case t.status when 'pending' then 0 when 'approved' then 1 else 2 end, t.created_at desc), '[]')
    from mb_therapists t join mb_profiles p on p.id = t.id
    where p_status is null or p_status = '' or t.status = p_status);
end $$;

-- 5. Approval needs complete documents (same signature as v1.00) ---------
create or replace function public.mb_admin_set_therapist_status(p_id uuid, p_status text, p_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare t mb_therapists; v_missing text[] := '{}';
begin
  perform mb_require_admin();
  if p_status not in ('pending','approved','suspended') then raise exception 'Unknown status.'; end if;
  select * into t from mb_therapists where id = p_id;
  if not found then raise exception 'Therapist not found.'; end if;
  if p_status = 'approved' then
    if t.id_doc_path = ''          then v_missing := v_missing || 'valid ID'::text; end if;
    if t.nbi_doc_path = ''         then v_missing := v_missing || 'NBI Clearance'::text; end if;
    if t.selfie_doc_path = ''      then v_missing := v_missing || 'selfie with ID'::text; end if;
    if t.loi_doc_path = ''         then v_missing := v_missing || 'signed Letter of Intent'::text; end if;
    if t.terms_accepted_at is null then v_missing := v_missing || 'Terms & Privacy acceptance'::text; end if;
    if array_length(v_missing, 1) > 0 then
      raise exception 'Cannot approve yet. Missing: %.', array_to_string(v_missing, ', ');
    end if;
  end if;
  update mb_therapists set status = p_status, admin_note = left(coalesce(p_note,''),300), updated_at = now() where id = p_id;
  perform mb_notify(p_id,
    case p_status when 'approved' then 'You are approved! 🎉' when 'suspended' then 'Account suspended' else 'Application update' end,
    case p_status when 'approved' then 'Customers can now find and book you. Make sure your services and schedule are set.'
                  else coalesce(nullif(p_note,''), 'Please check the app for details.') end,
    'therapist.html#home');
  return jsonb_build_object('ok', true);
end $$;

-- 6. Permissions ---------------------------------------------------------
revoke all on function public.mb_save_therapist_docs(text, text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.mb_save_therapist_docs(text, text, text, text, boolean) to authenticated;
revoke all on function public.mb_my_therapist() from public, anon;
grant execute on function public.mb_my_therapist() to authenticated;
revoke all on function public.mb_admin_therapists(text) from public, anon;
grant execute on function public.mb_admin_therapists(text) to authenticated;
revoke all on function public.mb_admin_set_therapist_status(uuid, text, text) from public, anon;
grant execute on function public.mb_admin_set_therapist_status(uuid, text, text) to authenticated;

-- 7. Check (should show ok = 1) --------------------------------------------
select case when
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'mb_therapists'
      and column_name in ('nbi_doc_path','selfie_doc_path','loi_doc_path','barangay_doc_path','terms_accepted_at')) = 5
    and exists (select 1 from pg_proc where proname = 'mb_save_therapist_docs')
  then 1 else 0 end as ok;

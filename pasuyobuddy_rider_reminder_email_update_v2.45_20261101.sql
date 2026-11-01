-- =====================================================================
-- PasuyoBuddy: one-click reminder emails to rider applicants (v2.45)
-- Run ONCE in Supabase > SQL Editor, after v2.44. Safe to run again.
--
--  * Admin > Riders > applicant card gets buttons that SEND the email right away:
--      - "Send reminder: finish documents"  (the email lists exactly what is still missing)
--      - "Send: owner papers needed"        (only when the vehicle is not in the rider's name)
--  * The same message also appears inside the Rider app.
--  * To avoid spamming, the same reminder can only be sent once every 12 hours per rider.
--  * Admin shows when each reminder was last sent.
-- (Approved / rejected / suspended / document rejected emails are already sent automatically.)
-- No existing data is changed.
-- =====================================================================
set lock_timeout = '15s';

create table if not exists public.rider_reminders (
  id         bigserial primary key,
  rider_id   uuid not null references public.riders(profile_id) on delete cascade,
  kind       text not null,
  sent_by    uuid,
  created_at timestamptz not null default now()
);
create index if not exists rider_reminders_rider on public.rider_reminders (rider_id, kind, created_at desc);
alter table public.rider_reminders enable row level security;

create or replace function public.pb_doc_name(p text)
returns text language sql immutable as $$
  select case p when 'drivers_license' then 'Driver''s license' when 'or_cr' then 'OR/CR of the vehicle'
    when 'nbi_clearance' then 'NBI clearance' when 'selfie' then 'Selfie holding your driver''s license'
    when 'letter_of_intent' then 'Signed Letter of Intent'
    when 'owner_authorization' then 'Owner''s signed authorization letter (or Deed of Sale)'
    when 'owner_id' then 'Owner''s valid ID (NOT expired)'
    else replace(p, '_', ' ') end
$$;

create or replace function public.admin_rider_email(p_rider uuid, p_kind text)
returns text language plpgsql security definer set search_path = public as $$
declare r public.riders; pr public.profiles; v_first text; v_missing text; v_body text; v_subj text; v_title text;
        v_last timestamptz; v_lb text := chr(10); v_note text;
begin
  perform public.require_staff('riders');
  select * into r from public.riders where profile_id = p_rider;
  if not found then raise exception 'Rider not found'; end if;
  select * into pr from public.profiles where id = p_rider;
  if coalesce(pr.email, '') = '' or pr.email like '%@deleted.invalid' then raise exception 'This rider has no email address'; end if;
  if r.status::text not in ('pending') then raise exception 'Reminders are only for riders who are still applying'; end if;

  select max(created_at) into v_last from public.rider_reminders where rider_id = p_rider and kind = p_kind;
  if v_last > now() - interval '12 hours' then
    raise exception 'This reminder was already sent % ago. You can send it again after 12 hours.',
      case when now() - v_last < interval '1 hour' then extract(minute from now() - v_last)::int || ' min'
           else extract(hour from now() - v_last)::int || ' hours' end;
  end if;
  v_first := coalesce(nullif(split_part(trim(pr.full_name), ' ', 1), ''), 'there');

  if p_kind = 'remind_docs' then
    -- documents not uploaded yet, or rejected (pending ones are waiting for us, not the rider)
    select string_agg('  • ' || public.pb_doc_name(t), v_lb) into v_missing
      from unnest(public.rider_needed_docs(p_rider)) t
     where not exists (select 1 from public.rider_documents d where d.rider_id = p_rider and d.doc_type::text = t
                         and d.review_status::text in ('pending', 'approved'));
    if r.vehicle_owner_self is null then
      v_missing := coalesce(v_missing || v_lb, '') || '  • Answer the question "Is this vehicle registered (OR/CR) in your name?"';
    end if;
    if v_missing is null then raise exception 'Nothing is missing: this rider uploaded everything. Please check the documents.'; end if;
    v_note := 'Please open Documents and complete: ' || replace(replace(v_missing, '  • ', ''), v_lb, ', ') || '. Salamat!';
    v_subj := 'Your PasuyoBuddy rider application is almost done';
    v_title := 'Almost there, ' || v_first || '!';
    v_body := 'Hi ' || v_first || ',' || v_lb || v_lb || 'Salamat for signing up as a PasuyoBuddy rider!' || v_lb || v_lb
      || 'Your application is almost done. Please open the PasuyoBuddy Rider app, go to Documents, and complete these:' || v_lb || v_lb
      || v_missing || v_lb || v_lb
      || 'Once complete, we will check them within 1-2 days. Tip: take clear photos where all 4 corners are visible and the text is readable.' || v_lb || v_lb
      || 'Ingat po,' || v_lb || 'PasuyoBuddy Team';
  elsif p_kind = 'owner_papers' then
    if r.vehicle_owner_self is distinct from false then raise exception 'This rider said the vehicle is in his/her own name'; end if;
    v_note := 'The OR/CR is not in your name. Please upload in Documents: the owner''s signed authorization letter and the owner''s valid ID (NOT expired). Form: pasuyobuddy.github.io/owner-authorization.html';
    v_subj := 'PasuyoBuddy: papers needed from the vehicle owner';
    v_title := 'Papers from the vehicle owner';
    v_body := 'Hi ' || v_first || ',' || v_lb || v_lb
      || 'The OR/CR is not in your name' || coalesce(' (owner: ' || r.vehicle_owner_name || ')', '') || '. No problem, you can still join!' || v_lb || v_lb
      || 'Please upload these in the Rider app under Documents:' || v_lb
      || '  1. The owner''s signed authorization letter. Download the form: https://pasuyobuddy.github.io/owner-authorization.html' || v_lb
      || '  2. The owner''s valid ID (NOT expired, name must match the OR/CR).' || v_lb || v_lb
      || 'Salamat po,' || v_lb || 'PasuyoBuddy Team';
  else
    raise exception 'Unknown reminder %', p_kind;
  end if;

  perform public.pb_queue_email(p_rider, v_subj, v_title, v_body, 'Open the Rider app', 'https://pasuyobuddy.github.io/rider.html', 'admin_' || p_kind);
  insert into public.rider_notices (rider_id, kind, title, body)
  values (p_rider, 'reminder', v_title, v_note);
  insert into public.rider_reminders (rider_id, kind, sent_by) values (p_rider, p_kind, auth.uid());
  return 'Email sent to ' || pr.email;
end $$;
revoke execute on function public.admin_rider_email(uuid, text) from public, anon;
grant execute on function public.admin_rider_email(uuid, text) to authenticated;

-- When each reminder was last sent: { "<rider id>": { "remind_docs": "...", "owner_papers": "..." } }
create or replace function public.admin_rider_reminders()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.staff_can('riders') then raise exception 'Your account cannot use this section (riders).'; end if;
  return (select coalesce(json_object_agg(rider_id, k), '{}'::json) from (
            select rider_id, json_object_agg(kind, last) as k from (
              select rider_id, kind, max(created_at) as last from public.rider_reminders group by 1, 2) a group by 1) b);
end $$;
grant execute on function public.admin_rider_reminders() to authenticated;

-- Check: should show ok = 1
select (exists (select 1 from pg_proc where proname = 'admin_rider_email')
        and public.pb_doc_name('or_cr') = 'OR/CR of the vehicle')::int as ok;

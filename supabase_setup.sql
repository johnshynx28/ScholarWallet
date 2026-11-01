-- Complete atomic setup: base + registration verification.
-- Use THIS file for fresh or existing projects; do not run the base alone.
begin;
-- ============================================================================
-- Scholar Wallet — Supabase schema (v2)
--
-- v2 changes:
--   • REMOVED the withdrawal / cash-out (GCash) flow entirely.
--   • Allowance is ONE fixed amount for every scholar (`allowance_settings`).
--   • The admin issues a single-use QR per scholar per payout
--     (`allowance_claims`). The scholar scans it -> status becomes 'received'
--     and only then is the balance credited.
--   • Fingerprint registration is tracked on the profile.
--
-- Run this base schema, THEN supabase_registration_verification.sql.
-- The legacy base creates a PUBLIC storage
-- bucket named `receipts` (the insert at the bottom does it for you).
-- ============================================================================

create extension if not exists pgcrypto;

-- Profiles: one row per Firebase Auth user (id = Firebase UID)
create table if not exists profiles (
  id text primary key,
  full_name text not null,
  email text,
  role text not null default 'scholar',        -- 'scholar' | 'admin'
  balance numeric not null default 0,
  student_number text,
  university text,
  program text,
  year_level text,
  is_active boolean not null default true,     -- deactivated scholars get no payout
  fcm_token text,
  biometric_registered boolean not null default false,
  biometric_enrolled_at timestamptz,
  last_allowance_received_at timestamptz,
  created_at timestamptz not null default now()
);

-- Additive migration for projects created with schema v1
alter table profiles add column if not exists biometric_registered boolean not null default false;
alter table profiles add column if not exists biometric_enrolled_at timestamptz;
alter table profiles add column if not exists last_allowance_received_at timestamptz;

-- ---------------------------------------------------------------------------
-- ONE global allowance. Row id = 1 always. There is deliberately NO per-user
-- amount column anywhere: every scholar is paid the same amount.
-- ---------------------------------------------------------------------------
create table if not exists allowance_settings (
  id int primary key default 1,
  allowance_amount numeric not null default 5000,
  label text not null default 'Monthly Allowance',
  updated_at timestamptz not null default now(),
  constraint allowance_settings_single_row check (id = 1)
);

insert into allowance_settings (id, allowance_amount, label)
values (1, 5000, 'Monthly Allowance')
on conflict (id) do nothing;

-- Wallet ledger
create table if not exists transactions (
  id bigint generated always as identity primary key,
  scholar_id text not null references profiles(id),
  title text not null,
  subtitle text,
  amount numeric not null,                      -- + credit / - debit
  type text not null,                           -- 'credit' | 'debit'
  status text not null default 'completed',     -- 'completed' | 'pending' | 'rejected'
  batch_id text,
  created_at timestamptz not null default now()
);

-- Payout batches created by the admin
create table if not exists disbursements (
  id text primary key,
  title text not null,
  amount_per_scholar numeric not null,
  recipient_count int not null,
  status text not null default 'issued',        -- 'issued' | 'completed'
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- One QR claim per scholar per payout.
--   issued   -> money is RESERVED for the scholar, QR printed/given to them
--   received -> scholar scanned the QR, balance credited (single use)
--   voided   -> admin cancelled the payout before it was scanned
-- ---------------------------------------------------------------------------
create table if not exists allowance_claims (
  id bigint generated always as identity primary key,
  batch_id text not null,
  batch_title text not null default 'Allowance',
  scholar_id text not null references profiles(id),
  amount numeric not null,
  token text not null unique,
  status text not null default 'issued',
  issued_at timestamptz not null default now(),
  claimed_at timestamptz
);

create index if not exists allowance_claims_scholar_idx
  on allowance_claims (scholar_id, status);

-- Expense reports / liquidation
create table if not exists expenses (
  id bigint generated always as identity primary key,
  scholar_id text not null references profiles(id),
  title text not null,
  amount numeric not null,
  category text,
  description text,
  receipt_url text,
  status text not null default 'pending',
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Single-use redemption. All validation happens HERE so the balance can never
-- be credited twice, even if two devices scan at the same moment.
-- ---------------------------------------------------------------------------
create or replace function claim_allowance(p_token text, p_scholar_id text)
returns numeric
language plpgsql
as $$
declare
  v_claim allowance_claims;
begin
  select * into v_claim
    from allowance_claims
   where token = p_token
     for update;

  if not found then
    raise exception 'CLAIM_NOT_FOUND';
  end if;
  if v_claim.status = 'received' then
    raise exception 'CLAIM_ALREADY_RECEIVED';
  end if;
  if v_claim.status = 'voided' then
    raise exception 'CLAIM_VOIDED';
  end if;
  if v_claim.scholar_id <> p_scholar_id then
    raise exception 'CLAIM_WRONG_SCHOLAR';
  end if;

  update allowance_claims
     set status = 'received',
         claimed_at = now()
   where id = v_claim.id;

  update profiles
     set balance = coalesce(balance, 0) + v_claim.amount,
         last_allowance_received_at = now()
   where id = p_scholar_id;

  insert into transactions (scholar_id, title, subtitle, amount, type, status, batch_id)
  values (p_scholar_id,
          coalesce(v_claim.batch_title, 'Allowance'),
          'Received via QR',
          v_claim.amount,
          'credit',
          'completed',
          v_claim.batch_id);

  return v_claim.amount;
end;
$$;

-- Atomic balance adjustment (kept for manual corrections)
create or replace function adjust_balance(p_scholar_id text, p_delta numeric)
returns void language sql as $$
  update profiles
     set balance = coalesce(balance, 0) + p_delta
   where id = p_scholar_id;
$$;

-- Public receipts bucket for expense uploads
insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', true)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Apply supabase_registration_verification.sql immediately after this file.
-- It enables RLS, installs authenticated RPCs and revokes legacy adjust_balance.
-- This base schema alone is NOT a complete or secure application deployment.
-- ---------------------------------------------------------------------------

-- Legacy tables from v1 (the withdrawal flow). They are no longer used by the
-- app; drop them if you want a clean database:
--   drop table if exists withdrawals;

-- To make an account an ADMIN, create the user in the app, then run:
--   update profiles set role = 'admin' where email = 'admin@school.edu';

-- Scholar Wallet: registration-first verification and authenticated payouts.
-- Run AFTER supabase_schema.sql. Supabase must trust this Firebase project
-- through its Third-Party Auth / Firebase integration. See SETUP_VERIFICATION.txt.
-- Existing scholars are deliberately pending until the admin re-verifies them.
-- Balances, transactions, receipts and old application records are NOT deleted.


alter table public.profiles add column if not exists declared_scholar boolean not null default false;
alter table public.profiles add column if not exists scholarship_name text not null default '';
alter table public.profiles add column if not exists scholarship_reference text not null default '';
alter table public.profiles add column if not exists verification_status text not null default 'pending'
  check (verification_status in ('pending','under_review','needs_info','approved','rejected'));
alter table public.profiles add column if not exists review_notes text not null default '';
alter table public.profiles add column if not exists reviewed_by text;
alter table public.profiles add column if not exists reviewed_at timestamptz;
alter table public.profiles alter column is_active set default false;
update public.profiles set is_active = false
  where role = 'scholar' and verification_status <> 'approved';
create index if not exists profiles_verification_idx on public.profiles(role, verification_status);

create table if not exists public.registration_reviews (
  id bigint generated always as identity primary key,
  scholar_id text not null references public.profiles(id),
  reviewer_id text references public.profiles(id),
  from_status text not null,
  decision text not null,
  notes text not null default '',
  created_at timestamptz not null default now()
);

-- Firebase subjects are text, not UUID. Never use auth.uid() for these IDs.
create or replace function public.wallet_uid() returns text
language sql stable set search_path = '' as $$
  select nullif(auth.jwt()->>'sub', '')
$$;
create or replace function public.wallet_is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.profiles
    where id = public.wallet_uid() and role = 'admin')
$$;
create or replace function public.wallet_is_verified() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.profiles where id = public.wallet_uid()
    and role = 'scholar' and verification_status = 'approved' and is_active)
$$;

-- Serialized decisions + optimistic status check prevent stale admin forms.
create or replace function public.review_registration(
  p_scholar_id text, p_expected_status text, p_decision text, p_notes text,
  p_roster_checked boolean default false
) returns void language plpgsql security definer set search_path = '' as $$
declare v public.profiles;
begin
  if not public.wallet_is_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  select * into v from public.profiles where id = p_scholar_id and role = 'scholar' for update;
  if not found then raise exception 'REGISTRATION_NOT_FOUND'; end if;
  if v.verification_status <> p_expected_status then raise exception 'STALE_REVIEW'; end if;
  if v.verification_status in ('approved','rejected') then raise exception 'REGISTRATION_ALREADY_DECIDED'; end if;
  if p_decision is null or p_decision not in ('under_review','needs_info','approved','rejected') then
    raise exception 'INVALID_DECISION';
  end if;
  if p_decision = v.verification_status then raise exception 'NO_STATUS_CHANGE'; end if;
  if p_decision in ('needs_info','rejected') and length(trim(coalesce(p_notes,''))) = 0 then
    raise exception 'REASON_REQUIRED';
  end if;
  if p_decision = 'approved' and (not coalesce(p_roster_checked,false) or
      not v.declared_scholar or length(trim(v.scholarship_name)) = 0) then
    raise exception 'VERIFY_OFFICIAL_ROSTER_FIRST';
  end if;
  update public.profiles set verification_status = p_decision,
    is_active = (p_decision = 'approved'), review_notes = trim(coalesce(p_notes,'')),
    reviewed_by = public.wallet_uid(), reviewed_at = now() where id = v.id;
  insert into public.registration_reviews(scholar_id,reviewer_id,from_status,decision,notes)
    values(v.id, public.wallet_uid(), v.verification_status,p_decision,trim(coalesce(p_notes,'')));
end;
$$;

create or replace function public.resubmit_registration(
  p_declared_scholar boolean, p_scholarship_name text, p_scholarship_reference text
) returns void language plpgsql security definer set search_path = '' as $$
declare v public.profiles;
begin
  select * into v from public.profiles where id = public.wallet_uid() and role = 'scholar' for update;
  if not found or v.verification_status <> 'needs_info' then raise exception 'INFORMATION_NOT_REQUESTED'; end if;
  if p_declared_scholar is null then raise exception 'DECLARATION_REQUIRED'; end if;
  if p_declared_scholar and length(trim(coalesce(p_scholarship_name,''))) = 0 then
    raise exception 'SCHOLARSHIP_NAME_REQUIRED';
  end if;
  update public.profiles set declared_scholar = p_declared_scholar,
    scholarship_name = case when p_declared_scholar then trim(p_scholarship_name) else '' end,
    scholarship_reference = case when p_declared_scholar then trim(coalesce(p_scholarship_reference,'')) else '' end,
    verification_status = 'pending', is_active = false
    where id = v.id;
  insert into public.registration_reviews(scholar_id,from_status,decision,notes)
    values(v.id,'needs_info','pending','Student updated requested verification details.');
end;
$$;

create or replace function public.set_verified_scholar_active(p_scholar_id text, p_active boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare v public.profiles;
begin
  if not public.wallet_is_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  select * into v from public.profiles where id = p_scholar_id and role = 'scholar' for update;
  if not found or v.verification_status <> 'approved' then raise exception 'SCHOLAR_NOT_VERIFIED'; end if;
  update public.profiles set is_active = p_active where id = v.id;
  insert into public.registration_reviews(scholar_id,reviewer_id,from_status,decision,notes)
    values(v.id,public.wallet_uid(),'approved','approved',
      case when p_active then 'Payout access activated.' else 'Payout access deactivated.' end);
end;
$$;

-- One transaction: invalid recipient or insert failure rolls back the batch.
create or replace function public.issue_verified_payout(p_title text, p_recipients text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_batch text := gen_random_uuid()::text; v_amount numeric; v_title text;
  v_ids text[]; v_id text; v_profile public.profiles; v_result jsonb;
begin
  if not public.wallet_is_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  select array_agg(distinct x order by x) into v_ids from unnest(p_recipients) x;
  if coalesce(array_length(v_ids,1),0) = 0 then raise exception 'RECIPIENTS_REQUIRED'; end if;
  select allowance_amount, coalesce(nullif(trim(p_title),''),label)
    into v_amount,v_title from public.allowance_settings where id = 1 for share;
  if v_amount is null or v_amount <= 0 then raise exception 'INVALID_ALLOWANCE'; end if;
  foreach v_id in array v_ids loop
    select * into v_profile from public.profiles where id = v_id for update;
    if not found or v_profile.role <> 'scholar' or
      v_profile.verification_status <> 'approved' or not v_profile.is_active then
      raise exception 'SCHOLAR_NOT_VERIFIED';
    end if;
  end loop;
  insert into public.disbursements(id,title,amount_per_scholar,recipient_count,status)
    values(v_batch,v_title,v_amount,array_length(v_ids,1),'issued');
  insert into public.allowance_claims(batch_id,batch_title,scholar_id,amount,token,status)
    select v_batch,v_title,x,v_amount,replace(gen_random_uuid()::text,'-',''),'issued'
      from unnest(v_ids) x;
  select jsonb_agg(to_jsonb(c) || jsonb_build_object('scholar_name', p.full_name))
    into v_result from public.allowance_claims c join public.profiles p on p.id = c.scholar_id
    where c.batch_id = v_batch;
  return v_result;
end;
$$;

-- Authoritative authenticated single-use receipt. Device biometrics protect the
-- UI; this RPC does NOT claim to attest a fingerprint on a remote server.
create or replace function public.claim_allowance(p_token text, p_scholar_id text)
returns numeric language plpgsql security definer set search_path = '' as $$
declare v_claim public.allowance_claims; v_profile public.profiles;
begin
  if public.wallet_uid() is null or p_scholar_id is distinct from public.wallet_uid() then
    raise exception 'CLAIM_WRONG_SCHOLAR';
  end if;
  select * into v_profile from public.profiles where id = public.wallet_uid() for update;
  if not found or v_profile.role <> 'scholar' or
      v_profile.verification_status <> 'approved' or not v_profile.is_active then
    raise exception 'SCHOLAR_NOT_VERIFIED';
  end if;
  select * into v_claim from public.allowance_claims where token = p_token for update;
  if not found then raise exception 'CLAIM_NOT_FOUND'; end if;
  if v_claim.scholar_id <> public.wallet_uid() then raise exception 'CLAIM_WRONG_SCHOLAR'; end if;
  if v_claim.status = 'received' then raise exception 'CLAIM_ALREADY_RECEIVED'; end if;
  if v_claim.status <> 'issued' then raise exception 'CLAIM_VOIDED'; end if;
  if v_claim.amount <= 0 then raise exception 'INVALID_ALLOWANCE'; end if;
  update public.allowance_claims set status = 'received', claimed_at = now() where id = v_claim.id;
  update public.profiles set balance = balance + v_claim.amount,
    last_allowance_received_at = now() where id = public.wallet_uid();
  insert into public.transactions(scholar_id,title,subtitle,amount,type,status,batch_id)
    values(public.wallet_uid(),v_claim.batch_title,'Allowance receipt confirmed',v_claim.amount,'credit','completed',v_claim.batch_id);
  -- Do not call a batch completed while any issued claims remain.
  update public.disbursements d set status = 'completed' where d.id = v_claim.batch_id
    and not exists(select 1 from public.allowance_claims c where c.batch_id = d.id and c.status = 'issued');
  return v_claim.amount;
end;
$$;

-- Remove legacy permissive policies for these application tables.
do $$ declare t text; p record; begin
  foreach t in array array['profiles','registration_reviews','transactions','expenses',
    'disbursements','allowance_claims','allowance_settings'] loop
    execute format('alter table public.%I enable row level security',t);
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I',p.policyname,t);
    end loop;
    execute format('revoke all on public.%I from anon, authenticated',t);
  end loop;
end $$;

-- When the older application flow was installed, archive access, not data.
do $$ declare t text; begin
  foreach t in array array['scholarship_programs','scholarship_applications','application_documents','application_reviews'] loop
    if to_regclass('public.' || t) is not null then
      execute format('alter table public.%I enable row level security',t);
      execute format('revoke all on public.%I from anon, authenticated',t);
    end if;
  end loop;
end $$;
-- Disable obsolete SECURITY DEFINER entry points as well.
do $$ declare f record; begin
  for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('submit_application','record_application_review','adjust_balance') loop
    execute format('revoke all on function %s from public, anon, authenticated',f.signature);
  end loop;
end $$;

-- Profile creation is self-only, never an approval or admin role assignment.
grant select, insert on public.profiles to authenticated;
grant update (fcm_token,biometric_registered,biometric_enrolled_at) on public.profiles to authenticated;
create policy profiles_read on public.profiles for select to authenticated
  using (id = public.wallet_uid() or public.wallet_is_admin());
create policy profiles_register on public.profiles for insert to authenticated with check (
  id = public.wallet_uid() and email = auth.jwt()->>'email' and role = 'scholar'
  and balance = 0 and verification_status = 'pending' and not is_active
  and reviewed_by is null and reviewed_at is null and review_notes = ''
  and (not declared_scholar or length(trim(scholarship_name)) > 0)
);
create policy profiles_device_update on public.profiles for update to authenticated
  using (id = public.wallet_uid()) with check (id = public.wallet_uid());

grant select on public.registration_reviews to authenticated;
create policy reviews_read on public.registration_reviews for select to authenticated
  using (scholar_id = public.wallet_uid() or public.wallet_is_admin());
grant select on public.transactions to authenticated;
create policy transactions_read on public.transactions for select to authenticated
  using (scholar_id = public.wallet_uid() or public.wallet_is_admin());
grant select, insert on public.expenses to authenticated;
grant update (status) on public.expenses to authenticated;
grant usage, select on sequence public.expenses_id_seq to authenticated;
create policy expenses_read on public.expenses for select to authenticated
  using (scholar_id = public.wallet_uid() or public.wallet_is_admin());
create policy expenses_insert on public.expenses for insert to authenticated with check (
  scholar_id = public.wallet_uid() and public.wallet_is_verified() and status = 'pending' and amount > 0);
create policy expenses_review on public.expenses for update to authenticated
  using (public.wallet_is_admin()) with check (public.wallet_is_admin() and status in ('approved','rejected','completed'));
grant select on public.disbursements to authenticated;
create policy batches_read on public.disbursements for select to authenticated
  using (public.wallet_is_admin() or exists(select 1 from public.allowance_claims c
    where c.batch_id = disbursements.id and c.scholar_id = public.wallet_uid()));
grant select on public.allowance_claims to authenticated;
grant update (status) on public.allowance_claims to authenticated;
create policy claims_read on public.allowance_claims for select to authenticated
  using (scholar_id = public.wallet_uid() or public.wallet_is_admin());
create policy claims_void on public.allowance_claims for update to authenticated
  using (public.wallet_is_admin() and status = 'issued')
  with check (public.wallet_is_admin() and status = 'voided');
grant select, insert, update on public.allowance_settings to authenticated;
create policy settings_read on public.allowance_settings for select to authenticated using (true);
create policy settings_insert on public.allowance_settings for insert to authenticated
  with check (public.wallet_is_admin() and id = 1 and allowance_amount > 0);
create policy settings_update on public.allowance_settings for update to authenticated
  using (public.wallet_is_admin()) with check (public.wallet_is_admin() and id = 1 and allowance_amount > 0);

-- Functions are not callable by anonymous sessions or PUBLIC.
do $$ declare f record; begin
  for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('wallet_uid','wallet_is_admin','wallet_is_verified',
      'review_registration','resubmit_registration','set_verified_scholar_active','issue_verified_payout','claim_allowance') loop
    execute format('revoke all on function %s from public, anon',f.signature);
    execute format('grant execute on function %s to authenticated',f.signature);
  end loop;
end $$;

-- Receipts: only a verified scholar can upload under their own UID folder.
drop policy if exists wallet_receipts_upload on storage.objects;
create policy wallet_receipts_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = public.wallet_uid()
    and public.wallet_is_verified());
-- NOTE: the original receipts bucket is public. Existing unrelated storage
-- policies are not deleted here; review receipt privacy before deployment.


commit;

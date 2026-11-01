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

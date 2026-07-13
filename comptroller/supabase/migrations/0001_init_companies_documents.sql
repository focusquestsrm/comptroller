-- ============================================================================
-- Comptroller Intelligence Agent — Phase 1 schema
-- Migration 0001: companies + documents + auth-gated access
-- Target: Supabase (Postgres 15+)
--
-- Decision (2026-07-13): Auth is pulled forward so owner/member-scoped RLS is
-- live from day one — there is NO permissive anon window. The app authenticates
-- users with Supabase Auth (email magic-link) before any data is read/written.
--
-- Access model: this is a SHARED workspace. Danielle and Sean are both admins
-- and must see the SAME portfolio, so access is MEMBERSHIP-based (an allowlist),
-- not per-row ownership. Per-partner / per-division scoping arrives in phase 5.
--
-- Design rules carried over from CLAUDE.md:
--   * Store ONLY the raw figures the user types. Every derived metric
--     (profit, workingCapital, health, riskScore, risk, trend, confidence)
--     stays computed in the client so the formulas remain transparent and
--     live in exactly one place.
--   * RLS is enabled on every table before any data can enter.
--   * Actual uploaded files are NOT stored here. That is Phase 2 (a private
--     Storage bucket + short-lived signed URLs). Only document metadata and
--     the original filenames live in this schema.
--   * The audit log is created now, not retrofitted (security requirement).
--
-- No API keys live in this file or in client code. The browser uses only the
-- public anon (publishable) key, safe to embed because RLS + Auth gate every
-- table. The service_role key and any Gemini key never touch the client.
-- ============================================================================

create extension if not exists pgcrypto;  -- gen_random_uuid() (preinstalled on Supabase)

-- ---------------------------------------------------------------------------
-- updated_at helper — bumps the column on every UPDATE
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- app_members — the allowlist. Only people listed here can use the app.
--   Keyed by email so you can authorize someone BEFORE their first login
--   (their auth.users row does not exist until they sign in once).
--   Managed from the Supabase dashboard / service_role only — RLS is on with
--   no anon/authenticated policy, so the client can never read or edit it.
-- ---------------------------------------------------------------------------
create table public.app_members (
  email      text primary key,
  role       text not null default 'admin' check (role in ('admin','read_only')),
  created_at timestamptz not null default now()
);

alter table public.app_members enable row level security;
-- (intentionally no policies for anon/authenticated — dashboard-managed only)

-- Seed the known admins (Danielle + Sean).
insert into public.app_members (email, role) values
  ('danniejenn@gmail.com', 'admin'),
  ('sean@back2learn.com',  'admin')
on conflict (email) do nothing;

-- is_member() / is_admin() — checked by every table policy below.
-- SECURITY DEFINER so it can read app_members past that table's RLS; search_path
-- pinned to public to keep it injection-safe. Matches the standard Supabase
-- "allowlist without recursive RLS" pattern.
create or replace function public.is_member()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.app_members m
    where lower(m.email) = lower(auth.jwt() ->> 'email')
  );
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.app_members m
    where lower(m.email) = lower(auth.jwt() ->> 'email')
      and m.role = 'admin'
  );
$$;

-- ---------------------------------------------------------------------------
-- companies
--   One row per company. Columns mirror the 8 inputs in the Add/Edit Company
--   dialog exactly. No derived column is stored.
--   user_id is provenance only ("who created this") — access is decided by
--   membership, not by this column. It feeds the audit trail and the phase-5
--   division scoping later.
-- ---------------------------------------------------------------------------
create table public.companies (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references auth.users(id) on delete set null default auth.uid(),

  name         text          not null check (length(trim(name)) > 0),
  cash         numeric(14,2) not null default 0 check (cash        >= 0),
  debt         numeric(14,2) not null default 0 check (debt        >= 0),
  revenue      numeric(14,2) not null default 0 check (revenue     >= 0),
  expenses     numeric(14,2) not null default 0 check (expenses    >= 0),
  obligations  numeric(14,2) not null default 0 check (obligations >= 0),
  projected    numeric(14,2) not null default 0 check (projected   >= 0),
  credit       numeric(5,2)  not null default 0 check (credit between 0 and 100),

  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create trigger companies_set_updated_at
  before update on public.companies
  for each row execute function public.set_updated_at();

create index companies_user_id_idx on public.companies (user_id);

-- ---------------------------------------------------------------------------
-- documents
--   Metadata for each uploaded statement/record, one row per upload.
--   * company_id has ON DELETE CASCADE, which replaces the client's manual
--     "remove this company's documents" cleanup.
--   * file_names holds the original filenames the user selected. The files
--     themselves are NOT stored yet (Phase 2).
--   * The company name is intentionally NOT duplicated here — the client
--     already has every company loaded and resolves the name by company_id,
--     so there is no denormalized copy to keep in sync on rename.
--   * created_at replaces the old display-only "added" string and gives us a
--     real date to build statement history on later (roadmap phase 6).
-- ---------------------------------------------------------------------------
create table public.documents (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  user_id      uuid references auth.users(id) on delete set null default auth.uid(),

  type         text not null check (type in (
                 'Credit card statements',
                 'Bank statements',
                 'Car loans',
                 'Office expenses',
                 'Mortgage or rent',
                 'Insurance',
                 'Invoices',
                 'Payroll',
                 'Tax documents'
               )),
  name         text          not null check (length(trim(name)) > 0),
  amount       numeric(14,2) not null default 0 check (amount >= 0),
  note         text          not null default '',
  file_names   text[]        not null default '{}',

  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create trigger documents_set_updated_at
  before update on public.documents
  for each row execute function public.set_updated_at();

create index documents_company_id_idx on public.documents (company_id);
create index documents_user_id_idx    on public.documents (user_id);

-- ---------------------------------------------------------------------------
-- audit_log
--   Who did what, when. Built now so we never have to backfill history.
-- ---------------------------------------------------------------------------
create table public.audit_log (
  id          bigint generated always as identity primary key,
  actor       text,                          -- JWT email, for readability
  user_id     uuid references auth.users(id) on delete set null default auth.uid(),
  action      text not null check (action in ('insert','update','delete','view')),
  entity      text not null,                 -- 'company' | 'document'
  entity_id   text,
  detail      jsonb not null default '{}',
  created_at  timestamptz not null default now()
);

create index audit_log_created_at_idx on public.audit_log (created_at desc);

-- ---------------------------------------------------------------------------
-- Row-level security — ON for every table, gated by Auth + membership
-- ---------------------------------------------------------------------------
alter table public.companies enable row level security;
alter table public.documents enable row level security;
alter table public.audit_log enable row level security;

-- Base privileges. Note: anon gets NOTHING on these tables. The anon key is
-- used only to reach the Auth endpoints (magic-link); once signed in the user
-- acts as `authenticated`, and the policies below still decide every row.
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.companies to authenticated;
grant select, insert, update, delete on public.documents to authenticated;
grant select, insert on public.audit_log to authenticated;

-- companies: any member reads/writes the shared portfolio.
create policy companies_member_all on public.companies
  for all to authenticated
  using (public.is_member())
  with check (public.is_member());

-- documents: same shared-member access.
create policy documents_member_all on public.documents
  for all to authenticated
  using (public.is_member())
  with check (public.is_member());

-- audit_log: members may append; only admins may read the trail back.
create policy audit_member_insert on public.audit_log
  for insert to authenticated
  with check (public.is_member());

create policy audit_admin_read on public.audit_log
  for select to authenticated
  using (public.is_admin());

-- ===========================================================================
-- Phase 5 note: to scope partners to specific companies/divisions, add a
-- membership-to-company (or membership-to-division) join table and tighten the
-- companies_member_all / documents_member_all policies to check it. The read-
-- only role is already modeled in app_members.role for that step.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Rollback (manual):
--   drop table if exists public.audit_log;
--   drop table if exists public.documents;
--   drop table if exists public.companies;
--   drop table if exists public.app_members;
--   drop function if exists public.is_member();
--   drop function if exists public.is_admin();
--   drop function if exists public.set_updated_at();
-- ---------------------------------------------------------------------------

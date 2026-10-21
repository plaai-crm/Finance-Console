-- Finance Console / Wealth owner hardening — 2026-10-20
-- Run in Supabase SQL Editor only after backup + staging verification.
-- This migration is intentionally non-destructive: it does not delete business data.

begin;

create extension if not exists pgcrypto with schema extensions;

alter table public.app_users add column if not exists auth_user_id uuid unique;

-- Minimal identity helpers used by RLS. They return only authorization facts.
create or replace function public.fc_is_active_user()
returns boolean language sql stable security definer set search_path=public,auth as $function$
  select exists(select 1 from public.app_users u where u.auth_user_id=auth.uid() and coalesce(u.active,true));
$function$;
create or replace function public.fc_is_owner()
returns boolean language sql stable security definer set search_path=public,auth as $function$
  select exists(select 1 from public.app_users u where u.auth_user_id=auth.uid() and coalesce(u.active,true) and u.role='owner');
$function$;
create or replace function public.fc_user_scope()
returns text language sql stable security definer set search_path=public,auth as $function$
  select case when u.role='owner' then 'all' else coalesce(u.scope,'general') end
  from public.app_users u where u.auth_user_id=auth.uid() and coalesce(u.active,true) limit 1;
$function$;
create or replace function public.fc_can_access_category(p_category text)
returns boolean language sql stable security definer set search_path=public,auth as $function$
  select public.fc_is_active_user() and (
    public.fc_user_scope()='all' or
    (public.fc_user_scope()='hotel' and p_category='hotel') or
    (public.fc_user_scope()='general' and coalesce(p_category,'general')<>'hotel')
  );
$function$;

-- ---------------------------------------------------------------------------
-- 1) Align database columns with the web client.
-- ---------------------------------------------------------------------------
alter table public.transactions add column if not exists amount_unknown boolean not null default false;
alter table public.transactions add column if not exists reminder_notified_at date;
alter table public.transactions add column if not exists reminder_snooze_until date;
alter table public.recurring_items add column if not exists amount_unknown boolean not null default false;

alter table public.affiliate_loans add column if not exists borrower_type text default 'affiliate';
alter table public.affiliate_loans add column if not exists purpose text;
alter table public.affiliate_loans add column if not exists expected_outcome text;
alter table public.affiliate_loans add column if not exists secured text default 'unsecured';
alter table public.affiliate_loans add column if not exists collateral_desc text;
alter table public.affiliate_loans add column if not exists collateral_value numeric default 0;
alter table public.affiliate_loans add column if not exists term_months integer default 0;
alter table public.affiliate_loans add column if not exists installment numeric default 0;
alter table public.affiliate_loans add column if not exists borrower_history text;
alter table public.affiliate_loans add column if not exists status text default 'active';
alter table public.affiliate_loans add column if not exists storage_path text;
alter table public.documents       add column if not exists storage_path text;

create table if not exists public.loan_payments(
  id uuid primary key default gen_random_uuid(),
  loan_id uuid not null references public.affiliate_loans(id) on delete cascade,
  amount numeric not null default 0,
  pay_date date,
  note text,
  created_by text,
  created_at timestamptz not null default now()
);
create table if not exists public.loan_followups(
  id uuid primary key default gen_random_uuid(),
  loan_id uuid not null references public.affiliate_loans(id) on delete cascade,
  channel text,
  fu_date date,
  detail text,
  next_date date,
  created_by text,
  created_at timestamptz not null default now()
);
create index if not exists loan_payments_loan_id_idx on public.loan_payments(loan_id);
create index if not exists loan_followups_loan_id_idx on public.loan_followups(loan_id);

create table if not exists public.investments(
  id uuid primary key default gen_random_uuid(),
  asset_type text,
  asset_name text,
  units text,
  buy_date date,
  buy_price numeric default 0,
  fee numeric default 0,
  current_value numeric default 0,
  "current_date" date,
  note text,
  created_by text,
  created_at timestamptz not null default now()
);
alter table public.investments add column if not exists "current_date" date;
create table if not exists public.investment_values(
  id uuid primary key default gen_random_uuid(),
  investment_id uuid not null references public.investments(id) on delete cascade,
  year integer not null check(year between 1900 and 2200),
  value numeric not null check(value>=0),
  note text,
  created_by text,
  created_at timestamptz not null default now(),
  unique(investment_id,year)
);
create table if not exists public.guarantees(
  id uuid primary key default gen_random_uuid(),
  beneficiary text,
  guarantee_type text,
  asset_desc text,
  facility_amount numeric default 0,
  fee_type text,
  fee_rate numeric default 0,
  fee_amount numeric default 0,
  start_date date,
  end_date date,
  status text default 'active',
  note text,
  created_by text,
  created_at timestamptz not null default now()
);

create unique index if not exists transactions_recurring_month_uidx
  on public.transactions(recurring_id,(extract(year from txn_date)),(extract(month from txn_date)))
  where recurring_id is not null;

-- Legacy rows did not always record paid_date. Use the transaction date as a
-- conservative historical fallback; new UI writes the actual cash date.
update public.transactions
   set paid_date=txn_date
 where coalesce(is_paid,false)=true and paid_date is null;

do $migration$
declare t text;
begin
  foreach t in array array[
    'businesses','transactions','recurring_items','owner_transfers','owner_loans',
    'affiliate_loans','loan_payments','loan_followups','investments',
    'investment_values','guarantees','documents','monthly_expense_plan'
  ] loop
    if to_regclass('public.'||t) is not null then
      execute format('alter table public.%I add column if not exists created_by_user_id uuid',t);
      execute format('alter table public.%I add column if not exists updated_by_user_id uuid',t);
      execute format('alter table public.%I add column if not exists updated_at timestamptz',t);
    end if;
  end loop;
end
$migration$;

-- New writes must be sane; NOT VALID avoids blocking the migration on legacy rows.
do $constraints$
begin
  if not exists(select 1 from pg_constraint where conname='fc_transactions_amount_nonnegative') then
    alter table public.transactions add constraint fc_transactions_amount_nonnegative check(amount>=0 and coalesce(wht,0)>=0 and coalesce(wht,0)<=amount) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='fc_transactions_kind_valid') then
    alter table public.transactions add constraint fc_transactions_kind_valid check(kind in ('income','expense')) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='fc_transactions_paid_date_required') then
    alter table public.transactions add constraint fc_transactions_paid_date_required check(not coalesce(is_paid,false) or paid_date is not null) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='fc_recurring_amount_nonnegative') then
    alter table public.recurring_items add constraint fc_recurring_amount_nonnegative check(amount>=0 and coalesce(wht,0)>=0 and coalesce(wht,0)<=amount) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='fc_recurring_kind_day_valid') then
    alter table public.recurring_items add constraint fc_recurring_kind_day_valid check(kind in ('income','expense') and pay_day between 1 and 31) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='fc_owner_loans_amount_direction_valid') then
    alter table public.owner_loans add constraint fc_owner_loans_amount_direction_valid check(amount>0 and direction in ('borrow','repay')) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='fc_affiliate_loans_values_valid') then
    alter table public.affiliate_loans add constraint fc_affiliate_loans_values_valid
      check(coalesce(principal,0)>0 and coalesce(interest_rate,0)>=0 and coalesce(term_months,0)>=0 and coalesce(installment,0)>=0 and coalesce(collateral_value,0)>=0) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='fc_loan_payments_amount_positive') then
    alter table public.loan_payments add constraint fc_loan_payments_amount_positive check(amount>0) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='fc_investments_values_valid') then
    alter table public.investments add constraint fc_investments_values_valid
      check(coalesce(buy_price,0)>0 and coalesce(fee,0)>=0 and coalesce(current_value,0)>=0) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conname='fc_guarantees_values_valid') then
    alter table public.guarantees add constraint fc_guarantees_values_valid
      check(coalesce(facility_amount,0)>=0 and coalesce(fee_rate,0)>=0 and coalesce(fee_amount,0)>=0) not valid;
  end if;
end
$constraints$;

-- ---------------------------------------------------------------------------
-- 2) Server-trusted actor stamps and immutable audit trail.
-- created_by text remains for display compatibility, but is no longer the audit source.
-- ---------------------------------------------------------------------------
create or replace function public.fc_stamp_actor()
returns trigger
language plpgsql
security definer
set search_path=public,auth
as $function$
begin
  if tg_op='INSERT' then
    new.created_by_user_id:=auth.uid();
  end if;
  new.updated_by_user_id:=auth.uid();
  new.updated_at:=now();
  return new;
end
$function$;

create table if not exists public.finance_audit_log(
  id bigint generated always as identity primary key,
  table_name text not null,
  record_id text,
  action text not null check(action in ('INSERT','UPDATE','DELETE')),
  actor_user_id uuid,
  old_data jsonb,
  new_data jsonb,
  occurred_at timestamptz not null default now()
);
create index if not exists finance_audit_log_record_idx
  on public.finance_audit_log(table_name,record_id,occurred_at desc);
alter table public.finance_audit_log enable row level security;
revoke all on table public.finance_audit_log from public,anon,authenticated;
grant select on table public.finance_audit_log to authenticated;

drop policy if exists finance_audit_owner_select on public.finance_audit_log;
create policy finance_audit_owner_select on public.finance_audit_log
  for select to authenticated using(public.fc_is_owner());

create or replace function public.fc_write_audit_log()
returns trigger
language plpgsql
security definer
set search_path=public,auth
as $function$
declare old_j jsonb; new_j jsonb; row_id text;
begin
  old_j:=case when tg_op in ('UPDATE','DELETE') then to_jsonb(old)-array['file_data','password','password_hash'] else null end;
  new_j:=case when tg_op in ('INSERT','UPDATE') then to_jsonb(new)-array['file_data','password','password_hash'] else null end;
  row_id:=coalesce(new_j->>'id',old_j->>'id');
  insert into public.finance_audit_log(table_name,record_id,action,actor_user_id,old_data,new_data)
  values(tg_table_name,row_id,tg_op,auth.uid(),old_j,new_j);
  if tg_op='DELETE' then return old; end if;
  return new;
end
$function$;

do $triggers$
declare t text;
begin
  foreach t in array array[
    'businesses','transactions','recurring_items','owner_transfers','owner_loans',
    'affiliate_loans','loan_payments','loan_followups','investments',
    'investment_values','guarantees','documents','monthly_expense_plan'
  ] loop
    if to_regclass('public.'||t) is not null then
      execute format('drop trigger if exists trg_fc_stamp_actor on public.%I',t);
      execute format('create trigger trg_fc_stamp_actor before insert or update on public.%I for each row execute function public.fc_stamp_actor()',t);
      execute format('drop trigger if exists trg_fc_audit on public.%I',t);
      execute format('create trigger trg_fc_audit after insert or update or delete on public.%I for each row execute function public.fc_write_audit_log()',t);
    end if;
  end loop;
end
$triggers$;

-- ---------------------------------------------------------------------------
-- 3) Wealth data is owner-only at the database layer.
-- ---------------------------------------------------------------------------
create or replace function public.fc_can_lending()
returns boolean language sql stable security definer set search_path=public,auth as $function$
  select public.fc_is_owner();
$function$;

do $policies$
declare r record; t text;
begin
  foreach t in array array[
    'owner_loans','affiliate_loans','loan_payments','loan_followups','investments',
    'investment_values','guarantees','documents','monthly_expense_plan'
  ] loop
    if to_regclass('public.'||t) is not null then
      for r in select policyname from pg_policies where schemaname='public' and tablename=t loop
        execute format('drop policy if exists %I on public.%I',r.policyname,t);
      end loop;
      execute format('alter table public.%I enable row level security',t);
      execute format('create policy %I on public.%I for all to authenticated using(public.fc_is_owner()) with check(public.fc_is_owner())','fc_owner_only_'||t,t);
    end if;
  end loop;
end
$policies$;

-- Businesses may be disabled, not hard-deleted by the browser.
revoke delete on table public.businesses from authenticated;

-- Explicit browser grants (required by current Supabase Data API behavior).
do $grants$
declare t text;
begin
  foreach t in array array[
    'app_users','businesses','transactions','recurring_items','owner_transfers','owner_loans',
    'affiliate_loans','loan_payments','loan_followups','investments','investment_values',
    'guarantees','documents','monthly_expense_plan'
  ] loop
    if to_regclass('public.'||t) is not null then
      execute format('revoke all on table public.%I from anon',t);
      execute format('revoke all on table public.%I from authenticated',t);
      if t='app_users' then
        execute 'grant select (id,name,username,role,scope,active,created_at) on table public.app_users to authenticated';
      elsif t='businesses' then
        execute format('grant select,insert,update on table public.%I to authenticated',t);
      else
        execute format('grant select,insert,update,delete on table public.%I to authenticated',t);
      end if;
    end if;
  end loop;
end
$grants$;

-- ---------------------------------------------------------------------------
-- 4) Complete recurring-item edit synchronization.
-- ---------------------------------------------------------------------------
create or replace function public.fc_api_sync_recurring_item(p_recurring_id text)
returns integer
language plpgsql
security definer
set search_path=public,auth
as $function$
declare r public.recurring_items%rowtype; changed integer; allowed boolean;
begin
  if not public.fc_is_active_user() then raise exception 'unauthorized'; end if;
  select * into r from public.recurring_items where id=p_recurring_id;
  if not found then raise exception 'recurring item not found'; end if;
  select public.fc_can_access_category(b.category) into allowed
  from public.businesses b where b.id=r.business_id;
  if coalesce(allowed,false)=false then raise exception 'forbidden'; end if;

  update public.transactions t
     set kind=r.kind,
         business_id=r.business_id,
         category=r.category,
         amount=coalesce(r.amount,0),
         wht=case when r.kind='income' then coalesce(r.wht,0) else 0 end,
         txn_date=(date_trunc('month',t.txn_date)::date+
           (least(greatest(coalesce(r.pay_day,1),1),
             extract(day from (date_trunc('month',t.txn_date)+interval '1 month - 1 day'))::integer)-1)),
         note=coalesce(r.note,''),
         amount_unknown=(r.kind='expense' and coalesce(r.amount_unknown,false))
   where t.recurring_id=r.id
     and coalesce(t.is_paid,false)=false
     and t.txn_date>=date_trunc('month',(now() at time zone 'Asia/Bangkok')::date)::date;
  get diagnostics changed=row_count;
  return changed;
end
$function$;

revoke all on function public.fc_api_sync_recurring_item(text) from public,anon;
grant execute on function public.fc_api_sync_recurring_item(text) to authenticated;

-- No public/anonymous API RPCs. The Edge Function uses service_role separately.
do $api_functions$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname like 'fc_api_%'
  loop
    execute format('revoke all on function %s from public,anon',r.sig);
    execute format('grant execute on function %s to authenticated',r.sig);
  end loop;
end
$api_functions$;

-- Internal functions stay server-only, except small helpers used inside RLS policies.
do $functions$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig,p.proname
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname like 'fc_%'
       and p.proname not like 'fc_api_%'
       and p.proname not in ('fc_is_active_user','fc_is_owner','fc_user_scope','fc_can_access_category','fc_can_lending','fc_stamp_actor','fc_write_audit_log')
  loop
    execute format('revoke all on function %s from public,anon,authenticated',r.sig);
    execute format('grant execute on function %s to service_role',r.sig);
  end loop;
end
$functions$;

revoke all on function public.fc_is_active_user() from public,anon;
revoke all on function public.fc_is_owner() from public,anon;
revoke all on function public.fc_user_scope() from public,anon;
revoke all on function public.fc_can_access_category(text) from public,anon;
revoke all on function public.fc_can_lending() from public,anon;
grant execute on function public.fc_is_active_user() to authenticated;
grant execute on function public.fc_is_owner() to authenticated;
grant execute on function public.fc_user_scope() to authenticated;
grant execute on function public.fc_can_access_category(text) to authenticated;
grant execute on function public.fc_can_lending() to authenticated;

revoke all on function public.fc_stamp_actor() from public,anon,authenticated;
revoke all on function public.fc_write_audit_log() from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- 5) Private document storage, owner-only.
-- ---------------------------------------------------------------------------
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('finance-documents','finance-documents',false,4194304,array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict(id) do update set
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists fc_finance_documents_select on storage.objects;
drop policy if exists fc_finance_documents_insert on storage.objects;
drop policy if exists fc_finance_documents_update on storage.objects;
drop policy if exists fc_finance_documents_delete on storage.objects;
create policy fc_finance_documents_select on storage.objects for select to authenticated
  using(bucket_id='finance-documents' and public.fc_is_owner());
create policy fc_finance_documents_insert on storage.objects for insert to authenticated
  with check(bucket_id='finance-documents' and public.fc_is_owner());
create policy fc_finance_documents_update on storage.objects for update to authenticated
  using(bucket_id='finance-documents' and public.fc_is_owner())
  with check(bucket_id='finance-documents' and public.fc_is_owner());
create policy fc_finance_documents_delete on storage.objects for delete to authenticated
  using(bucket_id='finance-documents' and public.fc_is_owner());

commit;

-- Verification queries (read-only):
-- select tablename,policyname,roles,cmd from pg_policies
-- where schemaname='public' and tablename in
-- ('owner_loans','affiliate_loans','loan_payments','loan_followups','investments','investment_values','guarantees','documents','monthly_expense_plan')
-- order by tablename,policyname;
-- select id,name,public,file_size_limit from storage.buckets where id='finance-documents';
-- select routine_name from information_schema.routines where routine_schema='public' and routine_name='fc_api_sync_recurring_item';

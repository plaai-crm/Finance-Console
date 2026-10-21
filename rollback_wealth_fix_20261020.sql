-- Operational rollback for wealth_fix_20261020.sql
-- Keeps added columns and finance_audit_log data so evidence is not destroyed.
-- WARNING: this restores the prior broader staff access to lending/documents.

begin;

-- Restore the prior lending rule: Owner + active staff with general scope.
create or replace function public.fc_can_lending()
returns boolean language sql stable security definer set search_path=public,auth as $function$
  select public.fc_is_owner() or
    (public.fc_is_active_user() and public.fc_user_scope()='general');
$function$;
revoke all on function public.fc_can_lending() from public,anon;
grant execute on function public.fc_can_lending() to authenticated;

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
    end if;
  end loop;
end
$policies$;

create policy owner_loans_allowed on public.owner_loans for all to authenticated
  using(public.fc_can_lending()) with check(public.fc_can_lending());
create policy affiliate_loans_allowed on public.affiliate_loans for all to authenticated
  using(public.fc_can_lending()) with check(public.fc_can_lending());
create policy loan_payments_allowed on public.loan_payments for all to authenticated
  using(public.fc_can_lending()) with check(public.fc_can_lending());
create policy loan_followups_allowed on public.loan_followups for all to authenticated
  using(public.fc_can_lending()) with check(public.fc_can_lending());
create policy investments_owner on public.investments for all to authenticated
  using(public.fc_is_owner()) with check(public.fc_is_owner());
create policy investment_values_owner on public.investment_values for all to authenticated
  using(public.fc_is_owner()) with check(public.fc_is_owner());
create policy guarantees_owner on public.guarantees for all to authenticated
  using(public.fc_is_owner()) with check(public.fc_is_owner());
create policy documents_active_users on public.documents for all to authenticated
  using(public.fc_is_active_user()) with check(public.fc_is_active_user());

do $monthly$
begin
  if to_regclass('public.monthly_expense_plan') is not null then
    execute 'create policy monthly_plan_owner on public.monthly_expense_plan for all to authenticated using(public.fc_is_owner()) with check(public.fc_is_owner())';
  end if;
end
$monthly$;

grant delete on table public.businesses to authenticated;

-- Restore the former app_users table grants for compatibility with the old UI.
revoke all on table public.app_users from authenticated;
grant select,insert,update,delete on table public.app_users to authenticated;

-- Remove only the new audit/stamp triggers. Audit rows and columns remain intact.
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
      execute format('drop trigger if exists trg_fc_audit on public.%I',t);
    end if;
  end loop;
end
$triggers$;

-- Keep the bucket private, but restore document access for every active user.
drop policy if exists fc_finance_documents_select on storage.objects;
drop policy if exists fc_finance_documents_insert on storage.objects;
drop policy if exists fc_finance_documents_update on storage.objects;
drop policy if exists fc_finance_documents_delete on storage.objects;
create policy fc_finance_documents_select on storage.objects for select to authenticated
  using(bucket_id='finance-documents' and public.fc_is_active_user());
create policy fc_finance_documents_insert on storage.objects for insert to authenticated
  with check(bucket_id='finance-documents' and public.fc_is_active_user());
create policy fc_finance_documents_update on storage.objects for update to authenticated
  using(bucket_id='finance-documents' and public.fc_is_active_user())
  with check(bucket_id='finance-documents' and public.fc_is_active_user());
create policy fc_finance_documents_delete on storage.objects for delete to authenticated
  using(bucket_id='finance-documents' and public.fc_is_active_user());

commit;

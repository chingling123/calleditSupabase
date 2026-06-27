-- =====================================================================
-- Cravou / Called It — 0008 device tokens (push notifications)
-- Guarda o APNs device token por usuário. Service role lê p/ enviar push.
-- =====================================================================

create table device_tokens (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  token      text not null unique,
  platform   text not null default 'ios',
  updated_at timestamptz not null default now()
);
create index device_tokens_user_idx on device_tokens (user_id);

alter table device_tokens enable row level security;

revoke all on device_tokens from anon, authenticated;
grant select, insert, update, delete on device_tokens to authenticated;

-- usuário gerencia só os próprios tokens
create policy device_tokens_select_own on device_tokens
  for select to authenticated using (user_id = auth.uid());
create policy device_tokens_insert_own on device_tokens
  for insert to authenticated with check (user_id = auth.uid());
create policy device_tokens_update_own on device_tokens
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy device_tokens_delete_own on device_tokens
  for delete to authenticated using (user_id = auth.uid());

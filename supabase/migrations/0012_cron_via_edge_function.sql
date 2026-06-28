-- =====================================================================
-- Cravou / Called It — 0012 cron via Edge Function (apuração + push)
-- O cron passa a chamar a Edge Function daily-settlement (que apura E notifica
-- os votantes via send-push), em vez de rodar run_daily_settlement() direto.
--
-- PRÉ-REQUISITOS (manuais, feitos 1x no projeto):
--   create extension if not exists pg_net;
--   select vault.create_secret('<SUPABASE_SERVICE_ROLE_KEY>', 'service_role_key');
--   (a key é a sb_secret_… injetada como SUPABASE_SERVICE_ROLE_KEY nas Edge Functions)
-- =====================================================================
create extension if not exists pg_net;

do $$
begin
  perform cron.unschedule('cravou-daily-settlement');
exception when others then null;  -- ainda não agendado
end $$;

select cron.schedule(
  'cravou-daily-settlement',
  '5 0 * * *',
  $$
  select net.http_post(
    url := 'https://wwqgkpcitbdqjtsmsezk.supabase.co/functions/v1/daily-settlement',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
    ),
    timeout_milliseconds := 30000   -- apuração + push leva ~6s; default 5s gera timeout no pg_net
  );
  $$
);

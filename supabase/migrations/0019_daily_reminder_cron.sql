-- =====================================================================
-- Cravou / Called It — 0019 cron do lembrete diário
-- Chama a Edge Function daily-reminder (avisa quem não votou no duelo aberto).
-- 18:00 UTC. Requer pg_net + vault secret 'service_role_key' (ver 0012).
-- =====================================================================
do $$ begin perform cron.unschedule('cravou-daily-reminder'); exception when others then null; end $$;

select cron.schedule(
  'cravou-daily-reminder',
  '0 18 * * *',
  $$
  select net.http_post(
    url := 'https://wwqgkpcitbdqjtsmsezk.supabase.co/functions/v1/daily-reminder',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
    ),
    timeout_milliseconds := 30000
  );
  $$
);

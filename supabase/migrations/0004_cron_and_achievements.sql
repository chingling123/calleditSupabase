-- =====================================================================
-- Cravou / Called It — 0004 pg_cron (job diário) + achievements de referência
-- =====================================================================

-- ---------- achievements de referência (não são dados de teste) ----------
insert into achievements (code, name, description, emoji, scope) values
  ('first_golden',   'Toque de Midas',     'Conquistou sua primeira carta dourada.',        '🥇', 'global'),
  ('streak_7',       'Sequência de Fogo',  'Atingiu uma sequência de 7 dias.',              '🔥', 'global'),
  ('perfect_season', 'Temporada Perfeita', 'Acertou todos os duelos de uma temporada.',     '💎', 'season')
on conflict (code) do nothing;

-- ---------- pg_cron ----------
create extension if not exists pg_cron;

-- "Virada do dia": roda 00:05 UTC. run_daily_settlement() é idempotente e só
-- apura duelos cujo closes_at já passou — seguro rodar mesmo sem nada a fazer.
-- Ajuste o horário ao fuso da temporada conforme calibragem.
select cron.schedule(
  'cravou-daily-settlement',
  '5 0 * * *',
  $$ select run_daily_settlement(); $$
);

-- ---------------------------------------------------------------------
-- ALTERNATIVA via Edge Function (descomente se precisar de efeitos
-- externos no fechamento — ex: push notifications). Requer pg_net e o
-- secret do service_role. A função run_daily_settlement() continua sendo
-- a fonte da verdade; a Edge Function apenas a invoca.
-- ---------------------------------------------------------------------
-- create extension if not exists pg_net;
-- select cron.schedule(
--   'cravou-daily-settlement-edge', '5 0 * * *',
--   $$
--   select net.http_post(
--     url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/daily-settlement',
--     headers := jsonb_build_object(
--       'Content-Type','application/json',
--       'Authorization','Bearer ' || current_setting('app.service_role_key', true)
--     )
--   );
--   $$
-- );

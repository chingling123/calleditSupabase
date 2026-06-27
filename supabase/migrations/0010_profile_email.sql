-- =====================================================================
-- Cravou / Called It — 0010 email no profile
-- Guarda o email (vindo do Apple no link) também em profiles, p/ consulta junto
-- ao resto. A fonte canônica continua auth.users.email.
-- =====================================================================
alter table profiles add column if not exists email text;
grant update (email) on profiles to authenticated;

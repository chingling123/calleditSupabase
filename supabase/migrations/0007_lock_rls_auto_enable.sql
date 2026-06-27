-- =====================================================================
-- Cravou / Called It — 0007
-- rls_auto_enable() é um event trigger (auto-liga RLS em tabelas novas do
-- schema public). Não deve ser chamável via RPC → revoga execute.
-- =====================================================================
revoke execute on function public.rls_auto_enable() from anon, authenticated, public;

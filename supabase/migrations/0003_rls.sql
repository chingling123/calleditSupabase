-- =====================================================================
-- Cravou / Called It — 0003 segurança (RLS, grants de coluna, view pública)
--
-- Princípios:
--  * Funções de apuração são SECURITY DEFINER (dono = postgres) e ignoram RLS.
--  * Cliente só escreve voto/perfil próprios; lê dados públicos.
--  * CRÍTICO: contagens de voto de um duelo NÃO são visíveis enquanto aberto.
--    RLS é por linha, não por coluna → escondemos as colunas por GRANT e
--    expomos contagens só quando 'settled' via view v_duel_results.
-- =====================================================================

alter table profiles            enable row level security;
alter table seasons             enable row level security;
alter table cards               enable row level security;
alter table card_value_history  enable row level security;
alter table duels               enable row level security;
alter table votes               enable row level security;
alter table user_cards          enable row level security;
alter table achievements        enable row level security;
alter table user_achievements   enable row level security;
alter table season_scores       enable row level security;

-- ---------------------------------------------------------------------
-- Reset de privilégios (recomeçar limpo; RLS continua gatekeeper de linha)
-- ---------------------------------------------------------------------
revoke all on profiles, seasons, cards, card_value_history, duels, votes,
              user_cards, achievements, user_achievements, season_scores
  from anon, authenticated;

-- Bloqueia QUALQUER acesso direto às funções de servidor pelo cliente
revoke execute on function settle_duel(uuid)            from anon, authenticated, public;
revoke execute on function run_daily_settlement()       from anon, authenticated, public;
revoke execute on function fn_apply_streaks(uuid)       from anon, authenticated, public;
revoke execute on function fn_check_achievements(uuid, boolean) from anon, authenticated, public;
revoke execute on function fn_recalc_ranks(uuid)        from anon, authenticated, public;

-- ============================ profiles ===============================
-- leitura pública (rankings mostram nome/avatar/streak)
grant select on profiles to anon, authenticated;
-- update só de colunas cosméticas do próprio perfil (pontos/streak são do servidor)
grant update (display_name, avatar_emoji, country_code) on profiles to authenticated;

create policy profiles_read_all on profiles
  for select to anon, authenticated using (true);
create policy profiles_update_own on profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ===================== tabelas públicas read-only =====================
grant select on seasons, cards, card_value_history, achievements, season_scores
  to anon, authenticated;

create policy seasons_read    on seasons            for select to anon, authenticated using (true);
create policy cards_read      on cards              for select to anon, authenticated using (true);
create policy cvh_read        on card_value_history for select to anon, authenticated using (true);
create policy ach_read        on achievements       for select to anon, authenticated using (true);
create policy scores_read     on season_scores      for select to anon, authenticated using (true);

-- ============================== duels ================================
-- select de TODAS as colunas EXCETO as contagens (escondidas até apuração)
grant select (id, season_id, day_number, card_a_id, card_b_id,
              opens_at, closes_at, status,
              favorite_card_id, underdog_card_id, settled_at, created_at)
  on duels to anon, authenticated;

create policy duels_read on duels for select to anon, authenticated using (true);

-- View pública: contagens só aparecem quando o duelo foi apurado.
-- (view roda com privilégio do dono => contorna o GRANT de coluna acima)
create or replace view v_duel_results
with (security_invoker = false) as
select
  id, season_id, day_number, card_a_id, card_b_id, opens_at, closes_at, status,
  case when status = 'settled' then votes_a     end as votes_a,
  case when status = 'settled' then votes_b     end as votes_b,
  case when status = 'settled' then total_votes end as total_votes,
  favorite_card_id, underdog_card_id, settled_at
from duels;
grant select on v_duel_results to anon, authenticated;

-- ============================== votes ================================
-- lê só os próprios; insere via cast_vote (colunas de resultado ficam null)
grant select on votes to authenticated;
grant insert (duel_id, user_id, card_id) on votes to authenticated;

create policy votes_read_own on votes
  for select to authenticated using (user_id = auth.uid());

-- insert defensivo: dono correto + duelo realmente aberto + card do duelo
-- (cast_vote já valida; esta policy protege contra insert direto via API)
create policy votes_insert_own on votes
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from duels dd
      where dd.id = duel_id
        and dd.status = 'open'
        and now() >= dd.opens_at and now() < dd.closes_at
        and card_id in (dd.card_a_id, dd.card_b_id)
    )
  );
-- sem policy de update/delete => voto imutável

-- =========================== user_cards ==============================
grant select on user_cards to authenticated;
create policy user_cards_read_own on user_cards
  for select to authenticated using (user_id = auth.uid());

-- ======================= user_achievements ==========================
grant select on user_achievements to authenticated;
create policy user_ach_read_own on user_achievements
  for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- cast_vote: único ponto de escrita de voto liberado ao cliente
-- ---------------------------------------------------------------------
grant execute on function cast_vote(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- get_rank_window: posição do usuário + N vizinhos (eficiente p/ UI)
-- SECURITY INVOKER: lê season_scores/profiles (ambos público p/ leitura)
-- ---------------------------------------------------------------------
create or replace function get_rank_window(p_season_id uuid, p_radius int default 5)
returns table (
  rank int, user_id uuid, display_name text, avatar_emoji text,
  country_code char(2), points bigint, correct_count int, is_me boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  with me as (
    select rank as my_rank from season_scores
    where season_id = p_season_id and user_id = auth.uid()
  )
  select ss.rank, ss.user_id, p.display_name, p.avatar_emoji, p.country_code,
         ss.points, ss.correct_count, (ss.user_id = auth.uid()) as is_me
  from season_scores ss
  join profiles p on p.id = ss.user_id
  cross join me
  where ss.season_id = p_season_id
    and ss.rank between me.my_rank - p_radius and me.my_rank + p_radius
  order by ss.rank;
$$;
grant execute on function get_rank_window(uuid, int) to authenticated;

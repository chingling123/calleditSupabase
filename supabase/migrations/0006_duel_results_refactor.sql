-- =====================================================================
-- Cravou / Called It — 0006 refactor de segurança (resolve advisors)
--  * Contagens saem de `duels` para `duel_results` (1:1). A linha só nasce
--    na apuração => contagem fica privada até 'settled' SEM view definer
--    nem grant de coluna. Remove o lint ERROR security_definer_view.
--  * search_path fixo nas funções de fórmula (lint WARN).
--  * handle_new_user fora do RPC público.
-- =====================================================================

-- ---------- nova tabela de resultado ----------
create table duel_results (
  duel_id        uuid primary key references duels(id) on delete cascade,
  season_id      uuid not null references seasons(id) on delete cascade,
  votes_a        int  not null,
  votes_b        int  not null,
  total_votes    int  not null,
  winner_card_id uuid not null references cards(id),   -- favorito (mais votado)
  loser_card_id  uuid not null references cards(id),   -- azarão (menos votado)
  winner_share   numeric(6,4) not null,
  was_golden     boolean not null,
  settled_at     timestamptz not null default now()
);
alter table duel_results enable row level security;
grant select on duel_results to anon, authenticated;
create policy duel_results_read on duel_results
  for select to anon, authenticated using (true);

-- ---------- duels: remove colunas sensíveis/derivadas ----------
drop view if exists v_duel_results;
alter table duels
  drop column if exists votes_a,
  drop column if exists votes_b,
  drop column if exists total_votes,
  drop column if exists favorite_card_id,
  drop column if exists underdog_card_id,
  drop column if exists settled_at;

-- agora a tabela inteira é pública (sem segredos) → grant simples
grant select on duels to anon, authenticated;

-- view de conveniência (invoker; sem segredo): duelo + resultado se houver
create or replace view v_duel_results
with (security_invoker = true) as
select
  d.id, d.season_id, d.day_number, d.card_a_id, d.card_b_id,
  d.opens_at, d.closes_at, d.status,
  r.votes_a, r.votes_b, r.total_votes,
  r.winner_card_id, r.loser_card_id, r.winner_share, r.was_golden, r.settled_at
from duels d
left join duel_results r on r.duel_id = d.id;
grant select on v_duel_results to anon, authenticated;

-- ---------- settle_duel: grava em duel_results ----------
create or replace function settle_duel(p_duel_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  d duels%rowtype;
  v_votes_a int; v_votes_b int; v_total int;
  v_winner uuid; v_loser uuid; v_win_votes int; v_win_share numeric; v_golden boolean;
  va_old numeric; vb_old numeric; va_new numeric; vb_new numeric;
begin
  select * into d from duels where id = p_duel_id for update;
  if not found then raise exception 'duel not found'; end if;
  if d.status = 'settled' then return; end if;

  select
    count(*) filter (where card_id = d.card_a_id),
    count(*) filter (where card_id = d.card_b_id),
    count(*)
  into v_votes_a, v_votes_b, v_total
  from votes where duel_id = p_duel_id;

  if v_votes_a >= v_votes_b then
    v_winner := d.card_a_id; v_loser := d.card_b_id; v_win_votes := v_votes_a;
  else
    v_winner := d.card_b_id; v_loser := d.card_a_id; v_win_votes := v_votes_b;
  end if;

  v_win_share := case when v_total > 0 then v_win_votes::numeric / v_total else 1 end;
  v_golden    := (v_total > 0) and (v_win_share < fn_cfg_golden_threshold());

  update votes set
    is_correct     = (card_id = v_winner),
    points_awarded = case when card_id = v_winner then fn_calc_points(v_win_share) else 0 end
  where duel_id = p_duel_id;

  insert into season_scores (season_id, user_id, points, correct_count)
  select d.season_id, vt.user_id, coalesce(vt.points_awarded, 0),
         case when vt.is_correct then 1 else 0 end
  from votes vt where vt.duel_id = p_duel_id
  on conflict (season_id, user_id) do update set
    points        = season_scores.points + excluded.points,
    correct_count = season_scores.correct_count + excluded.correct_count,
    updated_at    = now();

  update profiles p set total_points = p.total_points + sub.pts
  from (select user_id, sum(points_awarded) pts
        from votes where duel_id = p_duel_id and is_correct group by user_id) sub
  where p.id = sub.user_id;

  insert into user_cards (user_id, card_id, duel_id, is_golden)
  select vt.user_id, v_winner, p_duel_id, v_golden
  from votes vt where vt.duel_id = p_duel_id and vt.is_correct
  on conflict (user_id, duel_id) do nothing;

  select current_value into va_old from cards where id = d.card_a_id;
  select current_value into vb_old from cards where id = d.card_b_id;
  va_new := fn_calc_card_value(va_old, v_votes_a, v_total);
  vb_new := fn_calc_card_value(vb_old, v_votes_b, v_total);
  update cards set current_value = va_new where id = d.card_a_id;
  update cards set current_value = vb_new where id = d.card_b_id;

  insert into card_value_history (card_id, duel_id, day_number, value, delta, votes_received)
  values (d.card_a_id, p_duel_id, d.day_number, va_new, va_new - va_old, v_votes_a)
  on conflict (card_id, day_number) do nothing;
  insert into card_value_history (card_id, duel_id, day_number, value, delta, votes_received)
  values (d.card_b_id, p_duel_id, d.day_number, vb_new, vb_new - vb_old, v_votes_b)
  on conflict (card_id, day_number) do nothing;

  insert into duel_results (duel_id, season_id, votes_a, votes_b, total_votes,
                            winner_card_id, loser_card_id, winner_share, was_golden)
  values (p_duel_id, d.season_id, v_votes_a, v_votes_b, v_total,
          v_winner, v_loser, round(v_win_share, 4), v_golden)
  on conflict (duel_id) do nothing;

  update duels set status = 'settled' where id = p_duel_id;
end;
$$;

-- ---------- search_path fixo nas funções de fórmula ----------
alter function fn_cfg_points_base()      set search_path = public;
alter function fn_cfg_golden_threshold() set search_path = public;
alter function fn_cfg_shield_interval()  set search_path = public;
alter function fn_cfg_shield_cap()       set search_path = public;
alter function fn_cfg_value_k()          set search_path = public;
alter function fn_cfg_value_floor()      set search_path = public;
alter function fn_calc_points(numeric)   set search_path = public;
alter function fn_calc_card_value(numeric, int, int) set search_path = public;

-- ---------- handle_new_user fora do RPC público ----------
revoke execute on function handle_new_user() from anon, authenticated, public;

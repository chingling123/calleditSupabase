-- =====================================================================
-- Cravou / Called It — 0002 lógica de negócio
-- Funções: config, pontos, flutuação (bolsa), voto, apuração, streak,
-- achievements, ranking.
--
-- >>> BLOCO DE CALIBRAGEM <<<
-- Todos os parâmetros e as DUAS fórmulas-chave (pontos e valor) estão
-- isolados aqui no topo. Ajuste só estas funções para recalibrar o jogo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- CONSTANTES DE CONFIGURAÇÃO (calibrar testando)
-- ---------------------------------------------------------------------
create or replace function fn_cfg_points_base()      returns numeric language sql immutable as $$ select 1000::numeric $$;
-- card vencedor que fecha ABAIXO deste share => carta DOURADA (duelo disputado)
create or replace function fn_cfg_golden_threshold() returns numeric language sql immutable as $$ select 0.55::numeric $$;
-- +1 escudo a cada N dias de streak ...
create or replace function fn_cfg_shield_interval()  returns int     language sql immutable as $$ select 5 $$;
-- ... até este teto de escudos acumulados
create or replace function fn_cfg_shield_cap()       returns int     language sql immutable as $$ select 3 $$;
-- sensibilidade da "bolsa": quanto o valor reage à procura (0 = não move)
create or replace function fn_cfg_value_k()          returns numeric language sql immutable as $$ select 0.20::numeric $$;
-- piso de valor de um card (nunca abaixo disto)
create or replace function fn_cfg_value_floor()      returns numeric language sql immutable as $$ select 1.00::numeric $$;

-- ---------------------------------------------------------------------
-- FÓRMULA 1 — PONTOS (inversos à margem de vitória)
-- Só quem ACERTOU (votou no card mais votado) pontua.
-- winner_share ∈ (0.5, 1].  margem = winner_share - 0.5.
--   vitória apertada (share≈0.51) => muitos pontos (call difícil)
--   favorito esmagador (share≈0.95) => poucos pontos (era óbvio)
--   points = BASE * (1 - winner_share) / 0.5  =>  BASE em 0.5, 0 em 1.0
-- ---------------------------------------------------------------------
create or replace function fn_calc_points(winner_share numeric)
returns int language sql immutable as $$
  select greatest(1, round( fn_cfg_points_base() * (1 - winner_share) / 0.5 ))::int;
$$;

-- ---------------------------------------------------------------------
-- FÓRMULA 2 — FLUTUAÇÃO DE VALOR (a "bolsa") — sistema SEPARADO,
-- nunca afeta acerto nem pontos. Cada card sobe/desce conforme sua
-- procura vs o esperado (50% num duelo de 2 cards).
--   share = votes_card / total ; expected = 0.5
--   new = old * (1 + K * (share - expected)/expected)
--       = old * (1 + K * (2*share - 1))
--   total = 0 => share neutro 0.5 => valor não muda
-- ---------------------------------------------------------------------
create or replace function fn_calc_card_value(old_value numeric, votes_card int, total_votes int)
returns numeric language sql immutable as $$
  select greatest(
    fn_cfg_value_floor(),
    round(
      old_value * (1 + fn_cfg_value_k() *
        (2 * (case when total_votes > 0 then votes_card::numeric / total_votes else 0.5 end) - 1)
      ), 2)
  );
$$;

-- ---------------------------------------------------------------------
-- REGISTRAR VOTO  (cliente; SECURITY INVOKER => RLS aplica)
-- Valida: duelo aberto e na janela, card pertence ao duelo, sem voto prévio.
-- ---------------------------------------------------------------------
create or replace function cast_vote(p_duel_id uuid, p_card_id uuid)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_duel duels%rowtype;
  v_vote_id uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  select * into v_duel from duels where id = p_duel_id;
  if not found then
    raise exception 'duel not found' using errcode = 'P0002';
  end if;
  if v_duel.status <> 'open' or now() < v_duel.opens_at or now() >= v_duel.closes_at then
    raise exception 'duel is not open for voting' using errcode = 'P0001';
  end if;
  if p_card_id <> v_duel.card_a_id and p_card_id <> v_duel.card_b_id then
    raise exception 'card does not belong to this duel' using errcode = 'P0001';
  end if;

  begin
    insert into votes (duel_id, user_id, card_id)
    values (p_duel_id, v_uid, p_card_id)
    returning id into v_vote_id;
  exception when unique_violation then
    raise exception 'you already voted in this duel' using errcode = 'P0001';
  end;

  return v_vote_id;
end;
$$;

-- ---------------------------------------------------------------------
-- APURAÇÃO DE UM DUELO (service role; SECURITY DEFINER)
-- Conta votos, marca acertos+pontos, distribui cards (dourada se disputado),
-- atualiza a bolsa e grava histórico, fecha o duelo.
-- NÃO mexe em streak/ranking/abertura — isso é orquestrado em run_daily_settlement().
-- ---------------------------------------------------------------------
create or replace function settle_duel(p_duel_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  d            duels%rowtype;
  v_votes_a    int;
  v_votes_b    int;
  v_total      int;
  v_winner     uuid;
  v_loser      uuid;
  v_win_votes  int;
  v_win_share  numeric;
  v_golden     boolean;
  va_old numeric; vb_old numeric; va_new numeric; vb_new numeric;
begin
  select * into d from duels where id = p_duel_id for update;
  if not found then raise exception 'duel not found'; end if;
  if d.status = 'settled' then return; end if;  -- idempotente

  select
    count(*) filter (where card_id = d.card_a_id),
    count(*) filter (where card_id = d.card_b_id),
    count(*)
  into v_votes_a, v_votes_b, v_total
  from votes where duel_id = p_duel_id;

  -- vencedor = mais votado (empate => card_a, determinístico)
  if v_votes_a >= v_votes_b then
    v_winner := d.card_a_id; v_loser := d.card_b_id; v_win_votes := v_votes_a;
  else
    v_winner := d.card_b_id; v_loser := d.card_a_id; v_win_votes := v_votes_b;
  end if;

  v_win_share := case when v_total > 0 then v_win_votes::numeric / v_total else 1 end;
  v_golden    := (v_total > 0) and (v_win_share < fn_cfg_golden_threshold());

  -- marca acertos + pontos em cada voto
  update votes set
    is_correct     = (card_id = v_winner),
    points_awarded = case when card_id = v_winner then fn_calc_points(v_win_share) else 0 end
  where duel_id = p_duel_id;

  -- season_scores: upsert p/ TODOS os votantes (corretos somam pts+1 acerto)
  insert into season_scores (season_id, user_id, points, correct_count)
  select d.season_id, vt.user_id, coalesce(vt.points_awarded, 0),
         case when vt.is_correct then 1 else 0 end
  from votes vt where vt.duel_id = p_duel_id
  on conflict (season_id, user_id) do update set
    points        = season_scores.points + excluded.points,
    correct_count = season_scores.correct_count + excluded.correct_count,
    updated_at    = now();

  -- total_points lifetime no profile
  update profiles p set total_points = p.total_points + sub.pts
  from (select user_id, sum(points_awarded) pts
        from votes where duel_id = p_duel_id and is_correct group by user_id) sub
  where p.id = sub.user_id;

  -- distribui card aos acertadores (dourada se duelo disputado)
  insert into user_cards (user_id, card_id, duel_id, is_golden)
  select vt.user_id, v_winner, p_duel_id, v_golden
  from votes vt where vt.duel_id = p_duel_id and vt.is_correct
  on conflict (user_id, duel_id) do nothing;

  -- BOLSA: novo valor de cada card + histórico do dia
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

  -- fecha o duelo
  update duels set
    status = 'settled',
    votes_a = v_votes_a, votes_b = v_votes_b, total_votes = v_total,
    favorite_card_id = v_winner, underdog_card_id = v_loser,
    settled_at = now()
  where id = p_duel_id;
end;
$$;

-- ---------------------------------------------------------------------
-- STREAK + ESCUDOS de um duelo apurado (universo: profiles.current_streak>0)
-- ---------------------------------------------------------------------
create or replace function fn_apply_streaks(p_duel_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 1) quem votou hoje: +1 streak, atualiza max
  update profiles p set
    current_streak = p.current_streak + 1,
    max_streak     = greatest(p.max_streak, p.current_streak + 1)
  where p.id in (select user_id from votes where duel_id = p_duel_id);

  -- 2) escudo: +1 ao cruzar múltiplo de INTERVAL, respeitando o CAP
  update profiles p set streak_shields = p.streak_shields + 1
  where p.id in (select user_id from votes where duel_id = p_duel_id)
    and p.current_streak % fn_cfg_shield_interval() = 0
    and p.streak_shields < fn_cfg_shield_cap();

  -- 3a) faltou e SEM escudo => zera (rodar ANTES do consumo p/ snapshot correto)
  update profiles p set current_streak = 0
  where p.current_streak > 0
    and p.streak_shields = 0
    and p.id not in (select user_id from votes where duel_id = p_duel_id);

  -- 3b) faltou e COM escudo => consome 1, preserva streak
  update profiles p set streak_shields = p.streak_shields - 1
  where p.current_streak > 0
    and p.streak_shields > 0
    and p.id not in (select user_id from votes where duel_id = p_duel_id);
end;
$$;

-- ---------------------------------------------------------------------
-- ACHIEVEMENTS (idempotente; achievements precisam existir — ver seed)
-- ---------------------------------------------------------------------
create or replace function fn_check_achievements(p_season_id uuid, p_season_end boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- primeira dourada (global)
  insert into user_achievements (user_id, achievement_id, season_id)
  select distinct uc.user_id, a.id, null
  from user_cards uc join achievements a on a.code = 'first_golden'
  where uc.is_golden
  on conflict do nothing;

  -- streak de 7 (global)
  insert into user_achievements (user_id, achievement_id, season_id)
  select p.id, a.id, null
  from profiles p join achievements a on a.code = 'streak_7'
  where p.current_streak >= 7
  on conflict do nothing;

  -- temporada perfeita: acertou todos os dias (season scope) — só no fim
  if p_season_end then
    insert into user_achievements (user_id, achievement_id, season_id)
    select ss.user_id, a.id, ss.season_id
    from season_scores ss
    join seasons s     on s.id = ss.season_id
    join achievements a on a.code = 'perfect_season'
    where ss.season_id = p_season_id
      and ss.correct_count = s.duration_days
    on conflict do nothing;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- RECÁLCULO DE RANKING da season
-- ---------------------------------------------------------------------
create or replace function fn_recalc_ranks(p_season_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  with ranked as (
    select user_id, rank() over (order by points desc, user_id) as r
    from season_scores where season_id = p_season_id
  )
  update season_scores ss set rank = ranked.r, updated_at = now()
  from ranked
  where ss.season_id = p_season_id and ss.user_id = ranked.user_id;
end;
$$;

-- ---------------------------------------------------------------------
-- JOB DIÁRIO — orquestra o ciclo (service role; chamado pelo pg_cron/Edge Fn)
-- Para cada duelo vencido: apura, aplica streak, achievements; depois
-- recalcula ranks, abre o próximo dia ou encerra a season.
-- ---------------------------------------------------------------------
create or replace function run_daily_settlement()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  d record;
  v_next int;
  v_dur  int;
begin
  for d in
    select * from duels
    where status in ('open', 'closed') and closes_at <= now()
    order by season_id, day_number
  loop
    perform settle_duel(d.id);
    perform fn_apply_streaks(d.id);

    select duration_days into v_dur from seasons where id = d.season_id;
    v_next := d.day_number + 1;

    if v_next > v_dur then
      -- último dia: encerra season e congela ranking
      perform fn_recalc_ranks(d.season_id);
      perform fn_check_achievements(d.season_id, true);
      update seasons set status = 'ended' where id = d.season_id;
    else
      -- abre o duelo do dia seguinte
      update duels set status = 'open'
      where season_id = d.season_id and day_number = v_next and status = 'upcoming';
      perform fn_recalc_ranks(d.season_id);
      perform fn_check_achievements(d.season_id, false);
    end if;
  end loop;
end;
$$;

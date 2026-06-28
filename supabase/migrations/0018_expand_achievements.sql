-- =====================================================================
-- Cravou / Called It — 0018 catálogo de conquistas (3 → 9) + regras de unlock
-- Novas: first_call, streak_5, hundred_day, full_set(season), top_100(season),
-- top_10pct(season). Mantém first_golden, streak_7, perfect_season.
-- fn_check_achievements reescrita p/ desbloquear o conjunto computável a cada
-- apuração (globais + full_set) e no fim de season (perfect, top_100, top_10pct).
-- =====================================================================
insert into achievements (code, name, description, emoji, scope) values
  ('first_call',  '1º Palpite',     'Você fez seu primeiro palpite.',                 '🎯', 'global'),
  ('streak_5',    'Sequência de 5', '5 dias seguidos cravando.',                      '🔥', 'global'),
  ('hundred_day', '100 num Dia',    'Ganhou 100+ pontos num único palpite.',          '💯', 'global'),
  ('full_set',    'Coleção Cheia',  'Conquistou todas as cartas de uma temporada.',   '🃏', 'season'),
  ('top_100',     'Top 100',        'Terminou no top 100 da temporada.',              '🥇', 'season'),
  ('top_10pct',   'Top 10%',        'Terminou nos 10% melhores da temporada.',        '🌍', 'season')
on conflict (code) do nothing;

create or replace function fn_check_achievements(p_season_id uuid, p_season_end boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into user_achievements (user_id, achievement_id, season_id)
  select distinct v.user_id, a.id, null::uuid
  from votes v join achievements a on a.code = 'first_call'
  on conflict do nothing;

  insert into user_achievements (user_id, achievement_id, season_id)
  select p.id, a.id, null::uuid from profiles p join achievements a on a.code = 'streak_5'
  where p.current_streak >= 5 on conflict do nothing;

  insert into user_achievements (user_id, achievement_id, season_id)
  select p.id, a.id, null::uuid from profiles p join achievements a on a.code = 'streak_7'
  where p.current_streak >= 7 on conflict do nothing;

  insert into user_achievements (user_id, achievement_id, season_id)
  select distinct uc.user_id, a.id, null::uuid
  from user_cards uc join achievements a on a.code = 'first_golden'
  where uc.is_golden on conflict do nothing;

  insert into user_achievements (user_id, achievement_id, season_id)
  select distinct v.user_id, a.id, null::uuid
  from votes v join achievements a on a.code = 'hundred_day'
  where coalesce(v.points_awarded, 0) >= 100 on conflict do nothing;

  insert into user_achievements (user_id, achievement_id, season_id)
  select x.user_id, a.id, p_season_id
  from (
    select uc.user_id
    from user_cards uc join cards c on c.id = uc.card_id
    where c.season_id = p_season_id
    group by uc.user_id
    having count(distinct uc.card_id) = (select count(*) from cards where season_id = p_season_id)
  ) x join achievements a on a.code = 'full_set'
  on conflict do nothing;

  if p_season_end then
    insert into user_achievements (user_id, achievement_id, season_id)
    select ss.user_id, a.id, ss.season_id
    from season_scores ss
    join seasons s      on s.id = ss.season_id
    join achievements a on a.code = 'perfect_season'
    where ss.season_id = p_season_id and ss.correct_count = s.duration_days
    on conflict do nothing;

    insert into user_achievements (user_id, achievement_id, season_id)
    select ss.user_id, a.id, ss.season_id
    from season_scores ss join achievements a on a.code = 'top_100'
    where ss.season_id = p_season_id and ss.rank <= 100
    on conflict do nothing;

    insert into user_achievements (user_id, achievement_id, season_id)
    select ss.user_id, a.id, ss.season_id
    from season_scores ss join achievements a on a.code = 'top_10pct'
    where ss.season_id = p_season_id
      and ss.rank <= greatest(1, ceil(0.10 * (select count(*) from season_scores where season_id = p_season_id)))
    on conflict do nothing;
  end if;
end;
$$;

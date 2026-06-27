-- =====================================================================
-- Cravou / Called It — 0011 fix fn_check_achievements
-- O literal `null` p/ season_id era inferido como text → erro 42804 (uuid vs text)
-- ao apurar via run_daily_settlement. Cast explícito null::uuid.
-- =====================================================================
create or replace function fn_check_achievements(p_season_id uuid, p_season_end boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into user_achievements (user_id, achievement_id, season_id)
  select distinct uc.user_id, a.id, null::uuid
  from user_cards uc join achievements a on a.code = 'first_golden'
  where uc.is_golden
  on conflict do nothing;

  insert into user_achievements (user_id, achievement_id, season_id)
  select p.id, a.id, null::uuid
  from profiles p join achievements a on a.code = 'streak_7'
  where p.current_streak >= 7
  on conflict do nothing;

  if p_season_end then
    insert into user_achievements (user_id, achievement_id, season_id)
    select ss.user_id, a.id, ss.season_id
    from season_scores ss
    join seasons s      on s.id = ss.season_id
    join achievements a on a.code = 'perfect_season'
    where ss.season_id = p_season_id and ss.correct_count = s.duration_days
    on conflict do nothing;
  end if;
end;
$$;

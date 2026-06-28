-- =====================================================================
-- Cravou / Called It — 0016 ranking por país
-- Janela de ranking (posição + vizinhos) filtrada por profiles.country_code.
-- =====================================================================
create or replace function get_rank_window_country(p_season_id uuid, p_country text, p_radius int default 5)
returns table (
  rank int, user_id uuid, display_name text, avatar_emoji text,
  country_code char(2), points bigint, correct_count int, is_me boolean
)
language sql stable security invoker set search_path = public as $$
  with ranked as (
    select ss.user_id, p.display_name, p.avatar_emoji, p.country_code,
           ss.points, ss.correct_count,
           rank() over (order by ss.points desc, ss.user_id) as r
    from season_scores ss
    join profiles p on p.id = ss.user_id
    where ss.season_id = p_season_id and p.country_code = p_country
  ),
  me as (select r as my_rank from ranked where user_id = auth.uid())
  select ranked.r, ranked.user_id, ranked.display_name, ranked.avatar_emoji, ranked.country_code,
         ranked.points, ranked.correct_count, (ranked.user_id = auth.uid()) as is_me
  from ranked cross join me
  where ranked.r between me.my_rank - p_radius and me.my_rank + p_radius
  order by ranked.r;
$$;
grant execute on function get_rank_window_country(uuid, text, int) to authenticated;

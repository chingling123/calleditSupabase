-- =====================================================================
-- Cravou / Called It — 0017 rollover de temporada
-- Ao encerrar a temporada, ativa a próxima (upcoming, por start_date) e abre
-- o duelo do dia 1 (janela = agora). Evita ficar sem season ativa.
-- =====================================================================
create or replace function activate_next_season()
returns void language plpgsql security definer set search_path = public as $$
declare nxt uuid;
begin
  select id into nxt from seasons where status = 'upcoming'
  order by start_date asc, created_at asc limit 1;
  if nxt is null then return; end if;

  update seasons set status = 'active' where id = nxt;
  update duels set status = 'open', opens_at = now(),
    closes_at = date_trunc('day', now()) + interval '1 day'
  where season_id = nxt and day_number = 1 and status = 'upcoming';
end;
$$;

create or replace function run_daily_settlement()
returns void language plpgsql security definer set search_path = public as $$
declare
  d record; v_next int; v_dur int;
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
      perform fn_recalc_ranks(d.season_id);
      perform fn_check_achievements(d.season_id, true);
      update seasons set status = 'ended' where id = d.season_id;
      perform activate_next_season();
    else
      update duels set status = 'open', opens_at = now(),
        closes_at = date_trunc('day', now()) + interval '1 day'
      where season_id = d.season_id and day_number = v_next and status = 'upcoming';
      perform fn_recalc_ranks(d.season_id);
      perform fn_check_achievements(d.season_id, false);
    end if;
  end loop;
end;
$$;

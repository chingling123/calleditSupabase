-- =====================================================================
-- Cravou / Called It — 0015 fechar duelo na meia-noite (UTC)
-- Abrir com closes_at = now()+24h derivava alguns segundos por dia e corria
-- com o cron fixo (00:05): o fecho caía depois do cron → perdia 1 dia.
-- Agora o próximo duelo fecha em date_trunc('day', now())+1d (próxima meia-noite),
-- então o cron das 00:05 sempre apura.
-- =====================================================================
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

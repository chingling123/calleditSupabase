-- =====================================================================
-- Cravou / Called It — 0013 abrir próximo duelo com janela "agora"
-- A apuração abria o próximo duelo mantendo opens_at/closes_at do seed (datas
-- futuras) → cast_vote/RLS rejeitavam ("votação não aberta"). Agora, ao abrir,
-- a janela passa a começar em now() e fechar em +1 dia.
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
      update duels set status = 'open', opens_at = now(), closes_at = now() + interval '1 day'
      where season_id = d.season_id and day_number = v_next and status = 'upcoming';
      perform fn_recalc_ranks(d.season_id);
      perform fn_check_achievements(d.season_id, false);
    end if;
  end loop;
end;
$$;

-- =====================================================================
-- Cravou / Called It — 0005 SEED de teste: "Semana da Pizza"
-- 1 temporada ativa (7 dias), 6 cards, 7 duelos. Dia 1 aberto; demais upcoming.
-- Datas ancoradas em CURRENT_DATE para o duelo do dia 1 já estar votável.
-- =====================================================================
do $$
declare
  s_id uuid;
  c_pep uuid; c_cal uuid; c_mar uuid; c_qua uuid; c_por uuid; c_fra uuid;
  base_ts timestamptz := date_trunc('day', now());  -- meia-noite de hoje
begin
  -- ---------- season ----------
  insert into seasons (theme, emoji, start_date, end_date, duration_days, status)
  values ('Semana da Pizza', '🍕', current_date, current_date + 6, 7, 'active')
  returning id into s_id;

  -- ---------- cards (6) ----------
  insert into cards (season_id, name, emoji, rarity, initial_value, current_value) values
    (s_id, 'Pepperoni',           '🍕', 'common',    100, 100) returning id into c_pep;
  insert into cards (season_id, name, emoji, rarity, initial_value, current_value) values
    (s_id, 'Calabresa',           '🌶️', 'common',    100, 100) returning id into c_cal;
  insert into cards (season_id, name, emoji, rarity, initial_value, current_value) values
    (s_id, 'Margherita',          '🍅', 'rare',      100, 100) returning id into c_mar;
  insert into cards (season_id, name, emoji, rarity, initial_value, current_value) values
    (s_id, 'Quatro Queijos',      '🧀', 'rare',      100, 100) returning id into c_qua;
  insert into cards (season_id, name, emoji, rarity, initial_value, current_value) values
    (s_id, 'Portuguesa',          '🥚', 'epic',      100, 100) returning id into c_por;
  insert into cards (season_id, name, emoji, rarity, initial_value, current_value) values
    (s_id, 'Frango c/ Catupiry',  '🐔', 'legendary', 100, 100) returning id into c_fra;

  -- ---------- duelos (7) ----------
  -- dia N: abre base_ts + (N-1)d, fecha +1d. Dia 1 = 'open', resto = 'upcoming'.
  insert into duels (season_id, day_number, card_a_id, card_b_id, opens_at, closes_at, status) values
    (s_id, 1, c_pep, c_cal, base_ts,                  base_ts + interval '1 day',  'open'),
    (s_id, 2, c_mar, c_qua, base_ts + interval '1 day', base_ts + interval '2 day', 'upcoming'),
    (s_id, 3, c_por, c_fra, base_ts + interval '2 day', base_ts + interval '3 day', 'upcoming'),
    (s_id, 4, c_pep, c_mar, base_ts + interval '3 day', base_ts + interval '4 day', 'upcoming'),
    (s_id, 5, c_cal, c_por, base_ts + interval '4 day', base_ts + interval '5 day', 'upcoming'),
    (s_id, 6, c_qua, c_fra, base_ts + interval '5 day', base_ts + interval '6 day', 'upcoming'),
    (s_id, 7, c_pep, c_qua, base_ts + interval '6 day', base_ts + interval '7 day', 'upcoming');
end $$;

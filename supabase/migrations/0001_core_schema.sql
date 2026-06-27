-- =====================================================================
-- Cravou / Called It — 0001 core schema
-- Tabelas, tipos, constraints e índices. Sem lógica, sem RLS (ver 0002/0003).
-- =====================================================================

-- ---------- ENUMS ----------
create type season_status as enum ('upcoming', 'active', 'ended');
-- upcoming: dia futuro, ainda não abriu | open: votação ativa
-- closed: votação encerrada, aguardando apuração | settled: apurado
create type duel_status   as enum ('upcoming', 'open', 'closed', 'settled');
create type card_rarity   as enum ('common', 'rare', 'epic', 'legendary');
create type achievement_scope as enum ('global', 'season');

-- ---------- profiles (1:1 auth.users) ----------
create table profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  display_name   text not null,
  avatar_emoji   text not null default '🙂',
  country_code   char(2),
  total_points   bigint not null default 0,        -- lifetime, todas as seasons
  current_streak int    not null default 0,        -- presença (votou no dia), não acerto
  max_streak     int    not null default 0,
  streak_shields int    not null default 0,
  created_at     timestamptz not null default now()
);

-- ---------- seasons ----------
create table seasons (
  id            uuid primary key default gen_random_uuid(),
  theme         text not null,
  emoji         text not null default '🎮',
  start_date    date not null,
  end_date      date not null,
  duration_days int  not null check (duration_days between 1 and 31),
  status        season_status not null default 'upcoming',
  created_at    timestamptz not null default now(),
  check (end_date >= start_date)
);
-- no máx 1 season ativa por vez
create unique index seasons_one_active_idx on seasons (status) where status = 'active';

-- ---------- cards ----------
create table cards (
  id            uuid primary key default gen_random_uuid(),
  season_id     uuid not null references seasons(id) on delete cascade,
  name          text not null,
  emoji         text not null default '🃏',
  rarity        card_rarity not null default 'common',
  initial_value numeric(12,2) not null default 100.00,
  current_value numeric(12,2) not null default 100.00,
  created_at    timestamptz not null default now()
);
create index cards_season_idx on cards (season_id);

-- ---------- duels (1 duelo por dia) ----------
create table duels (
  id                uuid primary key default gen_random_uuid(),
  season_id         uuid not null references seasons(id) on delete cascade,
  day_number        int  not null check (day_number >= 1),
  card_a_id         uuid not null references cards(id),
  card_b_id         uuid not null references cards(id),
  opens_at          timestamptz not null,
  closes_at         timestamptz not null,
  status            duel_status not null default 'upcoming',
  -- preenchidos só na apuração:
  votes_a           int,
  votes_b           int,
  total_votes       int,
  favorite_card_id  uuid references cards(id),  -- card mais votado (descritivo)
  underdog_card_id  uuid references cards(id),  -- card menos votado (descritivo)
  settled_at        timestamptz,
  created_at        timestamptz not null default now(),
  constraint duels_distinct_cards check (card_a_id <> card_b_id),
  constraint duels_close_after_open check (closes_at > opens_at),
  unique (season_id, day_number)
);
create index duels_season_status_idx on duels (season_id, status);
create index duels_closes_at_idx on duels (closes_at) where status in ('open','closed');

-- ---------- card_value_history (1 registro/card/dia) ----------
create table card_value_history (
  id             uuid primary key default gen_random_uuid(),
  card_id        uuid not null references cards(id) on delete cascade,
  duel_id        uuid not null references duels(id) on delete cascade,
  day_number     int  not null,
  value          numeric(12,2) not null,   -- valor APÓS o fechamento do dia
  delta          numeric(12,2) not null,   -- variação vs valor anterior
  votes_received int  not null default 0,
  created_at     timestamptz not null default now(),
  unique (card_id, day_number)
);
create index cvh_card_idx on card_value_history (card_id, day_number);

-- ---------- votes (1 palpite/usuário/duelo, imutável) ----------
create table votes (
  id             uuid primary key default gen_random_uuid(),
  duel_id        uuid not null references duels(id) on delete cascade,
  user_id        uuid not null references profiles(id) on delete cascade,
  card_id        uuid not null references cards(id),
  is_correct     boolean,   -- null até apuração
  points_awarded int,       -- null até apuração
  created_at     timestamptz not null default now(),
  unique (duel_id, user_id)
);
create index votes_duel_idx on votes (duel_id);
create index votes_user_idx on votes (user_id);

-- ---------- user_cards (coleção) ----------
create table user_cards (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  card_id    uuid not null references cards(id),
  duel_id    uuid not null references duels(id),
  is_golden  boolean not null default false,
  created_at timestamptz not null default now(),
  unique (user_id, duel_id)   -- no máx 1 card ganho por duelo
);
create index user_cards_user_idx on user_cards (user_id);

-- ---------- achievements / user_achievements ----------
create table achievements (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  description text not null,
  emoji       text not null default '🏆',
  scope       achievement_scope not null default 'global'
);

create table user_achievements (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references profiles(id) on delete cascade,
  achievement_id uuid not null references achievements(id) on delete cascade,
  season_id      uuid references seasons(id) on delete cascade,  -- null p/ global
  unlocked_at    timestamptz not null default now()
);

-- season_id nullable não pode entrar em PK → unicidade via 2 índices parciais
-- global (season_id null): 1x por usuário+conquista
create unique index user_ach_global_uidx
  on user_achievements (user_id, achievement_id)
  where season_id is null;
-- por season: 1x por usuário+conquista+season
create unique index user_ach_season_uidx
  on user_achievements (user_id, achievement_id, season_id)
  where season_id is not null;

-- ---------- season_scores (ranking eficiente por season) ----------
create table season_scores (
  season_id     uuid not null references seasons(id) on delete cascade,
  user_id       uuid not null references profiles(id) on delete cascade,
  points        bigint not null default 0,
  correct_count int    not null default 0,
  rank          int,                              -- recalculado na apuração
  updated_at    timestamptz not null default now(),
  primary key (season_id, user_id)
);
-- chave do ranking: posição do usuário + vizinhos via window function
create index season_scores_rank_idx on season_scores (season_id, points desc, user_id);
create index season_scores_country_idx on season_scores (season_id, points desc) include (user_id);

-- ---------- auto-criação de profile ao registrar em auth.users ----------
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, avatar_emoji)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'avatar_emoji', '🙂')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

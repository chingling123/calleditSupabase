-- =====================================================================
-- Cravou / Called It — 0009 fix handle_new_user p/ usuários anônimos
-- Anônimos não têm email → display_name caía em NULL (viola NOT NULL),
-- causando "Database error creating anonymous user" (500) no signInAnonymously.
-- Fallback: meta.display_name -> prefixo do email -> "Player".
-- =====================================================================
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, avatar_emoji)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data->>'display_name', ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'Player'
    ),
    coalesce(nullif(new.raw_user_meta_data->>'avatar_emoji', ''), '🙂')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

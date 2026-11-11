-- aster shared leaderboard. Run once in Supabase: SQL Editor > New query > paste > Run.
-- The game can only read times and add new ones (no update, no delete).

create table public.lap_times (
  id bigint generated always as identity primary key,
  player_id text not null check (char_length(player_id) between 8 and 64),
  player_name text not null check (char_length(player_name) between 1 and 16),
  map text not null check (char_length(map) between 1 and 32),
  time_ms integer not null check (time_ms between 5000 and 3600000),
  created_at timestamptz not null default now()
);

alter table public.lap_times enable row level security;

create policy "anyone can read times" on public.lap_times
  for select to anon using (true);

create policy "anyone can add a time" on public.lap_times
  for insert to anon with check (true);

grant select, insert on public.lap_times to anon;

-- best time of each player on each map
create view public.leaderboard with (security_invoker = on) as
  select distinct on (player_id, map) player_id, player_name, map, time_ms, created_at
  from public.lap_times
  order by player_id, map, time_ms asc, created_at asc;

grant select on public.leaderboard to anon;

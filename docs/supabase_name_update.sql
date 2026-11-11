-- Run once in Supabase (SQL Editor > New query > Run) to show each player under their latest name.
create or replace view public.leaderboard with (security_invoker = on) as
  select distinct on (t.player_id, t.map) t.player_id, latest.player_name, t.map, t.time_ms, t.created_at
  from public.lap_times t
  cross join lateral (
    select l.player_name from public.lap_times l
    where l.player_id = t.player_id
    order by l.created_at desc
    limit 1
  ) latest
  order by t.player_id, t.map, t.time_ms asc, t.created_at asc;

grant select on public.leaderboard to anon;

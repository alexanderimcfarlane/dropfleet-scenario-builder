-- Dropfleet Scenario Builder: cloud library schema for Supabase.
-- Run once in the Supabase dashboard: SQL Editor → New query → paste this file → Run.
-- Safe to re-run: it drops and recreates its own policies, triggers and functions (not your data).
--
-- Model
--   profiles     one per signed-in user (display name only, readable by anyone)
--   groups       clubs / events that share scenarios; joined with an invite code
--   memberships  who is in which group: owner | editor | viewer
--   scenarios    the scenario JSON, owned by one user, visible as private | group | public
--
-- Every rule below is enforced by Postgres Row Level Security, because the page talks to the
-- database directly with the public (publishable / anon) key.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- tables
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'Commander' check (char_length(display_name) between 1 and 40),
  created_at   timestamptz not null default now()
);

create table if not exists public.groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 60),
  invite_code text not null unique default encode(gen_random_bytes(8), 'hex') check (char_length(invite_code) between 12 and 64),
  join_role   text not null default 'editor' check (join_role in ('editor', 'viewer')),
  created_by  uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now()
);

create table if not exists public.memberships (
  group_id  uuid not null references public.groups (id) on delete cascade,
  user_id   uuid not null references public.profiles (id) on delete cascade,
  role      text not null default 'viewer' check (role in ('owner', 'editor', 'viewer')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index if not exists memberships_user_idx on public.memberships (user_id);

create table if not exists public.scenarios (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  group_id   uuid references public.groups (id) on delete cascade,
  visibility text not null default 'private' check (visibility in ('private', 'group', 'public')),
  name       text not null default 'Untitled scenario' check (char_length(name) between 1 and 60),
  doc        jsonb not null check (jsonb_typeof(doc) = 'object' and pg_column_size(doc) < 262144),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_visibility check ((visibility = 'group') = (group_id is not null))
);
create index if not exists scenarios_owner_idx on public.scenarios (owner, updated_at desc);
create index if not exists scenarios_group_idx on public.scenarios (group_id, updated_at desc) where group_id is not null;
create index if not exists scenarios_public_idx on public.scenarios (updated_at desc) where visibility = 'public';

-- ---------------------------------------------------------------- helpers (security definer so policies don't recurse)
create or replace function public.group_role(g uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from memberships where group_id = g and user_id = auth.uid()
$$;
create or replace function public.is_member(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from memberships where group_id = g and user_id = auth.uid())
$$;
create or replace function public.can_edit_group(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.group_role(g) in ('owner', 'editor'), false)
$$;
create or replace function public.is_group_owner(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.group_role(g) = 'owner', false)
$$;

-- ---------------------------------------------------------------- triggers
-- A profile for every new account, named from the sign-up form or sign-in provider. Display names are public,
-- so the email address is never used as a fallback.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, display_name)
  values (new.id, left(coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), nullif(new.raw_user_meta_data ->> 'user_name', ''),
                                nullif(new.raw_user_meta_data ->> 'name', ''), 'Commander'), 40))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
-- Accounts created before this schema was run.
insert into public.profiles (id, display_name)
select id, left(coalesce(nullif(raw_user_meta_data ->> 'full_name', ''), nullif(raw_user_meta_data ->> 'user_name', ''), 'Commander'), 40)
from auth.users on conflict (id) do nothing;

-- The creator of a group becomes its owner; at most 20 groups created per person.
create or replace function public.groups_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.created_by := coalesce(auth.uid(), new.created_by);
  if (select count(*) from groups where created_by = auth.uid()) >= 20 then
    raise exception 'group_limit' using hint = 'You can create up to 20 groups.';
  end if;
  return new;
end $$;
drop trigger if exists groups_before_insert on public.groups;
create trigger groups_before_insert before insert on public.groups for each row execute function public.groups_before_insert();

create or replace function public.groups_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into memberships (group_id, user_id, role) values (new.id, new.created_by, 'owner');
  return new;
end $$;
drop trigger if exists groups_after_insert on public.groups;
create trigger groups_after_insert after insert on public.groups for each row execute function public.groups_after_insert();

-- Deleting a group keeps its scenarios: they go back to being private to whoever made them.
create or replace function public.groups_before_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update scenarios set visibility = 'private', group_id = null where group_id = old.id;
  return old;
end $$;
drop trigger if exists groups_before_delete on public.groups;
create trigger groups_before_delete before delete on public.groups for each row execute function public.groups_before_delete();

-- A group always keeps at least one owner (unless the whole group is being deleted).
create or replace function public.memberships_keep_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.role = 'owner' and (tg_op = 'DELETE' or new.role <> 'owner')
     and exists (select 1 from groups where id = old.group_id)
     and not exists (select 1 from memberships where group_id = old.group_id and role = 'owner' and user_id <> old.user_id) then
    raise exception 'last_owner' using hint = 'Make someone else an owner first, or delete the group.';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists memberships_keep_owner on public.memberships;
create trigger memberships_keep_owner before update or delete on public.memberships for each row execute function public.memberships_keep_owner();

-- Scenarios: stamp times, pin the owner, cap each person at 500, and only the owner may change who can see it.
-- auth.uid() is null only for you as admin (dashboard SQL editor / table editor, secret key): visitors can't write
-- without signing in, so admin changes such as un-publishing someone's scenario are let through.
create or replace function public.scenarios_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' then
    new.created_at := now();
    if auth.uid() is null then return new; end if;
    new.owner := auth.uid();
    if (select count(*) from scenarios where owner = auth.uid()) >= 500 then
      raise exception 'scenario_limit' using hint = 'You can keep up to 500 scenarios in the cloud.';
    end if;
  else
    new.owner := old.owner;
    new.created_at := old.created_at;
    -- pg_trigger_depth() > 1: changed by another trigger (a group being deleted), not by a person.
    if pg_trigger_depth() > 1 or auth.uid() is null then return new; end if;
    if auth.uid() is distinct from old.owner then
      new.visibility := old.visibility;
      new.group_id := old.group_id;
    end if;
  end if;
  if new.group_id is not null and not public.can_edit_group(new.group_id) and (tg_op = 'INSERT' or new.group_id is distinct from old.group_id) then
    raise exception 'not_group_editor' using hint = 'Only owners and editors can share into a group.';
  end if;
  return new;
end $$;
drop trigger if exists scenarios_guard on public.scenarios;
create trigger scenarios_guard before insert or update on public.scenarios for each row execute function public.scenarios_guard();

-- ---------------------------------------------------------------- invite codes
create or replace function public.join_group(code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare g groups;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select * into g from groups where invite_code = code;
  if not found then raise exception 'bad_invite' using hint = 'That invite link is wrong or has been replaced.'; end if;
  if (select count(*) from memberships where group_id = g.id) >= 200 then raise exception 'group_full'; end if;
  insert into memberships (group_id, user_id, role) values (g.id, auth.uid(), g.join_role) on conflict do nothing;
  return g.id;
end $$;
revoke all on function public.join_group(text) from public, anon;
grant execute on function public.join_group(text) to authenticated;

-- ---------------------------------------------------------------- row level security
alter table public.profiles    enable row level security;
alter table public.groups      enable row level security;
alter table public.memberships enable row level security;
alter table public.scenarios   enable row level security;

-- Table access is granted explicitly (newer projects don't grant it by default); the policies below then
-- narrow it row by row. Writes are column-level: everything else is fixed by triggers.
grant usage on schema public to anon, authenticated;
revoke all on public.profiles, public.groups, public.memberships, public.scenarios from anon, authenticated;
grant select on public.profiles, public.groups, public.scenarios to anon; -- groups: so public lists can ask for a group name (policy returns no rows)
grant select on public.profiles, public.groups, public.memberships, public.scenarios to authenticated;
grant delete on public.groups, public.memberships, public.scenarios to authenticated;
grant execute on function public.group_role(uuid), public.is_member(uuid), public.can_edit_group(uuid), public.is_group_owner(uuid) to anon, authenticated;
grant update (display_name) on public.profiles to authenticated;
grant insert (name, join_role) on public.groups to authenticated;
grant update (name, invite_code, join_role) on public.groups to authenticated;
grant update (role) on public.memberships to authenticated;
grant insert (name, doc, visibility, group_id) on public.scenarios to authenticated;
grant update (name, doc, visibility, group_id) on public.scenarios to authenticated;

drop policy if exists "profiles readable" on public.profiles;
drop policy if exists "profiles own update" on public.profiles;
create policy "profiles readable" on public.profiles for select to anon, authenticated using (true);
create policy "profiles own update" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "groups members read" on public.groups;
drop policy if exists "groups create" on public.groups;
drop policy if exists "groups owner update" on public.groups;
drop policy if exists "groups owner delete" on public.groups;
create policy "groups members read" on public.groups for select to authenticated using (public.is_member(id) or created_by = auth.uid());
create policy "groups create" on public.groups for insert to authenticated with check (auth.uid() is not null);
create policy "groups owner update" on public.groups for update to authenticated using (public.is_group_owner(id)) with check (public.is_group_owner(id));
create policy "groups owner delete" on public.groups for delete to authenticated using (public.is_group_owner(id));

drop policy if exists "memberships members read" on public.memberships;
drop policy if exists "memberships owner sets roles" on public.memberships;
drop policy if exists "memberships leave or remove" on public.memberships;
create policy "memberships members read" on public.memberships for select to authenticated using (public.is_member(group_id));
create policy "memberships owner sets roles" on public.memberships for update to authenticated
  using (public.is_group_owner(group_id)) with check (public.is_group_owner(group_id));
create policy "memberships leave or remove" on public.memberships for delete to authenticated
  using (user_id = auth.uid() or public.is_group_owner(group_id));

drop policy if exists "scenarios read" on public.scenarios;
drop policy if exists "scenarios create" on public.scenarios;
drop policy if exists "scenarios edit" on public.scenarios;
drop policy if exists "scenarios delete" on public.scenarios;
create policy "scenarios read" on public.scenarios for select to anon, authenticated using (
  visibility = 'public'
  or owner = auth.uid()
  or (visibility = 'group' and public.is_member(group_id))
);
create policy "scenarios create" on public.scenarios for insert to authenticated with check (
  auth.uid() is not null and (group_id is null or public.can_edit_group(group_id))
);
create policy "scenarios edit" on public.scenarios for update to authenticated
  using (owner = auth.uid() or (visibility = 'group' and public.can_edit_group(group_id)))
  with check (owner = auth.uid() or (visibility = 'group' and public.can_edit_group(group_id)));
create policy "scenarios delete" on public.scenarios for delete to authenticated
  using (owner = auth.uid() or (visibility = 'group' and public.is_group_owner(group_id)));

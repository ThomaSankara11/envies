-- ============================================================
--  Envies — schéma Supabase (à coller UNE FOIS dans SQL Editor → Run)
--  Comptes, amis (abonnements), listes privées, cadeaux réservés
--  en secret (invisibles pour le propriétaire de l'envie).
--
--  Règle de confidentialité : tes envies ne sont visibles QUE par
--  les personnes que TU suis (= tu les as acceptées en les suivant).
--  Quelqu'un qui te suit sans que tu le suives ne voit rien.
-- ============================================================

-- 1. Tables ---------------------------------------------------

create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  handle      text unique not null check (handle ~ '^[a-z0-9_.]{3,24}$'),
  name        text not null default '' check (length(name) <= 40),
  avatar_url  text check (avatar_url is null or avatar_url ~* '^https://'),
  created_at  timestamptz not null default now()
);

create table if not exists public.lists (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  name        text not null check (length(name) between 1 and 40),
  is_private  boolean not null default false,
  created_at  timestamptz not null default now()
);

create table if not exists public.wishes (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  list_id     uuid references public.lists(id) on delete set null,
  title       text not null check (length(title) between 1 and 300),
  brand       text not null default '' check (length(brand) <= 120),
  shop        text not null default '' check (length(shop) <= 120),
  price       numeric check (price is null or (price >= 0 and price < 100000000)),
  currency    text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  note        text not null default '' check (length(note) <= 1000),
  -- liens : uniquement http(s) (bloque les liens piégés « javascript: »)
  url         text not null default '' check (url = '' or url ~* '^https?://'),
  -- image : lien http(s) ou petite photo de la pellicule (≈ 400 Ko max)
  image_url   text not null default '' check (length(image_url) < 400000 and (image_url = '' or image_url ~* '^(https?://|data:image/)')),
  images      jsonb not null default '[]'::jsonb,
  fulfilled   boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists wishes_owner_idx on public.wishes(owner_id, created_at desc);

create table if not exists public.follows (
  follower_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  followee_id uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index if not exists follows_followee_idx on public.follows(followee_id);

create table if not exists public.reservations (
  wish_id     uuid not null references public.wishes(id) on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (wish_id, user_id)
);

-- 2. Création automatique du profil à l'inscription -----------
--    (si le pseudo est pris ou invalide, on en fabrique un unique
--     au lieu de faire échouer l'inscription)

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare h text;
begin
  h := lower(regexp_replace(coalesce(new.raw_user_meta_data->>'handle', ''), '[^a-zA-Z0-9_.]', '', 'g'));
  if h !~ '^[a-z0-9_.]{3,24}$' or exists (select 1 from public.profiles where handle = h) then
    h := left(coalesce(nullif(h, ''), 'user'), 17) || '_' || substr(replace(new.id::text, '-', ''), 1, 6);
  end if;
  insert into public.profiles (id, handle, name)
  values (new.id, h, left(coalesce(new.raw_user_meta_data->>'name', ''), 40));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Pseudo disponible ? (appelable avant l'inscription)
create or replace function public.handle_available(h text)
returns boolean language sql security definer set search_path = public as $$
  select not exists (select 1 from public.profiles where handle = lower(h));
$$;
grant execute on function public.handle_available(text) to anon, authenticated;

-- 3. Sécurité (Row Level Security) ----------------------------

alter table public.profiles     enable row level security;
alter table public.lists        enable row level security;
alter table public.wishes       enable row level security;
alter table public.follows      enable row level security;
alter table public.reservations enable row level security;

-- profils : lisibles par tout utilisateur connecté (pour « Trouver quelqu'un »)
-- (aucun e-mail n'est stocké ici)
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using (true);
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- listes : les miennes + les listes non privées des gens qui ME suivent
drop policy if exists lists_read on public.lists;
create policy lists_read on public.lists for select to authenticated
  using (
    owner_id = auth.uid()
    or (not is_private and exists (select 1 from public.follows f where f.follower_id = lists.owner_id and f.followee_id = auth.uid()))
  );
drop policy if exists lists_write on public.lists;
create policy lists_write on public.lists for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- envies : les miennes + celles des gens qui ME suivent (hors listes privées)
drop policy if exists wishes_read on public.wishes;
create policy wishes_read on public.wishes for select to authenticated
  using (
    owner_id = auth.uid()
    or (
      exists (select 1 from public.follows f where f.follower_id = wishes.owner_id and f.followee_id = auth.uid())
      and not exists (select 1 from public.lists l where l.id = wishes.list_id and l.is_private)
    )
  );
drop policy if exists wishes_write on public.wishes;
create policy wishes_write on public.wishes for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- abonnements
drop policy if exists follows_read on public.follows;
create policy follows_read on public.follows for select to authenticated using (true);
drop policy if exists follows_insert on public.follows;
create policy follows_insert on public.follows for insert to authenticated
  with check (follower_id = auth.uid());
drop policy if exists follows_delete on public.follows;
create policy follows_delete on public.follows for delete to authenticated
  using (follower_id = auth.uid());

-- réservations : visibles seulement sur les envies que je peux voir
-- ET qui ne sont pas les miennes (cadeau surprise)
drop policy if exists reservations_read on public.reservations;
create policy reservations_read on public.reservations for select to authenticated
  using (exists (select 1 from public.wishes w where w.id = reservations.wish_id and w.owner_id <> auth.uid()));
drop policy if exists reservations_insert on public.reservations;
create policy reservations_insert on public.reservations for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.wishes w where w.id = reservations.wish_id and w.owner_id <> auth.uid())
  );
drop policy if exists reservations_delete on public.reservations;
create policy reservations_delete on public.reservations for delete to authenticated
  using (user_id = auth.uid());

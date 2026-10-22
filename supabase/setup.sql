-- =====================================================================
--  Конструктор отчетности ММБ · база Supabase
--  Выполнить один раз: Supabase → SQL Editor → New query → вставить всё → Run
-- =====================================================================

-- 1. ПРОВЕРКА СВЯЗИ ------------------------------------------------------
--    Таблица только для страницы check.html. Пишет и читает кто угодно с anon-ключом,
--    поэтому в ней нет ничего, кроме служебных отметок. После проверки её можно удалить.
create table if not exists public.conn_test (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  client      text,        -- что за устройство (браузер), пишет страница проверки
  note        text
);
alter table public.conn_test enable row level security;
drop policy if exists conn_test_rw on public.conn_test;
create policy conn_test_rw on public.conn_test for all to anon, authenticated using (true) with check (true);

-- 2. УЧАСТНИКИ И РОЛИ ---------------------------------------------------
--    editor — загружает данные и правит дайджесты; viewer — только смотрит.
--    Пользователей заводит администратор: Authentication → Users → Add user (почта + пароль),
--    затем строка сюда:  insert into public.members (user_id, role, name)
--                        select id, 'editor', 'Иванов И.' from auth.users where email = 'ivanov@...';
create table if not exists public.members (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  role     text not null default 'viewer' check (role in ('editor','viewer')),
  name     text
);
alter table public.members enable row level security;
drop policy if exists members_self on public.members;
create policy members_self on public.members for select to authenticated using (user_id = auth.uid());

create or replace function public.mmb_role() returns text
  language sql stable security definer set search_path = public
  as $$ select role from public.members where user_id = auth.uid() $$;
revoke execute on function public.mmb_role() from public, anon;
grant execute on function public.mmb_role() to authenticated;

-- 3. ДАЙДЖЕСТЫ ----------------------------------------------------------
--    Один дайджест = одна строка: период, название и всё состояние конструктора (jsonb):
--    отчеты, данные, графики, презентация, версии. Excel-файлы не хранятся — только разобранные цифры.
create table if not exists public.digests (
  id          text primary key,
  period      text,
  name        text,
  info        jsonb,                        -- сводка для карточки в библиотеке
  state       jsonb not null,               -- полное состояние дайджеста
  rev         integer not null default 1,   -- номер правки: защита от затирания чужих изменений
  updated_at  timestamptz not null default now(),
  updated_by  uuid default auth.uid(),
  updated_name text
);
alter table public.digests enable row level security;

drop policy if exists digests_read on public.digests;
create policy digests_read on public.digests for select to authenticated
  using (public.mmb_role() in ('editor','viewer'));

drop policy if exists digests_insert on public.digests;
create policy digests_insert on public.digests for insert to authenticated
  with check (public.mmb_role() = 'editor');

drop policy if exists digests_update on public.digests;
create policy digests_update on public.digests for update to authenticated
  using (public.mmb_role() = 'editor') with check (public.mmb_role() = 'editor');

drop policy if exists digests_delete on public.digests;
create policy digests_delete on public.digests for delete to authenticated
  using (public.mmb_role() = 'editor');

-- 4. МГНОВЕННОЕ ОБНОВЛЕНИЕ У КОЛЛЕГ (Realtime) ---------------------------
--    Если в корпоративной сети websocket закрыт, конструктор сам переключится на опрос раз в 20 секунд.
do $$ begin
  begin alter publication supabase_realtime add table public.digests;  exception when others then null; end;
  begin alter publication supabase_realtime add table public.conn_test; exception when others then null; end;
end $$;

-- =====================================================================
--  راه‌اندازی دیتابیس آرایشگاه  (Supabase > SQL Editor > New query > Run)
--  قبل از اجرا: در خط زیر ایمیل مدیر را بنویسید (همان ایمیلی که در Auth > Users می‌سازید).
--  رمز آن کاربر همان پین ۶ رقمی مدیر است (مثلاً 482916).
-- =====================================================================

-- 1) ایمیل مدیر
create or replace function public.is_admin() returns boolean
language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = 'ali.ghadimi.1111@gmail.com'
$$;

-- 2) جدول‌ها
create table if not exists public.config (
  id text primary key default 'main',
  settings jsonb not null default '{}'::jsonb,
  services jsonb not null default '[]'::jsonb
);

create table if not exists public.bookings (
  id text primary key,
  "date" text not null,
  "time" text not null,
  sid text,
  sname text,
  n int not null default 1,
  name text not null,
  phone text not null default '',
  note text not null default '',
  code text,
  status text not null default 'pending',
  created bigint,
  uid uuid not null,
  cells text[] not null default '{}',
  orig jsonb
);
create index if not exists bookings_uid_idx  on public.bookings(uid);
create index if not exists bookings_date_idx on public.bookings("date");

-- هر خانه زمانی یک ردیف است؛ کلید اصلی یکتا جلوی رزرو دوبل را می‌گیرد
create table if not exists public.cells (
  id text primary key,
  "date" text not null,
  t int not null,
  bid text not null,
  uid uuid not null
);
create index if not exists cells_date_idx on public.cells("date");
create index if not exists cells_bid_idx  on public.cells(bid);

-- 3) دسترسی‌ها (RLS)
alter table public.config   enable row level security;
alter table public.bookings enable row level security;
alter table public.cells    enable row level security;

drop policy if exists "config read"      on public.config;
drop policy if exists "config admin"     on public.config;
drop policy if exists "cells read"       on public.cells;
drop policy if exists "cells admin"      on public.cells;
drop policy if exists "bookings read"    on public.bookings;
drop policy if exists "bookings admin"   on public.bookings;

create policy "config read"    on public.config   for select using (true);
create policy "config admin"   on public.config   for all    using (public.is_admin()) with check (public.is_admin());
create policy "cells read"     on public.cells    for select using (true);
create policy "cells admin"    on public.cells    for all    using (public.is_admin()) with check (public.is_admin());
create policy "bookings read"  on public.bookings for select using (public.is_admin() or uid = auth.uid());
create policy "bookings admin" on public.bookings for all    using (public.is_admin()) with check (public.is_admin());

-- 4) ثبت نوبت (مشتری فقط از همین تابع می‌تواند نوبت بسازد)
create or replace function public.place_booking(b jsonb, c jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  el jsonb;
  st text;
  adm boolean := public.is_admin();
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if jsonb_typeof(c) <> 'array' or jsonb_array_length(c) not between 1 and 16 then raise exception 'bad cells'; end if;
  if length(coalesce(b->>'name','')) not between 1 and 80 then raise exception 'bad name'; end if;
  if not adm and coalesce(b->>'phone','') !~ '^09[0-9]{9}$' then raise exception 'bad phone'; end if;
  if coalesce(b->>'date','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'bad date'; end if;
  st := case when adm then coalesce(b->>'status','pending') else 'pending' end;

  insert into public.bookings(id,"date","time",sid,sname,n,name,phone,note,code,status,created,uid,cells)
  values (b->>'id', b->>'date', b->>'time', b->>'sid', b->>'sname', (b->>'n')::int,
          b->>'name', coalesce(b->>'phone',''), left(coalesce(b->>'note',''),300), b->>'code', st,
          (b->>'created')::bigint, auth.uid(),
          array(select e.value->>'id' from jsonb_array_elements(c) with ordinality as e(value,ord) order by ord));

  for el in select value from jsonb_array_elements(c) loop
    if (el->>'date') is distinct from (b->>'date') or coalesce(el->>'id','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]+$' then
      raise exception 'bad cell';
    end if;
    insert into public.cells(id,"date",t,bid,uid)
    values (el->>'id', el->>'date', (el->>'t')::int, b->>'id', auth.uid());
  end loop;
end $$;

-- 5) تغییر وضعیت (مشتری فقط نوبت خودش را لغو یا پیشنهاد را قبول/رد می‌کند)
create or replace function public.set_status(p_id text, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cur text; v_owner uuid;
begin
  select status, uid into v_cur, v_owner from public.bookings where id = p_id;
  if not found then raise exception 'not found'; end if;
  if not public.is_admin() then
    if v_owner is distinct from auth.uid() then raise exception 'forbidden'; end if;
    if not ((p_status = 'cancelled' and v_cur in ('pending','confirmed','proposed'))
         or (v_cur = 'proposed' and p_status in ('confirmed','declined'))) then
      raise exception 'forbidden';
    end if;
  end if;
  update public.bookings set status = p_status where id = p_id;
  if p_status not in ('pending','confirmed','proposed') then
    delete from public.cells where bid = p_id;
  end if;
end $$;

-- 6) پیشنهاد زمان جدید (فقط مدیر)
create or replace function public.propose_booking(p_id text, p_date text, p_time text, c jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare el jsonb; v_owner uuid;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select uid into v_owner from public.bookings where id = p_id;
  if not found then raise exception 'not found'; end if;
  delete from public.cells where bid = p_id;
  for el in select value from jsonb_array_elements(c) loop
    insert into public.cells(id,"date",t,bid,uid) values (el->>'id', el->>'date', (el->>'t')::int, p_id, v_owner);
  end loop;
  update public.bookings
     set orig = jsonb_build_object('date', "date", 'time', "time"),
         "date" = p_date, "time" = p_time, status = 'proposed',
         cells = array(select e.value->>'id' from jsonb_array_elements(c) with ordinality as e(value,ord) order by ord)
   where id = p_id;
end $$;

grant execute on function public.place_booking(jsonb, jsonb)            to authenticated;
grant execute on function public.set_status(text, text)                 to authenticated;
grant execute on function public.propose_booking(text, text, text, jsonb) to authenticated;

-- 7) به‌روزرسانی لحظه‌ای (Realtime)
do $$ begin
  begin alter publication supabase_realtime add table public.config;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.cells;    exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.bookings; exception when duplicate_object then null; end;
end $$;

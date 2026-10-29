-- ============================================================
-- เกมไพ่สลาฟ (เกมส์สลาฟ) — ตารางห้องบน Supabase
-- โปรเจกต์เดียวกับ Dummy Rummy: dbtlbeymrchodloboymr
-- วิธีรัน: เปิด Supabase SQL Editor -> วางทั้งไฟล์ -> Run
-- รันซ้ำได้ (idempotent)
-- ============================================================

-- 1) ตารางห้อง: room = JSON ทั้งห้อง (ที่นั่ง + สถานะเกม), v = เวอร์ชันกันเขียนทับ
create table if not exists public.slave_card_rooms (
  code       text primary key,
  room       jsonb not null,
  v          bigint not null default 1,
  updated_at timestamptz not null default now()
);

create index if not exists idx_slave_card_rooms_updated
  on public.slave_card_rooms(updated_at);

-- 2) RLS: เกมไม่มีระบบล็อกอิน เปิดให้ anon อ่าน/เขียนได้ (เหมือน Dummy Rummy)
alter table public.slave_card_rooms enable row level security;

drop policy if exists slave_card_rooms_all on public.slave_card_rooms;
create policy slave_card_rooms_all on public.slave_card_rooms
  for all to anon, authenticated
  using (true) with check (true);

-- 3) RPC เขียนห้องแบบ optimistic lock
--    p_expected_v = เวอร์ชันที่ client เห็นล่าสุด
--    ถ้าไม่ตรง -> ตอบ conflict=true (client จะดึง state ใหม่แล้วลองใหม่)
create or replace function public.slave_card_upsert(
  p_code       text,
  p_room       jsonb,
  p_expected_v bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cur_v bigint;
  new_v bigint;
begin
  select v into cur_v
  from public.slave_card_rooms
  where code = p_code
  for update;

  -- ยังไม่มีห้องนี้ -> สร้างใหม่ (v=1) แต่ถ้ามีคนแทรกพร้อมกันให้อัปเดตแทน
  if cur_v is null then
    insert into public.slave_card_rooms (code, room, v, updated_at)
    values (p_code, p_room, 1, now())
    on conflict (code) do update
      set room = excluded.room,
          v = public.slave_card_rooms.v + 1,
          updated_at = now()
    returning v into new_v;
    return jsonb_build_object('ok', true, 'v', new_v);
  end if;

  -- เวอร์ชันไม่ตรง -> ชนกัน ให้ client รีโหลด
  if p_expected_v is not null and cur_v <> p_expected_v then
    return jsonb_build_object('ok', false, 'conflict', true, 'v', cur_v);
  end if;

  update public.slave_card_rooms
     set room = p_room,
         v = cur_v + 1,
         updated_at = now()
   where code = p_code
  returning v into new_v;

  return jsonb_build_object('ok', true, 'v', new_v);
end;
$$;

grant execute on function public.slave_card_upsert(text, jsonb, bigint) to anon, authenticated;

-- 4) RPC ลบห้อง (ออกจากห้อง)
create or replace function public.slave_card_delete(p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.slave_card_rooms where code = p_code;
  return true;
end;
$$;

grant execute on function public.slave_card_delete(text) to anon, authenticated;

-- 5) Realtime (ถ้าเปิดได้ ไม่เปิดก็ไม่เป็นไร เพราะ client poll ทุก 2 วินาที)
do $$
begin
  alter publication supabase_realtime add table public.slave_card_rooms;
exception
  when duplicate_object then null;
  when undefined_object then null;
end $$;

-- 6) VERIFY — ควรได้ 0 แถว (หรือจำนวนห้องที่ค้างอยู่)
select count(*) as slave_card_rooms from public.slave_card_rooms;

-- 7) ล้างห้องค้างเก่า (>6 ชม.) — รันเมื่อต้องการ
-- delete from public.slave_card_rooms where updated_at < now() - interval '6 hours';

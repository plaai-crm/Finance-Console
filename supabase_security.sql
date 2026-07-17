-- ============================================================
--  Finance Console — กฎความปลอดภัยฐานข้อมูล (Supabase)
--  ------------------------------------------------------------
--  วิธีใช้:  เปิด Supabase → เมนู "SQL Editor" → New query
--           วางทั้งไฟล์นี้ลงไป → กด "Run"
--           (รันซ้ำได้ปลอดภัย ไม่ทำข้อมูลเสีย)
--
--  สิ่งที่ไฟล์นี้ทำ:
--   1) เปิด Row Level Security (RLS) ให้ทุกตาราง
--   2) ใส่กฎให้แอปยังทำงานได้ตามปกติ
--   3) เข้ารหัส (hash) รหัสผ่านอัตโนมัติ — รหัสผ่านจริงจะไม่ถูกเก็บ
--      เป็นข้อความธรรมดาอีกต่อไป
--   4) สร้างฟังก์ชันล็อกอินฝั่งเซิร์ฟเวอร์ (fc_login) เพื่อไม่ให้
--      ต้องดึงรหัสผ่านลงมาที่เบราว์เซอร์
--
--  ⚠️ สำคัญ: ต้องใช้คู่กับ index.html เวอร์ชันใหม่ที่แก้ให้ล็อกอิน
--     ผ่าน fc_login แล้ว (ทำให้แล้วในไฟล์ที่ส่งให้)
-- ============================================================


-- ============================================================
-- 0) เปิดส่วนเสริมสำหรับเข้ารหัสรหัสผ่าน
-- ============================================================
create extension if not exists pgcrypto;


-- ============================================================
-- 1) เปิด RLS ให้ทุกตาราง
--    เมื่อเปิดแล้ว ตารางจะถูก "ควบคุมการเข้าถึง" ตามกฎ (policy)
--    ที่กำหนดในขั้นถัดไปเท่านั้น
-- ============================================================
alter table public.app_users        enable row level security;
alter table public.businesses       enable row level security;
alter table public.transactions     enable row level security;
alter table public.recurring_items  enable row level security;
alter table public.owner_transfers  enable row level security;
alter table public.owner_loans      enable row level security;
alter table public.affiliate_loans  enable row level security;
alter table public.documents        enable row level security;


-- ============================================================
-- 2) กฎสำหรับตารางข้อมูลทั่วไป (ให้แอปทำงานได้)
--    ------------------------------------------------------------
--    หมายเหตุตามจริง: แอปนี้ใช้ "คีย์ anon" ตัวเดียวร่วมกันทุกคน
--    และยังไม่มีระบบ session รายบุคคล ฐานข้อมูลจึงแยกไม่ออกว่าใคร
--    เป็นใคร กฎด้านล่างจึงเป็นแบบ "อนุญาตผู้ที่ถือคีย์" — ยังไม่ใช่
--    การจำกัดสิทธิ์รายคน (owner/staff, ทั่วไป/โรงแรม)
--    การจำกัดสิทธิ์รายคนจริง ๆ ต้องเปลี่ยนไปใช้ Supabase Auth
--    (ดูหัวข้อ "ขั้นถัดไป" ท้ายไฟล์)
-- ============================================================
do $$
declare t text;
begin
  foreach t in array array[
    'businesses','transactions','recurring_items',
    'owner_transfers','owner_loans','affiliate_loans','documents'
  ] loop
    execute format('drop policy if exists fc_app_all on public.%I', t);
    execute format(
      'create policy fc_app_all on public.%I for all to anon, authenticated using (true) with check (true)',
      t);
  end loop;
end $$;


-- ============================================================
-- 3) ตารางผู้ใช้ (app_users) — จัดการรหัสผ่านให้ปลอดภัย
-- ============================================================

-- 3.1 เพิ่มคอลัมน์เก็บรหัสผ่านแบบเข้ารหัส
alter table public.app_users add column if not exists password_hash text;

-- 3.1b ปลดเงื่อนไข NOT NULL ของคอลัมน์ password เดิม
--      (เพราะต่อไปจะเก็บเป็น hash แทน และล้างรหัสผ่านข้อความทิ้ง)
alter table public.app_users alter column password drop not null;

-- 3.2 ฟังก์ชัน+trigger: ทุกครั้งที่มีการเพิ่ม/แก้ผู้ใช้ ถ้ามีการใส่
--     รหัสผ่าน (คอลัมน์ password) ระบบจะเข้ารหัสเก็บไว้ที่ password_hash
--     แล้วล้างรหัสผ่านแบบข้อความธรรมดาทิ้งทันที
create or replace function public.fc_hash_password()
returns trigger
language plpgsql
as $$
begin
  if new.password is not null and new.password <> '' then
    new.password_hash := crypt(new.password, gen_salt('bf'));
    new.password := null;   -- ไม่เก็บรหัสผ่านจริงเป็นข้อความ
  end if;
  return new;
end;
$$;

drop trigger if exists trg_hash_password on public.app_users;
create trigger trg_hash_password
  before insert or update on public.app_users
  for each row execute function public.fc_hash_password();

-- 3.3 แปลงรหัสผ่านเดิมที่ยังเป็นข้อความธรรมดา ให้เป็น hash (รันครั้งเดียว)
update public.app_users
   set password_hash = crypt(password, gen_salt('bf')),
       password      = null
 where password is not null and password <> '';


-- ============================================================
-- 4) ฟังก์ชันล็อกอินฝั่งเซิร์ฟเวอร์ (fc_login)
--    ------------------------------------------------------------
--    รับ username/password มาตรวจสอบในฐานข้อมูล ถ้าถูกต้องจะคืน
--    ข้อมูลผู้ใช้กลับไป "โดยไม่มีรหัสผ่าน" ติดไปด้วย
--    ทำให้เบราว์เซอร์ไม่ต้องดึงตารางรหัสผ่านลงมาอีกต่อไป
-- ============================================================
create or replace function public.fc_login(p_username text, p_password text)
returns jsonb
language sql
security definer            -- ทำงานด้วยสิทธิ์เจ้าของฟังก์ชัน (ข้าม RLS ได้)
set search_path = public
as $$
  select to_jsonb(u) - 'password' - 'password_hash'
  from public.app_users u
  where lower(u.username) = lower(p_username)
    and coalesce(u.active, true) = true
    and u.password_hash is not null
    and u.password_hash = crypt(p_password, u.password_hash)
  limit 1;
$$;

-- อนุญาตให้เรียกใช้ฟังก์ชันล็อกอินได้ (แต่ยังอ่านตารางตรง ๆ ไม่ได้)
grant execute on function public.fc_login(text, text) to anon, authenticated;


-- ============================================================
--  ขั้นถัดไป (แนะนำ เพื่อความปลอดภัยเต็มรูปแบบ)
--  ------------------------------------------------------------
--  ระดับนี้ปิด "ช่องรหัสผ่านแบบข้อความธรรมดา" ได้แล้ว ซึ่งเป็น
--  ความเสี่ยงร้ายแรงที่สุด แต่เพื่อให้ปลอดภัยเต็มที่ (แยกสิทธิ์
--  รายคน + ไม่ให้ใครอ่านตาราง app_users ได้เลย) ควรวางแผน
--  ย้ายระบบล็อกอินไปใช้ Supabase Auth ในอนาคต
--  แจ้งได้เลยถ้าต้องการให้ช่วยวางแผนส่วนนี้ต่อ
-- ============================================================

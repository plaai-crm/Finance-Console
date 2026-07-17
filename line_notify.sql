-- ============================================================================
--  line_notify.sql
--  แจ้งเตือนรายจ่ายค้างจ่ายผ่าน LINE — สำหรับ Finance Console (Supabase)
--  ใช้ LINE Messaging API (push message) เพราะ LINE Notify ปิดบริการถาวรแล้ว
--  ตั้งแต่ 31 มี.ค. 2025
--
--  ระบบจะส่งสรุป "รายจ่ายที่ยังไม่ได้จ่าย และครบกำหนดภายใน N วัน"
--  ไปที่ LINE ของ Owner อัตโนมัติทุกเช้า 07:00 น. (เวลาไทย)
--
--  วิธีใช้ (ทำครั้งเดียว):
--    1) เปิด Supabase → SQL Editor → วางไฟล์นี้ทั้งหมด → กด Run
--    2) เตรียมค่า LINE 2 ตัว (ดูขั้นตอนด้านล่าง) แล้วรันคำสั่ง INSERT ในส่วน [4]
--    3) ทดสอบด้วย:  select public.fc_line_daily_reminder();
--  ============================================================================


-- ============================================================================
--  [1] เปิดส่วนขยาย (extensions) ที่จำเป็น
--      - pg_net  : ให้ฐานข้อมูลยิง HTTP ออกไปหา LINE ได้
--      - pg_cron : ตั้งเวลาให้ทำงานอัตโนมัติทุกวัน
--  ============================================================================
create extension if not exists pg_net;
create extension if not exists pg_cron;


-- ============================================================================
--  [2] ตารางเก็บการตั้งค่า LINE (มีได้แค่ 1 แถว)
--      ล็อกด้วย RLS และไม่สร้าง policy ใด ๆ  → anon/ผู้ใช้ทั่วไปอ่านโทเคนไม่ได้
--      ฟังก์ชันด้านล่างเป็น SECURITY DEFINER จึงอ่านค่าได้เอง
--  ============================================================================
create table if not exists public.line_config (
  id                   int primary key default 1,
  channel_access_token text        not null,          -- Channel access token (long-lived)
  target_id            text        not null,          -- userId หรือ groupId ปลายทาง
  remind_days          int         not null default 3, -- แจ้งล่วงหน้ากี่วัน (ตรงกับ REMIND_DAYS ในแอป)
  send_when_empty      boolean     not null default false, -- ส่งข้อความแม้ไม่มีรายการค้างหรือไม่
  enabled              boolean     not null default true,  -- เปิด/ปิดการแจ้งเตือน
  updated_at           timestamptz default now(),
  constraint line_config_single check (id = 1)
);

alter table public.line_config enable row level security;
-- (ตั้งใจไม่สร้าง policy — เข้าถึงได้เฉพาะ service_role และฟังก์ชัน SECURITY DEFINER)


-- ============================================================================
--  [3] ฟังก์ชันหลัก: รวบรวมรายจ่ายค้างจ่าย แล้วส่งเข้า LINE
--  ============================================================================
create or replace function public.fc_line_daily_reminder()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg        public.line_config;
  th_mon     text[] := array['ม.ค.','ก.พ.','มี.ค.','เม.ย.','พ.ค.','มิ.ย.',
                             'ก.ค.','ส.ค.','ก.ย.','ต.ค.','พ.ย.','ธ.ค.'];
  today      date   := (now() at time zone 'Asia/Bangkok')::date;
  msg        text;
  item       text;
  total      numeric := 0;
  cnt        int := 0;
  r          record;
begin
  -- อ่านการตั้งค่า
  select * into cfg from public.line_config where id = 1;
  if not found then return; end if;
  if not cfg.enabled then return; end if;

  -- หัวข้อความ
  msg := '🔔 แจ้งเตือนรายจ่ายที่ครบกำหนด' || chr(10)
      || 'ประจำวันที่ ' || extract(day from today)::int || ' '
                        || th_mon[extract(month from today)::int] || ' '
                        || (extract(year from today)::int + 543) || chr(10)
      || '━━━━━━━━━━━━';

  -- วนรายจ่ายที่ยังไม่จ่าย และครบกำหนดภายใน remind_days วัน (รวมที่เลยกำหนดแล้ว)
  for r in
    select t.txn_date,
           t.amount,
           coalesce(nullif(t.category,''),'รายจ่าย') as category,
           coalesce(b.name,'—')                     as biz,
           (t.txn_date - today)                     as dleft
    from public.transactions t
    left join public.businesses b on b.id = t.business_id
    where t.kind = 'expense'
      and coalesce(t.is_paid,false) = false
      and t.txn_date <= today + cfg.remind_days
    order by t.txn_date asc
  loop
    cnt   := cnt + 1;
    total := total + coalesce(r.amount,0);
    item  := chr(10) || '• ' || r.category || ' — ' || r.biz || chr(10)
          || '   ' || to_char(round(coalesce(r.amount,0),2),'FM999,999,990.00')
                   || ' บาท · กำหนด '
                   || extract(day from r.txn_date)::int || ' '
                   || th_mon[extract(month from r.txn_date)::int]
          || case
               when r.dleft < 0 then ' (เลยกำหนด ' || abs(r.dleft) || ' วัน)'
               when r.dleft = 0 then ' (ครบกำหนดวันนี้)'
               else                  ' (อีก ' || r.dleft || ' วัน)'
             end;
    msg := msg || item;
  end loop;

  -- ไม่มีรายการค้าง
  if cnt = 0 then
    if not cfg.send_when_empty then
      return;  -- เงียบไว้ ไม่รบกวน
    end if;
    msg := msg || chr(10) || '✅ ไม่มีรายจ่ายค้างจ่ายในช่วงนี้';
  else
    msg := msg || chr(10) || '━━━━━━━━━━━━'
               || chr(10) || 'รวม ' || cnt || ' รายการ · '
               || to_char(round(total,2),'FM999,999,990.00') || ' บาท';
  end if;

  -- ยิงเข้า LINE Messaging API (push)
  perform net.http_post(
    url     := 'https://api.line.me/v2/bot/message/push',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || cfg.channel_access_token
               ),
    body    := jsonb_build_object(
                 'to', cfg.target_id,
                 'messages', jsonb_build_array(
                   jsonb_build_object('type','text','text', msg)
                 )
               )
  );
end;
$$;


-- ============================================================================
--  [4] ใส่ค่า LINE ของคุณ (แก้ 2 ค่านี้ แล้วรันเฉพาะบล็อกนี้)
--  ----------------------------------------------------------------------------
--  วิธีหาค่า:
--   channel_access_token
--     • ไปที่ https://developers.line.biz/console/
--     • สร้าง Provider → สร้าง Channel แบบ "Messaging API"
--     • แท็บ "Messaging API" → เลื่อนลงล่างสุด → ออก Channel access token (long-lived)
--
--   target_id  (ปลายทางที่จะรับข้อความ)
--     • ส่งหา "ตัวเอง": เพิ่มบอทเป็นเพื่อน แล้วใช้ "Your user ID" ในแท็บ Basic settings
--       (userId ขึ้นต้นด้วย U...)
--     • ส่งเข้า "กลุ่ม LINE": เชิญบอทเข้ากลุ่ม แล้วอ่าน groupId จาก webhook event
--       (groupId ขึ้นต้นด้วย C...)
--  ============================================================================
insert into public.line_config (id, channel_access_token, target_id, remind_days, send_when_empty, enabled)
values (
  1,
  'ใส่_CHANNEL_ACCESS_TOKEN_ตรงนี้',
  'ใส่_USER_ID_หรือ_GROUP_ID_ตรงนี้',
  3,       -- แจ้งล่วงหน้ากี่วัน
  false,   -- true = ส่งทุกวันแม้ไม่มีรายการค้าง
  true     -- true = เปิดใช้งาน
)
on conflict (id) do update set
  channel_access_token = excluded.channel_access_token,
  target_id            = excluded.target_id,
  remind_days          = excluded.remind_days,
  send_when_empty      = excluded.send_when_empty,
  enabled              = excluded.enabled,
  updated_at           = now();


-- ============================================================================
--  [5] ตั้งเวลาส่งอัตโนมัติทุกวัน 07:00 น. (เวลาไทย)
--      หมายเหตุ: pg_cron ใช้เวลา UTC → 00:00 UTC = 07:00 Asia/Bangkok
--  ============================================================================
select cron.unschedule('fc_line_daily_reminder')
where exists (select 1 from cron.job where jobname = 'fc_line_daily_reminder');

select cron.schedule(
  'fc_line_daily_reminder',
  '0 0 * * *',                              -- ทุกวัน 00:00 UTC (07:00 ไทย)
  $$ select public.fc_line_daily_reminder(); $$
);


-- ============================================================================
--  [6] คำสั่งที่ใช้บ่อย (คัดลอกไปรันแยกได้)
--  ----------------------------------------------------------------------------
--  ทดสอบส่งทันที:
--      select public.fc_line_daily_reminder();
--
--  ดูผลการยิง HTTP ล่าสุด (เช็คว่า LINE ตอบ 200):
--      select id, status_code, content
--      from net._http_response order by id desc limit 5;
--
--  ปิด/เปิดการแจ้งเตือนชั่วคราว:
--      update public.line_config set enabled = false where id = 1;  -- ปิด
--      update public.line_config set enabled = true  where id = 1;  -- เปิด
--
--  ยกเลิกตารางเวลา:
--      select cron.unschedule('fc_line_daily_reminder');
--
--  ดูงาน cron ทั้งหมด:
--      select jobname, schedule, active from cron.job;
--  ============================================================================

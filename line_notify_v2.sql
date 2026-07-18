-- ============================================================================
--  line_notify_v2.sql  ·  อัปเกรดการแจ้งเตือน LINE ให้ตั้งค่าจากในแอปได้
--  ----------------------------------------------------------------------------
--  ของใหม่ในไฟล์นี้:
--    • เลือกได้ว่าจะแจ้ง "ล่วงหน้ากี่วัน" จากหน้าตั้งค่าในแอป (ซิงก์เข้า LINE ให้เอง)
--    • พิมพ์ "ข้อความแจ้งเตือนเอง" ได้ (ขึ้นเป็นหัวข้อความ)
--    • มีปุ่ม "ส่งทดสอบเข้า LINE" ในแอป
--
--  ⚠️ ต้องรันไฟล์ line_notify.sql (ตัวเดิม) ให้เสร็จก่อนหนึ่งครั้ง
--     (ไฟล์เดิมเป็นตัวใส่โทเคน LINE และตั้งเวลาส่งทุกเช้า)
--     ไฟล์นี้ "ไม่แตะโทเคน" ของคุณ จึงรันทับได้ปลอดภัย
--
--  วิธีใช้ (ทำครั้งเดียว):
--    เปิด Supabase → SQL Editor → New query → วางไฟล์นี้ทั้งหมด → กด Run
--    เสร็จแล้วกลับไปที่แอป หน้า "ตั้งค่า" จะปรับวัน/ข้อความได้ทันที
-- ============================================================================


-- ============================================================================
--  [1] เพิ่มช่องเก็บ "ข้อความพิมพ์เอง" และ "รูปแบบข้อความ" ในตารางตั้งค่า LINE
--      (ปรับได้จากหน้าเว็บในแอป ไม่ต้องแก้ SQL อีก)
-- ============================================================================
alter table public.line_config add column if not exists custom_message text;
alter table public.line_config add column if not exists show_date     boolean not null default true;  -- แสดงวันที่
alter table public.line_config add column if not exists show_divider  boolean not null default true;  -- แสดงเส้นคั่น
alter table public.line_config add column if not exists show_business boolean not null default false; -- แสดงชื่อธุรกิจต่อรายการ
alter table public.line_config add column if not exists show_total    boolean not null default true;  -- แสดงยอดรวมท้ายข้อความ
alter table public.line_config add column if not exists compact       boolean not null default true;  -- true=รายการละบรรทัด, false=ละเอียด 2 บรรทัด


-- ============================================================================
--  [2] อัปเดตฟังก์ชันส่งแจ้งเตือน — ให้ใช้ข้อความพิมพ์เองเป็นหัวข้อความ
--      และเพิ่มโหมด "ทดสอบ" (ส่งได้แม้ไม่มีรายการค้าง)
-- ============================================================================
create or replace function public.fc_line_daily_reminder(p_test boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg      public.line_config;
  th_mon   text[] := array['ม.ค.','ก.พ.','มี.ค.','เม.ย.','พ.ค.','มิ.ย.',
                           'ก.ค.','ส.ค.','ก.ย.','ต.ค.','พ.ย.','ธ.ค.'];
  today    date   := (now() at time zone 'Asia/Bangkok')::date;
  divider  text   := '━━━━━━━━━━━━';
  msg      text;
  head     text;
  item     text;
  bizpart  text;
  whentxt  text;
  total    numeric := 0;
  cnt      int := 0;
  r        record;
begin
  select * into cfg from public.line_config where id = 1;
  if not found then return; end if;
  if not cfg.enabled and not p_test then return; end if;

  -- หัวข้อความ: ใช้ "ข้อความพิมพ์เอง" ถ้ามี ไม่งั้นใช้ข้อความมาตรฐาน
  head := coalesce(nullif(btrim(cfg.custom_message), ''), '🔔 แจ้งเตือนรายจ่าย');

  msg := case when p_test then '🧪 (ทดสอบ) ' else '' end
      || head
      || case when cfg.show_date
              then ' (' || extract(day from today)::int || ' '
                        || th_mon[extract(month from today)::int] || ')'
              else '' end;
  if cfg.show_divider then msg := msg || chr(10) || divider; end if;

  -- รายจ่ายที่ยังไม่จ่าย และครบกำหนดภายใน remind_days วัน (รวมที่เลยกำหนด)
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
    cnt     := cnt + 1;
    total   := total + coalesce(r.amount,0);
    bizpart := case when cfg.show_business then ' — ' || r.biz else '' end;
    whentxt := case
                 when r.dleft < 0 then 'เลย ' || abs(r.dleft) || ' วัน'
                 when r.dleft = 0 then 'วันนี้'
                 else                  'อีก ' || r.dleft || ' วัน'
               end;
    if cfg.compact then
      -- กระชับ: หนึ่งรายการ = หนึ่งบรรทัด
      item := chr(10) || '• ' || r.category || bizpart || ' · '
           || to_char(round(coalesce(r.amount,0)),'FM999,999,990') || ' บาท · ' || whentxt;
    else
      -- ละเอียด: สองบรรทัด (ชื่อ + จำนวน/กำหนด)
      item := chr(10) || '• ' || r.category || bizpart
           || chr(10) || '   ' || to_char(round(coalesce(r.amount,0),2),'FM999,999,990.00')
           || ' บาท · กำหนด ' || extract(day from r.txn_date)::int || ' '
           || th_mon[extract(month from r.txn_date)::int] || ' (' || whentxt || ')';
    end if;
    msg := msg || item;
  end loop;

  if cnt = 0 then
    -- ไม่มีรายการค้าง: ส่งเฉพาะเมื่อเปิด send_when_empty หรือกำลังทดสอบ
    if not cfg.send_when_empty and not p_test then
      return;
    end if;
    msg := msg || chr(10) || '✅ ไม่มีรายจ่ายค้างจ่าย';
  elsif cfg.show_total then
    if cfg.show_divider then msg := msg || chr(10) || divider; end if;
    msg := msg || chr(10) || 'รวม ' || cnt || ' รายการ · '
               || to_char(round(total),'FM999,999,990') || ' บาท';
  end if;

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
--  [3] อ่านค่าตั้งค่าปัจจุบัน (ให้แอปแสดงในหน้าตั้งค่า)
--      คืนเฉพาะค่าที่ปลอดภัย — ไม่มีโทเคน LINE ติดไปด้วย
-- ============================================================================
create or replace function public.fc_get_line_settings()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'remind_days',     remind_days,
    'custom_message',  coalesce(custom_message, ''),
    'send_when_empty', send_when_empty,
    'enabled',         enabled,
    'show_date',       show_date,
    'show_divider',    show_divider,
    'show_business',   show_business,
    'show_total',      show_total,
    'compact',         compact
  )
  from public.line_config
  where id = 1;
$$;

grant execute on function public.fc_get_line_settings() to anon, authenticated;


-- ============================================================================
--  [4] บันทึกค่าตั้งค่าจากแอป (จำนวนวัน / ข้อความ / รูปแบบ / ตัวเลือกการส่ง)
--      แอปเรียกฟังก์ชันนี้เวลากดปุ่ม "บันทึกการตั้งค่า"
-- ============================================================================
-- ลบฟังก์ชันเวอร์ชันเก่า (4 พารามิเตอร์) ถ้ามี เพื่อไม่ให้ซ้ำซ้อน
drop function if exists public.fc_set_line_settings(int, text, boolean, boolean);

create or replace function public.fc_set_line_settings(
  p_remind_days     int,
  p_custom_message  text,
  p_send_when_empty boolean,
  p_enabled         boolean,
  p_show_date       boolean,
  p_show_divider    boolean,
  p_show_business   boolean,
  p_show_total      boolean,
  p_compact         boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.line_config
     set remind_days     = greatest(0, least(60, coalesce(p_remind_days, remind_days))),
         custom_message  = nullif(btrim(coalesce(p_custom_message, '')), ''),
         send_when_empty = coalesce(p_send_when_empty, send_when_empty),
         enabled         = coalesce(p_enabled, enabled),
         show_date       = coalesce(p_show_date,     show_date),
         show_divider    = coalesce(p_show_divider,  show_divider),
         show_business   = coalesce(p_show_business, show_business),
         show_total      = coalesce(p_show_total,    show_total),
         compact         = coalesce(p_compact,       compact),
         updated_at      = now()
   where id = 1;

  return public.fc_get_line_settings();
end;
$$;

grant execute on function public.fc_set_line_settings(int, text, boolean, boolean, boolean, boolean, boolean, boolean, boolean)
  to anon, authenticated;


-- ============================================================================
--  [5] ส่งทดสอบทันที (แอปเรียกเวลากดปุ่ม "ส่งทดสอบเข้า LINE")
--      ส่งได้แม้ไม่มีรายการค้าง เพื่อเช็คว่าการเชื่อมต่อทำงาน
-- ============================================================================
create or replace function public.fc_line_send_now()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.fc_line_daily_reminder(true);
end;
$$;

grant execute on function public.fc_line_send_now() to anon, authenticated;


-- ============================================================================
--  [6] คำสั่งที่ใช้บ่อย (คัดลอกไปรันแยกได้)
--  ----------------------------------------------------------------------------
--  ทดสอบส่งทันที:            select public.fc_line_send_now();
--  ดูค่าตั้งค่าปัจจุบัน:       select public.fc_get_line_settings();
--  ดูผลการยิง HTTP ล่าสุด:    select id, status_code, content
--                             from net._http_response order by id desc limit 5;
-- ============================================================================

-- ============================================================
-- Finance Console — อัปเดตฐานข้อมูลสำหรับหน้า "ปล่อยกู้ · ลงทุน · ค้ำประกัน"
-- รันไฟล์นี้หนึ่งครั้งใน Supabase → SQL Editor
-- (โหมดทดลองในเครื่องไม่ต้องรัน จะทำงานได้เอง)
-- ============================================================

-- 1) เพิ่มคอลัมน์ใหม่ให้ตารางสัญญากู้เดิม -------------------------
alter table public.affiliate_loans add column if not exists borrower_type    text default 'affiliate'; -- affiliate | external (ในเครือ/นอกเครือ)
alter table public.affiliate_loans add column if not exists purpose          text;   -- กู้ไปทำอะไร
alter table public.affiliate_loans add column if not exists expected_outcome text;   -- ผลลัพธ์ที่คาดหวัง
alter table public.affiliate_loans add column if not exists secured          text default 'unsecured'; -- secured | unsecured
alter table public.affiliate_loans add column if not exists collateral_desc  text;   -- หลักประกันเป็นอะไร
alter table public.affiliate_loans add column if not exists collateral_value numeric default 0; -- มูลค่าหลักประกัน
alter table public.affiliate_loans add column if not exists term_months      integer default 0; -- ระยะเวลาส่งคืน (เดือน)
alter table public.affiliate_loans add column if not exists installment      numeric default 0; -- ผ่อนคืนงวดละ
alter table public.affiliate_loans add column if not exists borrower_history text;   -- ประวัติผู้กู้
alter table public.affiliate_loans add column if not exists status           text default 'active'; -- active | overdue | closed

-- 2) ประวัติการรับชำระคืน (ติดตามว่าคืนแล้วเท่าไหร่ / คงค้างเท่าไหร่) ----
create table if not exists public.loan_payments (
  id         uuid primary key default gen_random_uuid(),
  loan_id    text not null,
  amount     numeric not null default 0,
  pay_date   date,
  note       text,
  created_by text,
  created_at timestamptz default now()
);

-- 3) บันทึกการติดตามหนี้ / ทวงถาม (Request 6: บริษัทยืมไปแล้วยังไม่คืน) --
create table if not exists public.loan_followups (
  id         uuid primary key default gen_random_uuid(),
  loan_id    text not null,
  channel    text,        -- โทร / LINE / จดหมาย / ทนาย ฯลฯ
  fu_date    date,        -- วันที่ติดตาม
  detail     text,        -- ผลการติดตาม
  next_date  date,        -- นัดติดตามครั้งถัดไป
  created_by text,
  created_at timestamptz default now()
);

-- 4) เงินลงทุนในสินทรัพย์ หุ้น/ทอง ฯลฯ (เฉพาะ Owner) -------------------
create table if not exists public.investments (
  id            uuid primary key default gen_random_uuid(),
  asset_type    text,      -- stock | gold | fund | crypto | bond | property | other
  asset_name    text,
  units         text,
  buy_date      date,
  buy_price     numeric default 0,  -- ราคา ณ วันที่ซื้อ
  fee           numeric default 0,  -- ค่าธรรมเนียม/ค่าใช้จ่ายอื่น
  current_value numeric default 0,  -- มูลค่า ณ วันปัจจุบัน
  "current_date" date,              -- ราคา ณ วันที่ (ต้องใส่ "" เพราะ current_date เป็นคำสงวนของ Postgres)
  note          text,
  created_by    text,
  created_at    timestamptz default now()
);

-- 5) รายได้ค่าค้ำประกันให้ธุรกิจ (เฉพาะ Owner) ------------------------
create table if not exists public.guarantees (
  id              uuid primary key default gen_random_uuid(),
  beneficiary     text,      -- ค้ำให้ใคร
  guarantee_type  text,      -- name (ใช้ชื่อ) | asset (ยืมทรัพย์สินค้ำ)
  asset_desc      text,
  facility_amount numeric default 0, -- วงเงินที่ค้ำ
  fee_type        text,      -- percent | fixed
  fee_rate        numeric default 0, -- % ต่อปี
  fee_amount      numeric default 0, -- บาท/ปี (แบบคงที่)
  start_date      date,
  end_date        date,
  status          text default 'active',
  note            text,
  created_by      text,
  created_at      timestamptz default now()
);

-- 6) เปิด RLS + นโยบายให้แอปเข้าถึงได้ (ให้ตรงกับตารางอื่นที่ใช้อยู่) ----
--    *** ปรับ role/นโยบายให้ตรงกับที่ระบบเดิมของคุณตั้งไว้ ***
alter table public.loan_payments  enable row level security;
alter table public.loan_followups enable row level security;
alter table public.investments    enable row level security;
alter table public.guarantees     enable row level security;

do $$
declare t text;
begin
  foreach t in array array['loan_payments','loan_followups','investments','guarantees'] loop
    execute format('drop policy if exists app_all on public.%I;', t);
    execute format('create policy app_all on public.%I for all using (true) with check (true);', t);
  end loop;
end $$;

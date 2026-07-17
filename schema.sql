-- ============================================================
--  Finance Console — ระบบบริหารการเงินกลุ่มธุรกิจ
--  ไฟล์นี้ใช้สร้างตารางบน Supabase (ทำครั้งเดียว)
--
--  วิธีใช้:
--   1) เข้า supabase.com > เปิดโปรเจกต์
--   2) เมนูซ้าย  SQL Editor  >  New query
--   3) คัดลอกไฟล์นี้ทั้งหมดไปวาง แล้วกด  Run
-- ============================================================

-- ---------- ผู้ใช้งาน (username + password) ----------
create table if not exists app_users (
  id         text primary key,
  name       text not null,
  username   text not null unique,
  password   text not null,
  role       text not null default 'staff',   -- owner | staff
  scope      text not null default 'general',  -- all | general | hotel
  active     boolean default true,
  created_at timestamptz default now()
);

-- ---------- ธุรกิจ ----------
create table if not exists businesses (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  category   text not null default 'general', -- general | hotel
  active     boolean default true,
  created_at timestamptz default now()
);

-- ---------- รายรับ-รายจ่าย ----------
create table if not exists transactions (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid references businesses(id) on delete set null,
  kind         text not null,                 -- income | expense
  category     text,
  amount       numeric not null default 0,
  wht          numeric default 0,             -- หัก ณ ที่จ่าย (เฉพาะรายรับ)
  txn_date     date not null,
  recurrence   text default 'once',           -- once | monthly
  recurring_id text,                           -- ผูกกับรายการประจำ (ถ้าสร้างอัตโนมัติ)
  is_paid      boolean default false,
  paid_date    date,
  note         text,
  created_by   text,
  created_at   timestamptz default now()
);

-- ---------- รายการประจำทุกเดือน (แม่แบบ) ----------
create table if not exists recurring_items (
  id          text primary key default gen_random_uuid()::text,
  business_id uuid references businesses(id) on delete set null,
  kind        text not null,                 -- income | expense
  category    text,
  amount      numeric not null default 0,
  wht         numeric default 0,
  pay_day     int not null default 1,        -- วันที่ของเดือน (1-31)
  note        text,
  active      boolean default true,
  created_at  timestamptz default now()
);

-- ---------- ปล่อยกู้ธุรกิจในเครือ ----------
create table if not exists affiliate_loans (
  id              uuid primary key default gen_random_uuid(),
  business_name   text not null,
  business_detail text,
  principal       numeric default 0,
  interest_rate   numeric default 0,          -- %/ปี
  contract_detail text,
  start_date      date,
  note            text,
  file_name       text,
  file_data       text,                        -- ไฟล์สัญญา (data URL)
  created_by      text,
  created_at      timestamptz default now()
);

-- ---------- คลังเอกสารสัญญา ----------
create table if not exists documents (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  doc_type      text default 'other',          -- lease_land | lease_building | loan | other
  business_name text,
  note          text,
  file_name     text,
  file_data     text,                            -- ไฟล์เอกสาร (data URL)
  created_by    text,
  created_at    timestamptz default now()
);

-- ---------- โอนเงินให้ Owner ----------
create table if not exists owner_transfers (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid references businesses(id) on delete set null,
  source        text default 'rent',         -- rent | business
  amount        numeric not null default 0,
  transfer_date date not null,
  bank_account  text,
  note          text,
  created_by    text,
  created_at    timestamptz default now()
);

-- ---------- เงินยืม / จ่ายคืน Owner ----------
create table if not exists owner_loans (
  id           uuid primary key default gen_random_uuid(),
  direction    text not null,                -- borrow | repay
  amount       numeric not null default 0,
  loan_date    date not null,
  bank_account text,
  note         text,
  created_by   text,
  created_at   timestamptz default now()
);

-- ============================================================
--  ข้อมูลเริ่มต้น (seed)
--  *** สำคัญ: เปลี่ยนรหัสผ่านทันทีหลังเข้าใช้งานครั้งแรก ***
-- ============================================================
insert into app_users (id, name, username, password, role, scope, active) values
  ('u_owner',  'เจ้าของกิจการ',  'owner',  'owner1234',  'owner', 'all',     true),
  ('u_admin2', 'ผู้บันทึก 1',    'admin2', 'admin2pass', 'staff', 'general', true),
  ('u_admin3', 'ผู้บันทึกโรงแรม','admin3', 'admin3pass', 'staff', 'hotel',   true)
on conflict (id) do nothing;

insert into businesses (name, category, active) values
  ('ซักรีด',                 'general', true),
  ('คลีนนิ่ง',               'general', true),
  ('พร็อพเพอร์ตี้ (ขายบ้าน)', 'general', true),
  ('โรงแรม',                 'hotel',   true)
on conflict do nothing;

-- ============================================================
--  เปิดสิทธิ์ให้แอปอ่าน/เขียน (ระบบทีมภายใน)
-- ============================================================
alter table app_users       enable row level security;
alter table businesses      enable row level security;
alter table transactions    enable row level security;
alter table recurring_items enable row level security;
alter table owner_transfers enable row level security;
alter table owner_loans     enable row level security;
alter table affiliate_loans enable row level security;
alter table documents       enable row level security;

do $$
declare t text;
begin
  foreach t in array array['app_users','businesses','transactions','recurring_items','owner_transfers','owner_loans','affiliate_loans','documents']
  loop
    execute format('drop policy if exists "allow all" on %I;', t);
    execute format('create policy "allow all" on %I for all using (true) with check (true);', t);
  end loop;
end $$;

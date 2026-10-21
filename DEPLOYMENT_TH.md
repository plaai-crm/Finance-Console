# คู่มือนำ Finance Console เวอร์ชันแก้ไขขึ้นใช้งาน

แพ็กเกจนี้เตรียมไว้สำหรับแอปของเจ้าของเงิน (Wealth Owner) โดยแยกการแก้หน้าเว็บออกจากการแก้ฐานข้อมูล เพื่อให้ทดสอบและย้อนกลับได้ ไม่ควรนำไฟล์ขึ้นระบบจริงหรือรัน SQL ระหว่างที่มีผู้ใช้งานกำลังบันทึกข้อมูล

## สิ่งที่แก้แล้ว

- Dashboard เปลี่ยนเป็นเกณฑ์เงินสด: นับเฉพาะรายการที่รับ/จ่ายแล้ว และจัดเดือนตาม `paid_date` (ถ้าเป็นข้อมูลเก่าที่ไม่มีวันที่รับ/จ่าย จะใช้ `txn_date` เป็น fallback)
- รายการค้างรับและค้างจ่ายยังคงแยกจากกระแสเงินสด
- หน้า Wealth ได้แก่ เงิน Owner, เงินให้กู้, การลงทุน, ค้ำประกัน และเอกสารสำคัญ ถูกจำกัดเฉพาะ Owner ทั้งหน้าเว็บและ RLS
- ปิดธุรกิจด้วย `active=false` แทนการลบ เพื่อรักษาประวัติ
- แก้สูตรมูลค่าการลงทุน: รองรับมูลค่า 0, เลือกข้อมูลล่าสุดตามวันที่ และ annualize ช่วงที่ข้ามปี
- ระบุชัดว่าผลตอบแทนเป็นประมาณการและไม่รวมเงินปันผล/เงินถอน/ภาษี/กระแสเงินสดระหว่างงวด
- สัญญาที่ปิดแล้วไม่รวมในยอดหนี้ active และระบุว่าสูตรเงินกู้เป็นดอกเบี้ยคงที่ตลอดสัญญา
- เพิ่มวันที่จ่ายเงินจริงสำหรับรายจ่าย
- แก้การเปลี่ยนไฟล์: บันทึกฐานข้อมูลให้สำเร็จก่อนลบไฟล์เดิม และลบไฟล์ใหม่ทิ้งหากบันทึกไม่สำเร็จ
- เพิ่ม `storage_path`, recurring sync RPC, actor stamp, audit trail, explicit grants และ private Storage policy
- หน้าเว็บอ่านข้อมูลผู้ใช้เฉพาะชื่อ บทบาท scope และสถานะ; คอลัมน์รหัสผ่าน/แฮชไม่เปิดให้ browser
- พรีวิว LINE ใช้ช่วง “วันนี้ถึงวันแจ้งล่วงหน้า” และเคารพสถานะแจ้งแล้ว/เลื่อนจ่าย

## ไฟล์

- `index.html` — หน้าเว็บเวอร์ชันแก้ไข
- `wealth_fix_20261020.sql` — migration หลัก (ไม่ลบข้อมูลธุรกิจ)
- `rollback_wealth_fix_20261020.sql` — rollback เชิงปฏิบัติการ; เก็บคอลัมน์และ audit log ไว้
- `static_audit.mjs` และ `logic_tests.mjs` — ชุดตรวจสอบอัตโนมัติ

## ก่อนเปลี่ยนระบบจริง

1. ยืนยันว่าไม่มีผู้ใช้กำลังบันทึกข้อมูล และประกาศช่วงหยุดใช้งานสั้น ๆ
2. สำรองฐานข้อมูลผ่าน Supabase Dashboard และเก็บ `index.html` ตัวที่ใช้งานจริงไว้เป็น rollback artifact
3. ทดสอบ migration ใน staging/สำเนาโปรเจกต์ก่อน
4. ตรวจข้อมูลเดิมแบบ read-only ด้วย SQL ด้านล่าง หากได้จำนวนมากกว่า 0 ให้ตรวจรายการก่อนรัน migration

```sql
select count(*) as paid_without_paid_date
from public.transactions
where coalesce(is_paid,false)=true and paid_date is null;

select count(*) as invalid_transaction_amounts
from public.transactions
where amount<0 or coalesce(wht,0)<0 or coalesce(wht,0)>amount;

select count(*) as invalid_investments
from public.investments
where coalesce(buy_price,0)<=0 or coalesce(fee,0)<0 or coalesce(current_value,0)<0;

select schemaname,tablename,policyname,roles,cmd,qual,with_check
from pg_policies
where (schemaname='public' and tablename in
  ('owner_loans','affiliate_loans','loan_payments','loan_followups','investments',
   'investment_values','guarantees','documents','monthly_expense_plan'))
   or (schemaname='storage' and tablename='objects')
order by schemaname,tablename,policyname;
```

ข้อควรดูเป็นพิเศษ: หาก `storage.objects` มี policy อื่นที่อนุญาตกว้างและครอบคลุม bucket `finance-documents` ต้องแก้/เอา policy นั้นออกด้วย มิฉะนั้น policy แบบ owner-only ใน migration จะไม่สามารถหักล้าง policy ที่กว้างกว่าได้ (Postgres รวม permissive policies แบบ OR)

## ลำดับการติดตั้งที่แนะนำ

1. ปิดการส่ง LINE ชั่วคราวจากหน้า Settings หรือ config ฝั่งฐานข้อมูล
2. รัน `wealth_fix_20261020.sql` ใน staging
3. รันคำสั่งตรวจหลัง migration:

```sql
select tablename,policyname,roles,cmd
from pg_policies
where schemaname='public' and tablename in
  ('owner_loans','affiliate_loans','loan_payments','loan_followups','investments',
   'investment_values','guarantees','documents','monthly_expense_plan')
order by tablename,policyname;

select id,name,public,file_size_limit
from storage.buckets where id='finance-documents';

select routine_name
from information_schema.routines
where routine_schema='public' and routine_name='fc_api_sync_recurring_item';
```

4. นำ `index.html` ขึ้น staging โดยคง URL เดิมของ staging
5. ทดสอบตาม checklist ด้านล่างด้วยบัญชี Owner และ Staff อย่างน้อยหนึ่งบัญชีต่อ scope
6. เมื่อผ่านแล้ว ทำ backup ของ production อีกครั้ง รัน migration และสลับ `index.html` ในช่วงหยุดใช้งาน
7. เปิด LINE กลับหลังทดสอบ “ส่งทดสอบ” สำเร็จเพียงหนึ่งครั้ง

หมายเหตุ: Supabase เปลี่ยนพฤติกรรม Data API โดยตารางใหม่ไม่ถูก expose อัตโนมัติและต้องมี explicit grants ตั้งแต่ 30 ตุลาคม 2026 เป็นต้นไป migration นี้จึงระบุ grants ของ `authenticated` และถอนสิทธิ์ `anon` ไว้ชัดเจน

## Checklist ยอมรับงาน

- Owner เข้าดูเงินให้กู้/ลงทุน/ค้ำประกัน/เอกสารได้
- Staff ทุก scope ไม่เห็นเมนู Wealth และ query ตาราง Wealth ถูก RLS ปฏิเสธ
- Staff ทั่วไปเห็นเฉพาะธุรกิจทั่วไป; Staff โรงแรมเห็นเฉพาะโรงแรม
- เพิ่มรายรับ/รายจ่ายค้างไว้ก่อน แล้วกดรับ/จ่าย: Dashboard ย้ายยอดเข้าเดือนของวันที่รับ/จ่ายจริง
- ปิดธุรกิจ: ประวัติยังดูได้ แต่สร้างรายการใหม่ให้ธุรกิจนั้นไม่ได้
- แก้แม่แบบ recurring: รายการอนาคตที่ยังไม่จ่ายเปลี่ยนหมวด จำนวน วัน ธุรกิจ WHT และหมายเหตุครบ
- เปลี่ยนเอกสาร: ถ้าบันทึก DB ล้มเหลว ไฟล์เดิมยังเปิดได้; ถ้าสำเร็จ ไฟล์ใหม่เปิดผ่าน signed URL ได้
- ใส่มูลค่าการลงทุน 0 ได้และแสดงผลตอบแทน -100%
- สัญญาที่ตั้งสถานะ “ปิด” ไม่รวมในยอดคงค้าง active
- พรีวิว LINE แสดงรายการ overdue และรายการที่ครบกำหนดภายในช่วงวันแจ้งล่วงหน้า ไม่ใช่เฉพาะวันปลายช่วง
- `finance_audit_log` มี actor UUID สำหรับการเพิ่ม/แก้/ลบจากผู้ใช้ และไม่มี `file_data`/รหัสผ่านใน JSON

## Rollback

หากเกิดปัญหา:

1. คืน `index.html` ตัวเดิมก่อน
2. รัน `rollback_wealth_fix_20261020.sql`
3. ตรวจการเข้าใช้งาน Owner/Staff และตรวจ LINE โดยยังไม่ส่งจริง

Rollback นี้ไม่ลบคอลัมน์ใหม่และไม่ลบ `finance_audit_log` เพื่อรักษาหลักฐานและลดความเสี่ยงข้อมูลสูญหาย แต่จะคืนสิทธิ์ lending/documents แบบเดิมที่กว้างกว่า จึงควรใช้เฉพาะเพื่อกู้การให้บริการชั่วคราว

## เอกสารอ้างอิง Supabase

- Data API grants: <https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically>
- Database security / grants + RLS: <https://supabase.com/docs/guides/database/secure-data>
- Row Level Security: <https://supabase.com/docs/guides/database/postgres/row-level-security>
- Storage access control: <https://supabase.com/docs/guides/storage/security/access-control>

import fs from 'node:fs';
import vm from 'node:vm';

const html=fs.readFileSync('index.html','utf8');
const migration=fs.readFileSync('wealth_fix_20261020.sql','utf8');
const rollback=fs.readFileSync('rollback_wealth_fix_20261020.sql','utf8');
const failures=[];
const ok=(cond,msg)=>{if(!cond)failures.push(msg);};

const ids=[...html.matchAll(/\sid="([^"]+)"/g)].map(m=>m[1]);
ok(new Set(ids).size===ids.length,'พบ HTML id ซ้ำ');
ok(html.includes('@supabase/supabase-js@2.55.0'),'Supabase JS ไม่ได้ล็อกเวอร์ชัน');
ok(!html.includes("sb.rpc('fc_login'"),'หน้าเว็บยังเรียก legacy login');
ok(!/sb\.rpc\('fc_(?!api_)/.test(html),'หน้าเว็บยังเรียก RPC ภายในที่ไม่ผ่าน authorization wrapper');
ok(!html.includes('markReminded(due)'),'Dashboard ยังทำเครื่องหมายว่า LINE แจ้งแล้ว');
ok(!/const todayISO=.*toISOString/.test(html),'todayISO ยังใช้ UTC');
ok(html.includes("type:'password',autocomplete:'new-password'"),'ช่องรหัสผ่านผู้ใช้ยังไม่ซ่อนข้อความ');
ok(html.includes("finance-console-auth"),'ไม่พบ Auth Edge Function ในหน้าเว็บ');
ok(html.includes("finance-documents"),'ไม่พบ private document storage');
ok(html.includes("storage_path"),'หน้าเว็บยังไม่รองรับ storage_path');
ok(html.includes("totalDue=principal+interest"),'ยอดเงินกู้ยังไม่รวมดอกเบี้ย');
ok(html.includes("fc_api_materialize_recurring"),'รายการประจำยังไม่ได้สร้างแบบ atomic');
ok(html.includes(".delete().eq('id',id).select('id')"),'การลบยังอาจรายงานสำเร็จทั้งที่ RLS ไม่ได้ลบ');
ok(html.includes("const cashDate=t=>t.is_paid?(t.paid_date||t.txn_date||''):''"),'Dashboard ยังไม่ได้ใช้วันที่รับ/จ่ายเงินจริง');
ok(html.includes('const canLending=()=>isOwner()'),'ข้อมูล Wealth ยังไม่ได้จำกัดหน้าเว็บเฉพาะ Owner');
ok(!html.includes("Store.remove('businesses',b.id)"),'ยังลบธุรกิจจริงแทนการปิดใช้งาน');
ok(html.includes('if(l.file_data||l.storage_path)'),'การ์ดสัญญากู้ยังไม่แสดงไฟล์จาก Storage');
ok(html.includes('await finalizeUpload(f)')&&html.includes('await rollbackUpload(f)'),'การเปลี่ยนไฟล์ยังไม่มี finalize/rollback');
ok(html.includes("valInput.value===''||v<0"),'มูลค่าการลงทุนศูนย์ยังถูกปฏิเสธ');
ok(html.includes('แม่แบบบันทึกแล้ว แต่ซิงก์รายการอนาคตไม่สำเร็จ'),'ยังไม่แยก partial success ของรายการประจำ');
ok(migration.includes('add column if not exists storage_path text'),'Migration ยังไม่เพิ่ม storage_path');
ok(migration.includes('fc_api_sync_recurring_item'),'Migration ยังไม่มี recurring sync RPC');
ok(migration.includes('finance_audit_log'),'Migration ยังไม่มี audit trail');
ok(migration.includes("bucket_id='finance-documents' and public.fc_is_owner()"),'Storage policy ยังไม่จำกัด Owner');
ok(!migration.includes('price_date'),'Migration ยังอ้างคอลัมน์ price_date ที่ไม่แน่นอน');
ok(migration.includes('revoke delete on table public.businesses from authenticated'),'Migration ยังไม่ป้องกันการลบธุรกิจ');
ok(!/to anon[\s\S]{0,80}using\s*\(true\)/i.test(migration),'Migration ยังมี RLS แบบ anon/allow-all');
for(const [name,sql] of [['migration',migration],['rollback',rollback]]){
  const tags=[...sql.matchAll(/\$[a-z_]*\$/gi)].map(m=>m[0]);
  const counts=tags.reduce((m,t)=>(m[t]=(m[t]||0)+1,m),{});
  ok(Object.values(counts).every(n=>n%2===0),`${name}: dollar-quote เปิด/ปิดไม่ครบ`);
  ok(/\bbegin;[\s\S]*\bcommit;/i.test(sql),`${name}: ไม่มี transaction ครอบ DDL`);
}

const scripts=[...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)].map(m=>m[1]).filter(s=>s.trim());
for(const [i,source] of scripts.entries()){
  try{new vm.Script(source,{filename:`inline-${i}.js`});}catch(e){failures.push(`JavaScript block ${i+1}: ${e.message}`);}
}

if(failures.length){console.error(failures.join('\n'));process.exit(1);}
console.log(JSON.stringify({status:'pass',html_ids:ids.length,inline_scripts:scripts.length,bytes:Buffer.byteLength(html)}));

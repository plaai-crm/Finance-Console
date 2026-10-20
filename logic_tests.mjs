import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const html=fs.readFileSync('index.html','utf8');

function extractFunction(name){
  const start=html.indexOf(`function ${name}(`);
  if(start<0)throw new Error(`ไม่พบ function ${name}`);
  const brace=html.indexOf('{',start);
  let depth=0,quote=null,escape=false;
  for(let i=brace;i<html.length;i++){
    const ch=html[i],next=html[i+1];
    if(quote){
      if(escape)escape=false;
      else if(ch==='\\')escape=true;
      else if(ch===quote)quote=null;
      continue;
    }
    if(ch==='"'||ch==="'"||ch==='`'){quote=ch;continue;}
    if(ch==='/'&&next==='/'){i=html.indexOf('\n',i);if(i<0)break;continue;}
    if(ch==='/'&&next==='*'){i=html.indexOf('*/',i+2)+1;continue;}
    if(ch==='{')depth++;
    if(ch==='}'&&--depth===0)return html.slice(start,i+1);
  }
  throw new Error(`ปิดวงเล็บ function ${name} ไม่ครบ`);
}

const context=vm.createContext({
  console,Date,Math,Number,String,
  TH_M:['ม.ค.','ก.พ.','มี.ค.','เม.ย.','พ.ค.','มิ.ย.','ก.ค.','ส.ค.','ก.ย.','ต.ค.','พ.ย.','ธ.ค.'],
  TH_MF:['มกราคม','กุมภาพันธ์','มีนาคม','เมษายน','พฤษภาคม','มิถุนายน','กรกฎาคม','สิงหาคม','กันยายน','ตุลาคม','พฤศจิกายน','ธันวาคม'],
  LINE_DIV:'━━━━━━━━━━━━',
  todayISO:()=> '2026-10-20',
  daysUntil:iso=>Math.round((new Date(iso+'T00:00:00')-new Date('2026-10-20T00:00:00'))/86400000),
  yrOf:iso=>iso?Number(String(iso).slice(0,4)):null,
  fmtMoneyExact:n=>Number(n||0).toLocaleString('en-US',{maximumFractionDigits:2})
});

for(const name of ['addMonths','yearsBetween','investCalc','loanCalc','assetSeries','buildMonthlyExpenseGroupMessage']){
  vm.runInContext(extractFunction(name),context,{filename:`${name}.js`});
}

const closed=context.loanCalc({id:'L1',principal:100000,interest_rate:12,term_months:12,start_date:'2025-01-01',status:'closed'},[]);
assert.equal(closed.contractualOutstanding,112000);
assert.equal(closed.outstanding,0,'สัญญาที่ปิดแล้วต้องไม่อยู่ในยอดคงค้าง active');

const newerCurrent=context.assetSeries({id:'I1',buy_price:100,fee:0,buy_date:'2020-01-01',current_value:150,current_date:'2026-10-20'},[
  {id:'V1',investment_id:'I1',year:2025,value:120}
]);
assert.equal(newerCurrent.latest,150,'มูลค่าปัจจุบันที่ใหม่กว่าต้องชนะค่าสิ้นปีเก่า');

const zeroCurrent=context.assetSeries({id:'I2',buy_price:100,fee:0,buy_date:'2020-01-01',current_value:0,current_date:'2026-10-20'},[]);
assert.equal(zeroCurrent.latest,0,'มูลค่าศูนย์ต้องไม่ย้อนกลับไปใช้ต้นทุน');
assert.equal(zeroCurrent.totRet,-1);

const gap=context.assetSeries({id:'I3',buy_price:100,fee:0,buy_date:'2020-01-01',current_value:'',current_date:'2022-12-31'},[
  {id:'V3',investment_id:'I3',year:2022,value:121}
]);
assert.ok(Math.abs(gap.gm-0.1)<1e-10,'ช่วงข้ามปีต้อง annualize ตามจำนวนปีจริง');

const preview=context.buildMonthlyExpenseGroupMessage([
  {category:'รายการ A',recurrence:'monthly',pay_day:21,amount:100,active:true},
  {category:'รายการ B',recurrence:'monthly',pay_day:23,amount:200,active:true},
  {category:'รายการนอกช่วง',recurrence:'monthly',pay_day:24,amount:300,active:true}
],'2026-10','',3,'2026-10-20');
assert.match(preview,/รายการ A/);
assert.match(preview,/รายการ B/);
assert.doesNotMatch(preview,/รายการนอกช่วง/);

console.log(JSON.stringify({status:'pass',tests:9}));

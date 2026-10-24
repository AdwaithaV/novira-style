import {admin,json} from '../_shared/common.ts';
const escape=(x:unknown)=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
Deno.serve(async req=>{
 if(req.method!=='POST'||req.headers.get('x-cron-secret')!==Deno.env.get('NOVIRA_CRON_SECRET'))return json({error:'Unauthorized'},401);
 const key=Deno.env.get('RESEND_API_KEY'),from=Deno.env.get('EMAIL_FROM'),owner=Deno.env.get('OWNER_EMAIL');
 if(!key||!from||!owner)return json({error:'Missing email settings'},500);
 // Paid owner emails are backfilled on every scheduler run, idempotently.
 const {data:paid}=await admin.from('novira_checkouts').select('order_id').eq('state','paid').limit(50);
 for(const c of paid||[])await admin.from('novira_email_outbox').upsert({order_id:c.order_id,kind:'owner_paid',recipient:owner},{onConflict:'order_id,kind',ignoreDuplicates:true});
 const {data:rows,error}=await admin.from('novira_email_outbox').select('*').is('sent_at',null).lt('attempts',8).order('id',{ascending:true}).limit(20);
 if(error)return json({error:error.message},500);
 let sent=0,failed=0;
 for(const job of rows||[]){
  const lockUntil=new Date(Date.now()+120000).toISOString();
  // Update with optimistic claim. A competing scheduler won't send the same job concurrently.
  let q=admin.from('novira_email_outbox').update({locked_until:lockUntil,attempts:job.attempts+1}).eq('id',job.id).is('sent_at',null).eq('attempts',job.attempts);
  const {data:claimed}=await q.select('id').maybeSingle();if(!claimed)continue;
  try{
   const {data:o,error:oe}=await admin.from('orders').select('order_code,customer,estimated_total,status,courier_name,tracking_number,tracking_url').eq('id',job.order_id).single();
   if(oe||!o)throw Error('Order unavailable');
   const subject=job.kind==='shipped'?`NOVIRA STYLE ${o.order_code} has shipped`:job.kind==='owner_paid'?`New paid order ${o.order_code}`:`Your NOVIRA STYLE payment is confirmed: ${o.order_code}`;
   const details=job.kind==='shipped'?`Courier: ${escape(o.courier_name)}<br>Tracking number: ${escape(o.tracking_number)}<br>${o.tracking_url&&/^https:\/\//.test(o.tracking_url)?`<a href="${escape(o.tracking_url)}">Track shipment</a>`:''}`:`Order reference: ${escape(o.order_code)}<br>Total: ₹${escape(o.estimated_total)}<br>Status: ${escape(o.status)}`;
   const html=`<div style="font-family:Arial,sans-serif"><h2>NOVIRA STYLE</h2><p>${job.kind==='owner_paid'?'A customer has completed payment.':job.kind==='shipped'?'Your order is on its way!':'Thank you for shopping with us. Your payment was verified.'}</p><p>${details}</p><p>For support: <a href="https://www.instagram.com/stylenovira/">NOVIRA STYLE Instagram</a></p></div>`;
   const r=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json','Idempotency-Key':`novira-${job.id}`},body:JSON.stringify({from,to:[job.recipient],subject,html})});
   if(!r.ok)throw Error(`Resend ${r.status}: ${(await r.text()).slice(0,300)}`);
   await admin.from('novira_email_outbox').update({sent_at:new Date().toISOString(),last_error:null,locked_until:null}).eq('id',job.id);sent++;
  }catch(e){failed++;await admin.from('novira_email_outbox').update({last_error:String(e).slice(0,400),locked_until:null}).eq('id',job.id);}
 }
 return json({sent,failed});
});

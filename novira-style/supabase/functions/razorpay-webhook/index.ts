import {admin,json,err,hmacHex,equalHex,verifyCaptured,attemptExpire} from '../_shared/common.ts';
Deno.serve(async req=>{
 if(req.method!=='POST')return json({error:'POST required'},405);
 try{
  const raw=await req.text();if(raw.length>200000)throw Error('Webhook too large');
  const sig=req.headers.get('x-razorpay-signature')||'';
  const expected=await hmacHex(raw,Deno.env.get('RAZORPAY_WEBHOOK_SECRET')!);
  if(!equalHex(expected,sig))return json({error:'Invalid signature'},401);
  const eventId=req.headers.get('x-razorpay-event-id')||'';
  if(!eventId||eventId.length>200)throw Error('Webhook event ID missing');
  const ev=JSON.parse(raw);
  if(ev.event!=='payment.captured'&&ev.event!=='order.paid')return json({ok:true,ignored:true});
  const p=ev.payload?.payment?.entity;
  if(!p?.id||!p?.order_id)return json({ok:true,ignored:true});
  const {data:c,error}=await admin.from('novira_checkouts').select('*').eq('razorpay_order_id',p.order_id).maybeSingle();
  if(error||!c)throw Error('Unknown checkout');
  await verifyCaptured(p.id,p.order_id,c.amount_paise);
  await attemptExpire();
  const {data:result,error:markError}=await admin.rpc('novira_mark_paid',{p_razorpay_order:p.order_id,p_payment:p.id,p_amount_paise:c.amount_paise});
  if(markError)throw markError;
  await admin.from('novira_webhook_receipts').upsert({event_id:eventId},{onConflict:'event_id',ignoreDuplicates:true});
  return json({ok:true,state:result.state});
 }catch(e){return err(e)}
});

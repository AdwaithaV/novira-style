import {admin,cors,json,err,getUser,razor,attemptExpire} from '../_shared/common.ts';
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response('',{headers:cors});
 if(req.method!=='POST')return json({error:'Method not allowed'},405);
 try {
  const user=await getUser(req);
  await attemptExpire();
  const {customer,items,turnstile_token}=await req.json();
  if(typeof turnstile_token!=='string'||!turnstile_token)throw Error('Complete security verification');
  const secret=Deno.env.get('TURNSTILE_SECRET_KEY');if(!secret)throw Error('Security check not configured');
  const verification=await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({secret,response:turnstile_token})});
  const captcha=await verification.json();if(!captcha.success)throw Error('Security verification failed');
  if(!Array.isArray(items)||items.length>20||!customer||typeof customer!=='object')throw Error('Invalid checkout');
  const payload={...customer,email:user.email}; // Never trust customer email from browser.
  const {data,error}=await admin.rpc('novira_reserve_checkout',{p_user:user.id,p_customer:payload,p_items:items});
  if(error)throw error;
  // Server-side amount comes only from locked DB price and shipping settings.
  let rz;
  try {rz=await razor('orders',{method:'POST',body:JSON.stringify({amount:data.amount_paise,currency:'INR',receipt:data.order_code,notes:{checkout_id:data.checkout_id}})});}
  catch(e){console.error('Razorpay create failed; reservation will expire',e);throw Error('Payment service unavailable; your temporary hold will expire automatically');}
  const {error:attachError}=await admin.rpc('novira_attach_razorpay',{p_checkout:data.checkout_id,p_razorpay_order:rz.id});
  if(attachError)throw attachError;
  return json({key_id:Deno.env.get('RAZORPAY_KEY_ID'),razorpay_order_id:rz.id,amount_paise:data.amount_paise,order_code:data.order_code,tracking_token:data.tracking_token});
 }catch(e){return err(e)}
});

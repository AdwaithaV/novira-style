import {admin,cors,json,err,getUser,hmacHex,equalHex,verifyCaptured,attemptExpire} from '../_shared/common.ts';
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response('',{headers:cors});
 if(req.method!=='POST')return json({error:'Method not allowed'},405);
 try{
  const user=await getUser(req);
  const {razorpay_order_id,razorpay_payment_id,razorpay_signature}=await req.json();
  if(![razorpay_order_id,razorpay_payment_id,razorpay_signature].every(x=>typeof x==='string'&&x.length<256))throw Error('Invalid payment response');
  const {data:c,error:ce}=await admin.from('novira_checkouts').select('*').eq('razorpay_order_id',razorpay_order_id).eq('user_id',user.id).single();
  if(ce||!c)throw Error('Checkout not found');
  const expected=await hmacHex(`${razorpay_order_id}|${razorpay_payment_id}`,Deno.env.get('RAZORPAY_KEY_SECRET')!);
  if(!equalHex(expected,razorpay_signature))throw Error('Payment signature verification failed');
  await verifyCaptured(razorpay_payment_id,razorpay_order_id,c.amount_paise);
  // Expired reservations are treated as payment_review, never confirmed automatically.
  await attemptExpire();
  const {data,error}=await admin.rpc('novira_mark_paid',{p_razorpay_order:razorpay_order_id,p_payment:razorpay_payment_id,p_amount_paise:c.amount_paise});
  if(error)throw error;
  return json(data);
 }catch(e){return err(e)}
});

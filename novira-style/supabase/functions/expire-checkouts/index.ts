import {admin,json} from '../_shared/common.ts';
Deno.serve(async req=>{
 if(req.method!=='POST'||req.headers.get('x-cron-secret')!==Deno.env.get('NOVIRA_CRON_SECRET'))return json({error:'Unauthorized'},401);
 const {data,error}=await admin.rpc('novira_expire_checkouts');
 if(error)return json({error:error.message},500);
 return json({expired:data});
});

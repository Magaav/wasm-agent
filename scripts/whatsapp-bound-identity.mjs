// Atomic page-side identity proof, shared by bound snapshot/media reads.
import {parseAccount,accountMatches} from './whatsapp-store-core.mjs';
export function boundIdentityExpression(account){
 if(!account)return '';
 return `{
  const PN_SUFFIXES=['@s.whatsapp.net','@c.us'];
  const parseAccount=${parseAccount.toString()},accountMatches=${accountMatches.toString()};
  let me;try{me=window.require('WAWebUserPrefsMeUser')}catch{return JSON.stringify({error:'account_unproven'})}
  const ids=[];for(const method of ['getMaybeMePnUser','getMaybeMeLidUser'])try{const v=me[method]?.();const id=String(v?._serialized||v?.id?._serialized||v||'');if(id)ids.push(id)}catch{}
  if(!ids.some(id=>accountMatches(${JSON.stringify(account)},id)))return JSON.stringify({error:ids.length?'account_mismatch':'account_unproven'});
 }`;
}

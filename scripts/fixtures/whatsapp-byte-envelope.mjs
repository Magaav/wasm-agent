// Synthetic protocol fixtures only; actual HTTP byte count includes the LF.
export function bytePage(input){
 const rows=(input.messages??[]).map((m,index)=>({...m,cursor:m.cursor??input.messages.length-index}));const data={...input,messages:rows,page_version:2,byte_limit:4*1024*1024,oversized_rows:[],rows_delivered:rows.length,inline_complete:true,order:rows.map((m,index)=>({cursor:m.cursor??rows.length-index,kind:'inline',index})),next_before:input.next_before??0,encoded_bytes:0};
 for(let i=0;i<5;i++){const text=JSON.stringify(data)+'\n',n=Buffer.byteLength(text);if(data.encoded_bytes===n)return text;data.encoded_bytes=n;}throw Error('fixture encoding did not stabilize');
}

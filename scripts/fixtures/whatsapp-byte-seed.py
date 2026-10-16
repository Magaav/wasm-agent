"""Synthetic-only journal seed/update for byte-page tests. No device/session access."""
import json
import sqlite3
import sys
mode,db=sys.argv[1:3]
con=sqlite3.connect(db,timeout=10)
chat='200@s.whatsapp.net'
def insert(id,body,audio=0):
    con.execute('INSERT INTO messages(account,generation,chat,id,sender,body,sent,observed,own,history,audio,unsupported,raw) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',('100@s.whatsapp.net',1,chat,id,chat,body,110,110,0,0,audio,'',None))
if mode=='base':
    for i in range(1,701): insert('b-'+str(i),str(i).zfill(10)+':'+'x'*39989)
elif mode=='late': insert('late','new insertion after first older-page window')
elif mode=='extra':
    insert('escaped',('<>"\\\x00é🗣'*2000))
    insert('huge',('Hé🗣<>"\\'*500000),1)
    con.execute("INSERT INTO audio(account,generation,chat,id,state,reason,transcript,language) VALUES(?,?,?,?,?,?,?,?)",('100@s.whatsapp.net',1,chat,'huge','transcribed','',('transcrição 🗣<>"\\'*30000),'pt'))
    con.execute("INSERT INTO chat_holds VALUES(?,?,?,?)",('100@s.whatsapp.net',1,chat,'hold<>"\\字'*20000))
    con.execute("INSERT INTO outbox(account,generation,chat,source,part,body,send_id,state,ack) VALUES(?,?,?,?,?,?,?,?,?)",('100@s.whatsapp.net',1,chat,'huge',0,'fixture','send-id','unknown','ack<>"\\字'*20000))
elif mode=='badmeta':
    value=json.loads(con.execute('SELECT value FROM config WHERE id=1').fetchone()[0]);value['account']='x'*300+'@s.whatsapp.net';con.execute('UPDATE config SET value=? WHERE id=1',(json.dumps(value),))
elif mode=='mutate': con.execute("UPDATE messages SET body='changed after descriptor' WHERE id='huge'")
else: raise ValueError('unsupported synthetic mode')
con.commit();con.close()

// Cooperative OS-held SQLite transaction. No PID/age/death inference.
import path from 'node:path';import {DatabaseSync} from 'node:sqlite';
export function withRecoveryLease(store,identity,body){
 if(!identity?.session||!identity.run||!identity.boot)throw Error('recovery_lease_exact_execution_identity_required');
 const db=new DatabaseSync(path.join(store,'recovery-target-lease.sqlite'));
 try{db.exec('PRAGMA busy_timeout=0; CREATE TABLE IF NOT EXISTS lease(id INTEGER PRIMARY KEY, identity TEXT)');
 try{db.exec('BEGIN IMMEDIATE');}catch{throw Error('recovery_target_lease_held');}
 db.prepare('INSERT OR REPLACE INTO lease VALUES(1,?)').run(JSON.stringify(identity));
 try{const value=body();db.exec('COMMIT');return value;}catch(e){db.exec('ROLLBACK');throw e;}
 }finally{db.close();}
}

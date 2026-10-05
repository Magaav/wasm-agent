//! Two-sided enrollment. Request data cannot grant a role or execution authority.
use super::*;

pub(super) fn schema(c: &Connection) -> rusqlite::Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS bindings (
      id TEXT PRIMARY KEY, node_id TEXT NOT NULL, public_key TEXT NOT NULL,
      code TEXT NOT NULL UNIQUE, digest TEXT NOT NULL, request TEXT NOT NULL,
      state TEXT NOT NULL, revision INTEGER NOT NULL, actor TEXT NOT NULL,
      pairing_expires INTEGER NOT NULL, consent_expires INTEGER NOT NULL, at INTEGER NOT NULL);
      CREATE UNIQUE INDEX IF NOT EXISTS binding_live_node ON bindings(node_id)
        WHERE state IN ('pending','accepted');
      CREATE TABLE IF NOT EXISTS binding_events (
        id INTEGER PRIMARY KEY, request_id TEXT NOT NULL, revision INTEGER NOT NULL,
        actor TEXT NOT NULL, action TEXT NOT NULL, at INTEGER NOT NULL);")
}

fn view(c: &Connection, id: &str) -> Option<Value> {
    c.query_row("SELECT request,digest,state,revision,actor FROM bindings WHERE id=?1", [id], |r| {
        let raw: String = r.get(0)?;
        Ok(json!({"request":serde_json::from_str::<Value>(&raw).unwrap_or(Value::Null),
            "digest":r.get::<_,String>(1)?,"state":r.get::<_,String>(2)?,
            "revision":r.get::<_,i64>(3)?,"actor":r.get::<_,String>(4)?}))
    }).ok()
}

pub(super) fn current(c:&Connection,node_id:&str)->Value {
    let id=c.query_row("SELECT id FROM bindings WHERE node_id=?1 ORDER BY at DESC,rowid DESC LIMIT 1",[node_id],|r|r.get::<_,String>(0)).ok();
    id.and_then(|id|view(c,&id)).unwrap_or(Value::Null)
}

pub(super) fn permits(c: &Connection, id: &str) -> bool {
    // Existing protocol-1 managed installations have no binding row; no silent migration.
    c.query_row("SELECT state,consent_expires FROM bindings WHERE node_id=?1 ORDER BY at DESC,rowid DESC LIMIT 1", [id], |r|
        Ok((r.get::<_,String>(0)?,r.get::<_,i64>(1)?)))
        .map(|(state,expires)|state=="accepted" && expires>now()).or_else(|error|match error {
            rusqlite::Error::QueryReturnedNoRows=>Ok(true),_=>Err(error)
        }).unwrap_or(false)
}

fn authority(c: &Connection, stream: &mut TcpStream, action: &str,
             header: &dyn Fn(&str)->String, body: Option<&[u8]>) -> bool {
    let from=header("x-wa-node");
    if !verify(c,&from,action,header,body,stream) {return false;}
    if !network_admins().contains(&from) {
        let _=respond(stream,403,"{\"error\":\"administrator_required\"}");return false;
    }
    true
}

pub(super) fn route(c:&Connection, stream:&mut TcpStream, path:&str, method:&str,
                   query:&str, body:&[u8], header:&dyn Fn(&str)->String) -> std::io::Result<()> {
    if network_admins().is_empty() {return respond(stream,403,"{\"error\":\"managed_service_required\"}");}
    let p:Value=serde_json::from_slice(body).unwrap_or(Value::Null);
    if path=="/bindings/request" && method=="POST" {return request(c,stream,&p,body,header);}
    if path=="/bindings/request" && method=="GET" {
        let id=query_value(query,"id");let from=header("x-wa-node");
        if !verify(c,&from,"bind-status",header,None,stream){return Ok(());}
        let Some(v)=view(c,&id) else{return respond(stream,404,"{\"error\":\"binding_unknown\"}");};
        if v["request"]["node_id"]!=from && !network_admins().contains(&from){return respond(stream,403,"{\"error\":\"forbidden\"}");}
        return respond(stream,200,&json!({"ok":true,"binding":v}).to_string());
    }
    if path=="/bindings/pending" && method=="GET" {
        if !authority(c,stream,"bind-pending",header,None){return Ok(());}
        let mut stmt=c.prepare("SELECT id FROM bindings WHERE state='pending' AND pairing_expires>?1 ORDER BY at LIMIT 101")
            .map_err(std::io::Error::other)?;
        let rows=stmt.query_map([now()],|r|r.get::<_,String>(0)).map_err(std::io::Error::other)?;
        let mut out=Vec::new();for row in rows {if let Some(v)=view(c,&row.map_err(std::io::Error::other)?){out.push(v);}}
        let truncated=out.len()>100;out.truncate(100);
        return respond(stream,200,&json!({"ok":true,"bindings":out,"truncated":truncated}).to_string());
    }
    if path=="/bindings/accept" && method=="POST" {return transition(c,stream,&p,body,header,"accept");}
    if path=="/bindings/revoke" && method=="POST" {return transition(c,stream,&p,body,header,"revoke");}
    respond(stream,404,"{\"error\":\"binding_route_unknown\"}")
}

fn request(c:&Connection,stream:&mut TcpStream,p:&Value,body:&[u8],header:&dyn Fn(&str)->String)->std::io::Result<()> {
    let id=p["id"].as_str().unwrap_or("");let node_id=p["node_id"].as_str().unwrap_or("");
    let key=p["public_key"].as_str().unwrap_or("");let code=p["code"].as_str().unwrap_or("");
    let hex=|s:&str,n:usize|s.len()==n&&s.bytes().all(|b|b.is_ascii_hexdigit()&&!b.is_ascii_uppercase());
    let ts=header("x-wa-ts").parse::<i64>().unwrap_or(0);let at=now();
    let expires=p["expires_at"].as_i64().unwrap_or(0);let pairing=p["pairing_expires_at"].as_i64().unwrap_or(0);
    if p.as_object().map(|m|m.len()!=11).unwrap_or(true) || p["schema"]!=1 || !hex(id,32)||!hex(node_id,32)||!hex(key,64)||!hex(code,12)
        || p["name"].as_str().map(|s|s.is_empty()||s.len()>100||s.chars().any(char::is_control)).unwrap_or(true)
        || p["scope"]!="user-account-tools" || expires<=at || expires>at+86400 || pairing<=at || pairing>at+600 || pairing>expires
        || p["service"].as_str().map(|s|s.len()>2048||!s.starts_with("https://")&&!s.starts_with("http://127.0.0.1:")).unwrap_or(true) {
        return respond(stream,400,"{\"error\":\"binding_request_invalid\"}");
    }
    let bytes=node::unhex(key).unwrap_or_default();
    if bytes.len()!=32||body_hash(&bytes)[..32]!=*node_id||header("x-wa-node")!=node_id||header("x-wa-pub")!=key
        ||at.abs_diff(ts)>120||!node::verify(key,&format!("bind-request|{node_id}|{ts}|{}",body_hash(body)),&header("x-wa-sig")) {
        return respond(stream,401,"{\"error\":\"binding_signature_invalid\"}");
    }
    let Some(pins)=p["operators"].as_array() else{return respond(stream,400,"{\"error\":\"binding_pins_invalid\"}");};
    let admins=network_admins();
    if admins.iter().any(|a|a==node_id){return respond(stream,403,"{\"error\":\"binding_administrator_identity_forbidden\"}");}
    if pins.is_empty()||pins.len()>32||pins.len()!=admins.len()||admins.iter().any(|a|{
        let matching:Vec<_>=pins.iter().filter(|pin|pin["node_id"]==a.as_str()).collect();
        matching.len()!=1||lookup(c,a).map(|n|matching[0]["public_key"]!=n["public_key"]).unwrap_or(true)
    }) {return respond(stream,409,"{\"error\":\"binding_operator_pins_changed\"}");}
    let digest=body_hash(body);
    if let Some(v)=view(c,id) {
        return if v["digest"]==digest {respond(stream,200,&json!({"ok":true,"binding":v,"collected":true}).to_string())}
        else{respond(stream,409,"{\"error\":\"binding_request_changed\"}")};
    }
    if public_key_of(c,node_id).map(|old|old!=key).unwrap_or(false){return respond(stream,409,"{\"error\":\"identity_conflict\"}");}
    let result=(||->rusqlite::Result<()>{let tx=c.unchecked_transaction()?;
        tx.execute("UPDATE bindings SET state='expired' WHERE node_id=?1 AND ((state='pending' AND pairing_expires<=?2) OR consent_expires<=?2)",rusqlite::params![node_id,at])?;
        tx.execute("INSERT INTO nodes(node_id,public_key,name,role,endpoints,last_seen,registered_at) VALUES(?1,?2,?3,'guest','[]',?4,?4) ON CONFLICT(node_id) DO NOTHING",rusqlite::params![node_id,key,p["name"].as_str(),at])?;
        tx.execute("DELETE FROM network_roles WHERE node_id=?1",[node_id])?;
        tx.execute("UPDATE nodes SET role='guest' WHERE node_id=?1",[node_id])?;
        tx.execute("INSERT INTO bindings VALUES(?1,?2,?3,?4,?5,?6,'pending',1,'',?7,?8,?9)",rusqlite::params![id,node_id,key,code,digest,String::from_utf8_lossy(body),pairing,expires,at])?;
        tx.execute("INSERT INTO binding_events(request_id,revision,actor,action,at) VALUES(?1,1,?2,'request',?3)",rusqlite::params![id,node_id,at])?;tx.commit()})();
    match result{Ok(())=>respond(stream,200,&json!({"ok":true,"binding":view(c,id)}).to_string()),Err(e)=>respond(stream,409,&json!({"error":"binding_request_conflict","detail":e.to_string()}).to_string())}
}

fn transition(c:&Connection,stream:&mut TcpStream,p:&Value,body:&[u8],header:&dyn Fn(&str)->String,action:&str)->std::io::Result<()> {
    let from=header("x-wa-node");let id=p["id"].as_str().unwrap_or("");
    if !verify(c,&from,&format!("bind-{action}"),header,Some(body),stream){return Ok(());}
    let Some(old)=view(c,id) else{return respond(stream,404,"{\"error\":\"binding_unknown\"}");};
    let admin=network_admins().contains(&from);
    if !admin && (action!="revoke" || old["request"]["node_id"]!=from){return respond(stream,403,"{\"error\":\"administrator_required\"}");}
    if p["node_id"]!=old["request"]["node_id"]||p["public_key"]!=old["request"]["public_key"]||p["digest"]!=old["digest"]||p["revision"]!=old["revision"]
        || (action=="accept"&&p["code"]!=old["request"]["code"]){return respond(stream,409,"{\"error\":\"binding_generation_changed\"}");}
    if action=="accept" && (old["state"]!="pending"||old["request"]["pairing_expires_at"].as_i64().unwrap_or(0)<=now()||old["request"]["expires_at"].as_i64().unwrap_or(0)<=now()) {
        return respond(stream,409,"{\"error\":\"binding_not_pending_or_expired\"}");
    }
    if action=="revoke" && !matches!(old["state"].as_str(),Some("accepted"|"pending")){return respond(stream,409,"{\"error\":\"binding_not_active\"}");}
    let next=if action=="accept"{"accepted"}else{"revoked"};
    let result=(||->rusqlite::Result<()>{let tx=c.unchecked_transaction()?;
        let changed=tx.execute("UPDATE bindings SET state=?1,revision=revision+1,actor=?2 WHERE id=?3 AND revision=?4 AND state=?5 AND (?1<>'accepted' OR (consent_expires>?6 AND pairing_expires>?6))",
            rusqlite::params![next,from,id,old["revision"].as_i64(),old["state"].as_str(),now()])?;
        if changed!=1{return Err(rusqlite::Error::ExecuteReturnedResults);}
        if action=="revoke" {
            tx.execute("UPDATE nodes SET role='guest' WHERE node_id=?1",[p["node_id"].as_str().unwrap()])?;
            tx.execute("DELETE FROM network_roles WHERE node_id=?1",[p["node_id"].as_str().unwrap()])?;
        }
        tx.execute("INSERT INTO binding_events(request_id,revision,actor,action,at) VALUES(?1,?2,?3,?4,?5)",rusqlite::params![id,old["revision"].as_i64().unwrap()+1,from,action,now()])?;tx.commit()})();
    match result{Ok(())=>respond(stream,200,&json!({"ok":true,"binding":view(c,id)}).to_string()),Err(e)=>respond(stream,409,&json!({"error":"binding_state_moved","detail":e.to_string()}).to_string())}
}

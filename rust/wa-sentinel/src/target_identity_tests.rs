use super::*;
use std::io::{Read,Write};
#[test]
fn identity_refusal_is_typed_not_hidden_as_foreign_node(){
 let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();let port=listener.local_addr().unwrap().port();
 let worker=std::thread::spawn(move||{for(status,body)in[(503,r#"{"error":"read_capacity_busy"}"#),(503,r#"{"error":"different"}"#),(200,r#"{"node_id":"expected"}"#)]{
  let(mut s,_)=listener.accept().unwrap();let mut buf=[0;4096];s.read(&mut buf).unwrap();write!(s,"HTTP/1.1 {status} Status\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
 }});
 assert!(node_id_on_port(port).unwrap_err().to_string().starts_with("node_identity_read_capacity_busy"));
 assert_eq!(node_id_on_port(port).unwrap_err().to_string(),"node_identity_http_status:503");
 assert_eq!(node_id_on_port(port).unwrap(),"expected");worker.join().unwrap();
}

use super::*;
use std::io::{Read,Write};
#[test]
fn identity_refusal_is_typed_not_hidden_as_foreign_node(){
 let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();let port=listener.local_addr().unwrap().port();
 let worker=std::thread::spawn(move||{for(status,body)in[(503,r#"{"error":"read_capacity_busy"}"#),(503,r#"{"error":"different"}"#),(200,r#"{"node_id":"expected"}"#)]{
  let(mut s,_)=listener.accept().unwrap();let mut buf=[0;4096];s.read(&mut buf).unwrap();write!(s,"HTTP/1.1 {status} Status\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
 }});
 assert!(node_id_on_port_once(port).unwrap_err().to_string().starts_with("node_identity_read_capacity_busy"));
 assert_eq!(node_id_on_port_once(port).unwrap_err().to_string(),"node_identity_http_status:503");
 assert_eq!(node_id_on_port_once(port).unwrap(),"expected");worker.join().unwrap();
}
#[test]
fn a_busy_read_lane_is_retried_until_the_node_answers(){
 let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();let port=listener.local_addr().unwrap().port();
 let worker=std::thread::spawn(move||{for(status,body)in[(503,r#"{"error":"read_capacity_busy"}"#),(503,r#"{"error":"read_capacity_busy"}"#),(200,r#"{"node_id":"expected"}"#)]{
  let(mut s,_)=listener.accept().unwrap();let mut buf=[0;4096];s.read(&mut buf).unwrap();write!(s,"HTTP/1.1 {status} Status\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
 }});
 assert_eq!(node_id_on_port(port).unwrap(),"expected");worker.join().unwrap();
}

#[test]
fn a_busy_or_unreachable_node_is_retried_and_a_wrong_answer_is_not(){
 for e in ["node_identity_read_capacity_busy; no target authority","node_identity_http_unavailable","node_identity_http_status:503","node_identity_body_unavailable"]{assert!(super::retryable_identity_error(e),"{e}");}
 for e in ["node_identity_http_status:404","node_identity_missing","node_identity_body_invalid"]{assert!(!super::retryable_identity_error(e),"{e}");}
}

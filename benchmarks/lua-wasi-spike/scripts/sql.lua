host.sql_exec("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT); INSERT INTO t(v) VALUES ('a'),('b'),('c');")
return host.sql_query("SELECT count(*) AS n, group_concat(v) AS vs FROM t")

SELECT jsonb_pretty(jsonb_build_object(
 'roles',(SELECT jsonb_agg(to_jsonb(r) ORDER BY rolname) FROM (SELECT rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls,rolconnlimit,rolvaliduntil,rolconfig FROM pg_roles WHERE rolname IN ('ritc_app','ritc_worker','ritc_test_worker')) r),
 'memberships',(SELECT jsonb_agg(to_jsonb(m) ORDER BY member,granted) FROM (SELECT r.rolname AS member,g.rolname AS granted,m.admin_option,m.inherit_option,m.set_option FROM pg_auth_members m JOIN pg_roles r ON r.oid=m.member JOIN pg_roles g ON g.oid=m.roleid WHERE r.rolname IN ('ritc_app','ritc_worker','ritc_test_worker')) m)
));

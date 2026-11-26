-- HANYA UNTUK PENGUJIAN LOKAL. Helper asersi di skema t.
create schema if not exists t;
grant usage on schema t to public;

create table if not exists t.results (n serial, passed boolean not null, msg text not null);
grant all on t.results to public;
grant all on sequence t.results_n_seq to public;

create or replace function t.ok(p_cond boolean, p_msg text) returns void
language plpgsql as $$
begin
  insert into t.results (passed, msg) values (coalesce(p_cond, false), p_msg);
  if coalesce(p_cond, false) then raise notice 'PASS  %', p_msg;
  else raise notice 'FAIL  %', p_msg; end if;
end $$;

-- Pernyataan harus gagal; p_expect dicocokkan dengan SQLSTATE atau potongan pesan.
create or replace function t.throws(p_sql text, p_expect text, p_msg text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    perform t.ok(p_expect is null or sqlstate = p_expect or sqlerrm like '%' || p_expect || '%',
                 p_msg || ' [' || sqlstate || ': ' || left(sqlerrm, 80) || ']');
    return;
  end;
  perform t.ok(false, p_msg || ' [TIDAK ditolak]');
end $$;

create or replace function t.lives(p_sql text, p_msg text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    perform t.ok(false, p_msg || ' [error: ' || sqlstate || ' ' || left(sqlerrm, 80) || ']');
    return;
  end;
  perform t.ok(true, p_msg);
end $$;

create or replace function t.count(p_sql text) returns bigint
language plpgsql as $$
declare n bigint;
begin
  execute 'select count(*) from (' || p_sql || ') q' into n;
  return n;
end $$;

create or replace function t.affected(p_sql text) returns bigint
language plpgsql as $$
declare n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function t.login(p_uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  execute 'set role authenticated';
end $$;

create or replace function t.anon() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', false);
  execute 'set role anon';
end $$;

create or replace function t.logout() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', false);
  execute 'reset role';
end $$;

create or replace function t.summary() returns void
language plpgsql as $$
declare v_pass int; v_fail int;
begin
  select count(*) filter (where passed), count(*) filter (where not passed)
    into v_pass, v_fail from t.results;
  raise notice 'RINGKASAN: % lulus, % gagal', v_pass, v_fail;
  if v_fail > 0 then raise exception '% pengujian gagal', v_fail; end if;
end $$;

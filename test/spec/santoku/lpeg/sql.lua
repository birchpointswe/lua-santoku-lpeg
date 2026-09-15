local test = require("santoku.test")
local sql = require("santoku.lpeg.sql")

local function ok (s, opts)
  local r, e = sql.parse(s, opts)
  assert(r ~= nil, tostring(e) .. " for: " .. s)
  return r
end

local function no (s, want, opts)
  local r, e = sql.parse(s, opts)
  assert(r == nil, "expected refusal for: " .. s)
  assert(e:find(want, 1, true) ~= nil, "wrong reason for: " .. s .. " got: " .. tostring(e))
  return e
end

test("sql", function ()

  test("classifies passthrough statements", function ()
    assert(ok("select 1").kind == "select")
    assert(ok("SELECT * FROM t WHERE x = 'a;b'").kind == "select")
    assert(ok("values (1), (2)").kind == "select")
    assert(ok("insert into t (a) values (1)").kind == "insert")
    assert(ok("insert or replace into t values (1)").kind == "insert")
    assert(ok("replace into t values (1)").kind == "insert")
    assert(ok("update t set a = 1 where b = 2").kind == "update")
    assert(ok("delete from t where a = 1").kind == "delete")
    assert(ok("  -- comment\n /* block */ select 1").kind == "select")
  end)

  test("classifies through WITH prefixes", function ()
    assert(ok("with c as (select 1) select * from c").kind == "select")
    assert(ok("with recursive c(x) as (select 1 union all select x+1 from c) select * from c").kind == "select")
    assert(ok("with c as (select 1), d as (select 2) insert into t select * from c, d").kind == "insert")
    assert(ok("with c as (select 1) update t set a = (select * from c)").kind == "update")
    assert(ok("with c as (select 1) delete from t where a in (select * from c)").kind == "delete")
    assert(ok("with c as materialized (select 1) select * from c").kind == "select")
    assert(ok("with c as not materialized (select 1) select * from c").kind == "select")
  end)

  test("explain wraps and validates the inner statement", function ()
    local r = ok("explain query plan select * from t")
    assert(r.kind == "explain")
    assert(r.inner.kind == "select")
    assert(ok("explain select 1").inner.kind == "select")
    no("explain create trigger tr after insert on t begin select 1; end", "triggers")
  end)

  test("create table extracts columns and pk", function ()
    local r = ok([[
      create table balances (
        account text not null,
        observed_on text,
        amount integer not null default 0,
        note text,
        primary key (account, observed_on)
      )
    ]])
    assert(r.kind == "create_table")
    assert(r.name == "balances")
    assert(#r.columns == 4)
    assert(r.columns[1].name == "account")
    assert(r.columns[1].type == "text")
    assert(r.columns[1].notnull == true)
    assert(r.columns[3].defaulted == true)
    assert(#r.pk == 2)
    assert(r.pk[1] == "account" and r.pk[2] == "observed_on")
  end)

  test("create table with column-level pk and modifiers", function ()
    local r = ok([[
      create table gifts (
        id integer primary key,
        amount real not null,
        kind text unique check (kind in ('check', 'wire', 'venmo')),
        note text default ('none'),
        stamp text default current_timestamp,
        total real generated always as (amount * 2) stored
      )
    ]])
    assert(#r.pk == 1 and r.pk[1] == "id")
    assert(r.columns[3].unique == true)
    assert(r.columns[3].checked == true)
    assert(r.columns[5].defaulted == true)
    assert(r.columns[6].generated == true)
    local r2 = ok("create table t (a text primary key desc on conflict replace, b varchar (10))")
    assert(r2.pk[1] == "a")
    assert(r2.columns[2].type == "varchar")
  end)

  test("create table pk-only and without rowid", function ()
    local r = ok("create table trip_items (trip text, item text, primary key (trip, item)) without rowid")
    assert(r.without_rowid == true)
    assert(#r.pk == 2)
    assert(ok("create table if not exists t (id text primary key)").if_not_exists == true)
  end)

  test("create table refusals", function ()
    no("create table t (a text)", "PRIMARY KEY is required")
    no("create table t (id integer primary key autoincrement)", "AUTOINCREMENT")
    no("create table t (id text primary key, o text references other (id))", "foreign keys")
    no("create table t (id text primary key, foreign key (id) references o (id))", "foreign keys")
    no("create table t (id text primary key) strict", "STRICT")
    no("create temp table t (id text primary key)", "TEMP")
    no("create temporary table t (id text primary key)", "TEMP")
    no("create table \"my table\" (id text primary key)", "quoted identifiers")
    no("create table [t] (id text primary key)", "quoted identifiers")
    no("create table `t` (id text primary key)", "quoted identifiers")
    no("create table main.t (id text primary key)", "schema-qualified")
    no("create table t (id text primary key, primary key (nope))", "unrecognized")
  end)

  test("create table honors injected checks", function ()
    local opts = {
      check_table = function (n)
        if n == "notes_sync" then return nil, "table name is reserved by sync" end
        return true
      end,
      check_column = function (n)
        if n == "seq" then return nil, "column name is reserved by sync: seq" end
        return true
      end,
    }
    no("create table notes_sync (id text primary key)", "reserved by sync", opts)
    no("create table txlog (id text primary key, seq integer)", "reserved by sync: seq", opts)
    assert(ok("create table txlog (id text primary key, n integer)", opts).name == "txlog")
  end)

  test("create view", function ()
    local r = ok("create view totals as select account, sum(amount) from balances group by account")
    assert(r.kind == "create_view")
    assert(r.name == "totals")
    local r2 = ok("create view v (a, b) as with c as (select 1, 2) select * from c")
    assert(r2.columns[1] == "a" and r2.columns[2] == "b")
    no("create view v as delete from t", "unrecognized")
    no("create temp view v as select 1", "TEMP")
  end)

  test("create index", function ()
    local r = ok("create index idx_b_on on balances (observed_on desc, account)")
    assert(r.kind == "create_index")
    assert(r.name == "idx_b_on" and r.table == "balances")
    assert(r.unique == false)
    local r2 = ok("create unique index if not exists u on t (a) where a > 0")
    assert(r2.unique == true and r2.if_not_exists == true)
  end)

  test("drop", function ()
    assert(ok("drop table t").kind == "drop_table")
    local r = ok("drop view if exists v")
    assert(r.kind == "drop_view" and r.if_exists == true)
    assert(ok("drop index i").kind == "drop_index")
    no("drop trigger tr", "triggers")
  end)

  test("alter", function ()
    local r = ok("alter table t add column note text not null default ''")
    assert(r.kind == "alter_add_column")
    assert(r.table == "t" and r.column.name == "note")
    assert(r.column.notnull == true and r.column.defaulted == true)
    local r2 = ok("alter table t drop column note")
    assert(r2.kind == "alter_drop_column" and r2.column == "note")
    assert(ok("alter table t add x integer").column.name == "x")
    no("alter table t rename to u", "RENAME")
    no("alter table t rename column a to b", "RENAME")
    no("alter table t add column p text primary key", "unrecognized")
    no("alter table t add column r text references o (id)", "foreign keys")
  end)

  test("pragma allowlist", function ()
    assert(ok("pragma table_info (balances)").name == "table_info")
    assert(ok("pragma table_xinfo(t)").name == "table_xinfo")
    assert(ok("pragma integrity_check").name == "integrity_check")
    assert(ok("PRAGMA quick_check").name == "quick_check")
    no("pragma journal_mode = wal", "not allowed")
    no("pragma foreign_keys = on", "not allowed")
    no("pragma writable_schema = on", "not allowed")
    no("pragma synchronous = off", "not allowed")
    local r = sql.parse("pragma busy_timeout = 5", { pragmas = { busy_timeout = true } })
    assert(r and r.name == "busy_timeout")
  end)

  test("maintenance statements", function ()
    assert(ok("vacuum").kind == "vacuum")
    assert(ok("vacuum;").kind == "vacuum")
    assert(ok("analyze").kind == "analyze")
    assert(ok("reindex").kind == "reindex")
    no("vacuum into 'copy.db'", "VACUUM INTO")
    no("vacuum main into 'copy.db'", "VACUUM INTO")
  end)

  test("transaction control refused", function ()
    no("begin", "atomically")
    no("begin transaction", "atomically")
    no("commit", "atomically")
    no("end", "atomically")
    no("rollback", "atomically")
    no("savepoint s1", "atomically")
    no("release s1", "atomically")
  end)

  test("attach and friends refused", function ()
    no("attach database 'x.db' as x", "ATTACH")
    no("attach ':memory:' as m", "ATTACH")
    no("detach x", "ATTACH")
    no("create trigger tr after insert on t begin select 1; end", "triggers")
    no("create virtual table ft using fts5 (a)", "virtual")
  end)

  test("reserved-name policy covers drop, alter, and index targets", function ()
    local opts = {
      check_table = function (n)
        if n == "notes_sync" then return nil, "table name is reserved by sync" end
        return true
      end,
      check_column = function (n)
        if n == "seq" then return nil, "column name is reserved by sync: seq" end
        return true
      end,
    }
    no("drop table notes_sync", "reserved by sync", opts)
    no("drop view if exists notes_sync", "reserved by sync", opts)
    no("drop index notes_sync", "reserved by sync", opts)
    no("alter table notes_sync add column x integer", "reserved by sync", opts)
    no("alter table notes_sync drop column x", "reserved by sync", opts)
    no("alter table t drop column seq", "reserved by sync: seq", opts)
    no("create index i on notes_sync (x)", "reserved by sync", opts)
    local bare = {
      check_table = function (n)
        if n == "nope" then return false end
        return true
      end,
    }
    no("drop table nope", "not allowed", bare)
  end)

  test("table-level pk autoincrement carries the right reason", function ()
    no("create table t (id integer, primary key (id autoincrement))", "AUTOINCREMENT")
    no("alter table t add column id text primary key autoincrement", "AUTOINCREMENT")
  end)

  test("analyze and reindex are bare only", function ()
    no("analyze t", "trailing")
    no("analyze main.t", "trailing")
    no("reindex t", "trailing")
    no("vacuum 'x'", "trailing")
  end)

  test("quoted CTE names pass through in DML", function ()
    assert(ok("with \"c\" as (select 1) select * from \"c\"").kind == "select")
    assert(ok("with [c] as (select 1) select * from [c]").kind == "select")
  end)

  test("create table as is refused with guidance", function ()
    no("create table t as select 1", "INSERT ... SELECT")
  end)

  test("passthrough residue is deliberate and pinned", function ()
    assert(ok("select * from pragma_table_info('t')").kind == "select")
    assert(ok("select * from pragma_journal_mode('wal')").kind == "select")
    assert(ok("update sqlite_master set sql = 'x'").kind == "update")
    assert(ok("insert into main.t values (1)").kind == "insert")
    assert(ok("select 1; drop table t").kind == "select")
  end)

  test("ddl refuses trailing statements", function ()
    no("create table t (id text primary key); select 1", "trailing")
    no("drop table t; select 1", "trailing")
  end)

  test("grammar coverage sweep", function ()
    assert(ok("insert into t default values").kind == "insert")
    assert(ok("create table t (n unsigned big int, primary key (n))").columns[1].type == "unsigned big int")
    assert(ok("create table t (id integer constraint pk primary key, a text constraint nn not null)").pk[1] == "id")
    assert(ok("create table t (a text not null on conflict replace, primary key (a))").columns[1].notnull == true)
    assert(ok("create table t (a text, primary key (a) on conflict ignore)").pk[1] == "a")
    assert(ok("create table t (a text default -1.5e-3, primary key (a))").columns[1].defaulted == true)
    assert(ok("create table t (a text default null, primary key (a))").columns[1].defaulted == true)
    assert(ok("create table t (a numeric (10, 2) default (1 + 2), primary key (a))").columns[1].type == "numeric")
    assert(ok("create table t (g integer generated always as (1) virtual, id text primary key)").columns[1].generated == true)
    assert(ok("alter table t add column g text as (x + 1)").column.generated == true)
    assert(ok("create/*x*/table/*y*/t(--z\nid text primary key)").name == "t")
    assert(ok("create table t (\r\nid text primary key\r\n)").name == "t")
    assert(ok("create view v as values (1)").kind == "create_view")
    no("create table main . t (id text primary key)", "schema-qualified")
    no("create unique index u on main.t (a)", "schema-qualified")
    no("pragma main.table_info (t)", "schema-qualified")
    no("drop view main.v", "schema-qualified")
    no("explain vacuum into 'x'", "VACUUM INTO")
    no("create table t (id text primary key) /* unterminated", "trailing")
  end)

  test("garbage and edge cases", function ()
    no("", "unrecognized")
    no("   \n  ", "unrecognized")
    no("bogus statement", "unrecognized")
    no("create table t (id text primary key) garbage", "trailing")
    no("drop table t extra", "trailing")
    assert(ok("create table t (id text primary key);").name == "t")
    assert(ok("select 1 -- trailing comment").kind == "select")
    local r = ok("create table t (a text, b text check (b in (');', 'x')), primary key (a))")
    assert(#r.pk == 1 and r.pk[1] == "a")
  end)

end)

from copy import deepcopy
from pathlib import Path

import pytest
from sqlparse.lexer import Lexer

from pymybot.errors import ScriptError
from pymybot.matrix import Matrix
from pymybot.sql import Statement, Table, apply_statement, load_structure, parse_sql


BASE = ("CREATE TABLE Timer(name String,delay Number);"
        "INSERT INTO Timer(delay,name) VALUES(50,'timer-0');")


def apply(tables, text):
    for statement in parse_sql(text):
        apply_statement(tables, statement, allow_mutations=True)


def test_statement_and_table_defaults_are_independent():
    first, second = Statement("CREATE"), Statement("CREATE")
    first.columns.append(("v", "String"))
    first.where.append(("v", "x"))
    assert second.columns == second.where == []
    first_table, second_table = Table("A"), Table("B")
    first_table.column_types["v"] = "Number"
    assert second_table.column_types == {}
    assert isinstance(first_table, Matrix)


def test_sqlparse_actually_tokenizes(monkeypatch):
    original = Lexer.get_tokens
    calls = []

    def tracked(self, text, encoding=None):
        calls.append(text)
        return original(self, text, encoding)

    monkeypatch.setattr(Lexer, "get_tokens", tracked)
    assert parse_sql("SHOW TABLES;") == [Statement("SHOW")]
    assert calls == ["SHOW TABLES;"]


def test_all_statement_payloads_and_keyword_case():
    assert parse_sql("cReAtE tAbLe T(a sTrInG,b nUmBeR);") == [
        Statement("CREATE", "T", columns=[("a", "String"), ("b", "Number")])]
    assert parse_sql("insert into T(b,a)values(-2,'hello');") == [
        Statement("INSERT", "T", names=["b", "a"], values=["-2", "hello"])]
    assert parse_sql("select*from T where a='x' aNd b=-1;") == [
        Statement("SELECT", "T", where=[("a", "x"), ("b", "-1")])]
    assert parse_sql("show tables;") == [Statement("SHOW")]
    assert parse_sql("delete from T where a='x';") == [
        Statement("DELETE", "T", where=[("a", "x")])]
    assert parse_sql("drop table T;") == [Statement("DROP", "T")]
    assert parse_sql("update T set a='x',b=-2 where a='y';") == [
        Statement("UPDATE", "T", assignments=[("a", "x"), ("b", "-2")], where=[("a", "y")])]


def test_create_order_and_insert_column_order_and_types():
    tables = load_structure(BASE + "CREATE TABLE A(v String);"
                            "INSERT INTO Timer(name,delay) VALUES('timer-1',+2e3);")
    assert list(tables) == ["Timer", "A"]
    assert tables["Timer"].rows == [["name", "delay"], ["timer-0", "50"], ["timer-1", "+2e3"]]
    assert tables["Timer"].header == ["name", "delay"]
    assert tables["Timer"].data == [["timer-0", "50"], ["timer-1", "+2e3"]]
    assert tables["Timer"].column_types == {"name": "String", "delay": "Number"}
    assert tables["A"].rows == [["v"]]


@pytest.mark.parametrize("quote", ["", "'", '"'])
@pytest.mark.parametrize("device", ["t0", "timer-0"])
def test_action_columns_support_dotted_names_and_named_mappings(quote, device):
    delay, count = f"{device}.delay", f"{device}.count"
    qdelay, qcount = f"{quote}{delay}{quote}", f"{quote}{count}{quote}"
    tables = load_structure(
        f"CREATE TABLE Action ({qdelay} Number, {qcount} Number);"
        f"INSERT INTO Action ({qcount}, {qdelay}) VALUES (2, 10);")
    assert tables["Action"].rows == [[delay, count], ["10", "2"]]
    assert tables["Action"].column_types == {delay: "Number", count: "Number"}
    assert parse_sql(f"SELECT * FROM Action WHERE {qdelay}=10;") == [
        Statement("SELECT", "Action", where=[(delay, "10")])]
    apply(tables, f"UPDATE Action SET {qdelay}=11 WHERE {qcount}=2;")
    assert tables["Action"].data == [["11", "2"]]
    apply(tables, f"DELETE FROM Action WHERE {qdelay}=11;")
    assert tables["Action"].rows == [[delay, count]]


def test_programmatic_action_columns_use_the_same_validation_and_mapping():
    tables = {}
    apply_statement(tables, Statement("CREATE", "Action", columns=[
        ("t0.delay", "Number"), ("timer-1.delay", "Number")]))
    apply_statement(tables, Statement("INSERT", "Action",
                                     names=["timer-1.delay", "t0.delay"], values=["2", "10"]))
    assert tables["Action"].data == [["10", "2"]]
    apply_statement(tables, Statement("UPDATE", "Action", assignments=[("t0.delay", "11")],
                                     where=[("timer-1.delay", "2")]), allow_mutations=True)
    assert tables["Action"].data == [["11", "2"]]
    apply_statement(tables, Statement("DELETE", "Action", where=[("t0.delay", "11")]),
                    allow_mutations=True)
    assert tables["Action"].data == []


@pytest.mark.parametrize("value", ["", "it's", "'", '"', 'a"b', "a'b'c", "a;b,c=(d)",
                                   "--not a comment", "/* not a comment */", " leading trailing ",
                                   "line\r\nnext", "Unicode 中文", "C:\\robots\\", "$other-0"])
@pytest.mark.parametrize("quote", ["'", '"'])
def test_quoted_values_are_lossless(value, quote):
    encoded = quote + value.replace(quote, quote * 2) + quote
    statement = parse_sql(f"INSERT INTO T(a,b) VALUES({encoded},'next');")[0]
    assert statement.values == [value, "next"]


def test_comments_semicolons_and_statement_boundaries():
    sql = ("-- first\r\nCREATE/* ; ' \" */TABLE T(a String);"
           "INSERT/**/INTO T(a) VALUES('a;--b/*c*/'); -- comment at EOF")
    assert load_structure(sql)["T"].data == [["a;--b/*c*/"]]
    assert parse_sql("") == parse_sql(" \t\r\n-- hi") == parse_sql("/* all comments */") == []


@pytest.mark.parametrize("comment", ["/*x*/", "--x\n"])
def test_comments_do_not_join_values(comment):
    with pytest.raises(ScriptError):
        parse_sql(f"INSERT INTO T(a) VALUES(50{comment}60);")
    assert parse_sql(f"INSERT INTO T(a) VALUES(50{comment});")[0].values == ["50"]


def test_quoted_reserved_names_do_not_become_keywords():
    tables = load_structure("CREATE TABLE 'Update'('drop' String,\"set\" String);"
                            "INSERT INTO 'Update'(\"set\",'drop') VALUES('SET','DROP');")
    assert tables["Update"].rows == [["drop", "set"], ["DROP", "SET"]]
    with pytest.raises(ScriptError):
        parse_sql("INSERT INTO T(a) VALUES(SET);")


@pytest.mark.parametrize("raw", ["42", "-1.5", "+2e3", "1e+3", "-.5", "+.5", "1.",
                                 "-0", "0x10", "-0Xf", "0x1.fp2", "1e-9999", "' 7 '"])
def test_number_literals_are_validated_but_retained_as_strings(raw):
    tables = load_structure(f"CREATE TABLE T(v Number);INSERT INTO T(v) VALUES({raw});")
    assert tables["T"].data == [[raw.strip("'")]]


@pytest.mark.parametrize("value", ["abc", "", "nan", "NaN", "inf", "-Infinity", "1e309", "-1e999",
                                   "0x1p99999", "1_000", "1,2", "12x", "-", "$(1+)",
                                   "$(1=2)", "$()", "$(1e999)", "$(1)tail", "$(1"])
def test_number_values_rejected_in_structure_and_runtime_without_mutating(value):
    encoded = "'" + value.replace("'", "''") + "'"
    with pytest.raises(ScriptError, match="Number"):
        parse_sql(f"CREATE TABLE T(v Number);INSERT INTO T(v) VALUES({encoded});")
    tables = load_structure(BASE)
    before = deepcopy(tables)
    for sql in (f"INSERT INTO Timer(name,delay) VALUES('x',{encoded});",
                f"UPDATE Timer SET delay={encoded};"):
        statement = parse_sql(sql)[0]  # No schema is available to this parse.
        with pytest.raises(ScriptError, match="Number"):
            apply_statement(tables, statement, allow_mutations=True)
        assert tables == before


def test_expressions_checked_without_evaluation_or_variable_resolution():
    expressions = ["$(unknown + 2)", "$(1 / 0)", "$(v*1e308*1e308)"]
    sql = "CREATE TABLE T(v Number);" + "".join(
        f"INSERT INTO T(v) VALUES('{value}');" for value in expressions)
    tables = load_structure(sql)
    assert tables["T"].data == [[value] for value in expressions]
    apply(tables, "UPDATE T SET v='$(later + 3)';")
    assert tables["T"].data == [["$(later + 3)"]] * 3


@pytest.mark.parametrize("sql", [
    ";", ";;;", "CREATE TABLE", "CREATE TABLE T(a String)",
    "CREATE TABLE T();", "CREATE TABLE T(a);", "CREATE TABLE T(a VARCHAR);",
    "CREATE TABLE T(a 'String');", "CREATE TABLE T(a String,);",
    "CREATE TABLE T(a String DEFAULT 'x');", "CREATE TEMP TABLE T(a String);",
    "CREATE TABLE IF NOT EXISTS T(a String);", "CREATE TABLE T AS SELECT * FROM U;",
    "ALTER TABLE T ADD a String;", "BEGIN;", "TRUNCATE TABLE T;",
    "INSERT T(a) VALUES(1);", "INSERT INTO T VALUES(1);", "INSERT INTO T() VALUES();",
    "INSERT INTO T(a,b) VALUES(1);", "INSERT INTO T(a) VALUES(1,2);",
    "INSERT INTO T(a,) VALUES(1);", "INSERT INTO T(a) VALUES(1,);",
    "INSERT INTO T(a) VALUES(1),(2);", "INSERT INTO T(a) SELECT a FROM U;",
    "INSERT INTO T(a) VALUES(1) RETURNING a;", "INSERT INTO T(a) VALUES('a'b);",
    "INSERT INTO T(a) VALUES('a' 'b');", "INSERT INTO T(a) VALUES($(1+2));",
    "INSERT INTO T(a) VALUES(1+2);", "INSERT INTO T(a) VALUES(1/2);",
    "INSERT INTO T(a) VALUES(+ 1);", "INSERT INTO T(a) VALUES(`text`);",
    "INSERT INTO T(a) VALUES($$text$$);", "INSERT INTO T(a) VALUES(?);",
    "SELECT a FROM T;", "SELECT COUNT(*) FROM T;", "SELECT DISTINCT * FROM T;",
    "SELECT * T;", "SELECT * FROM;", "SELECT * FROM T LIMIT 1;",
    "SELECT * FROM T ORDER BY a;", "SELECT * FROM T JOIN U;", "SELECT * FROM T alias;",
    "SELECT * FROM T WHERE;", "SELECT * FROM T WHERE a=1 OR b=2;",
    "SELECT * FROM T WHERE a=1 AND;", "SELECT * FROM T WHERE (a=1);",
    "SELECT * FROM T WHERE a=1,b=2;", "SELECT * FROM T WHERE a=1 AND b=2 trailing;",
    "SHOW TABLE;", "SHOW TABLES", "SHOW TABLES LIKE 'T';", "SHOW TABLES WHERE a=1;",
    "DELETE T;", "DELETE FROM T LIMIT 1;", "DELETE FROM T WHERE a=1 RETURNING a;",
    "DROP T;", "DROP TABLE T WHERE a=1;", "DROP TABLE T CASCADE;", "DROP TABLE IF EXISTS T;",
    "UPDATE T;", "UPDATE T SET;", "UPDATE T SET a;", "UPDATE T SET a=;",
    "UPDATE T SET a=1,;", "UPDATE T SET a=1 AND b=2;", "UPDATE T SET a=1 LIMIT 1;",
    "UPDATE T SET a=a+1;", "UPDATE T SET a=1 WHERE a=1 OR b=2;",
    "SHOW TABLES;;", "SELECT * FROM T; trailing", "# not a supported comment\nSHOW TABLES;",
])
def test_strict_grammar_rejects_unsupported_and_malformed_sql(sql):
    with pytest.raises(ScriptError):
        parse_sql(sql)


@pytest.mark.parametrize("operator", ["==", "!=", "<>", "<=", ">=", "<", ">", "+=", ":=", "LIKE", "IS", "IN"])
@pytest.mark.parametrize("template", ["SELECT * FROM T WHERE a{op}1;",
                                      "DELETE FROM T WHERE a{op}1;",
                                      "UPDATE T SET a{op}1;"])
def test_only_equality_operator_is_supported(operator, template):
    with pytest.raises(ScriptError):
        parse_sql(template.format(op=f" {operator} "))


@pytest.mark.parametrize("fragment", ["'unfinished", '"unfinished', "/*unfinished", "/*x*", "/*",
                                      "'a''", '"a""'])
def test_incomplete_quotes_or_comments_cannot_be_ignored_after_a_valid_statement(fragment):
    with pytest.raises(ScriptError, match="Unterminated"):
        parse_sql("SHOW TABLES;\n" + fragment)


@pytest.mark.parametrize("name", ["'../T'", "'T/x'", "'T\\x'", "'T;DROP'", "''", "' spaced '",
                                 "'a\nb'", "a.b", "@T", "a-b", "1table", "`T`", "[T]", "'a''b'"])
def test_unsafe_names_rejected_in_every_name_position(name):
    for sql in (f"CREATE TABLE {name}(a String);", f"CREATE TABLE T({name} String);",
                f"INSERT INTO {name}(a) VALUES(1);", f"INSERT INTO T({name}) VALUES(1);",
                f"SELECT * FROM {name};", f"DELETE FROM T WHERE {name}=1;",
                f"UPDATE T SET {name}=1;", f"DROP TABLE {name};"):
        with pytest.raises(ScriptError):
            parse_sql(sql)


@pytest.mark.parametrize("name", ["delay", "t0..delay", ".delay", "t0.", "t0.delay.extra",
                                  "../t0.delay", "t0/x.delay", "t0\\x.delay", "t0.delay;DROP",
                                  "t0.delay=x", "t0 .delay", "t0.$(p)", "$(t0).delay",
                                  "1t0.delay", "t0.1delay", "t0.de'lay", "t0.de\nlay", ""])
def test_action_column_validation_rejects_unsafe_or_malformed_names(name):
    quoted = "'" + name.replace("'", "''") + "'"
    cases = [
        (f"CREATE TABLE Action ({quoted} Number);",
         Statement("CREATE", "Action", columns=[(name, "Number")])),
        (f"INSERT INTO Action ({quoted}) VALUES (1);",
         Statement("INSERT", "Action", names=[name], values=["1"])),
        (f"UPDATE Action SET {quoted}=1;",
         Statement("UPDATE", "Action", assignments=[(name, "1")])),
        (f"DELETE FROM Action WHERE {quoted}=1;",
         Statement("DELETE", "Action", where=[(name, "1")])),
        (f"SELECT * FROM Action WHERE {quoted}=1;",
         Statement("SELECT", "Action", where=[(name, "1")])),
    ]
    tables = {"Action": Matrix("Action", [["t0.delay"], ["1"]])}
    before = deepcopy(tables)
    for sql, statement in cases:
        with pytest.raises(ScriptError, match="[Uu]nsafe or invalid"):
            parse_sql(sql)
        with pytest.raises(ScriptError, match="[Uu]nsafe or invalid"):
            apply_statement(tables, statement, allow_mutations=True)
        assert tables == before


@pytest.mark.parametrize("name", ["t0.delay", "timer-0.delay"])
def test_action_column_names_do_not_relax_table_or_other_column_names(name):
    for sql in (f"CREATE TABLE '{name}' (v String);",
                f"CREATE TABLE T ('{name}' String);",
                f"CREATE TABLE action ('{name}' String);",
                f"INSERT INTO T ('{name}') VALUES (1);",
                f"UPDATE T SET '{name}'=1;", f"DELETE FROM T WHERE '{name}'=1;"):
        with pytest.raises(ScriptError, match="[Uu]nsafe or invalid"):
            parse_sql(sql)
    for statement in (Statement("CREATE", name, columns=[("v", "String")]),
                      Statement("CREATE", "T", columns=[(name, "String")]),
                      Statement("INSERT", "T", names=[name], values=["1"]),
                      Statement("UPDATE", "T", assignments=[(name, "1")]),
                      Statement("DELETE", "T", where=[(name, "1")])):
        with pytest.raises(ScriptError, match="unsafe or invalid"):
            apply_statement({}, statement, allow_mutations=True)


@pytest.mark.parametrize("sql", [
    "CREATE TABLE Action(t0.delay Number,'t0.delay' String);",
    "INSERT INTO Action(t0.delay,t0.delay) VALUES(1,2);",
    "UPDATE Action SET t0.delay=1,t0.delay=2;",
    "DELETE FROM Action WHERE t0.delay=1 AND t0.delay=2;",
])
def test_duplicate_action_columns_are_rejected(sql):
    with pytest.raises(ScriptError, match="[Dd]uplicate"):
        parse_sql(sql)


@pytest.mark.parametrize("sql", [
    "INSERT INTO Action(t0.delay) VALUES(1);",
    "INSERT INTO Action(t0.delay,t1.delay) VALUES(1,2);",
    "INSERT INTO Action(t0.delay,t0.count) VALUES('invalid',2);",
    "UPDATE Action SET t0.delay='invalid';",
    "DELETE FROM Action WHERE t1.delay=1;",
])
def test_action_schema_checks_still_precede_mutation(sql):
    tables = load_structure("CREATE TABLE Action(t0.delay Number,t0.count Number);"
                            "INSERT INTO Action(t0.count,t0.delay) VALUES(2,10);")
    before = deepcopy(tables)
    with pytest.raises(ScriptError):
        apply(tables, sql)
    assert tables == before


@pytest.mark.parametrize("sql", ["CREATE TABLE T(a String,a Number);",
                                 "CREATE TABLE T(a String);CREATE TABLE T(b String);",
                                 "INSERT INTO T(a,a) VALUES(1,2);", "UPDATE T SET a=1,a=2;",
                                 "DELETE FROM T WHERE a=1 AND a=1;"])
def test_duplicate_declarations_and_columns_rejected(sql):
    with pytest.raises(ScriptError, match="[Dd]uplicate"):
        parse_sql(sql)


def test_nul_and_nontext_input_rejected():
    for text in (None, b"SHOW TABLES;", "SHOW\0 TABLES;", "INSERT INTO T(a) VALUES('a\0b');"):
        with pytest.raises(ScriptError):
            parse_sql(text)


def test_error_location_after_comments():
    with pytest.raises(ScriptError, match=r"line 3, column 19"):
        parse_sql("-- first\n/* block\ncomment */ CREATE x;")


@pytest.mark.parametrize("sql", ["INSERT INTO Timer(name) VALUES('x');",
                                 "INSERT INTO Timer(nome,delay) VALUES('x',1);",
                                 "UPDATE Timer SET nome='x';",
                                 "DELETE FROM Timer WHERE nome='x';"])
def test_schema_errors_precede_mutation(sql):
    tables = load_structure(BASE)
    before = deepcopy(tables)
    with pytest.raises(ScriptError):
        apply(tables, sql)
    assert tables == before


def test_missing_tables_duplicate_tables_and_case_sensitive_names():
    for sql in ("INSERT INTO Missing(a) VALUES(1);", "DROP TABLE Missing;",
                "UPDATE Missing SET a=1;", "DELETE FROM Missing;"):
        with pytest.raises(ScriptError, match="not defined"):
            apply({}, sql)
    tables = load_structure(BASE)
    with pytest.raises(ScriptError, match="already exists"):
        apply(tables, "CREATE TABLE Timer(x String);")
    with pytest.raises(ScriptError, match="not defined"):
        apply(tables, "DELETE FROM timer;")
    with pytest.raises(ScriptError, match="no such column"):
        apply(tables, "DELETE FROM Timer WHERE Name='timer-0';")


@pytest.mark.parametrize("sql", ["DELETE FROM Timer;", "DROP TABLE Timer;", "UPDATE Timer SET delay=1;"])
def test_mutations_require_explicit_permission(sql):
    tables = load_structure(BASE)
    before = deepcopy(tables)
    with pytest.raises(ScriptError, match="allow_mutations"):
        apply_statement(tables, parse_sql(sql)[0])
    assert tables == before
    with pytest.raises(ScriptError):
        load_structure(BASE + sql)


@pytest.mark.parametrize("sql", ["SELECT * FROM Timer;", "SHOW TABLES;"])
def test_queries_rejected_by_structure_loader_and_apply(sql):
    with pytest.raises(ScriptError, match="query"):
        load_structure(BASE + sql)
    for allowed in (False, True):
        with pytest.raises(ScriptError, match="query"):
            apply_statement({}, parse_sql(sql)[0], allow_mutations=allowed)


def inherited_table():
    return {"T": Matrix("T", [["name", "group", "v"],
                               ["a", "G", "01"], ["b", "-", "-"], ["c", "H", "3"]])}


def test_delete_matches_inherited_exact_strings_and_preserves_header():
    tables = inherited_table()
    before = deepcopy(tables)
    with pytest.raises(ScriptError, match="no row matches"):
        apply(tables, "DELETE FROM T WHERE v=1;")  # '01' is not '1'.
    assert tables == before
    apply(tables, "DELETE FROM T WHERE group='G' AND v='01';")
    assert tables["T"].rows == [["name", "group", "v"], ["c", "H", "3"]]
    apply(tables, "DELETE FROM T;")
    assert tables["T"].rows == [["name", "group", "v"]]
    with pytest.raises(ScriptError, match="no row matches"):
        apply(tables, "DELETE FROM T;")
    # Even an empty table must reject unknown WHERE columns.
    with pytest.raises(ScriptError, match="no such column"):
        apply(tables, "DELETE FROM T WHERE missing=1;")


def test_update_appends_and_materializes_inherited_values_before_deletion():
    tables = inherited_table()
    apply(tables, "UPDATE T SET name='changed' WHERE name='b';")
    assert tables["T"].rows == [["name", "group", "v"], ["a", "G", "01"],
                                 ["c", "H", "3"], ["changed", "G", "01"]]
    tables = inherited_table()
    apply(tables, "UPDATE T SET v='9' WHERE group='G';")
    assert tables["T"].data == [["c", "H", "3"], ["a", "G", "9"], ["b", "G", "9"]]
    apply(tables, "UPDATE T SET group='-';")
    assert [row[1] for row in tables["T"].data] == ["-", "-", "-"]


@pytest.mark.parametrize("kind", ["UPDATE", "DELETE"])
@pytest.mark.parametrize("typed", [False, True])
def test_mutations_preserve_survivors_after_removing_inheritance_source(kind, typed):
    tables = load_structure("CREATE TABLE T(name String,v String);"
                            "INSERT INTO T(name,v) VALUES('a','10');"
                            "INSERT INTO T(name,v) VALUES('b','-');"
                            "INSERT INTO T(name,v) VALUES('c','20');")
    if not typed:
        tables["T"] = Matrix("T", tables["T"].rows)
    sql = "UPDATE T SET v='11'" if kind == "UPDATE" else "DELETE FROM T"
    apply(tables, sql + " WHERE name='a';")
    expected = [["b", "10"], ["c", "20"]]
    if kind == "UPDATE":
        expected.append(["a", "11"])
    assert tables["T"].rows == [["name", "v"], *expected]
    assert tables["T"].inherited(1, 1) == "10"
    # The preserved value must also be visible to subsequent WHERE matching.
    apply(tables, "DELETE FROM T WHERE v='10';")
    assert tables["T"].data == expected[1:]


@pytest.mark.parametrize("kind", ["UPDATE", "DELETE"])
def test_mutations_preserve_each_column_across_multiple_removed_sources(kind):
    tables = {"T": Matrix("T", [["name", "group", "v", "w"],
                               ["a", "G", "10", "1"], ["b", "H", "-", "2"],
                               ["c", "G", "20", "-"], ["d", "H", "-", "-"],
                               ["e", "-", "-", "-"]])}
    sql = "UPDATE T SET v='11'" if kind == "UPDATE" else "DELETE FROM T"
    apply(tables, sql + " WHERE group='G';")
    expected = [["b", "H", "10", "2"], ["d", "H", "20", "2"], ["e", "H", "20", "2"]]
    if kind == "UPDATE":
        expected += [["a", "G", "11", "1"], ["c", "G", "11", "2"]]
    assert tables["T"].data == expected


def test_update_preserves_explicit_set_dash_but_materializes_survivors():
    tables = {"T": Matrix("T", [["name", "v"], ["a", "10"], ["b", "-"], ["c", "20"]])}
    apply(tables, "UPDATE T SET v='-' WHERE name='a';")
    assert tables["T"].data == [["b", "10"], ["c", "20"], ["a", "-"]]
    assert tables["T"].inherited(3, 1) == "20"


@pytest.mark.parametrize("sql", [
    "UPDATE T SET missing='11' WHERE name='a';",
    "UPDATE T SET v='11' WHERE missing='a';",
    "UPDATE T SET v='11' WHERE name='missing';",
    "DELETE FROM T WHERE missing='a';",
    "DELETE FROM T WHERE name='missing';",
])
def test_failed_mutations_leave_surviving_raw_inheritance_untouched(sql):
    tables = inherited_table()
    before = deepcopy(tables)
    with pytest.raises(ScriptError):
        apply(tables, sql)
    assert tables == before


def test_update_and_delete_no_match_are_errors_without_changes():
    tables = load_structure(BASE)
    before = deepcopy(tables)
    for sql in ("UPDATE Timer SET delay=2 WHERE name='missing';",
                "DELETE FROM Timer WHERE name='missing';"):
        with pytest.raises(ScriptError, match="no row matches"):
            apply(tables, sql)
        assert tables == before
    empty = load_structure("CREATE TABLE T(a String);")
    with pytest.raises(ScriptError, match="no row matches"):
        apply(empty, "UPDATE T SET a=1;")


def test_drop_empty_table_allowed_but_action_forbidden():
    tables = load_structure("CREATE TABLE T(a String);")
    apply(tables, "DROP TABLE T;")
    assert tables == {}
    with pytest.raises(ScriptError, match="Action"):
        parse_sql("DROP TABLE Action;")
    with pytest.raises(ScriptError, match="Action"):
        apply_statement({"Action": Matrix("Action")}, Statement("DROP", "Action"), allow_mutations=True)


_ROW_OPERATIONS = ["INSERT INTO T(a) VALUES(1);", "DELETE FROM T;", "UPDATE T SET a=2;"]


@pytest.mark.parametrize("other", _ROW_OPERATIONS)
@pytest.mark.parametrize("reverse", [False, True])
def test_update_exclusive_against_all_same_table_row_operations(other, reverse):
    update = "UPDATE T SET a=1;"
    with pytest.raises(ScriptError, match="separate statement batch"):
        parse_sql(other + update if reverse else update + other)


@pytest.mark.parametrize("other", _ROW_OPERATIONS + ["CREATE TABLE T(a String);", "DROP TABLE T;"])
@pytest.mark.parametrize("reverse", [False, True])
def test_drop_batch_isolation(other, reverse):
    drop = "DROP TABLE T;"
    sql = other + drop if reverse else drop + other
    if reverse and other.startswith("CREATE"):
        assert len(parse_sql(sql)) == 2  # Undoing a newly-created table is allowed.
    else:
        with pytest.raises(ScriptError, match="batch"):
            parse_sql(sql)


def test_create_then_update_is_forbidden_even_without_insert():
    with pytest.raises(ScriptError, match="created earlier in this batch"):
        parse_sql("CREATE TABLE T(a String);UPDATE T SET a=1;")


def test_created_table_insert_delete_drop_and_independent_table_mutations():
    tables = {}
    apply(tables, "CREATE TABLE T(a String);INSERT INTO T(a) VALUES(1);DELETE FROM T;DROP TABLE T;")
    assert tables == {}
    tables = load_structure("CREATE TABLE T(a String);CREATE TABLE U(a String);"
                            "INSERT INTO T(a) VALUES(1);INSERT INTO U(a) VALUES(2);")
    apply(tables, "UPDATE T SET a=3;DELETE FROM U;")
    assert tables["T"].data == [["3"]]
    assert tables["U"].data == []
    apply(tables, "INSERT INTO T(a) VALUES(4);DELETE FROM T WHERE a=3;")
    assert tables["T"].data == [["4"]]


def test_no_hidden_batch_state_and_read_queries_do_not_touch_rows():
    assert len(parse_sql("UPDATE T SET a=1;SELECT * FROM T;SHOW TABLES;")) == 3
    assert parse_sql("DROP TABLE T;") == parse_sql("DROP TABLE T;")
    tables = load_structure(BASE)
    apply(tables, "UPDATE Timer SET delay=1;")
    apply(tables, "UPDATE Timer SET delay=2;")
    apply(tables, "DROP TABLE Timer;")
    apply(tables, BASE)
    assert tables["Timer"].data == [["timer-0", "50"]]


def test_deepcopy_batch_rollback_preserves_rows_children_and_sql_types():
    original = load_structure(BASE)
    original["Timer"].children.append(Matrix("child", [["v"], ["original"]]))
    before = deepcopy(original)
    clone = deepcopy(original)
    statements = parse_sql("CREATE TABLE Extra(v Number);INSERT INTO Extra(v) VALUES(2);"
                           "INSERT INTO Timer(name,delay) VALUES('x',3);"
                           "DELETE FROM Timer WHERE name='missing';")
    with pytest.raises(ScriptError, match="no row matches"):
        for statement in statements:
            apply_statement(clone, statement, allow_mutations=True)
    clone["Timer"].children[0].rows[1][0] = "changed"
    assert original == before
    assert list(original) == ["Timer"]
    assert isinstance(clone["Timer"], Table)
    assert clone["Timer"].column_types == {"name": "String", "delay": "Number"}
    with pytest.raises(ScriptError, match="Number"):
        apply(clone, "UPDATE Timer SET delay='wrong';")
    clone["Timer"].column_types["delay"] = "String"
    assert original["Timer"].column_types["delay"] == "Number"


@pytest.mark.parametrize("statement", [Statement("EXECUTE", "T"), Statement("create", "T"),
    Statement("DELETE", "T", values=["ignored"]), Statement("DROP", "T", where=[("a", "1")]),
    Statement("UPDATE", "T"), Statement("INSERT", "T", names=["a"], values=[1]),
    Statement("INSERT", "T", names=["a", "a"], values=["1", "2"]),
    Statement("CREATE", "Bad/Name", columns=[("a", "String")]),
    Statement("CREATE", "T", columns=[("a", "Integer")])])
def test_programmatic_statements_cannot_bypass_validation(statement):
    with pytest.raises(ScriptError):
        apply_statement({}, statement, allow_mutations=True)


def test_large_quoted_value_and_wide_column_list_do_not_recurse():
    value = "x" * 100_000
    assert parse_sql(f"INSERT INTO T(a) VALUES('{value}');")[0].values == [value]
    columns = [(f"a{i}", "String") for i in range(3000)]
    statement = parse_sql("CREATE TABLE T(" + ",".join(f"{name} String" for name, _ in columns) + ");")[0]
    assert statement.columns == columns


def test_bundled_relay_sql():
    path = Path(__file__).resolve().parents[1] / "robots" / "relay-test.sql"
    tables = load_structure(path.read_text(encoding="utf-8"))
    assert list(tables) == ["Timer", "Relay"]
    assert all(isinstance(table, Table) for table in tables.values())
    assert tables["Timer"].rows == [["name"], ["timer-0"]]
    assert tables["Relay"].rows == [
        ["name", "controller", "note"], ["relay0", "timer-0", "hello-relay"],
    ]


@pytest.mark.parametrize(("name", "text", "message"), [
    ("insert_badcol.sql",
     "CREATE TABLE Timer(name String,delay Number);"
     "INSERT INTO Timer(nome) VALUES('timer-0');",
     "no such column 'nome'"),
    ("insert_typo.sql",
     "CREATE TABLE Timer(name String);INSERT INTO Timerr(name) VALUES('timer-0');",
     "Table 'Timerr' is not defined"),
    # A separator flood after valid statements must fail cleanly, not recurse.
    ("lex_semicolons.sql", BASE + ";" * 100_000, "Unsupported SQL statement"),
    ("number_bad.sql",
     "CREATE TABLE Timer(name String,delay Number);"
     "INSERT INTO Timer(name,delay) VALUES('timer-0',abc);",
     "declared Number"),
], ids=["insert_badcol", "insert_typo", "lex_semicolons", "number_bad"])
def test_invalid_generic_sql_fixtures(tmp_path, name, text, message):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    with pytest.raises(ScriptError, match=message):
        load_structure(path.read_text(encoding="utf-8"))

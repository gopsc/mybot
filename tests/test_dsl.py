"""Regression tests for the MT grammar and execution contracts."""
from contextlib import contextmanager
from pathlib import Path

import pytest

from conftest import usable_symlink
from pymybot.actions import ActionRunner
from pymybot.errors import BudgetExceeded, ScriptError
from pymybot.expr import Expression, expr_body, render
from pymybot.hardware import Alias, Metadata, Number
from pymybot.include import expand_includes
from pymybot.matrix import Matrix, parse_matrices


class FakeRegistry:
    def __init__(self, *variables):
        self.variables = {v.name: v for v in variables}

    def get(self, name):
        return self.variables.get(name)

    def require(self, name):
        if name not in self.variables:
            raise ScriptError(f"Undefined variable '{name}'")
        return self.variables[name]

    def resolve(self, name):
        variable = self.require(name)
        if variable.kind == "vars":
            return variable.numeric()
        if variable.kind in {"alias", "struct"}:
            return variable.read()
        raise ScriptError("Expression identifier is not a scalar")

    def resolve_number(self, name):
        variable = self.require(name)
        if variable.kind == "struct":
            return variable.read()
        if variable.kind != "vars":
            raise ScriptError(f"Expression identifier '{name}' must be an @Vars number or @Struct value")
        return variable.numeric()

    def override(self, name, variable):
        self.variables[name] = variable

    @contextmanager
    def session(self):
        before = self.variables.copy()
        try:
            yield self
        finally:
            self.variables = before


class FakeBudget:
    def __init__(self, limit=10000):
        self.remaining = limit

    def check(self):
        self.remaining -= 1
        if self.remaining < 0:
            raise BudgetExceeded("Stopped")


class Driver:
    kind = "lua"

    def __init__(self, name="dev", callback=None, trace=None):
        self.name = name
        self.calls = []
        self.callback = callback
        self.trace = trace

    def play(self, params):
        self.calls.append(params.copy())
        if self.trace is not None:
            self.trace.append(self.name)
        return self.callback(params) if self.callback else {"result": "OK", "reading": len(self.calls)}


def run(text, *variables, budget=None):
    registry = FakeRegistry(*variables)
    results = ActionRunner(registry, budget or FakeBudget()).run(parse_matrices(text))
    return registry, results


def block(name, header, *rows):
    return "@" + name + "\n" + ";\n".join([header, *rows]) + ";\n@\n"


def body(name, *parts):
    return "@" + name + "\n" + "".join(parts) + "@\n"


def expand(text, base):
    return expand_includes(parse_matrices(text), base)


def test_matrix_comments_crlf_and_eof():
    text = "@Ti#comment\nname count;\nt0 50#comment\n;\n@\n@Action\nd.p;\n1;\n@"
    assert parse_matrices(text) == parse_matrices(text.replace("\n", "\r\n"))
    first, second = parse_matrices(text)
    assert first.name == "Ti"
    assert first.rows == [["name", "count"], ["t0", "50"]]
    assert second.name == "Action"
    assert parse_matrices("# nothing\n\n") == []
    assert parse_matrices("@Action\na b;\n50# split\n60;\n@\n")[0].data == [["50", "60"]]


def test_matrix_nested_interleaved_implicit_actions():
    text = "@if(1>0)\na.p;1;\n@while(0>1)\n@Action\nb.p;2;\n@\n@\nc.p;3;\n@"
    matrix = parse_matrices(text)[0]
    assert matrix.rows == []
    assert [m.name for m in matrix.children] == ["Action", "while(0>1)", "Action"]
    assert matrix.children[0].header == ["a.p"]
    assert matrix.children[1].children[0].data == [["2"]]
    assert matrix.children[2].header == ["c.p"]


def test_matrix_inheritance_not_header_and_mutable_rows():
    matrix = Matrix("Action", [["d.p"], ["-"], ["1"], ["-"], ["-"]])
    assert matrix.inherited(1, 0) == "-"
    assert matrix.inherited(4, 0) == "1"
    matrix.rows[2][0] = "2"
    assert matrix.inherited(4, 0) == "2"
    del matrix.rows[2]
    assert matrix.inherited(3, 0) == "-"
    with pytest.raises(ScriptError):
        matrix.inherited(-1, 0)
    with pytest.raises(ScriptError):
        matrix.inherited(1, 3)


@pytest.mark.parametrize("text", [
    "@\n", "@Action\na.p;\n1;\n", "@Action\na b;\n1;\n@",
    "@Action\na.p;1\n@if(1>0)\na.p;1;\n@\n@",
    "@if(1>0)\n@Action\na.p;1;\n@\n",
    "@Action\na.p;\n1# missing semicolon\n@",
])
def test_matrix_rejects_malformed(text):
    with pytest.raises(ScriptError):
        parse_matrices(text)


@pytest.mark.parametrize("name", ["Action", "Reflex(f)"])
def test_matrix_action_and_reflex_have_same_ordered_nested_body(name):
    matrix = parse_matrices(body(name, "dev.p;1;\n",
                                 body("Action", "dev.p;2;\n",
                                      body("if(1>0)", block("Action", "dev.p", "3")),
                                      "dev.q;4;\n"),
                                 body("while(0>1)", "dev.p;5;\n"),
                                 "dev.r;6;\n"))[0]
    assert matrix.rows == []
    assert [child.name for child in matrix.children] == ["Action", "Action", "while(0>1)", "Action"]
    assert matrix.children[0].rows == [["dev.p"], ["1"]]
    nested = matrix.children[1]
    assert nested.rows == []
    assert [child.name for child in nested.children] == ["Action", "if(1>0)", "Action"]
    assert nested.children[0].data == [["2"]]
    assert nested.children[1].children[0].data == [["3"]]
    assert nested.children[2].rows == [["dev.q"], ["4"]]
    assert matrix.children[2].children[0].data == [["5"]]
    assert matrix.children[3].rows == [["dev.r"], ["6"]]


def test_matrix_plain_action_keeps_rows_but_reflex_always_has_action_children():
    action = parse_matrices(block("Action", "dev.p", "1", "-"))[0]
    reflex = parse_matrices(block("Reflex(f)", "dev.p", "1", "-"))[0]
    assert action.rows == [["dev.p"], ["1"], ["-"]] and action.children == []
    assert reflex.rows == [] and reflex.children == [action]
    assert parse_matrices(body("Reflex(empty)"))[0].children == []


@pytest.mark.parametrize("parent", ["Action", "if(0>1)", "while(0>1)", "Reflex(outer)"])
@pytest.mark.parametrize("declaration", [body("Reflex(inner)"), '@Struct(state)\n{}\n@\n'])
def test_reflex_and_struct_definitions_are_top_level_only(parent, declaration):
    with pytest.raises(ScriptError):
        parse_matrices(body(parent, declaration))


@pytest.mark.parametrize("declaration", [block("Alias", "name alias", "target dev"),
                                          block("Vars", "name value", "n 1")])
@pytest.mark.parametrize("parent", ["Action", "if(0>1)", "while(0>1)"])
@pytest.mark.parametrize("in_reflex", [False, True])
def test_scalar_declarations_cannot_be_inside_action_or_control(declaration, parent, in_reflex):
    script = body(parent, declaration)
    if in_reflex:
        script = body("Reflex(f)", script)
    with pytest.raises(ScriptError):
        parse_matrices(script)


@pytest.mark.parametrize("name", ["Reflex", "Reflex()", "Reflex(1bad)", "Reflex(a.b)",
                                      "Reflex(a b)", "Reflex(f)junk", "Reflex(f"])
def test_reflex_rejects_old_or_malformed_declaration_names(name):
    with pytest.raises(ScriptError):
        parse_matrices(block(name, "dev.p", "1"))


def test_matrix_depth_limit_and_global_line_number():
    assert parse_matrices("@if(1>0)\n" * 32 + "@\n" * 32)
    with pytest.raises(ScriptError, match="depth"):
        parse_matrices("@if(1>0)\n" * 33 + "@\n" * 33)
    with pytest.raises(ScriptError, match="line 6"):
        parse_matrices("@Relay\n# h\nname note;\n# d\nr0 hello;\nr1;\n@\n")


@pytest.mark.parametrize(("text", "expected"), [
    ("1+2*3", 7.0), ("(1+2)*3", 9.0), ("10-2-3", 5.0),
    ("100/5/2", 10.0), ("-7%4", -3.0), ("--5", 5.0), ("2e3+.5", 2000.5),
    ('"x"+2', "x2"), ('2e3+"x"', "2000x"), ('"a"+"b"', "ab"),
    ("1<0||2>0&&3>4", False), ("1>0||2>0&&3>4", True),
    ('"x"=="x"', True), ("(1>0)==(2>1)", True), ("!(1>0)", False),
    ("1<0&&missing", False), ("1>0||1/0>0", True),
    (r'"a\n\t\r\\\""', 'a\n\t\r\\"'),
    # Unary-run parity is deliberate compatibility with expr.cpp.
    ("!!1", 1.0), ('+"x"', "x"), ("--1", 1.0),
])
def test_expression_grammar(text, expected):
    value = Expression(text).evaluate(lambda name: pytest.fail(f"Resolved skipped '{name}'"))
    assert type(value) is type(expected)
    assert value == expected


def test_expression_identifiers_hyphen_and_number_rendering():
    expression = Expression("foo-bar+foo")
    assert expression.identifiers == {"foo", "bar"}
    assert expression.evaluate({"foo": 3.0, "bar": 2.0}.__getitem__) == 4.0
    assert Expression("1>0||missing").identifiers == {"missing"}
    assert render(2e3) == "2000"
    assert render(1 / 3) == "0.333333333333333"
    assert render(True) == "true"
    assert expr_body("$(x+1)") == "x+1"
    assert expr_body("$(x) ") is None
    assert expr_body("$x") is None


@pytest.mark.parametrize("text", [
    "", "1+", "(1+2", "1 2", "1=2", "a.b", "[1]", "__import__('os')",
    "1e309", '"unterminated', r'"bad\q"', "0x10", "1_000", "1e",
    "1/0", "1%0", "1&&2", "!1", '"x"-1', '1=="1"', "1<2<3",
    "(1>0)+2", '(1>0)+"x"', "1e308*10>0", "1e308*1e308", '"a"+(1e308*10)',
])
def test_expression_rejects_invalid_or_ill_typed_input(text):
    with pytest.raises(ScriptError):
        Expression(text).evaluate(lambda name: 1.0)


def test_expression_depth_operator_limits_and_safe_diagnostics():
    assert Expression("(" * 128 + "1" + ")" * 128).evaluate(None) == 1.0
    assert Expression("0" + "+1" * 512).evaluate(None) == 512.0
    for text in ["(" * 10000, "0" + "+1" * 513]:
        with pytest.raises(ScriptError) as error:
            Expression(text)
        assert len(str(error.value)) < 512
    with pytest.raises(ScriptError) as error:
        Expression("\x1b[31m")
    assert "\x1b" not in str(error.value)


def test_dispatch_aliases_expression_headers_and_group_order():
    trace = []
    a, b = Driver("relay-2", trace=trace), Driver("b", trace=trace)
    registry, outputs = run(
        block("Action", "$(prefix+n).$(key) b.p alias.q", "$(n+1) 4 $(text+n)", "- - -"),
        a, b, Alias("prefix", "relay-"), Number("n", 2), Alias("key", "angle"),
        Alias("alias", "relay-2"), Alias("text", "v="),
    )
    assert trace == ["relay-2", "b", "relay-2", "b"]
    assert a.calls == [{"angle": 3.0, "q": "v=2"}] * 2
    assert b.calls == [{"p": 4.0}] * 2
    assert len(outputs) == 4
    assert registry.resolve("n") == 2


def test_dispatch_phase_padding_and_all_dash_no_argument_devices():
    a, b, c = Driver("a"), Driver("b"), Driver("c")
    run(block("Action", "a.p b.p c.p", "1 - -", "- 2 -", "- - -"), a, b, c)
    assert a.calls == [{"p": 1.0}] * 3
    assert b.calls == [{"p": 2.0}] * 2
    assert c.calls == [{"p": 0.0}] * 3


def test_captures_are_after_whole_row_evaluation_and_re_evaluate_inherited_expressions():
    a, b = Driver("a"), Driver("b")
    registry, _ = run(block("Action", "a.p b.p", "$count=reading $(count)", "- -"),
                      a, b, Number("count", 0))
    assert a.calls == [{}, {}]
    assert b.calls == [{"p": 0.0}, {"p": 1.0}]
    assert registry.resolve("count") == 2.0


def test_capture_path_auto_types_and_declared_alias_bool():
    dev = Driver(callback=lambda params: {"obj": {"n": 2.5, "s": "hi", "b": True}})
    registry, _ = run(block("Action", "dev.a dev.b dev.c", "$n=obj.n $s=obj.s $flag=obj.b"),
                      dev, Alias("flag", "before"))
    assert dev.calls == [{}]
    assert registry.get("n").kind == "vars"
    assert registry.get("s").kind == "alias"
    assert registry.resolve("n") == 2.5
    assert registry.resolve("flag") == "true"


@pytest.mark.parametrize(("value", "target"), [
    (True, None), (None, None), ({}, None), ([], None),
    ("text", Number("x", 0)), (True, Number("x", 0)),
    ({}, Alias("x", "")), (None, Alias("x", "")), (1, Driver("x")),
    (float("inf"), None),
])
def test_capture_rejects_invalid_type(value, target):
    dev = Driver(callback=lambda params: {"reading": value})
    variables = [dev] + ([target] if target else [])
    with pytest.raises(ScriptError):
        run(block("Action", "dev.p", "$x=reading"), *variables)


@pytest.mark.parametrize("cell", ["$x", "$=field", "$x=", "$x=a..b", "$x=.a", "$x=a.", "$bad-name=f", "$x=missing"])
def test_capture_rejects_bad_shape_or_missing_field(cell):
    with pytest.raises(ScriptError):
        run(block("Action", "dev.p", cell), Driver())


def test_nested_conditions_capture_driven_while_and_order():
    trace = []
    a, b, c = Driver("a", trace=trace), Driver("b", trace=trace), Driver("c", trace=trace)
    script = ("@if(1>0)\n@while(count<3)\na.p;\n$count=reading;\n"
              "@if(count>1)\n@Action\nb.p;\n$(count);\n@\n@\n"
              "c.p;\n1;\n@\n@\n")
    registry, outputs = run(script, a, b, c, Number("count", 0))
    assert registry.resolve("count") == 3.0
    assert trace == ["a", "c", "a", "b", "c", "a", "b", "c"]
    assert b.calls == [{"p": 2.0}, {"p": 3.0}]
    assert len(outputs) == 8


def test_false_outer_condition_does_not_evaluate_children():
    dev = Driver()
    run("@if(0>1)\n@while(missing>0)\ndev.p;\n1;\n@\n@\n", dev)
    assert dev.calls == []


@pytest.mark.parametrize("name", ["if", "while", "if()", "while()", "if(1>", "if(1)", 'while("yes")'])
def test_bad_conditions_rejected(name):
    with pytest.raises(ScriptError):
        ActionRunner(FakeRegistry(), FakeBudget()).run([Matrix(name)])


def test_stop_and_deadline_budget_propagate_even_in_empty_loop():
    with pytest.raises(BudgetExceeded):
        run("@while(1==1)\n@", budget=FakeBudget(25))
    budget = FakeBudget()
    dev = Driver(callback=lambda params: (setattr(budget, "remaining", -1) or {"result": "OK"}))
    other = Driver("other")
    with pytest.raises(BudgetExceeded):
        run(block("Action", "dev.p other.p", "1 1"), dev, other, budget=budget)
    assert len(dev.calls) == 1
    assert not other.calls


@pytest.mark.parametrize(("header", "cell", "extras"), [
    ("dev", "1", []), ("dev..p", "1", []), (".p", "1", []), ("dev.", "1", []),
    ("dev.$(1>0)", "1", []), ("dev.p", "garbage", []), ("dev.p", "$(1>0)", []),
    ("dev.p", "nan", []), ("dev.p", "inf", []), ("dev.p", "1_000", []),
    ("dev.p", "$(1+", []), ("n.p", "1", [Number("n", 2)]),
    ("a.p", "1", [Alias("a", "b"), Alias("b", "dev")]),
    ("a.p", "1", [Alias("a", "missing")]),
    ("missing.p", "-", []),
])
def test_invalid_dispatch(header, cell, extras):
    with pytest.raises(ScriptError):
        run(block("Action", header, cell), Driver(), *extras)


def test_duplicate_resolved_columns_reject_before_play():
    dev = Driver()
    with pytest.raises(ScriptError, match="duplicates"):
        run(block("Action", "a.p dev.$(key)", "1 2"), dev, Alias("a", "dev"), Alias("key", "p"))
    assert dev.calls == []


@pytest.mark.parametrize("result", [{}, 1, None, {"result": "ERR"}, {"result": "unknown"}, {"result": 1}])
def test_driver_failure_halts_later_rows(result):
    dev = Driver(callback=lambda params: result)
    with pytest.raises(ScriptError):
        run(block("Action", "dev.p", "1", "2"), dev)
    assert len(dev.calls) == 1


def test_reflex_order_multibeat_arguments_inheritance_and_restore():
    dev = Driver()
    script = (block("Action", "dev.p", "1")
              + block("Action", "blink.x", "2", "-")
              + block("Reflex(blink)", "dev.p", "$(x)", "-")
              + block("Reflex(other)", "dev.p", "9")
              + block("Action", "other.unused", "0"))
    registry, outputs = run(script, dev, Alias("x", "original"))
    assert dev.calls == [{"p": 1.0}] + [{"p": 2.0}] * 4 + [{"p": 9.0}]
    assert registry.resolve("x") == "original"
    assert registry.get("unused") is None
    assert [output["reading"] for output in outputs] == list(range(1, 7))


def test_reflex_scopes_restore_on_driver_failure_and_unused_body_is_lazy():
    original = Alias("x", "original")
    dev = Driver(callback=lambda p: {"result": "ERR"})
    registry = FakeRegistry(dev, original)
    runner = ActionRunner(registry, FakeBudget())
    with pytest.raises(ScriptError):
        runner.run(parse_matrices(block("Reflex(f)", "dev.p", "$(x)") + block("Action", "f.x", "2")))
    assert registry.get("x") is original
    runner.run(parse_matrices(block("Reflex(unused)", "missing.p", "$(undefined)") + body("if(1<0)")))
    assert len(dev.calls) == 1


@pytest.mark.parametrize("call", ["f", "f()", "f(x=1)", "f(x)", "f(x=)", "f(=x)",
                                   "f(x=1,x=2)", "f(x=1", "f(bad-name=1)", "missing", "(x=1)"])
@pytest.mark.parametrize("nested", [False, True])
def test_removed_trigger_calls_are_rejected_at_parse_time(call, nested):
    trigger = block("Trigger", "trigger", call)
    script = body("if(0>1)", trigger) if nested else trigger
    with pytest.raises(ScriptError):
        parse_matrices(block("Reflex(f)", "dev.p", "1") + script)


@pytest.mark.parametrize("parent", [None, "if(0>1)", "Reflex(unused)"])
def test_legacy_reflex_table_is_rejected_even_when_unreachable(parent):
    legacy = block("Reflex", "name dev.p", "f 1")
    with pytest.raises(ScriptError):
        parse_matrices(body(parent, legacy) if parent else legacy)


@pytest.mark.parametrize(("cell", "expression", "expected"), [
    ("4", "$(x+1)", 5.0), ("$(2+3)", "$(x*2)", 10.0),
    ('$("你好")', '$(x+"!")', "你好!"), ('$("4")', '$(x+"!")', "4!"),
])
def test_reflex_action_typed_arguments_and_literal_parameter_names(cell, expression, expected):
    dev = Driver()
    original = Alias("x", "original")
    script = (block("Action", "f.x", cell) + block("Reflex(f)", "dev.p", expression))
    registry, outputs = run(script, dev, original)
    assert dev.calls == [{"p": expected}]
    assert type(dev.calls[0]["p"]) is type(expected)
    assert registry.get("x") is original
    assert len(outputs) == 1


def test_reflex_action_preserves_numeric_precision_without_text_coercion():
    dev = Driver()
    number = Number("n", 2.3456, precision=2)
    script = (block("Reflex(f)", "dev.p", "$(x+1)")
              + block("Action", "f.x dev.p", "$(n) $(n)"))
    registry, outputs = run(script, dev, number)
    assert dev.calls[0]["p"] == pytest.approx(3.3456)
    assert isinstance(dev.calls[0]["p"], float)
    assert dev.calls[1]["p"] == "2.35"
    assert registry.get("n") is number
    assert len(outputs) == 2


def test_reflex_action_multibeat_inline_order():
    trace = []
    dev, other = Driver(trace=trace), Driver("other", trace=trace)
    script = (block("Action", "other.p f.x f.y", "0 2 3", "- 4 -")
              + block("Reflex(f)", "dev.p dev.q", "$(x) $(y)", "- -")
              + block("Action", "f.x f.y", "9 8"))
    registry, outputs = run(script, dev, other)
    assert trace == ["other", "dev", "dev", "other", "dev", "dev", "dev", "dev"]
    assert dev.calls == ([{"p": 2.0, "q": 3.0}] * 2 + [{"p": 4.0, "q": 3.0}] * 2
                         + [{"p": 9.0, "q": 8.0}] * 2)
    assert len(outputs) == 8
    assert registry.get("x") is None and registry.get("y") is None


@pytest.mark.parametrize("name", ["Action", "Reflex(f)"])
def test_action_and_reflex_execute_same_mixed_nested_body_in_order(name):
    dev = Driver()
    contents = ("dev.p;10;\n"
                + body("Action", "dev.p;20;\n",
                       body("while(count<4)", block("Action", "dev.cap", "$count=reading"),
                            body("if(count==3)", "dev.p;30;\n")),
                       "dev.p;40;\n")
                + "dev.p;50;\n")
    script = body(name, contents)
    if name != "Action":
        script += block("Action", "f.capture", "$returned=reading")
    registry, outputs = run(script, dev, Number("count", 0))
    assert dev.calls == [{"p": 10.0}, {"p": 20.0}, {}, {"p": 30.0}, {}, {"p": 40.0}, {"p": 50.0}]
    assert [output["reading"] for output in outputs] == list(range(1, 8))
    assert registry.resolve("count") == (5.0 if name == "Action" else 0.0)
    if name != "Action":
        assert registry.resolve("returned") == 7.0


def test_reflex_action_alias_dynamic_headers_and_duplicate_targets():
    dev = Driver()
    definitions = block("Reflex(f)", "dev.p", "$(x)")
    run(definitions + block("Action", "target.x $(name).$(key)", "2 3"),
        dev, Alias("target", "f"), Alias("name", "f"), Alias("key", "y"))
    assert dev.calls == [{"p": 2.0}]
    with pytest.raises(ScriptError, match="duplicates"):
        run(definitions + block("Action", "target.x f.$(key)", "2 3"),
            dev, Alias("target", "f"), Alias("key", "x"))
    assert len(dev.calls) == 1


def test_reflex_action_capture_uses_last_result_and_whole_row_evaluation():
    dev, other = Driver(), Driver("other")
    script = (block("Reflex(f)", "dev.p", "$(x)", "-")
              + block("Action", "f.x f.capture other.p", "7 $count=reading $(count)", "- - -"))
    registry, outputs = run(script, dev, other, Number("count", 0))
    assert other.calls == [{"p": 0.0}, {"p": 2.0}]
    assert registry.resolve("count") == 4.0
    assert len(outputs) == 6


def test_reflex_capture_only_calls_have_no_required_dummy_argument():
    dev = Driver()
    script = (block("Reflex(f)", "dev.p", "7", "-")
              + block("Action", "f.capture", "$count=reading")
              + block("Action", "f.unused", "0"))
    registry, outputs = run(script, dev)
    assert dev.calls == [{"p": 7.0}] * 4
    assert registry.resolve("count") == 2.0
    assert registry.get("capture") is None and registry.get("unused") is None
    assert [output["reading"] for output in outputs] == [1, 2, 3, 4]


def test_reflex_action_inside_capture_driven_loop():
    dev = Driver()
    script = (block("Reflex(f)", "dev.p", "$(x)")
              + body("while(count<3)", block("Action", "f.x f.capture", "$(count+1) $count=reading")))
    registry, outputs = run(script, dev, Number("count", 0))
    assert dev.calls == [{"p": 1.0}, {"p": 2.0}, {"p": 3.0}]
    assert registry.resolve("count") == 3.0
    assert len(outputs) == 3


def test_reflex_action_nested_scopes_only_propagate_explicit_outer_capture():
    dev = Driver()
    original, count = Number("x", 20), Number("count", 99)
    script = (body("Reflex(outer)",
                   block("Action", "inner.x inner.capture", "$(x+1) $count=reading"),
                   block("Action", "dev.p dev.q", "$(x) $(count)"))
              + block("Reflex(inner)", "dev.p dev.cap dev.local", "$(x+2) $count=reading $x=reading")
              + block("Action", "outer.x outer.capture", "4 $returned=reading")
              + block("Action", "dev.p dev.q", "$(x) $(count)"))
    registry, outputs = run(script, dev, original, count)
    assert dev.calls == [{"p": 7.0}, {"p": 4.0, "q": 1.0}, {"p": 20.0, "q": 99.0}]
    assert registry.get("x") is original and registry.get("count") is count
    assert registry.resolve("returned") == 2.0
    assert [output["reading"] for output in outputs] == [1, 2, 3]


@pytest.mark.parametrize("nested", [False, True])
def test_reflex_action_failure_restores_all_captures_without_undoing_calls(nested):
    dev = Driver()
    original, count = Alias("x", "original"), Number("count", 99)
    registry = FakeRegistry(dev, original, count)
    script = block("Reflex(inner)", "dev.p dev.cap dev.new", "$(x) $count=reading $fresh=reading",
                   "$(missing) - -")
    if nested:
        script += (body("Reflex(outer)", block("Alias", "name alias", "target inner"),
                        block("Action", "target.x target.capture", "$(x) $count=reading"))
                   + block("Action", "outer.x outer.capture", "4 $returned=reading"))
    else:
        script += block("Action", "inner.x inner.capture", "4 $returned=reading")
    with pytest.raises(ScriptError, match="missing"):
        ActionRunner(registry, FakeBudget()).run(parse_matrices(script))
    assert dev.calls == [{"p": 4.0}]
    assert registry.get("x") is original and registry.get("count") is count
    assert all(registry.get(name) is None for name in ("target", "fresh", "returned"))


@pytest.mark.parametrize("mutual", [False, True])
def test_reflex_action_recursion_has_shared_depth_limit(mutual):
    original = Alias("x", "original")
    registry = FakeRegistry(original)
    script = block("Reflex(f)", "g.x" if mutual else "f.x", "$(x)")
    if mutual:
        script += block("Reflex(g)", "f.x", "$(x)")
    script += block("Action", "f.x", "1")
    with pytest.raises(ScriptError, match="(?i)reflex.*32"):
        ActionRunner(registry, FakeBudget()).run(parse_matrices(script))
    assert registry.get("x") is original


@pytest.mark.parametrize("depth", [0, 3, 15])
def test_reflex_recursion_terminates_on_condition_and_restores_each_frame(depth):
    dev = Driver()
    original = Number("n", 100)
    script = (body("Reflex(countdown)", "dev.p;$(n);\n",
                   body("if(n>0)", block("Action", "countdown.n", "$(n-1)")),
                   "dev.p;$(n);\n")
              + block("Action", "countdown.n countdown.capture", f"{depth} $last=reading"))
    registry, outputs = run(script, dev, original)
    expected = list(range(depth, -1, -1)) + list(range(depth + 1))
    assert [params["p"] for params in dev.calls] == expected
    assert len(outputs) == 2 * (depth + 1)
    assert registry.resolve("last") == len(outputs)
    assert registry.get("n") is original


@pytest.mark.parametrize("depth", [16, 31])
def test_reflex_recursion_and_control_blocks_share_execution_depth_limit(depth):
    dev = Driver()
    original = Number("n", 100)
    registry = FakeRegistry(dev, original)
    runner = ActionRunner(registry, FakeBudget())
    script = (body("Reflex(countdown)", "dev.p;$(n);\n",
                   body("if(n>0)", block("Action", "countdown.n", "$(n-1)")))
              + block("Action", "countdown.n", str(depth)))
    with pytest.raises(ScriptError, match="nesting.*depth"):
        runner.run(parse_matrices(script))
    assert registry.get("n") is original
    assert len(dev.calls) == 16
    runner.run(parse_matrices(block("Action", "dev.p", "1")))
    assert dev.calls[-1] == {"p": 1.0}


@pytest.mark.parametrize("parameter", ["bad-name", '$("1bad")', '$("x.y")'])
def test_reflex_action_rejects_invalid_parameter_names(parameter):
    dev = Driver()
    script = block("Reflex(f)", "dev.p", "1") + block("Action", f"f.{parameter}", "1")
    with pytest.raises(ScriptError, match="safe identifiers"):
        run(script, dev)
    assert dev.calls == []


@pytest.mark.parametrize("kind", ["lua", "daemon", "struct"])
@pytest.mark.parametrize("source", ["parameter", "Alias", "Vars"])
def test_reflex_bindings_cannot_replace_non_scalars(kind, source):
    dev, protected = Driver(), Driver("protected")
    protected.kind = kind
    registry = FakeRegistry(dev, protected)
    declaration = "" if source == "parameter" else block(
        source, "name alias" if source == "Alias" else "name value", "protected 1")
    script = (body("Reflex(f)", declaration, block("Action", "dev.p", "1"))
              + block("Action", "f.protected" if source == "parameter" else "f.unused", "1"))
    with pytest.raises(ScriptError, match="(?i)cannot replace"):
        ActionRunner(registry, FakeBudget()).run(parse_matrices(script))
    assert registry.get("protected") is protected
    assert dev.calls == []


@pytest.mark.parametrize("source", ["parameter", "Alias", "Vars", "capture"])
def test_reflex_bindings_and_captures_respect_registry_flow_refs(source):
    from pymybot.hardware import Registry

    registry = Registry()
    dev, protected = Driver(), Number("protected", 42)
    registry.add(dev)
    registry.add(protected)
    registry.flow_refs.add("protected")
    declaration = (block(source, "name alias" if source == "Alias" else "name value", "protected 1")
                   if source in {"Alias", "Vars"} else "")
    script = (body("Reflex(f)", declaration,
                   block("Action", "dev.p", "$protected=reading" if source == "capture" else "1"))
              + block("Action", "f.protected" if source == "parameter" else "f.unused", "1"))
    with pytest.raises(ScriptError, match="referenced|override|protected"):
        ActionRunner(registry, FakeBudget()).run(parse_matrices(script))
    assert registry.get("protected") is protected
    assert registry.flow_refs == {"protected"}
    assert len(dev.calls) == (1 if source == "capture" else 0)


@pytest.mark.parametrize("limit", ["MAX_OUTPUTS", "MAX_OUTPUT_BYTES"])
@pytest.mark.parametrize("nested", [False, True])
def test_reflex_action_uses_shared_output_budget(limit, nested, monkeypatch):
    import pymybot.actions as actions_module

    monkeypatch.setattr(actions_module, limit, 2 if limit == "MAX_OUTPUTS" else 80)
    dev = Driver(callback=lambda params: {"result": "OK", "payload": "x" * 20})
    script = block("Reflex(f)", "dev.p", "$(x)", "-", "-")
    if nested:
        script += block("Reflex(outer)", "f.x", "$(x)")
    script += block("Action", "dev.p outer.x" if nested else "dev.p f.x", "0 1")
    registry = FakeRegistry(dev)
    with pytest.raises(ScriptError, match="output budget"):
        ActionRunner(registry, FakeBudget()).run(parse_matrices(script))
    assert len(dev.calls) == (3 if limit == "MAX_OUTPUTS" else 2)
    assert registry.get("x") is None


def test_reflex_action_cancel_restores_scope_and_stops_later_calls():
    budget = FakeBudget()
    dev = Driver(callback=lambda params: (setattr(budget, "remaining", -1) or {"result": "OK"}))
    other = Driver("other")
    original = Alias("target", "before")
    registry = FakeRegistry(dev, other, original)
    script = (body("Reflex(f)", block("Alias", "name alias", "target dev"),
                   block("Vars", "name value", "local 5"),
                   block("Action", "target.p other.p", "$(x+local) 1"))
              + block("Action", "f.x", "2"))
    with pytest.raises(BudgetExceeded):
        ActionRunner(registry, budget).run(parse_matrices(script))
    assert dev.calls == [{"p": 7.0}] and other.calls == []
    assert registry.get("x") is None and registry.get("local") is None
    assert registry.get("target") is original


def test_reflex_definitions_do_not_survive_another_run():
    dev = Driver()
    registry = FakeRegistry(dev)
    runner = ActionRunner(registry, FakeBudget())
    action = block("Action", "f.x", "1")
    runner.run(parse_matrices(block("Reflex(f)", "dev.p", "$(x)") + action))
    with pytest.raises(ScriptError, match="Undefined"):
        runner.run(parse_matrices(action))
    assert len(dev.calls) == 1
    runner.run(parse_matrices(block("Reflex(unused)", "missing.p", "$(undefined)") + body("if(1<0)")))
    assert len(dev.calls) == 1


def test_reflex_action_does_not_shadow_existing_hardware_or_alias():
    dev, other = Driver("f"), Driver("other")
    script = (block("Reflex(f)", "absent.p", "9")
              + block("Reflex(target)", "absent.p", "9")
              + block("Action", "f.x target.p", "1 2"))
    run(script, dev, other, Alias("target", "other"))
    assert dev.calls == [{"x": 1.0}] and other.calls == [{"p": 2.0}]


def test_registry_number_takes_precedence_over_same_named_reflex():
    dev = Driver()
    with pytest.raises(ScriptError):
        run(block("Reflex(f)", "dev.p", "1") + block("Action", "f.x", "1"), dev, Number("f", 2))
    assert dev.calls == []


@pytest.mark.parametrize("script", [
    block("Reflex(f)", "dev.p", "1") + block("Action", "missing.x", "1"),
    block("Reflex(f)", "name dev.p", "f 1") + block("Action", "f.unused", "0"),
    block("Reflex(f)", "dev.p name", "1 f") + block("Action", "f.unused", "0"),
    block("Reflex(f)", "dev.p", "$(x)") + block("Action", "f.y", "1"),
    block("Reflex(f)", "dev.p", "$(x)") + block("Action", "f.capture", "$out=reading"),
    block("Reflex(f)", "dev.p", "$(x)") + block("Action", "f.x", "$(1>0)"),
])
def test_reflex_action_invalid_calls_do_not_dispatch(script):
    dev = Driver()
    with pytest.raises(ScriptError):
        run(script, dev)
    assert dev.calls == []


@pytest.mark.parametrize("called", [False, True])
def test_duplicate_reflex_definitions_fail_before_any_action(called):
    dev = Driver()
    script = block("Action", "dev.p", "99") + block("Reflex(f)", "dev.p", "1") * 2
    if called:
        script += block("Action", "f.unused", "0")
    with pytest.raises(ScriptError, match="(?i)duplicate"):
        run(script, dev)
    assert dev.calls == []


def test_unused_reflex_body_is_still_checked_for_syntax_errors():
    script = block("Action", "dev.p", "99") + "@Reflex(unused)\ndev.p dev.q;\n1;\n@\n"
    dev = Driver()
    with pytest.raises(ScriptError):
        run(script, dev)
    assert dev.calls == []


def test_reflex_local_declarations_are_registered_on_call_with_parameter_precedence():
    dev = Driver()
    base, word, target = Number("base", 100), Alias("word", "parent"), Alias("target", "absent")
    script = (body("Reflex(f)", "target.p target.q;$(scaled) $(word);\n",
                   block("Vars", "name value", "scaled $(base*2)", "base 2"),
                   block("Alias", "name alias", "target dev", "word default"))
              + block("Action", "f.base f.word", '5 $("passed")')
              + block("Action", "f.unused", "0"))
    registry, outputs = run(script, dev, base, word, target)
    assert dev.calls == [{"p": 10.0, "q": "passed"}, {"p": 4.0, "q": "default"}]
    assert registry.get("base") is base and registry.get("word") is word
    assert registry.get("target") is target
    assert registry.get("scaled") is None and registry.get("unused") is None
    assert len(outputs) == 2


@pytest.mark.parametrize("declaration", [block("Vars", "name value", "x 99"),
                                          block("Alias", "name alias", "x default")])
@pytest.mark.parametrize(("argument", "expected"), [("5", 5.0), ('$("text")', "text")])
def test_reflex_typed_parameters_override_local_default_type(declaration, argument, expected):
    dev = Driver()
    original = Alias("x", "parent")
    script = (body("Reflex(f)", declaration, block("Action", "dev.p", "$(x)"))
              + block("Action", "f.x", argument))
    registry, _ = run(script, dev, original)
    assert dev.calls == [{"p": expected}]
    assert type(dev.calls[0]["p"]) is type(expected)
    assert registry.get("x") is original


def test_reflex_local_vars_precision_formats_driver_but_not_nested_typed_argument():
    dev = Driver()
    script = (body("Reflex(outer)", block("Vars", "name value precision", "ratio 2.3456 2"),
                   block("Action", "dev.p inner.x", "$(ratio) $(ratio)"))
              + block("Reflex(inner)", "dev.p", "$(x+1)")
              + block("Action", "outer.unused", "0"))
    registry, outputs = run(script, dev)
    assert dev.calls[0] == {"p": "2.35"}
    assert dev.calls[1]["p"] == pytest.approx(3.3456)
    assert isinstance(dev.calls[1]["p"], float)
    assert registry.get("ratio") is None and registry.get("x") is None
    assert len(outputs) == 2


@pytest.mark.parametrize("precision", ["-1", "16", "1.5", "nope"])
def test_reflex_invalid_local_precision_restores_partially_registered_scope(precision):
    dev = Driver()
    original = Alias("target", "parent")
    registry = FakeRegistry(dev, original)
    script = (body("Reflex(f)", block("Alias", "name alias", "target dev"),
                   block("Vars", "name value precision", f"x 1 {precision}"),
                   block("Action", "target.p", "$(x)"))
              + block("Action", "f.unused", "0"))
    with pytest.raises(ScriptError, match="precision"):
        ActionRunner(registry, FakeBudget()).run(parse_matrices(script))
    assert dev.calls == []
    assert registry.get("target") is original
    assert registry.get("x") is None and registry.get("unused") is None


def test_reflex_local_numeric_expressions_reject_alias_dependencies():
    dev = Driver()
    script = (body("Reflex(f)", block("Alias", "name alias", "text 3"),
                   block("Vars", "name value", "x $(text+1)"),
                   block("Action", "dev.p", "$(x)"))
              + block("Action", "f.unused", "0"))
    registry = FakeRegistry(dev)
    with pytest.raises(ScriptError, match="Vars"):
        ActionRunner(registry, FakeBudget()).run(parse_matrices(script))
    assert dev.calls == [] and set(registry.variables) == {"dev"}


def test_unused_reflex_local_declarations_never_replace_parent_scalars():
    original = Number("x", 7)
    script = (body("Reflex(unused)", block("Vars", "name value", "x $(missing)"),
                   block("Alias", "name alias", "target absent"), block("Action", "target.p", "$(x)"))
              + body("if(0>1)"))
    registry, outputs = run(script, original)
    assert outputs == [] and registry.get("x") is original
    assert registry.get("target") is None


def test_top_level_scalars_are_pre_registered_by_caller_not_action_runner():
    dev = Driver()
    original = Number("x", 8)
    script = (block("Vars", "name value", "x 1") + block("Alias", "name alias", "target absent")
              + block("Action", "target.p", "$(x)"))
    registry, _ = run(script, dev, original, Alias("target", "dev"))
    assert dev.calls == [{"p": 8.0}]
    assert registry.get("x") is original


def test_no_executable_block_and_unexpanded_directive_rejected():
    for text in ["", block("Alias", "name alias", "x y"),
                 block("Include", "path", "x.mt"), block("Unknown", "name", "x")]:
        with pytest.raises(ScriptError):
            run(text)


def test_reflex_definitions_alone_do_not_execute_the_body():
    dev = Driver()
    with pytest.raises(ScriptError, match="No @Action"):
        run(block("Reflex(f)", "dev.p", "1"), dev)
    assert dev.calls == []


def test_include_preserves_multiple_reflex_definitions_and_mixed_action_order(tmp_path):
    definitions = (body("Reflex(f)", block("Alias", "name alias", "target dev"),
                        block("Vars", "name value", "next $(x+1)"), "target.p;$(x);\n",
                        body("Action", body("if(x>0)", block("Action", "g.x", "$(next)"))),
                        "target.p;$(x);\n")
                   + block("Reflex(g)", "dev.p", "$(x)"))
    (tmp_path / "definitions.mt").write_text(definitions, encoding="utf-8")
    script = (block("Action", "dev.p", "0") + block("Include", "path", "definitions.mt")
              + body("Action", "f.x;2;\n", body("if(1>0)", block("Action", "g.x", "4")),
                     "dev.p;9;\n"))
    matrices = expand(script, tmp_path)
    assert [matrix.name for matrix in matrices] == ["Action", "Reflex(f)", "Reflex(g)", "Action"]
    dev = Driver()
    registry = FakeRegistry(dev)
    outputs = ActionRunner(registry, FakeBudget()).run(matrices)
    assert dev.calls == [{"p": value} for value in (0.0, 2.0, 3.0, 2.0, 4.0, 9.0)]
    assert [output["reading"] for output in outputs] == list(range(1, 7))
    assert set(registry.variables) == {"dev"}


def test_include_duplicate_reflex_names_fail_before_any_driver_call(tmp_path):
    (tmp_path / "definitions.mt").write_text(block("Reflex(f)", "dev.p", "1"), encoding="utf-8")
    dev = Driver()
    with pytest.raises(ScriptError, match="(?i)duplicate"):
        matrices = expand(block("Action", "dev.p", "99")
                          + block("Include", "path", "definitions.mt", "definitions.mt"), tmp_path)
        ActionRunner(FakeRegistry(dev), FakeBudget()).run(matrices)
    assert dev.calls == []


def test_include_copy_repeated_once_named_files_and_nested_relative_paths(tmp_path):
    sub = tmp_path / "sub"
    sub.mkdir()
    (sub / "inner.once.mt").write_text("@if(1>0)\na.p;1;\n@", encoding="utf-8")
    (sub / "mid.mt").write_text(block("Include", "path", "inner.once.mt", "inner.once.mt"), encoding="utf-8")
    matrices = expand(block("Include", "path", "sub/mid.mt") + block("Action", "b.p", "2"), tmp_path)
    assert [m.name for m in matrices] == ["if(1>0)", "if(1>0)", "Action"]
    assert matrices[0].children[0].header == ["a.p"]


def test_merge_phase_padding_inherited_phase_and_anchor(tmp_path):
    (tmp_path / "b.mt").write_text(block("Action", "b.p", "100", "200"), encoding="utf-8")
    (tmp_path / "c.mt").write_text(block("Action", "c.p", "7"), encoding="utf-8")
    text = ("@if(0>1)\na.p;1;\n@\n" + block("Action", "a.p", "1", "2")
            + block("Merge", "path phase", "b.mt 1", "c.mt -"))
    matrices = expand(text, tmp_path)
    assert [m.name for m in matrices] == ["if(0>1)", "Action"]
    action = matrices[1]
    assert action.rows == [["a.p", "b.p", "c.p"], ["1", "-", "-"], ["2", "100", "7"], ["-", "200", "-"]]
    a, b, c = Driver("a"), Driver("b"), Driver("c")
    ActionRunner(FakeRegistry(a, b, c), FakeBudget()).run(matrices)
    assert b.calls == [{"p": 100.0}, {"p": 200.0}]
    assert c.calls == [{"p": 7.0}, {"p": 7.0}]


def test_merge_first_fragment_ignores_phase_without_accumulator(tmp_path):
    (tmp_path / "b.mt").write_text(block("Action", "b.p", "1"), encoding="utf-8")
    assert expand(block("Merge", "path phase", "b.mt 5"), tmp_path)[0].data == [["1"]]


def test_merge_nested_relative_once_diamond_and_scalar_precedence(tmp_path):
    sub = tmp_path / "sub"
    sub.mkdir()
    (sub / "shared.once.mt").write_text(block("Vars", "name value", "n 2") + block("Action", "s.p", "3"), encoding="utf-8")
    (sub / "a.mt").write_text(block("Vars", "name value", "n 1") + block("Merge", "path", "shared.once.mt")
                              + block("Action", "a.p", "1"), encoding="utf-8")
    (sub / "b.mt").write_text(block("Merge", "path", "shared.once.mt") + block("Action", "b.p", "2"), encoding="utf-8")
    matrices = expand(block("Vars", "name value", "n 9") + block("Merge", "path", "sub/a.mt", "sub/b.mt"), tmp_path)
    assert matrices[0].rows == [["name", "value"], ["n", "9"]]
    assert matrices[1].header == ["a.p", "s.p", "b.p"]
    assert matrices[1].data == [["1", "3", "2"]]


def test_merge_scalar_collision_and_repeated_definitions(tmp_path):
    for name in ["a", "b"]:
        (tmp_path / f"{name}.mt").write_text(block("Alias", "name alias", "x y"), encoding="utf-8")
    with pytest.raises(ScriptError, match="duplicate Alias"):
        expand(block("Merge", "path", "a.mt", "b.mt"), tmp_path)
    with pytest.raises(ScriptError, match="duplicate Vars"):
        expand(block("Vars", "name value", "x 1") + block("Vars", "name value", "x 2") + "@Merge\n@", tmp_path)


def test_include_and_merge_cycles(tmp_path):
    (tmp_path / "copy.mt").write_text(block("Include", "path", "copy.mt"), encoding="utf-8")
    with pytest.raises(ScriptError, match="cycle"):
        expand(block("Include", "path", "copy.mt"), tmp_path)
    (tmp_path / "plain.mt").write_text(block("Merge", "path", "plain.mt"), encoding="utf-8")
    with pytest.raises(ScriptError, match="more than once"):
        expand(block("Merge", "path", "plain.mt"), tmp_path)
    (tmp_path / "shared.once.mt").write_text(block("Merge", "path", "shared.once.mt") + block("Action", "a.p", "1"), encoding="utf-8")
    assert expand(block("Merge", "path", "shared.once.mt"), tmp_path)[0].data == [["1"]]


def test_nested_merge_is_position_local_and_recursive(tmp_path):
    (tmp_path / "b.mt").write_text(block("Action", "b.p", "2"), encoding="utf-8")
    text = "@if(1>0)\n@while(0>1)\n" + block("Merge", "path phase", "b.mt 1") + block("Action", "a.p", "1") + "@\n@"
    matrices = expand(text, tmp_path)
    merged = matrices[0].children[0].children[0]
    assert merged.rows == [["a.p", "b.p"], ["1", "-"], ["-", "2"]]


@pytest.mark.parametrize("directive", ["Include", "Merge"])
@pytest.mark.parametrize("path", ["/secret.mt", "../secret.mt", "./a.mt", "a//b.mt", "a/../b.mt", "a.lua", "C:/secret.mt", "C:secret.mt", r"a\b.mt", "a\0.mt"])
def test_include_sandbox_paths(tmp_path, directive, path):
    matrices = [Matrix(directive, [["path"], [path]])]
    with pytest.raises(ScriptError):
        expand_includes(matrices, tmp_path)


def test_include_rejects_links_and_directory_targets(tmp_path):
    (tmp_path / "target.mt").write_text(block("Action", "a.p", "1"), encoding="utf-8")
    (tmp_path / "directory.mt").mkdir()
    with pytest.raises(ScriptError, match="regular file"):
        expand(block("Include", "path", "directory.mt"), tmp_path)
    try:
        created = (usable_symlink(tmp_path / "link.mt", tmp_path / "target.mt")
                   and usable_symlink(tmp_path / "dirlink", tmp_path))
    except NotImplementedError:
        created = False
    if not created:
        pytest.skip("Platform cannot create usable symbolic links")
    for path in ["link.mt", "dirlink/target.mt"]:
        with pytest.raises(ScriptError, match="symbolic link"):
            expand(block("Include", "path", path), tmp_path)


def test_include_shared_row_depth_and_byte_budgets(tmp_path, monkeypatch):
    import pymybot.include as module

    (tmp_path / "a.mt").write_text(block("Action", "a.p", "1"), encoding="utf-8")
    monkeypatch.setattr(module, "MAX_INCLUDES", 2)
    with pytest.raises(ScriptError, match="limit"):
        expand(block("Include", "path", "a.mt", "a.mt", "absent.mt"), tmp_path)
    monkeypatch.setattr(module, "MAX_INCLUDES", 32)
    monkeypatch.setattr(module, "MAX_INCLUDE_DEPTH", 1)
    (tmp_path / "b.mt").write_text(block("Include", "path", "a.mt"), encoding="utf-8")
    with pytest.raises(ScriptError, match="limit"):
        expand(block("Include", "path", "b.mt"), tmp_path)
    monkeypatch.setattr(module, "MAX_INCLUDE_DEPTH", 32)
    monkeypatch.setattr(module, "MAX_INCLUDE_BYTES", (tmp_path / "a.mt").stat().st_size + 1)
    with pytest.raises(ScriptError, match="byte limit"):
        expand(block("Include", "path", "a.mt", "a.mt"), tmp_path)


def test_include_parse_failure_does_not_disclose_content(tmp_path):
    secret = "VERY_SECRET_LOCAL_VALUE"
    (tmp_path / "bad.mt").write_text("@" + secret, encoding="utf-8")
    with pytest.raises(ScriptError) as error:
        expand(block("Include", "path", "bad.mt"), tmp_path)
    assert secret not in str(error.value)


@pytest.mark.parametrize("text", [
    block("Include", "path phase", "a.mt 1"),
    "@if(1>0)\n" + block("Include", "path", "a.mt") + "@",
    "@if(1>0)\n" + block("Merge", "path", "a.mt") + "@",
    "@if(1>0)\n" + block("Merge", "path", "a.mt") + "@while(0>1)\n@\n@",
    block("Action", "a.p", "1") + block("Merge", "path phase", "a.mt 1"),
    block("Merge", "path phase", "a.mt nope"),
    block("Merge", "path phase", "a.mt 100001"),
    block("Merge", "path phase", "a.mt " + "9" * 10000),
    block("Action", "b.p", "1") + block("Merge", "path phase", "a.mt 100000"),
    block("Action", "b.p", "1") + block("Merge", "path phase", "a.mt -1"),
])
def test_merge_and_include_negative_contracts(tmp_path, text):
    (tmp_path / "a.mt").write_text(block("Action", "a.p", "1"), encoding="utf-8")
    with pytest.raises(ScriptError):
        expand(text, tmp_path)


@pytest.mark.parametrize("fragment", ["@if(1>0)\na.p;1;\n@", block("Reflex(f)", "a.p", "1"),
                                       body("Action", body("if(1>0)", "a.p;1;\n"))])
def test_merge_rejects_unmergeable_fragment_blocks(tmp_path, fragment):
    (tmp_path / "fragment.mt").write_text(fragment, encoding="utf-8")
    with pytest.raises(ScriptError):
        expand(block("Merge", "path", "fragment.mt"), tmp_path)


def test_merge_negative_phase_partial_drop_and_cell_budget(tmp_path, monkeypatch):
    import pymybot.include as module

    (tmp_path / "b.mt").write_text(block("Action", "b.p", "1", "2", "3"), encoding="utf-8")
    text = block("Action", "a.p", "0") + block("Merge", "path phase", "b.mt -1")
    assert expand(text, tmp_path)[0].data == [["0", "2"], ["-", "3"]]
    monkeypatch.setattr(module, "MAX_MERGED_CELLS", 3)
    with pytest.raises(ScriptError, match="row/cell"):
        expand(text, tmp_path)


@pytest.mark.parametrize("nested", [False, True])
@pytest.mark.parametrize(("header", "rows", "phase", "seed", "params"), [
    ("b.p", ["10", "-", "-"], -1, ["10"], {"p": 10.0}),
    ("b.p b.q b.r b.s", ["10 1 - 9", "- 20 - -", "- - - 30", "- - - -"],
     -2, ["10", "20", "-", "30"], {"p": 10.0, "q": 20.0, "s": 30.0}),
])
def test_merge_negative_phase_seeds_retained_inheritance_and_dispatch(
        tmp_path, nested, header, rows, phase, seed, params):
    (tmp_path / "b.mt").write_text(block("Action", header, *rows), encoding="utf-8")
    directive = block("Merge", "path phase", f"b.mt {phase}")
    action = block("Action", "a.p", "0")
    text = "@if(1>0)\n" + directive + action + "@\n" if nested else action + directive
    matrices = expand(text, tmp_path)
    merged = matrices[0].children[0] if nested else matrices[0]
    assert merged.rows == [["a.p", *header.split()], ["0", *seed], ["-"] * (len(seed) + 1)]
    assert [[merged.inherited(row, col) for col in range(1, len(merged.header))]
            for row in (1, 2)] == [seed, seed]
    a, b = Driver("a"), Driver("b")
    ActionRunner(FakeRegistry(a, b), FakeBudget()).run(matrices)
    assert a.calls == [{"p": 0.0}] * 2
    assert b.calls == [params] * 2


def test_reflex_capture_is_local_until_outer_capture_explicitly_returns_it():
    dev = Driver()
    script = (block("Reflex(read)", "dev.p", "$count=reading")
              + block("Reflex(use)", "dev.p", "$(count)")
              + block("Reflex(local)", "dev.p", "$arg=reading")
              + block("Action", "read.unused", "0")
              + block("Action", "use.unused", "0")
              + block("Action", "read.capture", "$count=reading")
              + block("Action", "use.unused", "0")
              + block("Action", "local.arg", '$("temporary")'))
    registry, outputs = run(script, dev, Number("count", 0), Alias("arg", "original"))
    assert registry.resolve("count") == 3.0
    assert registry.resolve("arg") == "original"
    assert dev.calls == [{}, {"p": 0.0}, {}, {"p": 3.0}, {}]
    assert len(outputs) == 5


def test_no_directives_fast_path_does_not_touch_filesystem(tmp_path):
    matrices = parse_matrices(block("Action", "dev.p", "1"))
    assert expand_includes(matrices, tmp_path / "nonexistent") is matrices


def test_top_level_merge_retains_only_first_action_like_cpp(tmp_path, caplog):
    (tmp_path / "a.mt").write_text(block("Action", "a.p", "3"), encoding="utf-8")
    script = block("Action", "b.p", "1") + block("Action", "c.p", "2") + block("Merge", "path", "a.mt")
    matrices = expand(script, tmp_path)
    assert len(matrices) == 1
    assert matrices[0].rows == [["b.p", "a.p"], ["1", "3"]]
    assert "discarded" in caplog.text


def test_bundled_relay_script():
    path = Path(__file__).resolve().parents[1] / "scripts" / "relay-test.mt"
    assert parse_matrices(path.read_text(encoding="utf-8")) == [
        Matrix("Action", [["relay0.test"], ["1"]]),
    ]


def test_generic_script_fixture(tmp_path):
    path = tmp_path / "generic.mt"
    path.write_text(
        "# Scalars, an alias, and inherited expression cells.\n"
        "@Vars\nname value;\nlevel 2;\n@\n"
        "@Alias\nname alias;\noutput relay0;\n@\n"
        "@Action\noutput.test timer-0.delay;\n$(level+1) 10;\n- -;\n@\n",
        encoding="utf-8",
    )
    assert parse_matrices(path.read_text(encoding="utf-8")) == [
        Matrix("Vars", [["name", "value"], ["level", "2"]]),
        Matrix("Alias", [["name", "alias"], ["output", "relay0"]]),
        Matrix("Action", [["output.test", "timer-0.delay"], ["$(level+1)", "10"], ["-", "-"]]),
    ]


@pytest.mark.parametrize(("name", "text", "message"), [
    ("missing_at.mt", "@Action\nrelay0.test;\n1;\n", "unclosed block"),
    ("ragged.mt", "@Action\nrelay0.test timer-0.delay;\n1;\n@\n", "header column count"),
])
def test_invalid_generic_script_fixtures(tmp_path, name, text, message):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    with pytest.raises(ScriptError, match=message):
        parse_matrices(path.read_text(encoding="utf-8"))


def _expand_fixture_graph(tmp_path, files):
    for name, text in files.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return expand((tmp_path / "main.mt").read_text(encoding="utf-8"), tmp_path)


def test_include_main_fixture(tmp_path):
    matrices = _expand_fixture_graph(tmp_path, {
        "main.mt": (block("Merge", "path phase", "parts/a.mt 1", "parts/b.mt 2")
                    + block("Action", "timer-0.delay", "200", "200")),
        "parts/a.mt": block("Action", "r1.test", "100", "110"),
        "parts/b.mt": block("Action", "r2.test", "200", "210", "220"),
    })
    assert matrices == [Matrix("Action", [
        ["timer-0.delay", "r1.test", "r2.test"],
        ["200", "-", "-"],
        ["200", "100", "-"],
        ["-", "110", "200"],
        ["-", "-", "210"],
        ["-", "-", "220"],
    ])]


def test_include_diamond_fixture(tmp_path):
    matrices = _expand_fixture_graph(tmp_path, {
        "main.mt": block("Merge", "path", "parts/a.once.mt", "parts/b.once.mt"),
        "parts/a.once.mt": (block("Merge", "path", "shared.once.mt")
                            + block("Action", "r1.test", "100", "110")),
        "parts/b.once.mt": (block("Merge", "path", "shared.once.mt")
                            + block("Action", "r2.test", "200")),
        "parts/shared.once.mt": block("Action", "r3.test", "300"),
    })
    # Both arms resolve the same relative path, but its column/row occurs only once.
    assert matrices == [Matrix("Action", [
        ["r1.test", "r3.test", "r2.test"], ["100", "300", "200"], ["110", "-", "-"],
    ])]


def test_include_nested_fixture(tmp_path):
    matrices = _expand_fixture_graph(tmp_path, {
        "main.mt": (block("Action", "timer-0.delay", "100")
                    + block("Merge", "path", "parts/scene.once.mt")),
        # A composition-only fragment resolves its leaves relative to itself.
        "parts/scene.once.mt": block("Merge", "path", "a.mt", "b.mt"),
        "parts/a.mt": block("Action", "r1.test", "100", "110"),
        "parts/b.mt": block("Action", "r2.test", "200", "210", "220"),
    })
    assert matrices == [Matrix("Action", [
        ["timer-0.delay", "r1.test", "r2.test"],
        ["100", "100", "200"], ["-", "110", "210"], ["-", "-", "220"],
    ])]


def test_include_knob_fixture(tmp_path):
    matrices = _expand_fixture_graph(tmp_path, {
        "main.mt": (block("Merge", "path", "parts/level.once.mt")
                    + block("Vars", "name value", "amp 35")),
        "parts/level.once.mt": (block("Vars", "name value", "amp 21")
                                + block("Action", "r1.test", "$(amp)")),
    })
    assert matrices == [
        Matrix("Vars", [["name", "value"], ["amp", "35"]]),
        Matrix("Action", [["r1.test"], ["$(amp)"]]),
    ]
    relay = Driver("r1")
    variables = [Number(name, float(value)) for name, value in matrices[0].data]
    ActionRunner(FakeRegistry(relay, *variables), FakeBudget()).run(matrices)
    assert relay.calls == [{"test": 35.0}]


@pytest.mark.parametrize(("text", "expected"), [
    ("state.count", 3.0), ("-state.count+2", -1.0),
    ("state.points[i+1].x", 7.0), ("(state.points)[i+1].x*2", 14.0),
    ("state.grid[state.indices[i]][i+1]", 9.0),
    ("state.points[.0].x", 2.0), ("state.points[1e0].x", 7.0),
    ("state.points[+1.].x", 7.0), ("state.points[-0].x", 2.0),
    ('state.label+state.count', "count=3"),
    ('state.points[0].label=="origin"', True),
    ("state.enabled", True), ("!!state.enabled", True),
    ("!state.enabled", False), ("state.enabled&&state.count>1", True),
    ("state.flags[0]||state.flags[1]", True),
    ("state.enabled||(missing[1/0].x>0)", True),
    ("state.flags[0]&&state.points[999].x>0", False),
])
def test_expression_json_field_and_index_chains(text, expected):
    state = {"count": 3, "points": [{"x": 2, "label": "origin"}, {"x": 7}],
             "grid": [[4, 5], [8, 9]], "indices": [1], "label": "count=",
             "enabled": True, "flags": [False, True]}
    result = Expression(text).evaluate({"state": state, "i": 0}.__getitem__)
    assert result == expected
    assert type(result) is type(expected)


def test_expression_json_identifiers_track_roots_not_field_names():
    expression = Expression("state.points[i+offset.n].x+other.rows[lookup[j]]")
    assert expression.identifiers == {"state", "i", "offset", "other", "lookup", "j"}


def test_expression_json_python_names_are_only_data_keys():
    state = {"__class__": {"__name__": "data"}, "items": [17]}
    assert Expression("state.__class__.__name__").evaluate(lambda name: state) == "data"
    assert Expression("state.items[0]").evaluate(lambda name: state) == 17.0
    for text in ["state.keys", "state.items.__class__", "state.items[0].real"]:
        with pytest.raises(ScriptError):
            Expression(text).evaluate(lambda name: state)
    with pytest.raises(ScriptError, match="no field"):
        Expression("state.items").evaluate(lambda name: {})

    class NotJson:
        @property
        def count(self):
            pytest.fail("Expression must never access Python attributes")

    with pytest.raises(ScriptError, match="JSON"):
        Expression("state.count").evaluate(lambda name: NotJson())


@pytest.mark.parametrize(("text", "value", "message"), [
    ("state.missing", {}, "no field"),
    ("state.x.y", {"x": None}, "requires an object"),
    ("state.x[0]", {"x": None}, "requires an array"),
    ("state.x", None, "requires an object"),
    ("state.x", 1, "requires an object"),
    ("state.x", "text", "requires an object"),
    ("state.x", True, "requires an object"),
    ("state.items", [], "requires an object"),
    ("state[0]", {"0": 1}, "requires an array"),
    ("state[0]", "text", "requires an array"),
    ("state[0]", None, "requires an array"),
    ("state[0]", 5, "requires an array"),
    ("state[0]", [], "out of bounds"),
    ("state[1]", [5], "out of bounds"),
])
def test_expression_json_invalid_traversal(text, value, message):
    with pytest.raises(ScriptError, match=message):
        Expression(text).evaluate(lambda name: value)


@pytest.mark.parametrize("index", [
    True, False, -1, -0.5, 0.5, "0", "x", None, [], {},
    float("nan"), float("inf"), float("-inf"), 10**400,
])
def test_expression_json_invalid_dynamic_indices(index):
    from pymybot.expr import Reference

    resolve = {"state": [1], "i": index}.__getitem__
    with pytest.raises(ScriptError):
        Expression("state[i]").evaluate(resolve)
    with pytest.raises(ScriptError):
        Reference("state[i]").resolve_path(resolve)


@pytest.mark.parametrize("index", ['"x"', '"0"', "1>0", "-1", "1/2", "1e308*10", "1/0"])
def test_expression_json_invalid_index_expressions(index):
    from pymybot.expr import Reference

    text = f"state[{index}]"
    with pytest.raises(ScriptError):
        Expression(text).evaluate(lambda name: [1])
    with pytest.raises(ScriptError):
        Reference(text).resolve_path(lambda name: pytest.fail("Target must not be resolved"))


@pytest.mark.parametrize("text", [
    "state.", "state..x", "state.0", "state.[0]", "state[]", "state[1", "state[0]]",
    "state[0:1]", "state[0,1]", "state[*i]", "state[0x0]", "state[0b0]",
    "state.items()", "state.__class__.__subclasses__()", '__import__("os")',
    "state[x for x in y]", "state[(i:=0)]", "state[lambda:0]", "state[{0:1}]",
    "state[[0]]", "state[i=0]", "state[0];x", "state[0] = 1",
])
def test_expression_json_malformed_and_executable_syntax(text):
    from pymybot.expr import Reference

    for parser in (Expression, Reference):
        with pytest.raises(ScriptError):
            parser(text)


@pytest.mark.parametrize("value", [{"x": 1}, [1], None])
@pytest.mark.parametrize("text", ["state", "root.child", "root.array[0]"])
def test_expression_json_final_value_must_be_scalar(value, text):
    resolve = {"state": value, "root": {"child": value, "array": [value]}}.__getitem__
    with pytest.raises(ScriptError, match="scalar"):
        Expression(text).evaluate(resolve)


@pytest.mark.parametrize("text", [
    "state==state", "state!=state", "state+1", '"x"+state',
    "state<1", "-state", "!state", "state&&1>0", "1>0&&state",
])
@pytest.mark.parametrize("value", [{}, [], None])
def test_expression_json_containers_have_no_implicit_scalar_semantics(text, value):
    with pytest.raises(ScriptError):
        Expression(text).evaluate(lambda name: value)


@pytest.mark.parametrize("value", [float("inf"), float("-inf"), float("nan"), 10**400])
@pytest.mark.parametrize("text", ["state.x", "state.array[0]", "state.x==state.x", '"x"+state.x'])
def test_expression_json_nonfinite_scalar_guards(value, text):
    with pytest.raises(ScriptError, match="non-finite"):
        Expression(text).evaluate(lambda name: {"x": value, "array": [value]})


def test_expression_json_access_depth_and_shared_operator_budgets():
    from pymybot.expr import Reference

    fields, arrays = 7, 7
    for _ in range(128):
        fields, arrays = {"x": fields}, [arrays]
    field_path = "state" + ".x" * 128
    array_path = "state" + "[0]" * 128
    assert Expression(field_path).evaluate(lambda name: fields) == 7.0
    assert Expression(array_path).evaluate(lambda name: arrays) == 7.0
    assert Reference(field_path).resolve_path(None) == ("x",) * 128
    assert Reference(array_path).resolve_path(None) == (0,) * 128
    assert Expression("state.x" + "+1" * 511).evaluate(lambda name: {"x": 1}) == 512.0
    assert Reference("state[0" + "+0" * 510 + "].x").resolve_path(None) == (0, "x")
    for text in [field_path + ".x", array_path + "[0]", "state[0" + "+0" * 511 + "].x"]:
        for parser in (Expression, Reference):
            with pytest.raises(ScriptError):
                parser(text)
    with pytest.raises(ScriptError, match="operators"):
        Expression("state.x" + "+1" * 512)
    with pytest.raises(ScriptError, match="access depth"):
        Expression("(" + field_path + ").x")


def test_expression_json_nested_indices_are_bounded_without_python_recursion():
    from pymybot.expr import Reference

    resolve = lambda name: [0]
    nested = "n[0+" * 128 + "0" + "]" * 128
    assert Expression(nested).evaluate(resolve) == 0.0
    assert Reference(nested).resolve_path(resolve) == (0,)
    mixed = "n[(" * 64 + "0" + ")]" * 64
    assert Expression(mixed).evaluate(resolve) == 0.0
    for text in ["n[" * 10000 + "0" + "]" * 10000,
                 "n[(" * 65 + "0" + ")]" * 65]:
        for parser in (Expression, Reference):
            with pytest.raises(ScriptError, match="nesting") as error:
                parser(text)
            assert len(str(error.value)) < 512


def test_expression_reference_resolves_only_index_dependencies_in_order():
    from pymybot.expr import Reference

    seen = []
    values = {"i": 0, "lookup": [1], "j": 0, "offset": {"n": 2}}

    def resolve(name):
        seen.append(name)
        assert name != "state", "Resolving a path must not read the capture target"
        return values[name]

    reference = Reference(" state.points[i+1].grid[lookup[j]][offset.n] ")
    assert reference.name == "state"
    assert reference.resolve_path(resolve) == ("points", 1, "grid", 1, 2)
    assert seen == ["i", "lookup", "j", "offset"]
    values["i"] = 2
    assert reference.resolve_path(resolve) == ("points", 3, "grid", 1, 2)
    assert Reference("state").name == "state"
    assert Reference("state").resolve_path(None) == ()
    # The target need not exist; bounds checks belong to subsequent traversal.
    assert Reference("state[999].items.__class__").resolve_path(None) == (999, "items", "__class__")
    assert Reference("state[state.count]").resolve_path(lambda name: {"count": 2}) == (2,)


@pytest.mark.parametrize("text", [
    "", " ", "1", '"state"', ".state", "(state)", "(state).x", "+state",
    "--state", "!!state", "state+1", "state.x*2", "state[0]||other", "state other",
    "state,other", "state()", "$state", "$(state)", "bad-name", "[state]",
])
def test_expression_reference_rejects_non_reference_capture_targets(text):
    from pymybot.expr import Reference

    with pytest.raises(ScriptError):
        Reference(text)


def test_expression_select_member_reads_data_without_coercion_or_mutation():
    from pymybot.expr import select_member

    child = {"count": 1}
    array = [child, None, True]
    value = {"items": array, "__class__": "data"}
    assert select_member(value, "items") is array
    assert select_member(value, "__class__") == "data"
    assert select_member(array, 0) is child
    assert select_member(array, 1) is None
    assert select_member(array, 2) is True
    assert select_member({"": "empty key"}, "") == "empty key"
    assert value == {"items": [{"count": 1}, None, True], "__class__": "data"}


@pytest.mark.parametrize(("value", "key"), [
    ({}, "items"), ({}, "__class__"), ([1], "0"), ({0: "x"}, 0),
    ((1,), 0), ("abc", 0), (None, 0), (None, "x"), (1, "real"),
    ([1], True), ([1], False), ([1], 0.0), ([1], 0.5), ([1], -1),
    ([1], 1), ([1], 10**400), ([1], None), ([1], float("nan")),
])
def test_expression_select_member_rejects_invalid_keys_and_containers(value, key):
    from pymybot.expr import select_member

    with pytest.raises(ScriptError):
        select_member(value, key)


@pytest.mark.parametrize("value", [None, True, False, 12, 1.5, "# ; @ \n中文", [], {},
                                       {"points": [{"x": 1}], "text": 'a b # ; @ " \\'}])
def test_struct_raw_json_parsing(value):
    import json

    source = "@Struct(state)\n" + json.dumps(value, ensure_ascii=False, indent=2) + "\n  @ # end\n"
    matrix, action = parse_matrices(source + block("Action", "dev.p", "1"))
    assert matrix.name == "Struct(state)" and not matrix.rows and not matrix.children
    assert json.loads(matrix.json_text) == value
    assert action.name == "Action"
    assert parse_matrices(source.replace("\n", "\r\n"))[0] == matrix


@pytest.mark.parametrize("body", ["", "{", "{};", "{} {}", "{'x':1}", '{"x":1,}',
                                       '{"x":1,"x":2}', "NaN", "Infinity", "-Infinity",
                                       '{"x":1e999}', '# comment\n{}', r'"\ud800"'])
def test_struct_rejects_non_json_and_nonfinite_values(body):
    with pytest.raises(ScriptError):
        parse_matrices("@Struct(state)\n" + body + "\n@\n")


@pytest.mark.parametrize("name", ["Struct", "Struct()", "Struct(bad-name)", "Struct(1bad)",
                                       "Struct(a.b)", "Struct(a b)", "Struct(a)junk"])
def test_struct_rejects_invalid_declaration_names(name):
    with pytest.raises(ScriptError):
        parse_matrices("@" + name + "\n{}\n@\n")


def test_struct_top_level_and_json_depth_limits():
    from pymybot.matrix import struct_json

    with pytest.raises(ScriptError, match="top level"):
        parse_matrices("@if(1>0)\n@Struct(state)\n{}\n@\n@\n")
    with pytest.raises(ScriptError, match="unclosed"):
        parse_matrices("@Struct(state)\n{}")
    assert parse_matrices("@Struct(state)\n" + "[" * 32 + "0" + "]" * 32 + "\n@")
    for depth in (33, 10000):
        with pytest.raises(ScriptError):
            parse_matrices("@Struct(state)\n" + "[" * depth + "0" + "]" * depth + "\n@")
    cycle = []
    cycle.append(cycle)
    with pytest.raises(ScriptError, match="depth"):
        struct_json(cycle)


def test_struct_size_and_json_capture_value_limits(monkeypatch):
    import pymybot.matrix as module

    monkeypatch.setattr(module, "MAX_SCRIPT_BYTES", 32)
    with pytest.raises(ScriptError, match="byte limit"):
        module.struct_json("x" * 32)
    for value in (float("nan"), 10**400, {1: "bad"}, (1, 2), object()):
        with pytest.raises(ScriptError):
            module.struct_json(value)


def test_struct_copy_on_write_and_capture_does_not_alias_source():
    from pymybot.hardware import Registry, Struct

    source = {"points": [{"x": 1}], "enabled": True, "empty": None}
    state = Struct("state", source)
    registry = Registry()
    registry.add(state)
    with registry.session():
        updated = state.updated(("points", 0, "x"), 8)
        registry.override("state", updated)
        assert registry.resolve("state")["points"][0]["x"] == 8
        assert state.read() == source
    assert registry.get("state") is state
    assert source["points"][0]["x"] == 1
    with pytest.raises(ScriptError):
        state.updated(("missing",), 5)
    with pytest.raises(ScriptError):
        state.updated(("points", 1), {})
    with pytest.raises(ScriptError):
        state.updated(("points", 0, "x"), float("nan"))
    assert state.read() == source


@pytest.mark.parametrize("fail", [False, True])
def test_nested_reflex_global_struct_captures_are_local_even_on_failure(fail):
    from pymybot.hardware import Registry, Struct

    registry = Registry()
    state = Struct("state", {"count": 0, "points": [{"x": 10}]})
    dev = Driver()
    registry.add(state)
    registry.add(dev)
    script = (body("Reflex(inner)",
                   block("Action", "dev.p dev.cap dev.slot dev.new",
                         "$(x) $state.count=reading $state.points[0].x=reading $fresh=reading"),
                   block("Action", "dev.p", "$(state.count+state.points[0].x)"))
              + body("Reflex(outer)",
                     block("Action", "inner.x inner.capture", "4 $inner_count=reading"),
                     block("Action", "dev.p dev.cap", "$(state.count) $state.points[0].x=reading"),
                     block("Action", "dev.p", "$(state.points[0].x)"),
                     block("Action", "dev.p", "$(missing)") if fail else "")
              + block("Action", "outer.capture", "$returned=reading"))
    runner = ActionRunner(registry, FakeBudget())
    if fail:
        with pytest.raises(ScriptError, match="missing"):
            runner.run(parse_matrices(script))
        assert registry.get("returned") is None
    else:
        outputs = runner.run(parse_matrices(script))
        assert [item["reading"] for item in outputs] == [1, 2, 3, 4]
        assert registry.resolve("returned") == 4.0
    assert dev.calls == [{"p": 4.0}, {"p": 2.0}, {"p": 0.0}, {"p": 3.0}]
    assert registry.get("state") is state
    assert state.read() == {"count": 0, "points": [{"x": 10}]}
    assert all(registry.get(name) is None for name in ("x", "fresh", "inner_count"))


def test_struct_member_expressions_in_action_headers():
    from pymybot.hardware import Registry, Struct

    registry = Registry()
    registry.add(Struct("cfg", {"devices": ["dev"], "key": "p"}))
    driver = Driver()
    registry.add(driver)
    ActionRunner(registry, FakeBudget()).run(parse_matrices(
        block("Action", "$(cfg.devices[0]).$(cfg.key)", "4") + block("Action", "dev.$(1.5)", "2")))
    assert driver.calls == [{"p": 4.0}, {"1.5": 2.0}]


@pytest.mark.parametrize("directive", ["Include", "Merge"])
def test_struct_payload_survives_include_merge(directive, tmp_path):
    import json

    payload = {"text": "a b # ; @\n", "x": 2}
    (tmp_path / "part.mt").write_text(
        "@Struct(cfg)\n" + json.dumps(payload) + "\n@\n" + block("Action", "dev.p", "$(cfg.x)"), encoding="utf-8")
    matrices = expand(block(directive, "path", "part.mt"), tmp_path)
    assert json.loads(matrices[0].json_text) == payload
    assert matrices[1].name == "Action"


def test_struct_is_rejected_in_position_local_merge_fragments(tmp_path):
    (tmp_path / "part.mt").write_text("@Struct(cfg)\n{}\n@\n", encoding="utf-8")
    source = "@if(1>0)\n" + block("Merge", "path", "part.mt") + block("Action", "dev.p", "1") + "@\n"
    with pytest.raises(ScriptError, match="plain matrix"):
        expand(source, tmp_path)


@pytest.mark.parametrize("suffix", ["", " ", "\t", "#comment", " # comment", "\t # ; @ comment"])
def test_struct_declaration_line_comments_do_not_become_json(suffix):
    import json

    source = '@Struct(state)' + suffix + '\n{"text":"# ; @"}\n@\n'
    assert json.loads(parse_matrices(source)[0].json_text) == {"text": "# ; @"}
    assert parse_matrices(source.replace("\n", "\r\n")) == parse_matrices(source)
    with pytest.raises(ScriptError, match="Invalid Struct JSON"):
        parse_matrices('@Struct(state)' + suffix + '\n# not a JSON comment\n{}\n@\n')


def test_struct_rejects_inline_json_on_declaration_line():
    with pytest.raises(ScriptError, match="line after"):
        parse_matrices('@Struct(state) {}\n@\n')


def test_struct_many_at_characters_do_not_copy_line_prefixes():
    import json

    copied = 0

    class TrackedSource(str):
        def replace(self, *args):
            return TrackedSource(super().replace(*args))

        def __getitem__(self, key):
            nonlocal copied
            if isinstance(key, slice):
                copied += len(range(*key.indices(len(self))))
            return super().__getitem__(key)

    payload = "@" * 20000
    source = TrackedSource('@Struct(state)\n"' + payload + '"\n@\n')
    assert json.loads(parse_matrices(source)[0].json_text) == payload
    assert copied <= len(source)


class _MetaTable:
    header = ["name", "count"]

    def inherited(self, row, index):
        return row[index]


class _MetaRegistry:
    def __init__(self):
        self.variables = {}

    def require(self, name):
        return self.variables[name]


class _MetaVariable:
    def __init__(self, name, kind, value):
        self.name = name
        self.kind = kind
        self.value = value

    def read(self):
        return self.value


def test_metadata_reference_resolves_session_override_by_name():
    registry = _MetaRegistry()
    registry.variables["n"] = _MetaVariable("n", "vars", 1.0)
    metadata = Metadata(_MetaTable(), ["dev", "$n"], registry)
    metadata.seed()
    assert metadata.collect()["count"] == 1.0
    registry.variables["n"] = _MetaVariable("n", "vars", 2.0)
    assert metadata.collect()["count"] == 2.0
    registry.variables["n"] = _MetaVariable("n", "vars", 1.0)
    assert metadata.collect()["count"] == 1.0


def test_metadata_reference_still_merges_driver_tables():
    registry = _MetaRegistry()
    registry.variables["dev"] = _MetaVariable("dev", "lua", {"result": "OK", "T": 25})
    metadata = Metadata(_MetaTable(), ["dev", "$dev"], registry)
    metadata.seed()
    assert metadata.collect() == {"result": "OK", "T": 25}


def test_action_output_budget_is_cumulative(monkeypatch):
    import pymybot.actions as actions_module

    monkeypatch.setattr(actions_module, "MAX_OUTPUT_BYTES", 200, raising=False)
    dev = Driver(callback=lambda params: {"result": "OK", "payload": "x" * 120})
    script = (block("Action", "dev.p", "1") + block("Action", "dev.p", "2")
              + block("Action", "dev.p", "3"))
    with pytest.raises(ScriptError, match="output budget"):
        run(script, dev)
    assert len(dev.calls) == 2


def test_action_output_count_is_bounded(monkeypatch):
    import pymybot.actions as actions_module

    monkeypatch.setattr(actions_module, "MAX_OUTPUTS", 2, raising=False)
    dev = Driver(callback=lambda params: {"result": "OK", "n": 1})
    script = (block("Action", "dev.p", "1") + block("Action", "dev.p", "2")
              + block("Action", "dev.p", "3"))
    with pytest.raises(ScriptError, match="output budget"):
        run(script, dev)
    assert len(dev.calls) == 3


def test_expression_dependency_expansion_checks_budget():
    values = {"n0": Number("n0", "1")}

    def resolve(name):
        return values[name].numeric()

    for index in range(1, 16):
        values[f"n{index}"] = Number(f"n{index}", f"$(n{index-1} + n{index-1})", resolve)

    class Registry(FakeRegistry):
        def resolve(self, name):
            return values[name].numeric()

    runner = ActionRunner(Registry(), FakeBudget(limit=100))
    with pytest.raises(BudgetExceeded):
        runner._value(Expression("n15"))
    assert ActionRunner(Registry(), FakeBudget())._value(Expression("n3")) == 8.0

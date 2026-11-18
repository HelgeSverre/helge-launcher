#!/usr/bin/env -S python3 -I
"""Calculator: type an expression, Enter pastes the result, ⌘Enter copies it.

Evaluates only numbers, + - * / // % ** and parentheses (no names, no calls),
so typing arbitrary text can't run code.
"""
import ast
import json
import operator
import sys

OPS = {
    ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
    ast.Div: operator.truediv, ast.FloorDiv: operator.floordiv, ast.Mod: operator.mod,
    ast.Pow: operator.pow, ast.USub: operator.neg, ast.UAdd: operator.pos,
}


def ev(node):
    if isinstance(node, ast.Expression):
        return ev(node.body)
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return node.value
    if isinstance(node, ast.BinOp) and type(node.op) in OPS:
        if isinstance(node.op, ast.Pow) and abs(ev(node.right)) > 1000:
            raise ValueError("exponent too large")
        return OPS[type(node.op)](ev(node.left), ev(node.right))
    if isinstance(node, ast.UnaryOp) and type(node.op) in OPS:
        return OPS[type(node.op)](ev(node.operand))
    raise ValueError("unsupported expression")


query = sys.argv[1] if len(sys.argv) > 1 else ""
items = []
expr = query.replace(",", ".").replace("×", "*").replace("÷", "/").strip()
if expr:
    try:
        value = ev(ast.parse(expr, mode="eval"))
        text = f"{value:.10g}" if isinstance(value, float) else str(value)
        items.append({
            "title": text,
            "subtitle": query,
            "icon": "equal.circle",
            "actions": [{"title": "Paste", "paste": text}, {"title": "Copy", "copy": text}],
        })
    except (ValueError, SyntaxError, ZeroDivisionError, OverflowError) as e:
        items.append({"title": "…", "subtitle": str(e) or "incomplete expression", "icon": "equal.circle"})
print(json.dumps({"items": items}))

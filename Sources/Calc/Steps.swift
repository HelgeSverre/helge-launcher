import Foundation

/// One line of a worked chain: the operation applied and the running result.
public struct CalcStep: Sendable {
    /// "500 km" for the start, then "@ 6 L ÷ 100 km", "→ EUR".
    public let operation: String
    /// The running result after this operation, as shown.
    public let result: String
    /// False when the result would only repeat the operation ("500 km" → "500 km").
    public var showsResult: Bool { CalcResult.essence(operation) != CalcResult.essence(result) }
}

/// Splits a chain along its left side and evaluates each prefix.
enum Steps {
    /// A binary operator with its right side, or a conversion (`op` nil) with its target.
    private struct Op {
        var op: String?
        var rhs: Node?
        var target: Target?
        var rate: Node?
    }

    /// Operators that continue a chain; others (powers, functions) are single steps.
    private static let chainOps: Set<String> = ["+", "-", "*", "/", "at", "for", "of", "juxt", "mod"]

    private static func spine(_ n: Node) -> (Node, [Op]) {
        switch n {
        case .binary(let op, let a, let b) where chainOps.contains(op):
            if op == "juxt", Describe.isQuantityChain(n) { return (n, []) }
            let inner: (Node, [Op]) = spine(a)
            return (inner.0, inner.1 + [Op(op: op, rhs: b)])
        case .convert(let a, let t, let rate):
            let inner: (Node, [Op]) = spine(a)
            return (inner.0, inner.1 + [Op(target: t, rate: rate)])
        case .call("id", let args) where args.count == 1:
            return spine(args[0])
        case .seq(let ns):
            guard let last = ns.last else { return (n, []) }
            return spine(last)
        default:
            return (n, [])
        }
    }

    private static func apply(_ cur: Node, _ op: Op) -> Node {
        if let o = op.op, let b = op.rhs { return .binary(o, cur, b) }
        return .convert(cur, op.target!, rate: op.rate)
    }

    private static func text(_ op: Op, _ loc: CalcLocale) -> String {
        guard let o = op.op, let b = op.rhs else {
            let t = op.target!
            if case .expr(let x) = t { return (loc.nb ? "i " : "in ") + Describe.node(x, loc) }
            return (op.rate.map { "@ " + Describe.node($0, loc) + " " } ?? "") + "→ " + Describe.target(t, nb: loc.nb)
        }
        let sym: String
        switch o {
        case "*", "juxt", "for": sym = "×"
        case "/": sym = "÷"
        case "-": sym = "−"
        case "of": sym = loc.nb ? "av" : "of"
        case "at": sym = "@"
        default: sym = o
        }
        let inner = Describe.node(b, loc)
        if case .binary(let bo, _, _) = b, ["+", "-"].contains(bo) { return sym + " (" + inner + ")" }
        return sym + " " + inner
    }

    /// Steps when the query has at least two operations; each prefix is evaluated on its own.
    static func of(_ root: Node, _ ctx: CalcContext) -> [CalcStep] {
        var assignments: [Node] = []
        if case .seq(let ns) = root { assignments = Array(ns.dropLast()) }
        var (leaf, ops) = spine(root)
        guard ops.count >= 2 else { return [] }
        // "2 × 1450 km" starts the chain as one line, not "2" then "× 1450 km".
        if case .num = leaf, let first = ops.first, ["*", "juxt"].contains(first.op ?? "") {
            leaf = apply(leaf, first)
            ops.removeFirst()
        }
        func value(_ n: Node) -> String? {
            let ev = Evaluator(ctx)
            for a in assignments { _ = try? ev.eval(a) }
            guard let v = try? ev.eval(n) else { return nil }
            return Calculator.answer(v, label: nil, targeted: Calculator.isTargeted(n), Output(ev: ev)).text
        }
        guard let start = value(leaf) else { return [] }
        var steps = [CalcStep(operation: Describe.node(leaf, ctx.locale), result: start)]
        var cur = leaf
        for op in ops {
            cur = apply(cur, op)
            guard let r = value(cur) else { return [] }
            steps.append(CalcStep(operation: text(op, ctx.locale), result: r))
        }
        return steps
    }
}

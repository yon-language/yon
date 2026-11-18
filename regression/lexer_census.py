"""The census of the lexer, read off frontend/lexer.mll.

Every case of every rule of the lexer (`rule raw_token`, `and block_comment`, `and string_lit`),
the keyword table, and the wrapper `token` that the parser calls, each with: its pattern; the
tokens it can give; the conditions it reads (a state, the character before, the input ahead);
the states it writes; what it refuses. Nothing here is a list written by hand: every line comes
from the code, and the code is read with a closed vocabulary. A name in an action that the
vocabulary does not know stops the census with the rule and the name (ExtractorStop): a form of
rule the census cannot read is said, never skipped.

`census()` returns the lines of regression/GRAMMAR.tokens (test_grammar_guard.py writes and
checks them) and the sets the checks of the whole need.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PARSER = ROOT / "frontend" / "parser.mly"
LEXER = ROOT / "frontend" / "lexer.mll"


class ExtractorStop(RuntimeError):
    """A form of the lexer the census cannot read."""


# --------------------------------------------------------------------------------------------
# Reading the sources
# --------------------------------------------------------------------------------------------
def strip_comments(src: str) -> str:
    """The OCaml text without its comments (nested), string and char literals kept."""
    out, i, depth = [], 0, 0
    while i < len(src):
        if not depth and src[i] == '"':
            j = i + 1
            while j < len(src) and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1]); i = j + 1; continue
        if not depth and src[i] == "'" and re.match(r"'(\\x[0-9a-fA-F]{2}|\\.|[^\\'])'", src[i:i + 6]):
            m = re.match(r"'(\\x[0-9a-fA-F]{2}|\\.|[^\\'])'", src[i:i + 6])
            out.append(m.group(0)); i += len(m.group(0)); continue
        if src.startswith("(*", i):
            depth += 1; i += 2; continue
        if depth and src.startswith("*)", i):
            depth -= 1; i += 2; continue
        if not depth:
            out.append(src[i])
        i += 1
    return "".join(out)


def norm(code: str) -> str:
    return " ".join(code.split())


def ocaml_literal(lit: str) -> str:
    """The text of an OCaml string or char literal body, escapes decoded (UTF-8)."""
    raw, i = bytearray(), 0
    while i < len(lit):
        c = lit[i]
        if c == "\\" and i + 1 < len(lit):
            n = lit[i + 1]
            if n == "x":
                raw.append(int(lit[i + 2:i + 4], 16)); i += 4; continue
            raw.extend({"n": b"\n", "t": b"\t", "r": b"\r", "\\": b"\\", "'": b"'", '"': b'"'}.get(n, n.encode()))
            i += 2; continue
        raw.extend(c.encode()); i += 1
    return raw.decode("utf-8")


def show_pattern(pat: str) -> str:
    """A pattern as written, with its literals decoded (`"\\xe2\\x86\\xa6"` is shown `"↦"`)."""
    def esc(text):
        return (text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
                .replace("\r", "\\r"))
    def lit(m):
        # a byte that is not a character of UTF-8 by itself is shown as it is written
        try:
            if m.group(1) is not None:
                return '"' + esc(ocaml_literal(m.group(1))) + '"'
            return "'" + esc(ocaml_literal(m.group(2))) + "'"
        except UnicodeDecodeError:
            return m.group(0)
    return norm(re.sub(r'"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\x[0-9a-fA-F]{2}|\\.))\'', lit, pat))


def declared_tokens(mly: str) -> list:
    names = []
    for line in mly.splitlines():
        m = re.match(r"%token(\s*<[^>]*>)?\s+(.*)", line)
        if m:
            for n in re.findall(r"\b[A-Z][A-Z0-9_]*\b", re.sub(r"/\*.*?\*/", "", m.group(2))):
                if n not in names:
                    names.append(n)
    return names


def precedence_names(mly: str, declared) -> list:
    """The names of the precedence declarations that are not tokens: `%prec LOWEST`."""
    out = []
    for line in mly.splitlines():
        m = re.match(r"%(left|right|nonassoc)\s+(.*)", line)
        if m:
            for n in re.findall(r"\b[A-Z][A-Z0-9_]*\b", re.sub(r"/\*.*?\*/", "", m.group(2))):
                if n not in declared and n not in out:
                    out.append(n)
    return out


REFUSAL = re.compile(r"\{\s*\(?\s*(failwith|form_gone)\b")


def parser_refused(mly: str, tokens: set) -> list:
    """The tokens every production of parser.mly refuses: each production that reads the
    token has an action that is a refusal and nothing else (`{ failwith ... }`, `{ form_gone
    ... }`). Such a token is a word the lexer still gives and no program can use: a form that
    is gone."""
    body = strip_comments(mly).split("\n%%\n", 1)
    if len(body) != 2:
        raise ExtractorStop("parser.mly: no `%%` between the declarations and the rules")
    uses = {t: [] for t in tokens}
    for m in re.finditer(r"\n([a-z_][a-z0-9_]*)(?:\([^)]*\))?:\s*(.*?)(?=\n[a-z_][a-z0-9_]*(?:\([^)]*\))?:|\n%%|\Z)",
                         body[1], re.S):
        for alt in re.split(r"\n\s*\|", "\n" + m.group(2)):
            if "{" not in alt:
                continue
            i = alt.index("{")
            refuse = bool(REFUSAL.match(alt[i:]))
            for t in set(re.findall(r"\b[A-Z][A-Z0-9_]*\b", alt[:i])) & tokens:
                uses[t].append(refuse)
    return [t for t, u in uses.items() if u and all(u)]


def split_lexer(mll: str):
    """(header, definitions, rules, trailer): the OCaml blocks, `let` regexes and the rules."""
    m = re.match(r"\s*\{(.*?)\n\}\n(.*)", mll, re.S)
    if not m:
        raise ExtractorStop("lexer.mll: no OCaml header `{ ... }` at the top")
    header, rest = m.group(1), m.group(2)
    t = re.search(r"\n\{\n(.*)\n\}\s*\Z", rest, re.S)
    if not t:
        raise ExtractorStop("lexer.mll: no OCaml trailer `{ ... }` at the bottom")
    trailer, body = t.group(1), rest[:t.start()]
    defs, rules = [], []
    parts = re.split(r"\n(?=rule |and )", body)
    head = parts[0]
    for d in re.finditer(r"^let ([a-z_]+) = (.*)$", head, re.M):
        defs.append((d.group(1), norm(d.group(2))))
    leftover = re.sub(r"^let [a-z_]+ = .*$", "", head, flags=re.M).strip()
    if leftover:
        raise ExtractorStop("lexer.mll: a form between the header and the rules the census cannot read: " + leftover[:80])
    for p in parts[1:]:
        r = re.match(r"(?:rule|and) ([a-z_]+)((?: [a-z_]+)*) = parse(.*)", p, re.S)
        if not r:
            raise ExtractorStop("lexer.mll: a rule the census cannot read: " + p[:80])
        rules.append((r.group(1), r.group(2).split(), r.group(3)))
    return header, defs, rules, trailer


def cases(body: str):
    """The cases `| pattern { action }` of a rule body: (pattern, action)."""
    out, i = [], 0
    while True:
        j = body.find("|", i)
        if j < 0:
            if body[i:].strip():
                raise ExtractorStop("lexer.mll: text after the last case: " + body[i:i + 80])
            return out
        if body[i:j].strip():
            raise ExtractorStop("lexer.mll: text between two cases: " + body[i:j][:80])
        k, pat = j + 1, []
        while k < len(body) and body[k] != "{":
            if body[k] == '"':
                e = k + 1
                while body[e] != '"':
                    e += 2 if body[e] == "\\" else 1
                pat.append(body[k:e + 1]); k = e + 1; continue
            m = re.match(r"'(\\x[0-9a-fA-F]{2}|\\.|[^\\'])'", body[k:k + 6])
            if m:
                pat.append(m.group(0)); k += len(m.group(0)); continue
            pat.append(body[k]); k += 1
        depth, a = 0, k
        while a < len(body):
            ch = body[a]
            m = re.match(r"'(\\x[0-9a-fA-F]{2}|\\.|[^\\'])'", body[a:a + 6])
            if m:
                a += len(m.group(0)); continue
            if ch == '"':
                e = a + 1
                while body[e] != '"':
                    e += 2 if body[e] == "\\" else 1
                a = e
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    break
            a += 1
        out.append(("".join(pat), body[k + 1:a]))
        i = a + 1


# --------------------------------------------------------------------------------------------
# The vocabulary of an action
# --------------------------------------------------------------------------------------------
OCAML_WORDS = {"let", "in", "match", "with", "if", "then", "else", "when", "begin", "end", "true",
               "false", "fun", "function", "not", "and", "or", "raise", "ignore", "try", "as",
               "Some", "None", "succ", "pred", "_", "land", "lor", "lsl", "lsr", "Option.map", "List.nth_opt", "List.iter"}
# names of the OCaml library an action may use, and what each says about the rule
LIBRARY = {
    "lexbuf": None, "Lexing.lexeme_start_p": None, "Lexing.lexeme_end": None,
    "Lexing.lexeme_start": None, "lexbuf.Lexing.lex_start_pos": None,
    "lexbuf.Lexing.lex_curr_p": None, "Lexing.pos_cnum": None, "Lexing.pos_fname": None,
    "Lexing.pos_lnum": None, "Lexing.pos_bol": None,
    "float_of_string": None, "int_of_string": None, "Printf.sprintf": None,
    "Char.code": None, "String.length": None,
    "Buffer.create": None, "Buffer.add_char": None,
    "Buffer.contents": ("does", "gives the text read so far"),
    "Lexing.new_line": ("does", "counts a line"),
    "Hashtbl.replace": None,
    "Surface_ast.exact_int_literals": ("writes", "Surface_ast.exact_int_literals (the text of an integer literal, by its site)"),
    "Bytes.get": None,
    "lexbuf.Lexing.lex_buffer": ("reads", "the character before the lexeme"),
    "lexbuf.Lexing.lex_curr_pos": ("reads", "the input ahead (it reads past the lexeme and gives the rest back)"),
    "lexbuf.Lexing.lex_curr_p.Lexing.pos_cnum": None,
    "Lexer_error": None,
}


def names_of(code: str):
    """The names an OCaml fragment uses, string and char literals left out."""
    code = re.sub(r'"(?:[^"\\]|\\.)*"', " ", code)
    code = re.sub(r"'(\\x[0-9a-fA-F]{2}|\\.|[^\\'])'", " ", code)
    code = re.sub(r"\b0[xX][0-9a-fA-F]+\b|\b\d+\b", " ", code)   # numeric literals are no names
    return re.findall(r"!?[A-Za-z_][A-Za-z0-9_']*(?:\.[A-Za-z_][A-Za-z0-9_']*)*", code)


class Header:
    """What the OCaml header of the lexer declares: the keyword table, types, refs, helpers."""

    def __init__(self, header: str, tokens: set):
        self.keywords = [(w, t) for w, t in re.findall(r'"([^"]+)",\s*([A-Z][A-Z0-9_]*)\b[^;"]*;', header)]
        self.constructors = set()
        for tdef in re.findall(r"\btype [a-z_]+ = ([^\n]*)", header):
            self.constructors |= set(re.findall(r"\b([A-Z][A-Za-z0-9_]*)\b", tdef)) - {"Lexing", "Parser"}
        self.refs = dict((n, norm(v)) for n, v in re.findall(r"\blet ([a-z_]+)\s*(?::[^=]*)?= ref ([^\n]*)", header))
        self.functions = {}
        for name, body in re.findall(r"\blet ([a-z_]+) [^=\n]*=\s*\n?(.*?)(?=\n  let |\n  type |\Z)", header, re.S):
            if name in self.refs or name == "keyword_table":
                continue
            self.functions[name] = norm(body)
        unknown = set(t for _, t in self.keywords) - tokens
        if unknown:
            raise ExtractorStop("lexer.mll: keywords whose token parser.mly does not declare: " + ", ".join(sorted(unknown)))


def read_action(rule: str, pat: str, action: str, hdr: Header, tokens: set, rule_names: set, locals_: set):
    """gives / reads / writes / does / refuses / calls of one action, by the vocabulary."""
    gives, reads, writes, does, refuses, calls = [], [], [], [], [], []
    bound = set(locals_) | set(re.findall(r"\bas ([a-z_][A-Za-z0-9_]*)", pat))
    bound |= set(re.findall(r"\blet ([a-z_][A-Za-z0-9_]*)\b", action))
    # the parameters of a local function: `let b i = ...`
    for params in re.findall(r"\blet [a-z_][A-Za-z0-9_]*((?: [a-z_][A-Za-z0-9_]*)+) =", action):
        bound |= set(params.split())
    # pattern variables of a match on a state: `Inside k`
    bound |= set(re.findall(r"\b(?:%s) ([a-z_])\b" % "|".join(sorted(hdr.constructors)) if hdr.constructors else r"(?!)", action))
    for raw in names_of(action):
        deref = raw.startswith("!")
        n = raw.lstrip("!")
        head = n.split(".")[0]
        if n in tokens:
            gives.append(n)
        elif n in hdr.constructors or n in OCAML_WORDS:
            pass
        elif n in hdr.refs:
            if deref:
                reads.append(n)
            elif re.search(r"\b" + re.escape(n) + r"\s*:=", action):
                writes.append(n)
            else:
                raise ExtractorStop(f"lexer.mll, rule {rule} {show_pattern(pat)}: the state {n} is used neither as !{n} nor as {n} :=")
        elif n == "ident_or_keyword":
            gives.append("IDENT"); gives.append("a keyword of the table")
        elif n in hdr.functions:
            body = hdr.functions[n]
            for r in hdr.refs:
                if re.search(r"\b" + r + r"\s*:=", body):
                    writes.append(r)
        elif n == "raw_token" and rule == "raw_token":
            does.append("skips the lexeme")
        elif n == rule:
            does.append("goes on in " + rule)
        elif n in rule_names:
            calls.append(n); does.append("reads on in the rule " + n)
        elif n in LIBRARY:
            if n == "Lexer_error":
                msgs = [ocaml_literal(s) for s in re.findall(r'"((?:[^"\\]|\\.)*)"', action)]
                refuses.extend(msgs or ["(no message)"])
            elif LIBRARY[n]:
                kind, what = LIBRARY[n]
                {"does": does, "reads": reads, "writes": writes}[kind].append(what)
        elif head in bound:
            pass
        else:
            raise ExtractorStop(f"lexer.mll, rule {rule} {show_pattern(pat)}: the census cannot read `{n}` in the action")
    uniq = lambda xs: list(dict.fromkeys(xs))
    return dict(gives=uniq(gives), reads=uniq(reads), writes=uniq(writes), does=uniq(does),
                refuses=uniq(refuses), calls=uniq(calls))


# --------------------------------------------------------------------------------------------
# The wrapper `token`
# --------------------------------------------------------------------------------------------
def trailer_census(trailer: str, tokens: set):
    """The states of the wrapper, its functions as code, and where it gives a token of its own."""
    refs = dict((n, norm(v)) for n, v in re.findall(r"\blet ([a-z_]+)\s*(?::[^=]*)?= ref ([^\n]*)", trailer))
    funs = {}
    for name, body in re.findall(r"\n  let ([a-z_]+) \(lexbuf[^\n]*\n(.*?)(?=\n  let |\Z)", "\n" + trailer, re.S):
        funs[name] = norm(body)
    if "token" not in funs:
        raise ExtractorStop("lexer.mll: the trailer has no `let token (lexbuf ...)`: the wrapper the parser calls")
    tok = funs["token"]
    # the tokens the wrapper gives of its own: `virtual_token X`, or `previous := X; X`
    own = re.findall(r"virtual_token ([A-Z][A-Z0-9_]*)", tok) + re.findall(r"previous := ([A-Z][A-Z0-9_]*); ([A-Z][A-Z0-9_]*)\b", tok)
    virtual = []
    for o in own:
        if isinstance(o, tuple):
            if o[0] != o[1]:
                raise ExtractorStop(f"lexer.mll, token: `previous := {o[0]}; {o[1]}` gives a token it does not record")
            o = o[0]
        if o not in tokens:
            raise ExtractorStop(f"lexer.mll, token: the wrapper gives {o}, which parser.mly does not declare")
        if o not in virtual:
            virtual.append(o)
    for t in set(re.findall(r"\b([A-Z][A-Z0-9_]*)\b", tok)) & tokens:
        pass
    reads_of = {}
    for v in virtual:
        reads_of[v] = sorted(r for r in refs if re.search(r"!" + r + r"\b", tok)) if v else []
    return refs, funs, virtual


def _depth0_find(text: str, needle: str, start: int = 0) -> int:
    """The first `needle` in `text` at parenthesis depth 0 and outside begin/end."""
    depth, i = 0, start
    while i < len(text):
        if text.startswith(needle, i) and depth == 0:
            return i
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif text.startswith("begin ", i) and (i == 0 or not text[i - 1].isalnum()):
            depth += 1; i += 6; continue
        elif text.startswith(" end", i) and (i + 4 == len(text) or not text[i + 4].isalnum()):
            depth -= 1; i += 4; continue
        i += 1
    return -1


def split_arms(text: str) -> list:
    """The arms `pattern -> body` of a match, split on the bars at depth 0 that follow a body."""
    text = text.strip()
    if text.startswith("| "):
        text = text[2:]
    arms, cur, i, depth = [], "", 0, 0
    while i < len(text):
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if depth == 0 and text.startswith(" | ", i) and " -> " in cur:
            arms.append(cur.strip()); cur = ""; i += 3; continue
        cur += ch; i += 1
    if cur.strip():
        arms.append(cur.strip())
    return arms


def _effects(body: str, refs) -> dict:
    gives = re.findall(r"previous := ([A-Z][A-Z0-9_]*); \1\b", body)
    if re.search(r"\bfinish tok\b", body):
        gives.append("the token read, through finish")
    writes = [r for r in refs if re.search(r"(?<![!\w])" + r + r" :=", body)]
    does = []
    if "put_back ()" in body:
        does.append("gives the token read back, for the next call")
    return dict(gives=gives, writes=writes, does=does)


def _reads(cond: str, refs) -> list:
    out = [r for r in refs if re.search(r"!" + r + r"\b", cond)]
    if re.search(r"\bline\b", cond):
        out.append("the line of the token")
    if re.search(r"\btok\b", cond):
        out.append("the token read")
    if "path_ahead" in cond:
        out.append("the tokens ahead to the end of the line (path_ahead)")
    return out


def wrapper_decisions(tok: str, refs, tokens) -> list:
    """The decisions of the wrapper `token`, in order: (where, when, fields)."""
    out = []
    m = re.search(r"\bif (.+?) then virtual_token ([A-Z][A-Z0-9_]*) else begin ", tok)
    if not m:
        raise ExtractorStop("lexer.mll, token: the census cannot read the first decision of the wrapper "
                            "(`if ... then virtual_token X else begin`)")
    out.append(("token", m.group(1), dict(gives=[m.group(2)], reads=_reads(m.group(1), refs),
                                          writes=[r for r in refs if re.search(r"(?<![!\w])" + r + r" :=", m.group(1))])))
    f = re.search(r"let finish t = \(match t with (.*?) \| _ -> \(\)\); (.*?); t in ", tok)
    if not f:
        raise ExtractorStop("lexer.mll, token: the census cannot read `let finish t = (match t with ... | _ -> ())`")
    for arm in split_arms(f.group(1)):
        pat, _, body = arm.partition(" -> ")
        if not body:
            raise ExtractorStop("lexer.mll, token.finish: an arm the census cannot read: " + arm[:80])
        guard = pat.split(" when ", 1)
        fields = dict(on=[guard[0]], reads=_reads(guard[1], refs) if len(guard) > 1 else [],
                      writes=[r for r in refs if re.search(r"(?<![!\w])" + r + r" :=", body)])
        out.append(("token.finish", guard[1] if len(guard) > 1 else "", dict(fields, code=[body])))
    tail = f.group(2)
    out.append(("token.finish", "", dict(on=["every token"],
                                         writes=[r for r in refs if re.search(r"(?<![!\w])" + r + r" :=", tail)],
                                         code=[tail])))
    rest = tok[f.end():]
    while rest:
        if rest.startswith("if "):
            t = _depth0_find(rest, " then begin ", 3)
            if t < 0:
                raise ExtractorStop("lexer.mll, token: an `if` of the wrapper the census cannot read: " + rest[:80])
            cond = rest[3:t]
            e = _depth0_find(rest, " end", t + len(" then begin "))
            body = rest[t + len(" then begin "):e]
            ef = _effects(body, refs)
            if "if " in body:
                inner = re.search(r"\bif (.+?) then (\w+) := (\w+);", body)
                if not inner:
                    raise ExtractorStop("lexer.mll, token: a nested `if` the census cannot read: " + body[:80])
                out.append(("token", inner.group(1), dict(reads=_reads(inner.group(1), refs), writes=[inner.group(2)])))
            out.append(("token", cond, dict(ef, reads=_reads(cond, refs))))
            rest = rest[e + len(" end"):].strip()
            if rest.startswith("else "):
                rest = rest[5:]
            elif rest in ("", "end"):
                break
            else:
                raise ExtractorStop("lexer.mll, token: after a decision the census expected `else`: " + rest[:80])
        elif rest.startswith("match tok with "):
            arms = rest[len("match tok with "):]
            if arms.endswith(" end"):
                arms = arms[:-4]
            for arm in split_arms(arms):
                pat, _, body = arm.partition(" -> ")
                if not body:
                    raise ExtractorStop("lexer.mll, token: an arm the census cannot read: " + arm[:80])
                guard = pat.split(" when ", 1)
                ef = _effects(body, refs)
                out.append(("token, inside the clause `this >`", pat,
                            dict(ef, reads=_reads(guard[1], refs) if len(guard) > 1 else [])))
            break
        else:
            raise ExtractorStop("lexer.mll, token: a form of the wrapper the census cannot read: " + rest[:80])
    given = {g for _, _, fl in out for g in fl.get("gives", []) if g in tokens}
    found = set(re.findall(r"virtual_token ([A-Z][A-Z0-9_]*)", tok)) | set(re.findall(r"previous := ([A-Z][A-Z0-9_]*); \1\b", tok))
    if found - given:
        raise ExtractorStop("lexer.mll, token: tokens of the wrapper outside every decision the census read: "
                            + ", ".join(sorted(found - given)))
    return out


# --------------------------------------------------------------------------------------------
# The census
# --------------------------------------------------------------------------------------------
def census(mll_text: str = None, mly_text: str = None):
    mly = mly_text if mly_text is not None else PARSER.read_text()
    declared = declared_tokens(mly)
    tokens = set(declared)
    mll = strip_comments(mll_text if mll_text is not None else LEXER.read_text())
    header, defs, rules, trailer = split_lexer(mll)
    hdr = Header(header, tokens)
    rule_names = {r for r, _, _ in rules}
    read = []          # (rule, pattern, census of the action, normalized action)
    for rname, args, body in rules:
        for pat, action in cases(body):
            c = read_action(rname, pat, action, hdr, tokens, rule_names, set(args))
            read.append((rname, show_pattern(pat), c, norm(action)))
    # a rule that hands the lexeme to another rule gives that rule's tokens
    gives_of_rule = {}
    for rname, _, c, _ in read:
        gives_of_rule.setdefault(rname, [])
        gives_of_rule[rname] += [g for g in c["gives"] if g not in gives_of_rule[rname]]
    for rname, _, c, _ in read:
        for called in c["calls"]:
            c["gives"] += [g for g in gives_of_rule.get(called, []) if g not in c["gives"]]
    trefs, tfuns, virtual = trailer_census(trailer, tokens)

    produced = set()
    for _, _, c, _ in read:
        produced |= {g for g in c["gives"] if g in tokens}
        if "a keyword of the table" in c["gives"]:
            produced |= {t for _, t in hdr.keywords}
    produced |= set(virtual)
    # the payload of a token given by the header (`IDENT s`, the BOOL_LIT of `true`)
    produced |= {t for t in re.findall(r"\b([A-Z][A-Z0-9_]*)\b", header) if t in tokens}
    produced_unknown = sorted({t for t in re.findall(r"\b([A-Z][A-Z0-9_]{2,})\b", trailer)
                               if t not in tokens and t.isupper() and t not in {"EOF"}} - {"PI", "SIGMA"})

    L = ["# The lexer of Yon (frontend/lexer.mll), read off the code: every case of every rule, the",
         "# keyword table, and the wrapper `token` the parser calls. GENERATED by",
         "# `python regression/test_grammar_guard.py`; `--check` verifies it. Nothing is written by",
         "# hand: a form of rule the census cannot read stops it (regression/lexer_census.py).",
         "# Fields: gives= the tokens a case can give; reads= the conditions (a state, the character",
         "# before, the input ahead); writes= the states it changes; does= what else it does; refuses=",
         "# the message of a refusal. A case that can give more than one token, or reads or writes a",
         "# state, is written again in # Context, with its code.",
         "", "# Tokens (frontend/parser.mly, %token, in order of declaration); refused= when every",
         "# production of parser.mly that reads the token refuses it (a form that is gone)"]
    refused_tokens = parser_refused(mly, tokens)
    for t in declared:
        L.append("TOKEN\t" + t + ("\trefused=by every production of parser.mly" if t in refused_tokens else ""))
    L += ["", "# Precedence names (parser.mly %left/%right/%nonassoc, not tokens: no case gives them)"]
    for p in precedence_names(mly, tokens):
        L.append("PRECEDENCE\t" + p)
    L += ["", "# Keywords (keyword_table: a name the identifier case reads is looked up here)"]
    for w, t in hdr.keywords:
        L.append(f"KEYWORD\t{w}\t{t}" + ("\trefused=by every production of parser.mly" if t in refused_tokens else ""))
    L += ["", "# Definitions (`let` regular expressions)"]
    for n, d in defs:
        L.append(f"DEFINITION\t{n}\t{show_pattern(d)}")
    L += ["", "# Cases (rule <tab> pattern <tab> fields)"]
    context = []
    for rname, pat, c, action in read:
        f = []
        for key in ("gives", "reads", "writes", "does", "refuses"):
            if c[key]:
                f.append(key + "=" + " | ".join(c[key]))
        L.append("\t".join(["CASE", rname, pat] + f))
        many = len([g for g in c["gives"]]) > 1
        if many or c["reads"] or c["writes"]:
            context.append((rname, pat, f, action))
    L += ["", "# States (the refs of the lexer and of its wrapper, with their first value)"]
    for n, v in hdr.refs.items():
        L.append(f"STATE\t{n}\t{v}")
    for n, v in trefs.items():
        L.append(f"STATE\ttoken: {n}\t{v}")
    L += ["", "# Context: each case that can give more than one token, or reads or writes a state, by the",
          "# name of its rule and its pattern, with its code; then the wrapper `token`, by function"]
    for rname, pat, f, action in context:
        L.append("\t".join(["CONTEXT", rname + " " + pat] + f + ["code=" + action]))
    for name, body in hdr.functions.items():
        writes = [r for r in hdr.refs if re.search(r"\b" + r + r"\s*:=", body)]
        if writes or name == "ident_or_keyword":
            L.append("\t".join(["CONTEXT", "function " + name] + (["writes=" + " | ".join(writes)] if writes else [])
                               + ["code=" + body]))
    for where, when, fl in wrapper_decisions(tfuns["token"], {**hdr.refs, **trefs}, tokens):
        f = []
        for key in ("on", "gives", "reads", "writes", "does", "code"):
            if fl.get(key):
                f.append(key + "=" + " | ".join(fl[key]))
        L.append("\t".join(["CONTEXT", where] + (["when " + when] if when else []) + f))
    for name, body in tfuns.items():
        L.append(f"CONTEXT\tfunction {name}\tcode={body}")
    L += ["", "# Refused by the lexer (a case that raises Lexer_error)"]
    for rname, pat, c, _ in read:
        for r in c["refuses"]:
            L.append(f"REFUSED\t{rname} {pat}\t{r}")
    return "\n".join(L) + "\n", dict(declared=declared, produced=produced, virtual=virtual,
                                     precedence=precedence_names(mly, tokens),
                                     refused=refused_tokens,
                                     keywords=hdr.keywords)

//! Syntax extraction: walk a tree-sitter AST and emit definition nodes + reference edges.
//!
//! tree-sitter gives syntax, not semantics, so this pass is deliberately shallow: it records
//! *what is defined where* and *what name is referenced where*. A later resolve pass turns a
//! referenced name into a real node id. That split is what keeps this honest — an unresolved
//! call stays visible instead of being silently guessed.

use tree_sitter::{Node, Parser};

/// A definition found in a file. `local` indexes into the per-file node list so an edge can point
/// at the enclosing definition before database ids exist.
#[derive(Clone, Debug)]
pub struct DefNode {
    pub kind: &'static str,
    pub name: String,
    pub line: usize,
    pub col: usize,
    /// Exact UTF-8 byte range of the syntax node in the indexed source snapshot.
    /// Ranges are not persisted: source retrieval reparses only the selected file.
    pub start_byte: usize,
    pub end_byte: usize,
    pub detail: Option<String>,
}

/// A reference (call/import/implements/mention) at a site, attributed to the nearest enclosing def.
#[derive(Clone, Debug)]
pub struct RefEdge {
    pub src: usize,
    pub kind: &'static str,
    pub target: String,
    pub line: usize,
    pub col: usize,
}

#[derive(Default)]
pub struct Extract {
    pub nodes: Vec<DefNode>,
    pub edges: Vec<RefEdge>,
    /// `local <alias> = require("<module>")` bindings, used to resolve dotted calls across modules.
    pub imports: Vec<ImportAlias>,
}

#[derive(Clone, Debug)]
pub struct ImportAlias {
    pub alias: String,
    pub module: String,
}

/// Which grammar a path belongs to. Unknown extensions are not indexed.
pub fn language_for(path: &str) -> Option<&'static str> {
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "rs" => Some("rust"),
        "lua" => Some("lua"),
        "sh" | "bash" => Some("bash"),
        "ps1" | "psm1" => Some("powershell"),
        "md" | "markdown" => Some("markdown"),
        "js" | "mjs" | "cjs" | "jsx" => Some("javascript"),
        "ts" | "mts" | "cts" | "tsx" => Some("typescript"),
        _ => None,
    }
}

pub fn parser_for(lang: &str) -> Option<Parser> {
    let mut parser = Parser::new();
    let loaded = match lang {
        "rust" => parser
            .set_language(&tree_sitter_rust::LANGUAGE.into())
            .is_ok(),
        "lua" => parser.set_language(&tree_sitter_lua::language()).is_ok(),
        "bash" => parser
            .set_language(&tree_sitter_bash::LANGUAGE.into())
            .is_ok(),
        "powershell" => parser
            .set_language(&tree_sitter_powershell::language())
            .is_ok(),
        "javascript" => parser
            .set_language(&tree_sitter_javascript::LANGUAGE.into())
            .is_ok(),
        "typescript" => parser
            .set_language(&tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into())
            .is_ok(),
        _ => return None,
    };
    if loaded {
        Some(parser)
    } else {
        None
    }
}

/// Extract every definition and reference from one source file.
pub fn extract(path: &str, lang: &str, source: &str) -> Extract {
    let mut ctx = Ctx {
        src: source,
        nodes: Vec::new(),
        edges: Vec::new(),
        imports: Vec::new(),
        scope: Vec::new(),
        lang,
    };
    // Node 0 is always the file itself, so file-level refs (imports, doc mentions) have a source.
    ctx.nodes.push(DefNode {
        kind: if lang == "markdown" { "doc" } else { "file" },
        name: path.replace('\\', "/"),
        line: 1,
        col: 0,
        start_byte: 0,
        end_byte: source.len(),
        detail: None,
    });
    ctx.scope.push(0);

    match lang {
        "rust" | "lua" | "bash" | "powershell" | "javascript" | "typescript" => {
            if let Some(mut parser) = parser_for(lang) {
                if let Some(tree) = parser.parse(source, None) {
                    walk(&mut ctx, tree.root_node());
                }
            }
        }
        "markdown" => markdown_mentions(&mut ctx, source),
        _ => {}
    }
    Extract {
        nodes: ctx.nodes,
        edges: ctx.edges,
        imports: ctx.imports,
    }
}

struct Ctx<'a> {
    src: &'a str,
    nodes: Vec<DefNode>,
    edges: Vec<RefEdge>,
    imports: Vec<ImportAlias>,
    scope: Vec<usize>,
    lang: &'a str,
}

impl<'a> Ctx<'a> {
    fn cur(&self) -> usize {
        *self.scope.last().unwrap_or(&0)
    }

    fn text(&self, node: Node) -> &'a str {
        node.utf8_text(self.src.as_bytes()).unwrap_or("")
    }

    fn push_node(
        &mut self,
        kind: &'static str,
        name: String,
        node: Node,
        detail: Option<String>,
    ) -> usize {
        let pos = node.start_position();
        self.nodes.push(DefNode {
            kind,
            name,
            line: pos.row + 1,
            col: pos.column,
            start_byte: node.start_byte(),
            end_byte: node.end_byte(),
            detail,
        });
        self.nodes.len() - 1
    }

    fn push_edge(&mut self, kind: &'static str, target: String, node: Node) {
        let target = normalize_target(&target);
        if target.is_empty() {
            return;
        }
        let pos = node.start_position();
        self.edges.push(RefEdge {
            src: self.cur(),
            kind,
            target,
            line: pos.row + 1,
            col: pos.column,
        });
    }

    fn in_impl(&self) -> bool {
        self.scope.iter().any(|&i| self.nodes[i].kind == "impl")
    }
}

fn walk(ctx: &mut Ctx, node: Node) {
    if ctx.lang == "rust" {
        if walk_rust(ctx, node) {
            return;
        }
    } else if ctx.lang == "lua" && walk_lua(ctx, node) {
        return;
    } else if ctx.lang == "bash" && walk_bash(ctx, node) {
        return;
    } else if ctx.lang == "powershell" && walk_ps(ctx, node) {
        return;
    } else if (ctx.lang == "javascript" || ctx.lang == "typescript") && walk_js(ctx, node) {
        return;
    }
    // Default: descend.
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        walk(ctx, child);
    }
}

/// Bash: function definitions, `source`/`.` imports, and command invocations.
fn walk_bash(ctx: &mut Ctx, node: Node) -> bool {
    match node.kind() {
        "function_definition" => {
            let name = field_text(ctx, node, "name");
            if name.is_empty() {
                return false;
            }
            let idx = ctx.push_node("fn", name, node, None);
            ctx.scope.push(idx);
            recurse(ctx, node);
            ctx.scope.pop();
            true
        }
        "command" => {
            let name = node
                .child_by_field_name("name")
                .map(|n| ctx.text(n).to_string())
                .unwrap_or_default();
            if name == "source" || name == "." {
                if let Some(arg) = node.child_by_field_name("argument") {
                    ctx.push_edge("imports", strip_quotes(ctx.text(arg)), node);
                }
            } else if !name.is_empty() {
                ctx.push_edge("calls", name, node);
            }
            recurse(ctx, node);
            true
        }
        "variable_assignment" => {
            let name = field_text(ctx, node, "name");
            if !name.is_empty() {
                ctx.push_node("var", name, node, None);
            }
            true
        }
        _ => false,
    }
}

/// PowerShell: `function` statements, dot-sourcing / `Import-Module`, and command invocations.
fn walk_ps(ctx: &mut Ctx, node: Node) -> bool {
    match node.kind() {
        "function_statement" => {
            let name = find_child(node, "function_name")
                .map(|n| ctx.text(n).to_string())
                .unwrap_or_default();
            if name.is_empty() {
                return false;
            }
            let idx = ctx.push_node("fn", name, node, None);
            ctx.scope.push(idx);
            recurse(ctx, node);
            ctx.scope.pop();
            true
        }
        "command" => {
            let dot_sourced = {
                let mut cursor = node.walk();
                let found = node
                    .named_children(&mut cursor)
                    .any(|c| c.kind() == "command_invokation_operator");
                found
            };
            let name = node
                .child_by_field_name("command_name")
                .map(|n| ctx.text(n).to_string())
                .unwrap_or_default();
            if dot_sourced {
                ctx.push_edge("imports", strip_quotes(&name), node);
            } else if name.eq_ignore_ascii_case("Import-Module") {
                if let Some(elements) = node.child_by_field_name("command_elements") {
                    ctx.push_edge("imports", strip_quotes(ctx.text(elements)), node);
                }
            } else if !name.is_empty() {
                ctx.push_edge("calls", name, node);
            }
            recurse(ctx, node);
            true
        }
        "assignment_expression" => {
            if let Some(var) = find_descendant(node, "variable") {
                let name = ctx.text(var).trim_start_matches('$').to_string();
                if !name.is_empty() {
                    ctx.push_node("var", name, node, None);
                }
            }
            recurse(ctx, node);
            true
        }
        _ => false,
    }
}

/// JavaScript/TypeScript: function/class/method declarations, arrow functions bound to a
/// variable, `require`/`import` aliases and their bindings, and calls. The node kinds are the
/// tree-sitter-javascript/-typescript ones the shared `walk` dispatch sees; `export` and
/// `lexical_declaration` are not handled here, so the default descent reaches their declarations.
fn walk_js(ctx: &mut Ctx, node: Node) -> bool {
    match node.kind() {
        "function_declaration" | "generator_function_declaration" | "function_signature" => {
            let name = field_text(ctx, node, "name");
            if name.is_empty() {
                return false;
            }
            let idx = ctx.push_node("fn", name, node, None);
            ctx.scope.push(idx);
            recurse(ctx, node);
            ctx.scope.pop();
            true
        }
        "class_declaration" | "abstract_class_declaration" => {
            let name = field_text(ctx, node, "name");
            if name.is_empty() {
                return false;
            }
            let idx = ctx.push_node("class", name, node, None);
            ctx.scope.push(idx);
            recurse(ctx, node);
            ctx.scope.pop();
            true
        }
        "interface_declaration" => {
            let name = field_text(ctx, node, "name");
            if name.is_empty() {
                return false;
            }
            let idx = ctx.push_node("interface", name, node, None);
            ctx.scope.push(idx);
            recurse(ctx, node);
            ctx.scope.pop();
            true
        }
        "enum_declaration" => {
            let name = field_text(ctx, node, "name");
            if name.is_empty() {
                return false;
            }
            let idx = ctx.push_node("enum", name, node, None);
            ctx.scope.push(idx);
            recurse(ctx, node);
            ctx.scope.pop();
            true
        }
        "type_alias_declaration" => {
            let name = field_text(ctx, node, "name");
            if name.is_empty() {
                return false;
            }
            ctx.push_node("type", name, node, None);
            recurse(ctx, node);
            true
        }
        "method_definition" | "method_signature" => {
            let name = field_text(ctx, node, "name");
            if name.is_empty() {
                return false;
            }
            let idx = ctx.push_node("method", name, node, None);
            ctx.scope.push(idx);
            recurse(ctx, node);
            ctx.scope.pop();
            true
        }
        "variable_declarator" => {
            let name = field_text(ctx, node, "name");
            let value = node.child_by_field_name("value");
            if let Some(v) = value {
                let is_fn = matches!(v.kind(), "arrow_function" | "function" | "function_expression");
                if is_fn && !name.is_empty() {
                    let idx = ctx.push_node("fn", name, node, None);
                    ctx.scope.push(idx);
                    recurse(ctx, node);
                    ctx.scope.pop();
                    return true;
                }
                if let Some(module) = js_required_module(ctx, v) {
                    if !name.is_empty() {
                        ctx.push_edge("imports", module.clone(), node);
                        ctx.imports.push(ImportAlias { alias: name.clone(), module });
                    }
                }
            }
            // A destructuring pattern (`const { a } = ...`) names no single binding; skip it.
            if !name.is_empty() && !name.contains(['{', ',', '[']) {
                ctx.push_node("var", name, node, None);
            }
            if let Some(v) = value {
                walk(ctx, v);
            }
            true
        }
        "assignment_expression" => {
            // `exports.f = function () {}` / `module.exports.f = () => {}`: the left member
            // expression names the export, and the value is its definition.
            let left = node.child_by_field_name("left");
            let right = node.child_by_field_name("right");
            if let (Some(l), Some(r)) = (left, right) {
                let is_fn = matches!(r.kind(), "arrow_function" | "function" | "function_expression");
                if is_fn && l.kind() == "member_expression" {
                    let name = ctx.text(l).to_string();
                    if !name.is_empty() {
                        let idx = ctx.push_node("fn", name, node, None);
                        ctx.scope.push(idx);
                        recurse(ctx, r);
                        ctx.scope.pop();
                        return true;
                    }
                }
            }
            false
        }
        "import_statement" => {
            let module = node
                .child_by_field_name("source")
                .map(|n| strip_quotes(ctx.text(n)))
                .unwrap_or_default();
            if !module.is_empty() {
                ctx.push_edge("imports", module.clone(), node);
            }
            if let Some(clause) = find_child(node, "import_clause") {
                collect_js_imports(ctx, clause, &module);
            }
            true
        }
        "call_expression" => {
            if let Some(f) = node.child_by_field_name("function") {
                let target = ctx.text(f).to_string();
                if !target.is_empty() && target != "require" && target != "import" {
                    ctx.push_edge("calls", target, node);
                }
            }
            recurse(ctx, node);
            true
        }
        _ => false,
    }
}

/// `require('m')` or `require('m').x` names module `m`.
fn js_required_module(ctx: &Ctx, value: Node) -> Option<String> {
    let call = if value.kind() == "member_expression" {
        value.child_by_field_name("object")?
    } else {
        value
    };
    if call.kind() != "call_expression" {
        return None;
    }
    let f = call.child_by_field_name("function")?;
    if ctx.text(f) != "require" {
        return None;
    }
    let args = call.child_by_field_name("arguments")?;
    let first = first_named(args)?;
    if first.kind() != "string" {
        return None;
    }
    Some(strip_quotes(ctx.text(first)))
}

/// The local names an `import` clause binds: default, `* as ns`, and `{ a, b as c }`.
fn collect_js_imports(ctx: &mut Ctx, clause: Node, module: &str) {
    let mut cursor = clause.walk();
    for part in clause.named_children(&mut cursor) {
        match part.kind() {
            "identifier" => ctx.imports.push(ImportAlias {
                alias: ctx.text(part).to_string(),
                module: module.to_string(),
            }),
            "namespace_import" => {
                let mut inner = part.walk();
                for child in part.named_children(&mut inner) {
                    if child.kind() == "identifier" {
                        ctx.imports.push(ImportAlias {
                            alias: ctx.text(child).to_string(),
                            module: module.to_string(),
                        });
                    }
                }
            }
            "named_imports" => {
                let mut inner = part.walk();
                for spec in part.named_children(&mut inner) {
                    if spec.kind() != "import_specifier" {
                        continue;
                    }
                    let alias = field_text(ctx, spec, "alias");
                    let local = if alias.is_empty() { field_text(ctx, spec, "name") } else { alias };
                    if !local.is_empty() {
                        ctx.imports.push(ImportAlias { alias: local, module: module.to_string() });
                    }
                }
            }
            _ => {}
        }
    }
}

/// Returns true if the node was fully handled (including its own recursion).
fn walk_rust(ctx: &mut Ctx, node: Node) -> bool {
    let kind = node.kind();
    match kind {
        "function_item" | "function_signature_item" => {
            let name = field_text(ctx, node, "name");
            if name.is_empty() {
                return false;
            }
            let def_kind = if ctx.in_impl() { "method" } else { "fn" };
            let detail = rust_signature(ctx, node);
            let idx = ctx.push_node(def_kind, name, node, detail);
            ctx.scope.push(idx);
            recurse(ctx, node);
            ctx.scope.pop();
            true
        }
        "struct_item" | "enum_item" | "trait_item" | "union_item" => {
            let name = field_text(ctx, node, "name");
            if name.is_empty() {
                return false;
            }
            let def_kind = kind.trim_end_matches("_item");
            let idx = ctx.push_node(def_kind, name, node, None);
            ctx.scope.push(idx);
            recurse(ctx, node);
            ctx.scope.pop();
            true
        }
        "type_item" | "const_item" | "static_item" | "macro_definition" => {
            let name = field_text(ctx, node, "name");
            if !name.is_empty() {
                let def_kind = kind.trim_end_matches("_item");
                ctx.push_node(def_kind, name, node, None);
            }
            true
        }
        "mod_item" => {
            let name = field_text(ctx, node, "name");
            if name.is_empty() {
                return false;
            }
            let idx = ctx.push_node("module", name, node, None);
            ctx.scope.push(idx);
            recurse(ctx, node);
            ctx.scope.pop();
            true
        }
        "impl_item" => {
            let ty = field_text(ctx, node, "type");
            if ty.is_empty() {
                return false;
            }
            let trait_name = node
                .child_by_field_name("trait")
                .map(|n| ctx.text(n).to_string())
                .filter(|s| !s.is_empty());
            let idx = ctx.push_node("impl", ty, node, trait_name.clone());
            if let Some(t) = trait_name {
                ctx.push_edge("implements", t, node);
            }
            ctx.scope.push(idx);
            recurse(ctx, node);
            ctx.scope.pop();
            true
        }
        "field_declaration" => {
            let name = field_text(ctx, node, "name");
            if !name.is_empty() {
                ctx.push_node("field", name, node, None);
            }
            true
        }
        "use_declaration" => {
            if let Some(arg) = node.child_by_field_name("argument") {
                let target = ctx.text(arg).to_string();
                ctx.push_edge("imports", target, node);
            }
            true
        }
        "call_expression" => {
            if let Some(f) = node.child_by_field_name("function") {
                let target = ctx.text(f).to_string();
                ctx.push_edge("calls", target, node);
                // The host invokes exported Lua entrypoints by string. Preserve that
                // cross-language call, but only when the name is a literal identifier.
                if ctx.text(f).ends_with(".call_string") {
                    if let Some(arguments) = node.child_by_field_name("arguments") {
                        if let Some(first) = arguments.named_child(0) {
                            if first.kind() == "string_literal" {
                                let name = strip_quotes(ctx.text(first));
                                if !name.is_empty()
                                    && name
                                        .chars()
                                        .next()
                                        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
                                    && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                                {
                                    ctx.push_edge("calls", name, node);
                                }
                            }
                        }
                    }
                }
            }
            // arguments may contain further calls
            recurse(ctx, node);
            true
        }
        "string_literal" => {
            // HTTP route patterns are otherwise invisible to a symbol-only graph.
            // Index literal paths, not arbitrary strings or interpolated expressions.
            let route = strip_quotes(ctx.text(node));
            if route.len() > 1
                && route.len() <= 128
                && route.starts_with('/')
                && route.chars().skip(1).all(|c| {
                    c.is_ascii_alphanumeric() || matches!(c, '/' | '-' | '_' | ':' | '*' | '.')
                })
            {
                ctx.push_node("route", route, node, None);
            }
            true
        }
        "macro_invocation" => {
            if let Some(m) = node.child_by_field_name("macro") {
                let target = ctx.text(m).to_string();
                ctx.push_edge("macro", target, node);
            }
            recurse(ctx, node);
            true
        }
        _ => false,
    }
}

/// Returns true if the node was fully handled (including its own recursion).
fn walk_lua(ctx: &mut Ctx, node: Node) -> bool {
    match node.kind() {
        "function_declaration" => {
            let name = node
                .child_by_field_name("name")
                .map(|n| ctx.text(n).to_string())
                .unwrap_or_default();
            if name.is_empty() {
                return false;
            }
            let idx = ctx.push_node("fn", name, node, None);
            ctx.scope.push(idx);
            recurse(ctx, node);
            ctx.scope.pop();
            true
        }
        "function_call" => {
            if let Some(f) = node.child_by_field_name("name") {
                let target = ctx.text(f).to_string();
                let edge_kind = if is_capability(&normalize_target(&target)) {
                    "capability"
                } else {
                    "calls"
                };
                ctx.push_edge(edge_kind, target, node);
                // `pcall(M.control, ...)` invokes its first argument even though that argument
                // is not a syntactic function_call. Record only a plain named function here;
                // closures and computed expressions cannot be resolved safely by name.
                if matches!(ctx.text(f), "pcall" | "xpcall") {
                    if let Some(arguments) = node.child_by_field_name("arguments") {
                        let first = ctx
                            .text(arguments)
                            .trim_start_matches('(')
                            .split(',')
                            .next()
                            .unwrap_or("")
                            .trim();
                        if !first.is_empty()
                            && first
                                .chars()
                                .next()
                                .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
                            && first
                                .chars()
                                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':'))
                        {
                            ctx.push_edge("calls", first.to_string(), node);
                        }
                    }
                }
            }
            recurse(ctx, node);
            true
        }
        // `local M = {}` / `local x = require("y")` / `M.f = function() end` / `M.f = 1`.
        // A `variable_declaration` wraps an `assignment_statement`, so only the inner node is
        // handled — otherwise the same definition would be emitted twice.
        "assignment_statement" => {
            let scoped = handle_lua_assign(ctx, node);
            if let Some(idx) = scoped {
                ctx.scope.push(idx);
            }
            recurse(ctx, node);
            if scoped.is_some() {
                ctx.scope.pop();
            }
            true
        }
        "field" => {
            // `{ greet = function() end }` — a named function inside a table constructor.
            let value = node.child_by_field_name("value");
            let name = field_text(ctx, node, "name");
            if !name.is_empty() {
                if let Some(v) = value {
                    if v.kind() == "function_definition" {
                        let idx = ctx.push_node("fn", name, node, None);
                        ctx.scope.push(idx);
                        recurse(ctx, v);
                        ctx.scope.pop();
                        return true;
                    }
                }
            }
            false
        }
        _ => false,
    }
}

/// Returns the index of a newly-created definition whose value subtree should be scoped under it
/// (a function assigned to a name), or `None` when no scope change is needed.
fn handle_lua_assign(ctx: &mut Ctx, assign: Node) -> Option<usize> {
    let var = assign
        .child_by_field_name("name")
        .or_else(|| find_child(assign, "variable_list"));
    let name = var
        .map(|v| ctx.text(v).trim().to_string())
        .unwrap_or_default();
    // `child_by_field_name("value")` already reaches the value; only fall back to the
    // expression list when it does not. Applying `first_named` to a found value would descend
    // into a call's callee instead of returning the call.
    let value = assign
        .child_by_field_name("value")
        .or_else(|| find_child(assign, "expression_list").and_then(first_named));

    if let Some(v) = value {
        if v.kind() == "function_call" {
            let callee = v
                .child_by_field_name("name")
                .map(|n| ctx.text(n).to_string());
            // `require('core.memory')` and `dofile('lua/core/memory.lua')` both bind a module table
            // to a local name. Only `require` was recorded, so a dotted call through a dofile alias
            // (`provider.budget`, `windowlib.policy`) stayed unresolved whenever the member name was
            // ambiguous. Both are imports; the resolver normalises the two spellings.
            if matches!(callee.as_deref(), Some("require") | Some("dofile")) {
                if let Some(arg) = v.child_by_field_name("arguments").and_then(first_named) {
                    let target = ctx
                        .text(arg)
                        .trim_matches(|c| c == '"' || c == '\'')
                        .to_string();
                    ctx.push_edge("imports", target.clone(), assign);
                    if !name.is_empty() {
                        ctx.imports.push(ImportAlias {
                            alias: name.clone(),
                            module: target,
                        });
                    }
                }
            }
        }
    }

    if name.is_empty() || name == "self" {
        return None;
    }
    let is_fn = value
        .map(|v| v.kind() == "function_definition")
        .unwrap_or(false);
    // A bare `local` or `M.field` assignment becomes a node; anonymous table values do not.
    let kind = if is_fn {
        "fn"
    } else if name.contains('.') || name.contains(':') {
        "field"
    } else {
        "var"
    };
    let idx = ctx.push_node(kind, name, assign, None);
    if is_fn {
        Some(idx)
    } else {
        None
    }
}

/// Markdown: link a backtick identifier to a same-named node as a `mentions` edge.
/// Filtered to avoid noise: one token, at least 4 chars, no spaces or punctuation soup.
fn markdown_mentions(ctx: &mut Ctx, source: &str) {
    for (line_no, line) in source.lines().enumerate() {
        let mut rest = line;
        while let Some(start) = rest.find('`') {
            let after = &rest[start + 1..];
            let Some(end) = after.find('`') else { break };
            let span = &after[..end];
            rest = &after[end + 1..];
            let tok = span.trim();
            if tok.len() < 4 || tok.len() > 80 || tok.contains(' ') {
                continue;
            }
            if !tok.chars().all(|c| {
                c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':' | '/' | '*')
            }) {
                continue;
            }
            // Strip call parens / trailing markers so `append_turn()` links to `append_turn`.
            let simple = tok.trim_end_matches("()").trim_end_matches('*').to_string();
            if simple.len() < 4 {
                continue;
            }
            ctx.edges.push(RefEdge {
                src: 0,
                kind: "mentions",
                target: simple,
                line: line_no + 1,
                col: start,
            });
        }
    }
}

fn recurse(ctx: &mut Ctx, node: Node) {
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        walk(ctx, child);
    }
}

fn field_text(ctx: &Ctx, node: Node, field: &str) -> String {
    node.child_by_field_name(field)
        .map(|n| ctx.text(n).to_string())
        .unwrap_or_default()
}

fn first_named(node: Node) -> Option<Node> {
    let mut cursor = node.walk();
    let found = node.named_children(&mut cursor).next();
    found
}

fn find_descendant<'a>(node: Node<'a>, kind: &str) -> Option<Node<'a>> {
    if node.kind() == kind {
        return Some(node);
    }
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        if let Some(found) = find_descendant(child, kind) {
            return Some(found);
        }
    }
    None
}

fn strip_quotes(raw: &str) -> String {
    raw.trim()
        .trim_matches(|c| c == '"' || c == '\'')
        .trim()
        .to_string()
}

fn find_child<'a>(node: Node<'a>, kind: &str) -> Option<Node<'a>> {
    let mut cursor = node.walk();
    let found = node.named_children(&mut cursor).find(|c| c.kind() == kind);
    found
}

fn rust_signature(ctx: &Ctx, node: Node) -> Option<String> {
    let params = node
        .child_by_field_name("parameters")
        .map(|p| ctx.text(p).to_string());
    let ret = node
        .child_by_field_name("return_type")
        .map(|r| ctx.text(r).to_string());
    match (params, ret) {
        (Some(p), Some(r)) => Some(format!("{p} -> {r}")),
        (Some(p), None) => Some(p),
        _ => None,
    }
}

/// Keep the reference text, but collapse whitespace so `a :: b` and `a::b` resolve the same.
fn normalize_target(raw: &str) -> String {
    raw.split_whitespace().collect::<Vec<_>>().join("")
}

/// The last path segment of a reference: `a::b::c` -> `c`, `x.y` -> `y`, `host.sql_exec` -> `sql_exec`.
pub fn simple_name(target: &str) -> &str {
    target
        .rsplit(|c| matches!(c, ':' | '.' | '>' | '!' | '&' | '('))
        .find(|s| !s.is_empty())
        .unwrap_or(target)
}

/// A clean `host.<ident>` capability reference. This is what makes the graph a *control* graph:
/// `host.db.lock().map_err` from Rust is a local variable, not a capability, and is rejected here.
pub fn is_capability(target: &str) -> bool {
    let Some(rest) = target.strip_prefix("host.") else {
        return false;
    };
    !rest.is_empty() && rest.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

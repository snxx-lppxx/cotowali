// Copyright (c) 2021 zakuro <z@kuro.red>. All rights reserved.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
module checker

import cotowali.ast
import cotowali.symbols { builtin_type }
import cotowali.token { KeywordIdent }
import cotowali.messages { args_count_mismatch }
import cotowali.util { li_panic }
import cotowali.source { Pos }

fn (mut c Checker) attrs(attrs []ast.Attr) {
	for attr in attrs {
		c.attr(attr)
	}
}

fn (mut c Checker) attr(attr ast.Attr) {
	$if trace_checker ? {
		c.trace_begin(@FN, attr.name)
		defer {
			c.trace_end()
		}
	}

	if attr.kind() == .unknown {
		c.warn('unknown attribute `$attr.name`', attr.pos)
	}
}

fn stmt_is_specific_inline_shell(sh KeywordIdent, stmt ast.Stmt) bool {
	return if stmt is ast.InlineShell { stmt.key.keyword_ident() == sh } else { false }
}

fn (mut c Checker) stmts(stmts []ast.Stmt) {
	for i, stmt in stmts {
		c.stmt(stmt)
		if stmt is ast.InlineShell {
			if c.ctx.config.backend.is_sh_like() && stmt.key.keyword_ident() == .pwsh {
				prev_is_sh := i > 0 && stmt_is_specific_inline_shell(.sh, stmts[i - 1])
				next_is_sh := i < stmts.len - 1 && stmt_is_specific_inline_shell(.sh, stmts[i + 1])
				if !(prev_is_sh || next_is_sh) {
					c.warn('sh block is missing. pwsh block will be skipped in pwsh backend',
						stmt.key.pos)
				}
			}
			if c.ctx.config.backend == .pwsh && stmt.key.keyword_ident() == .sh {
				prev_is_pwsh := i > 0 && stmt_is_specific_inline_shell(.pwsh, stmts[i - 1])
				next_is_pwsh := i < stmts.len - 1
					&& stmt_is_specific_inline_shell(.pwsh, stmts[i + 1])
				if !(prev_is_pwsh || next_is_pwsh) {
					c.warn('pwsh block is missing. sh block will be skipped in pwsh backend',
						stmt.key.pos)
				}
			}
		}
	}
}

fn (mut c Checker) stmt(stmt ast.Stmt) {
	$if trace_checker ? {
		c.trace_begin(@FN)
		defer {
			c.trace_end()
		}
	}

	match mut stmt {
		ast.AssignStmt { c.assign_stmt(mut stmt) }
		ast.AssertStmt { c.assert_stmt(stmt) }
		ast.Block { c.block(stmt) }
		ast.Break { c.break_(stmt) }
		ast.Continue { c.continue_(stmt) }
		ast.Expr { c.expr(stmt) }
		ast.DocComment, ast.Empty {}
		ast.FnDecl { c.fn_decl(stmt) }
		ast.ForInStmt { c.for_in_stmt(mut stmt) }
		ast.IfStmt { c.if_stmt(stmt) }
		ast.InlineShell {}
		ast.ModuleDecl { c.module_decl(stmt) }
		ast.ReturnStmt { c.return_stmt(stmt) }
		ast.RequireStmt { c.require_stmt(mut stmt) }
		ast.WhileStmt { c.while_stmt(stmt) }
		ast.YieldStmt { c.yield_stmt(stmt) }
	}
}

fn is_assignment_to_outside_of_fn(current_fn &ast.FnDecl, left ast.Expr) bool {
	if left is ast.ParenExpr {
		return left.exprs.any(is_assignment_to_outside_of_fn(current_fn, it))
	}
	if left is ast.Var {
		sym := left.sym() or { return false }
		scope := sym.scope() or { return false }
		return if owner := scope.owner() {
			owner.id != current_fn.sym.id
		} else {
			!isnil(current_fn)
		}
	}
	li_panic(@FN, @FILE, @LINE, 'invalid left')
}

fn (mut c Checker) assign_stmt(mut stmt ast.AssignStmt) {
	$if trace_checker ? {
		c.trace_begin(@FN)
		defer {
			c.trace_end()
		}
	}

	c.expr(stmt.right)

	// if left type is placeholder, left is undefined variable.
	// So error has been reported by resolver.
	if stmt.left.typ() == builtin_type(.placeholder) {
		return
	}

	if stmt.is_const && !stmt.is_decl {
		c.error('cannot assign to constant variable', stmt.pos())
	}

	match stmt.left {
		ast.Var, ast.ParenExpr {
			pos := stmt.pos()
			if !stmt.is_decl && is_assignment_to_outside_of_fn(c.current_fn, stmt.left) {
				c.error('cannot assign to variables outside of current function', pos)
			} else if stmt.right !is ast.DefaultValue {
				// if stmt.right is DefaultValue, no need to check because it is decl without init expr.
				c.check_types(
					want: stmt.left.type_symbol()
					got: stmt.right.type_symbol()
					pos: pos
				) or {}
			}
		}
		ast.IndexExpr {
			index_expr := stmt.left as ast.IndexExpr
			index_left_ts := index_expr.left.type_symbol()

			if index_left_ts.resolved().kind() !in [.map, .array] {
				c.error('`$index_left_ts.name` does not support index assignment', index_expr.pos)
			}
		}
		else {
			// Handled by resolver. Nothing to do
		}
	}
}

fn (mut c Checker) assert_stmt(stmt ast.AssertStmt) {
	$if trace_checker ? {
		c.trace_begin(@FN)
		defer {
			c.trace_end()
		}
	}

	c.exprs(stmt.args)

	args_count := stmt.args.len
	if args_count !in [1, 2] {
		c.error(args_count_mismatch(expected: '1 or 2', actual: args_count), stmt.pos)
		return
	}
	c.expect_bool_expr(stmt.args[0], 'assert condition') or {}
	if args_count > 1 {
		msg_expr := stmt.args[1]
		c.check_types(
			want: msg_expr.scope().must_lookup_type(builtin_type(.string))
			got: msg_expr.type_symbol()
			pos: msg_expr.pos()
		) or {}
	}
}

fn (mut c Checker) block(block ast.Block) {
	$if trace_checker ? {
		c.trace_begin(@FN)
		defer {
			c.trace_end()
		}
	}

	c.stmts(block.stmts)
}

fn (mut c Checker) expect_inside_loop(stmt_name string, pos Pos) ? {
	if !c.inside_loop {
		return c.error('`$stmt_name` is not in a loop', pos)
	}
}

fn (mut c Checker) break_(stmt ast.Break) {
	c.expect_inside_loop('break', stmt.token.pos) or {}
}

fn (mut c Checker) continue_(stmt ast.Continue) {
	c.expect_inside_loop('continue', stmt.token.pos) or {}
}

fn (mut c Checker) for_in_stmt(mut stmt ast.ForInStmt) {
	$if trace_checker ? {
		c.trace_begin(@FN)
		defer {
			c.trace_end()
		}
	}

	c.expr(stmt.expr)
	ts := stmt.expr.type_symbol()
	if !ts.is_iterable() {
		c.error('`$ts.name` is not iterable', stmt.expr.pos())
	}

	inside_loop_save := c.inside_loop
	c.inside_loop = true
	defer {
		c.inside_loop = inside_loop_save
	}

	c.block(stmt.body)
}

fn (mut c Checker) if_stmt(stmt ast.IfStmt) {
	$if trace_checker ? {
		c.trace_begin(@FN)
		defer {
			c.trace_end()
		}
	}

	for i, branch in stmt.branches {
		if i == stmt.branches.len - 1 && stmt.has_else {
			c.block(branch.body)
			break
		}
		c.expr(branch.cond)
		c.expect_bool_expr(branch.cond, 'if condition') or {}
		c.block(branch.body)
	}
}

fn (mut c Checker) module_decl(mod ast.ModuleDecl) {
	$if trace_checker ? {
		c.trace_begin(@FN, mod.block.scope.name)
		defer {
			c.trace_end()
		}
	}

	c.block(mod.block)
}

fn (mut c Checker) return_stmt(stmt ast.ReturnStmt) {
	$if trace_checker ? {
		c.trace_begin(@FN)
		defer {
			c.trace_end()
		}
	}

	c.expr(stmt.expr)
	c.check_types(
		want: c.current_fn.ret_type_symbol()
		got: stmt.expr.type_symbol()
		pos: stmt.expr.pos()
	) or {}
}

fn (mut c Checker) require_stmt(mut stmt ast.RequireStmt) {
	$if trace_checker ? {
		c.trace_begin(@FN)
		defer {
			c.trace_end()
		}
	}

	c.check_file(mut stmt.file)
}

fn (mut c Checker) while_stmt(stmt ast.WhileStmt) {
	$if trace_checker ? {
		c.trace_begin(@FN)
		defer {
			c.trace_end()
		}
	}

	c.expr(stmt.cond)
	c.expect_bool_expr(stmt.cond, 'while condition') or {}

	inside_loop_save := c.inside_loop
	c.inside_loop = true
	defer {
		c.inside_loop = inside_loop_save
	}

	c.block(stmt.body)
}

fn (mut c Checker) yield_stmt(stmt ast.YieldStmt) {
	$if trace_checker ? {
		c.trace_begin(@FN)
		defer {
			c.trace_end()
		}
	}

	c.expr(stmt.expr)

	mut want_typ := builtin_type(.placeholder)
	if sequence_info := c.current_fn.ret_type_symbol().sequence_info() {
		want_typ = sequence_info.elem
	}

	if want_typ == builtin_type(.placeholder) {
		c.error('cannot use yield in function that return non-sequence type', stmt.pos)
		return
	}

	c.check_types(
		want: c.current_fn.body.scope.must_lookup_type(want_typ)
		got: stmt.expr.type_symbol()
		pos: stmt.expr.pos()
	) or {}
}

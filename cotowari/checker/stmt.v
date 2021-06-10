module checker

import cotowari.ast
import cotowari.symbols { builtin_type }

fn (mut c Checker) stmts(stmts []ast.Stmt) {
	for stmt in stmts {
		c.stmt(stmt)
	}
}

fn (mut c Checker) stmt(stmt ast.Stmt) {
	match mut stmt {
		ast.AssignStmt { c.assign_stmt(mut stmt) }
		ast.AssertStmt { c.assert_stmt(stmt) }
		ast.Block { c.block(stmt) }
		ast.Expr { c.expr(stmt) }
		ast.EmptyStmt {}
		ast.FnDecl { c.fn_decl(stmt) }
		ast.ForInStmt { c.for_in_stmt(mut stmt) }
		ast.IfStmt { c.if_stmt(stmt) }
		ast.InlineShell {}
		ast.ReturnStmt { c.return_stmt(stmt) }
		ast.RequireStmt { c.require_stmt(mut stmt) }
	}
}

fn (mut c Checker) assign_stmt(mut stmt ast.AssignStmt) {
	c.expr(stmt.right)
	mut skip_type_check := false
	match stmt.left {
		ast.Var {
			if stmt.left.typ() == builtin_type(.placeholder) {
				mut left_var := stmt.left as ast.Var
				left_var.set_typ(stmt.right.typ())
				skip_type_check = true
			}
		}
		else {
			c.error('invalid left-hand side of assignment', stmt.left.pos())
			return
		}
	}

	if !skip_type_check {
		c.check_types(
			want: stmt.left.type_symbol()
			got: stmt.right.type_symbol()
			pos: stmt.right.pos()
		) or {}
	}
}

fn (mut c Checker) assert_stmt(stmt ast.AssertStmt) {
	c.expr(stmt.expr)
	if stmt.expr.typ() != builtin_type(.bool) {
		c.error('non-bool type used as assert condition', stmt.expr.pos())
	}
}

fn (mut c Checker) block(block ast.Block) {
	c.stmts(block.stmts)
}

fn (mut c Checker) fn_decl(stmt ast.FnDecl) {
	old_fn := c.cur_fn
	c.cur_fn = stmt
	defer {
		c.cur_fn = old_fn
	}
	for param in stmt.params {
		c.expr(param)
	}
	c.block(stmt.body)
}

fn (mut c Checker) for_in_stmt(mut stmt ast.ForInStmt) {
	c.expr(stmt.expr)
	ts := stmt.expr.type_symbol()
	if ts.kind() != .array {
		c.error('non-array type `$ts.name` is not iterable', stmt.expr.pos())
	}
	stmt.val.set_typ((ts.info as symbols.ArrayTypeInfo).elem)
	c.block(stmt.body)
}

fn (mut c Checker) if_stmt(stmt ast.IfStmt) {
	for i, branch in stmt.branches {
		if i == stmt.branches.len - 1 && stmt.has_else {
			c.block(branch.body)
			break
		}
		c.expr(branch.cond)
		cond_type := branch.cond.typ()
		if cond_type != builtin_type(.bool) {
			c.error('non-bool type used as if condition', branch.cond.pos())
		}
		c.block(branch.body)
	}
}

fn (mut c Checker) return_stmt(stmt ast.ReturnStmt) {
	c.expr(stmt.expr)
	c.check_types(
		want: c.cur_fn.ret_type_symbol()
		got: stmt.expr.type_symbol()
		pos: stmt.expr.pos()
	) or {}
}

fn (mut c Checker) require_stmt(mut stmt ast.RequireStmt) {
	c.check_file(mut stmt.file)
}

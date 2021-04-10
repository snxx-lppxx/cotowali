module token

import cotowari.source { none_pos, pos }

fn test_eq() {
	t := Token{.unknown, 'text', pos(i: 10)}

	assert t == Token{
		...t
		pos: none_pos
	}
	assert t != Token{
		...t
		pos: pos({})
	}
	assert t != Token{
		...t
		kind: .eof
	}
	assert t != Token{
		...t
		text: 'x'
	}
}

fn test_is() {
	assert TokenKind.op_plus.@is(.op)
	assert !TokenKind.ident.@is(.op)
	assert TokenKind.bool_lit.@is(.literal)
	assert !TokenKind.ident.@is(.literal)
	assert TokenKind.key_if.@is(.keyword)
	assert !TokenKind.ident.@is(.keyword)
}

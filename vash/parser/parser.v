module parser

import vash.source { Source }
import vash.lexer { Lexer }
import vash.token { Token }
import vash.util { abs }
import vash.ast

pub struct Parser {
mut:
	lexer Lexer
	buf []Token
	token_idx int
}

pub fn (p &Parser) token(i int) Token {
	if abs(i) >= p.buf.len {
		panic('cannot take token($i) (p.buf.len = $p.buf.len)')
	}
	return p.buf[(p.token_idx + i) % p.buf.len]
}

pub fn (mut p Parser) read() Token {
	p.buf[p.token_idx] = p.lexer.next() or { p.buf[p.token_idx] }
	p.token_idx++
	return p.token(0)
}

[inline]
pub fn new(lexer Lexer) Parser {
	mut p := Parser{
		lexer: lexer
		buf: []Token{len: 3}  // LL(3)
	}
	for i in 0..p.buf.len {
		p.buf[i] = p.lexer.next() or { p.buf[i - 1] } // at least p.lexer.next() returns 1 item, .eof. so (i - 1) >= 0
	}
	return p
}

pub fn (p &Parser) source() Source {
	return p.lexer.source
}

pub fn (mut p Parser) parse() ?ast.File {
	return ast.File{
		path: p.source().path
	}
}

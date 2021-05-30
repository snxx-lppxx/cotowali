module source

import cotowari.util { @in, in2 }

pub type Char = string // utf-8 char

pub type CharCond = fn (c Char) bool

pub fn (c Char) rune() rune {
	return rune(c.utf32_code())
}

pub enum CharClass {
	whitespace
	eol
	alphabet
	digit
	hex_digit
	oct_digit
	binary_digit
}

pub fn (c Char) is_not(class CharClass) bool {
	return !c.@is(class)
}

pub fn (c Char) is_any(classes ...CharClass) bool {
	for class in classes {
		if c.@is(class) {
			return true
		}
	}
	return false
}

pub fn (c Char) @is(class CharClass) bool {
	return match class {
		.whitespace { (c.len == 1 && c[0].is_space() && c[0] !in [`\n`, `\r`]) || c == '　' }
		.eol { c[0] in [`\r`, `\n`] }
		.alphabet { in2(c[0], `a`, `z`, `A`, `Z`) }
		.digit { @in(c[0], `0`, `9`) }
		.hex_digit { c.@is(.digit) || in2(c[0], `a`, `f`, `A`, `F`) }
		.oct_digit { @in(c[0], `0`, `7`) }
		.binary_digit { @in(c[0], `0`, `1`) }
	}
}

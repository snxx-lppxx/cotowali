// Copyright (c) 2021 zakuro <z@kuro.red>. All rights reserved.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
import os
import rand
import term
import v.util { color_compare_strings, find_working_diff_command }
import time
import runtime

// -- config --

const (
	fail_list            = [
		'assert.li',
		'assert_minimal.li',
		'exit_nonzero_test.li',
		'panic.li',
		'test_runner_test.li',
		'std/platform/require_command.li',
		'std/platform/required_command_not_found.li',
		'std/assert.li',
		'std/http_404.li',
	]
	skip_list            = ['raytracing.li', 'welcome.li']
	pwsh_skip_list       = [
		'readme_example.li',
		'posix_test.li',
		'glob_test.li',
	]
	himorogi_list        = [
		'assert_minimal.li',
		'empty.li',
		'expr/int_test.li',
		'expr/float_test.li',
		'expr/bool_test.li',
	]
	use_test_runner_list = ['test_runner_test.li', 'std/assert.li']
	slow_list            = os.glob('tests/require_remote/*') ?
)

// --

fn indent(n int) string {
	return '  '.repeat(n)
}

fn indent_each_lines(n int, s string) string {
	return s.split_into_lines().map(indent(n) + it).join('\n')
}

enum FileSuffix {
	li
	sh
	err
	mod
	todo
	out
	noemit
}

fn suffix(s FileSuffix) string {
	return match s {
		.li { '.li' }
		.sh { '.sh' }
		.err { '.err' }
		.mod { '.mod' }
		.todo { '.todo' }
		.out { '.out' }
		.noemit { '.noemit' }
	}
}

fn is_err_test_file(f string) bool {
	name := os.base(f.trim_string_right(suffix(.li)).trim_string_right(suffix(.todo)))
	dir_parts := os.dir(f).split(os.path_separator)
	return name.ends_with(suffix(.err)) || name == 'error' || dir_parts.any(it.ends_with('errors'))
}

fn is_fail_test_file(f string) bool {
	return fail_list.any(f.ends_with(it))
}

fn is_todo_test_file(f string) bool {
	return f.trim_string_right(suffix(.li)).ends_with(suffix(.todo))
}

fn is_noemit_test_file(f string) bool {
	return f.trim_string_right(suffix(.li)).trim_string_right(suffix(.todo)).ends_with(suffix(.noemit))
}

fn is_mod_file(f string) bool {
	return f.trim_string_right(suffix(.li)).ends_with(suffix(.mod))
}

fn out_path(f string) string {
	return f.trim_string_right(suffix(.li)) + suffix(.out)
}

fn is_target_file(s string, opt TestOption) bool {
	if skip_list.any(s.ends_with(it)) {
		return false
	}
	if opt.pwsh && pwsh_skip_list.any(s.ends_with(it)) {
		return false
	}
	if opt.himorogi && !himorogi_list.any(s.ends_with(it)) {
		return false
	}
	if opt.fast && slow_list.any(s.ends_with(it)) {
		return false
	}
	return s.ends_with(suffix(.li)) && !is_mod_file(s)
}

fn use_test_runner(f string) bool {
	return use_test_runner_list.any(f.ends_with(it))
}

fn get_sources(paths []string, opt TestOption) []string {
	mut res := []string{}
	for path in paths {
		if os.is_dir(path) {
			sub_paths := os.ls(path) or { panic(err) }
			res << get_sources(sub_paths.map(os.join_path(path, it)), opt)
		} else if is_target_file(path, opt) {
			res << path
		}
	}
	return res
}

struct Lic {
	source   string [required]
	bin      string [required]
	backend  string = 'sh'
	prod     bool
	autofree bool
}

enum LicCommand {
	shellcheck
	compile
	compile_to_file
	noemit
	run
	test
}

fn (lic Lic) compile() ? {
	mut flags := if lic.prod { '-prod' } else { '-g' }
	if lic.autofree {
		flags += ' -autofree'
	}
	res := os.execute('v $flags $lic.source -o $lic.bin')
	if res.exit_code != 0 {
		return error_with_code(res.output, res.exit_code)
	}
	return
}

fn (lic Lic) execute(c LicCommand, file string) os.Result {
	if lic.bin.contains('himorogi') {
		if c == .run {
			return os.execute('$lic.bin $file')
		} else {
			panic('invalid command `$c` for himorogi')
		}
	}

	cmd := '$lic.bin -b $lic.backend'
	return match c {
		.shellcheck { os.execute('$cmd -test $file | shellcheck -') }
		.compile { os.execute('$cmd -test $file') }
		.compile_to_file { os.execute('$cmd -test $file > ${file.trim_string_right(suffix(.li))}${suffix(.sh)}') }
		.noemit { os.execute('$cmd -no-emit $file') }
		.run { os.execute('$cmd run $file') }
		.test { os.execute('$cmd test $file') }
	}
}

fn (lic Lic) new_test_case(path string, opt TestOption) TestCase {
	out := out_path(path)
	return TestCase{
		lic: lic
		opt: opt
		path: path
		out_path: out
		is_err_test: is_err_test_file(path)
		is_fail_test: is_fail_test_file(path)
		is_todo_test: is_todo_test_file(path)
		is_noemit_test: is_noemit_test_file(path)
		expected: os.read_file(out) or { '' }
	}
}

struct TestOption {
	shellcheck   bool
	fix_mode     bool
	compile_only bool
	pwsh         bool
	himorogi     bool
	prod         bool
	fast         bool
	autofree     bool
	parallel     bool = true
}

enum TestResultStatus {
	ok
	compiled
	failed
	fixed
	todo
}

struct TestResult {
	path      string
	exit_code int
	expected  string
	output    string
	elapsed   time.Duration
mut:
	status TestResultStatus
}

struct TestCase {
	lic Lic
	opt TestOption
mut:
	path               string [required]
	out_path           string [required]
	is_shellcheck_test bool
	is_err_test        bool   [required]
	is_fail_test       bool   [required]
	is_todo_test       bool   [required]
	is_noemit_test     bool   [required]
	expected           string [required]
}

fn (t TestCase) is_normal_test() bool {
	return !(t.is_todo_test || t.is_err_test || t.is_noemit_test)
}

fn fix_todo(f string, s FileSuffix) {
	base := f.trim_string_right(suffix(s)).trim_string_right(suffix(.todo))
	os.mv(f, base + suffix(s)) or { panic(err) }
}

fn (t &TestCase) run() TestResult {
	mut sw := time.new_stopwatch()
	sw.start()
	cmd_res := if t.is_shellcheck_test {
		t.lic.execute(.shellcheck, t.path)
	} else if t.is_err_test {
		t.lic.execute(.compile, t.path)
	} else if t.opt.compile_only {
		t.lic.execute(.compile_to_file, t.path)
	} else if t.is_noemit_test {
		t.lic.execute(.noemit, t.path)
	} else if use_test_runner(t.path) {
		t.lic.execute(.test, t.path)
	} else {
		t.lic.execute(.run, t.path)
	}

	sw.stop()
	mut result := TestResult{
		path: t.path
		elapsed: sw.elapsed()
		expected: t.expected
		output: cmd_res.output
		exit_code: cmd_res.exit_code
	}

	correct_exit_code := if t.is_err_test || (t.is_fail_test && !t.opt.compile_only) {
		result.exit_code != 0
	} else {
		result.exit_code == 0
	}
	result.status = if t.is_todo_test {
		TestResultStatus.todo
		// result.status = .todo
	} else if t.opt.compile_only {
		if correct_exit_code { TestResultStatus.compiled } else { TestResultStatus.failed }
	} else if (result.output == result.expected || t.opt.compile_only) && correct_exit_code {
		TestResultStatus.ok
	} else {
		TestResultStatus.failed
	}

	if t.opt.fix_mode && !t.is_shellcheck_test {
		if correct_exit_code {
			if t.is_todo_test {
				if result.output == result.expected {
					fix_todo(t.path, .li)
					fix_todo(t.out_path, .out)
					result.status = .fixed
				}
			} else if result.output != result.expected {
				os.write_file(t.out_path, result.output) or { panic(err) }
				result.status = .fixed
			}
		}
	}

	return result
}

fn (result TestResult) summary_message(file string) string {
	status := match result.status {
		.ok, .fixed { term.ok_message('[ OK ]') }
		.compiled { term.ok_message('[COMPILED]') }
		.todo { term.warn_message('[TODO]') }
		.failed { term.fail_message('[FAIL]') }
	}
	elapsed_ms := f64(result.elapsed.microseconds()) / 1000.0
	msg := '$status ${elapsed_ms:6.2f} ms $file'
	return if result.status == .fixed { '$msg (FIXED)' } else { msg }
}

fn (r TestResult) failed_message(file string) string {
	format_output := fn (text string) string {
		indent := ' '.repeat(4)
		return if text.len == 0 { '${indent}__EMPTY__' } else { indent_each_lines(1, text) }
	}

	mut lines := [
		r.summary_message(file),
		'${indent(1)}exit_code: $r.exit_code',
		'${indent(1)}output:',
		format_output(r.output),
		'${indent(1)}expected:',
		format_output(r.expected),
	]
	if diff_cmd := find_working_diff_command() {
		diff := color_compare_strings(diff_cmd, rand.ulid(), r.expected, r.output)
		lines << [
			'${indent}diff:',
			indent_each_lines(2, diff),
		]
	}

	return lines.map(it + '\n').join('')
}

fn (r TestResult) message() string {
	file := os.real_path(r.path).trim_string_left(os.real_path(@VMODROOT)).trim_string_left('/')
	return match r.status {
		.failed { r.failed_message(file) }
		else { r.summary_message(file) }
	}
}

struct TestSuite {
	opt TestOption
mut:
	cases []TestCase
}

fn new_test_suite(paths []string, opt TestOption) TestSuite {
	dir := os.real_path(@VMODROOT)
	lic_dir := os.join_path(dir, 'cmd', if opt.himorogi { 'himorogi' } else { 'lic' })
	sources := get_sources(paths, opt)

	lic := Lic{
		prod: opt.prod
		autofree: opt.autofree
		source: lic_dir
		backend: if opt.pwsh { 'pwsh' } else { 'sh' }
		bin: os.join_path('tests', if opt.himorogi { 'himorogi' } else { 'lic' })
	}

	lic.compile() or {
		eprintln([
			'${term.fail_message('ERROR')} Faild to compile lic',
			'    exit_code: $err.code',
			'    output:',
			indent_each_lines(2, err.msg),
		].join('\n'))
		exit(1)
	}

	mut cases := []TestCase{}
	for s in sources {
		test := lic.new_test_case(s, opt)
		cases << test
		if opt.shellcheck && test.is_normal_test() {
			cases << TestCase{
				...test
				is_shellcheck_test: true
			}
		}
	}
	return TestSuite{
		opt: opt
		cases: cases
	}
}

fn (t TestSuite) run() bool {
	mut sw := time.new_stopwatch()
	mut ok_n, mut compiled_n, mut fixed_n, mut todo_n, mut failed_n := 0, 0, 0, 0, 0
	sw.start()

	mut status_list := []TestResultStatus{}
	if t.opt.parallel {
		mut threads := []thread TestResultStatus{}
		for tt in t.cases {
			threads << go fn (t TestCase) TestResultStatus {
				res := t.run()
				println(res.message())
				return res.status
			}(tt)
			if threads.len >= runtime.nr_jobs() - 1 {
				status_list << threads.wait()
				threads.clear()
			}
		}
		status_list << threads.wait()
	} else {
		for tt in t.cases {
			res := tt.run()
			println(res.message())
			status_list << res.status
		}
	}
	sw.stop()

	for s in status_list {
		match s {
			.ok { ok_n++ }
			.compiled { compiled_n++ }
			.fixed { fixed_n++ }
			.todo { todo_n++ }
			.failed { failed_n++ }
		}
	}

	println('Total: $t.cases.len, Runtime: ${sw.elapsed().milliseconds()}ms')
	println(if t.opt.compile_only {
		term.ok_message('$compiled_n Compiled')
	} else {
		term.ok_message('$ok_n Passed')
	})
	if fixed_n > 0 {
		println(term.ok_message('$fixed_n Fixed'))
	}
	if todo_n > 0 {
		println(term.warn_message('$todo_n Skipped'))
	}
	if failed_n > 0 {
		println(term.fail_message('$failed_n Failed'))
	}

	return failed_n == 0
}

fn main() {
	// TODO: Use cli module

	if ['--help', '-h', 'help'].any(it in os.args) {
		println('Usage: v run tests/tester.v flags... [test.li|tests]...')
		println('Flags:')
		println('  --shellcheck   use shellcheck')
		println('  --fix-mode     auto fix failed tests')
		println('  --compile      compile tests instead of run tests')
		println('  --pwsh         use pwsh backend')
		println('  --himorogi     himorogi test')
		println("  --prod         enable V's -prod")
		println('  --fast         skip slow tests')
		println('  --autofree     enable autofree')
		println('  --no-parallel  disable parallel test')
		return
	}

	shellcheck := '--shellcheck' in os.args
	fix_mode := '--fix' in os.args
	compile_only := '--compile' in os.args
	pwsh := '--pwsh' in os.args
	himorogi := '--himorogi' in os.args
	prod := '--prod' in os.args
	fast := '--fast' in os.args
	autofree := '--autofree' in os.args
	parallel := '--no-parallel' !in os.args
	if compile_only && (fix_mode || shellcheck) {
		eprintln('cannot use --compile with another flags')
		exit(1)
	}

	args := os.args.filter(!it.starts_with('-'))
	paths := if args.len > 1 {
		os.args[1..]
	} else if compile_only {
		['tests'].map(os.join_path(@VMODROOT, it))
	} else {
		['examples', 'tests'].map(os.join_path(@VMODROOT, it))
	}

	t := new_test_suite(paths,
		shellcheck: shellcheck
		fix_mode: fix_mode
		compile_only: compile_only
		autofree: autofree
		pwsh: pwsh
		himorogi: himorogi
		prod: prod
		fast: fast
		parallel: parallel
	)
	exit(if t.run() { 0 } else { 1 })
}

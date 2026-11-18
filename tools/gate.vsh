#!/usr/bin/env -S v run

// The local gate: what a pull request has to pass, runnable before pushing so
// that a red review is never the first news of a problem.
//
// Six steps, each reporting on its own line: formatting, the pure-V rule, a
// build that answers --version and --help, the suite, the suite again with no
// garbage collector, and the links between the documents in the tree. The exit
// status is zero only when all six pass.
//
// The build is a step because this tree has a binary: a frontend that compiles
// and cannot answer --help has not been built, and a library would have nothing
// to build at all.

import os

const c_source_extensions = ['.c', '.h', '.cc', '.cpp', '.hpp', '.S', '.s']

// The patterns that bring C into a V program. A line whose trimmed text starts
// with `//` is exempt, which is why prose in a comment is safe and a trailing
// comment on a code line is not.
const interop_patterns = ['#include ', '#flag ', 'C.']

struct CommandResult {
	output    string
	exit_code int
}

fn main() {
	root := os.dir(os.dir(@FILE))
	println('gate: ${root}')
	mut failures := []string{}
	report('formatting', check_formatting(root), mut failures)
	report('pure V', check_pure_v(root), mut failures)
	report('build', check_build(root), mut failures)
	report('tests', check_tests(root), mut failures)
	report('tests, no collector', check_tests_without_a_collector(root), mut failures)
	report('links', check_links(root), mut failures)
	if failures.len > 0 {
		eprintln('')
		eprintln('gate: ${failures.len} step(s) failed: ${failures.join(', ')}')
		exit(1)
	}
	println('')
	println('gate: all steps pass')
}

fn report(name string, problems []string, mut failures []string) {
	if problems.len == 0 {
		println('  ${name}: ok')
		return
	}
	failures << name
	eprintln('  ${name}: failed')
	for problem in problems {
		eprintln('    ${problem}')
	}
}

fn run(arguments []string) CommandResult {
	result := os.exec(arguments)
	return CommandResult{
		output:    result.output
		exit_code: result.exit_code
	}
}

fn check_formatting(root string) []string {
	result := run(['v', 'fmt', '-verify', root])
	if result.exit_code == 0 {
		return []string{}
	}
	mut problems := []string{}
	for line in result.output.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed.contains('is not formatted') || trimmed.starts_with('diff ') {
			problems << trimmed
		}
	}
	if problems.len == 0 {
		problems << 'v fmt -verify exited ${result.exit_code}: ${result.output.trim_space()}'
	}
	return problems
}

// check_pure_v looks for what breaks the first rule rather than for the rule: a
// C source file anywhere in the tree, and C interop in any file the frontend is
// compiled from. tools/ is skipped because the gate names those patterns on
// purpose, and .omh/ holds notes for one agent run rather than frontend source.
fn check_pure_v(root string) []string {
	mut problems := []string{}
	for extension in c_source_extensions {
		for file in os.walk_ext(root, extension) {
			if ignored(file) {
				continue
			}
			problems << '${relative(file, root)}: C source in a tree that is V only'
		}
	}
	for file in os.walk_ext(root, '.v') {
		if ignored(file) || file.contains('/tools/') {
			continue
		}
		lines := os.read_lines(file) or { continue }
		for i, line in lines {
			trimmed := line.trim_space()
			if trimmed.starts_with('//') {
				continue
			}
			for pattern in interop_patterns {
				if trimmed.contains(pattern) {
					problems << '${relative(file, root)}:${i + 1}: ${pattern.trim_space()} brings C into the frontend'
				}
			}
		}
	}
	return problems
}

// check_build compiles the binary into a scratch directory, so nothing is left in
// the tree, and then asks it the two questions that need no input. A frontend is
// built when it answers them, not when the compiler exits zero.
fn check_build(root string) []string {
	scratch := os.join_path(os.temp_dir(), 'vvd_gate_${os.getpid()}')
	os.mkdir_all(scratch) or { return ['the gate cannot make ${scratch}: ${err}'] }
	defer {
		os.rmdir_all(scratch) or {}
	}
	binary := os.join_path(scratch, 'vvd')
	built := run(['v', '-gc', 'none', '-nocache', '-o', binary, root])
	if built.exit_code != 0 {
		return ['v -gc none -o ${binary} exited ${built.exit_code}: ${built.output.trim_space()}']
	}
	asked := run([binary, '--version'])
	if asked.exit_code != 0 {
		return ['${binary} --version exited ${asked.exit_code}: ${asked.output.trim_space()}']
	}
	if !asked.output.starts_with('vvd ') {
		return ['${binary} --version printed something else: ${asked.output.trim_space()}']
	}
	answered := run([binary, '--help'])
	if answered.exit_code != 0 || !answered.output.contains('-o <file>') {
		return ['${binary} --help did not print the flag surface']
	}
	return []string{}
}

fn check_tests(root string) []string {
	// -nocache, not `v test .`: the module cache makes a run depend on which C
	// compiler V picked for each file, and a failing suite that clears itself on
	// a cold cache wastes the reader's afternoon.
	return test_failures(run(['v', '-nocache', 'test', root]))
}

// check_tests_without_a_collector is the same suite compiled the way a program
// that links through vlk is built: `-gc none`, no collector at all. The library
// promises it does not lean on a collection, and the frontend is the first
// program that would notice if it did.
fn check_tests_without_a_collector(root string) []string {
	return test_failures(run(['v', '-gc', 'none', '-nocache', 'test', root]))
}

fn test_failures(result CommandResult) []string {
	if result.exit_code == 0 {
		return []string{}
	}
	mut problems := []string{}
	for line in result.output.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed.starts_with('FAIL') || trimmed.contains('error:') {
			problems << trimmed
		}
	}
	if problems.len == 0 {
		problems << 'v -nocache test exited ${result.exit_code}: ${result.output.trim_space()}'
	}
	return problems
}

// check_links resolves every relative link in the markdown at the root of the
// tree. A link to a file that is not here is a promise to a reader that the tree
// does not keep, and nothing else in the tree reads markdown.
fn check_links(root string) []string {
	mut problems := []string{}
	for file in os.walk_ext(root, '.md') {
		if ignored(file) {
			continue
		}
		text := os.read_file(file) or { continue }
		directory := os.dir(file)
		mut rest := text
		for {
			start := rest.index('](') or { break }
			rest = rest[start + 2..]
			end := rest.index(')') or { break }
			target := rest[..end].trim_space()
			rest = rest[end + 1..]
			if target == '' || target.starts_with('#') || target.starts_with('http://')
				|| target.starts_with('https://') || target.starts_with('mailto:') {
				continue
			}
			path := target.all_before('#')
			if os.exists(os.join_path(directory, path)) || os.exists(os.join_path(root, path)) {
				continue
			}
			problems << '${relative(file, root)}: ${target} does not resolve'
		}
	}
	return problems
}

// ignored keeps the walk out of the directories that hold no frontend source:
// the git database, and the notes for one agent run.
fn ignored(file string) bool {
	return file.contains('/.git/') || file.contains('/.omh/')
}

fn relative(file string, root string) string {
	return file.replace('${root}/', '')
}

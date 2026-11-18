module cli

import os

// The tests read the flag surface the way a build writes one, and a response file
// is written where a test can look at it rather than committed.
fn scratch(name string, text string) string {
	dir := os.join_path(os.temp_dir(), 'vvd_cli_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	path := os.join_path(dir, name)
	if text != '' {
		os.write_file(path, text) or { panic(err) }
	}
	return path
}

// refusal_message is the error a line comes to, and the empty string when the
// line parses. It lets a test ask many lines one question.
fn refusal_message(args []string) string {
	parse(args) or { return err.msg() }
	return ''
}

fn test_an_input_and_an_output() {
	opts := parse(['seven.o', '-o', 'seven'])!
	assert opts.inputs == ['seven.o']
	assert opts.output == 'seven'
	assert opts.entry == default_entry
	assert opts.flavor == default_flavor
	assert opts.link_items.len == 1
	assert !opts.link_items[0].library
}

fn test_the_joined_spellings_mean_the_same_as_the_separate_ones() {
	separate := parse(['-o', 'program', '-l', 'm', '-L', '/usr/lib', 'x.o'])!
	joined := parse(['-oprogram', '-lm', '-L/usr/lib', 'x.o'])!
	long := parse(['--output=program', '--library=m', '--library-path=/usr/lib', 'x.o'])!
	assert joined.output == separate.output
	assert long.output == separate.output
	assert joined.libraries == separate.libraries
	assert long.libraries == separate.libraries
	assert joined.library_dirs == separate.library_dirs
	assert long.library_dirs == separate.library_dirs
}

fn test_the_library_holds_the_place_it_was_written_in() {
	opts := parse(['a.o', '-lm', 'b.o', '-l', 'c'])!
	assert opts.inputs == ['a.o', 'b.o']
	assert opts.libraries == ['m', 'c']
	assert opts.link_items.len == 4
	assert !opts.link_items[0].library && opts.link_items[0].value == 'a.o'
	assert opts.link_items[1].library && opts.link_items[1].value == 'm'
	assert !opts.link_items[2].library && opts.link_items[2].value == 'b.o'
	assert opts.link_items[3].library && opts.link_items[3].value == 'c'
}

fn test_an_entry_is_a_name_the_line_names() {
	assert parse(['-e', 'start', 'x.o'])!.entry == 'start'
	assert parse(['-estart', 'x.o'])!.entry == 'start'
	assert parse(['--entry=start', 'x.o'])!.entry == 'start'
	assert parse(['x.o'])!.entry == default_entry
	assert !parse(['x.o'])!.entry_given
	assert parse(['-e', 'start', 'x.o'])!.entry_given
}

fn test_shared_and_static_are_two_different_files() {
	assert parse(['-shared', 'x.o'])!.shared
	assert parse(['--shared', 'x.o'])!.shared
	assert parse(['-static', 'x.o'])!.static_link
	refusal := refusal_message(['-shared', '-static', 'x.o'])
	assert refusal.contains('-shared')
	assert refusal.contains('-static')
	assert parse(['-shared', 'x.o'])!.static_link == false
}

fn test_a_soname_belongs_to_a_shared_object() {
	assert parse(['-shared', '--soname=libx.so.1', 'x.o'])!.soname == 'libx.so.1'
	assert parse(['-shared', '-soname', 'libx.so.1', 'x.o'])!.soname == 'libx.so.1'
	// -h is GNU ld's short spelling of the same request, and --help is the
	// question, so the two do not collide.
	assert parse(['-shared', '-h', 'libx.so.1', 'x.o'])!.soname == 'libx.so.1'
	assert refusal_message(['-soname', 'libx.so.1', 'x.o']).contains('shared')
}

fn test_a_loader_is_named_by_a_program_and_by_neither_of_the_others() {
	assert parse(['--dynamic-linker=/lib/ld.so', 'x.o'])!.dynamic_linker == '/lib/ld.so'
	assert refusal_message(['-static', '--dynamic-linker=/lib/ld.so', 'x.o']).contains('-static')
	assert refusal_message(['-shared', '--dynamic-linker=/lib/ld.so', 'x.o']).contains('shared')
}

fn test_every_z_keyword_this_linker_implements_is_read() {
	assert parse(['-z', 'now', 'x.o'])!.bind_now
	assert parse(['-z', 'relro', 'x.o'])!.relro
	assert !parse(['-z', 'norelro', 'x.o'])!.relro
	exec_stack := parse(['-z', 'execstack', 'x.o'])!
	assert exec_stack.execstack && !exec_stack.noexecstack
	// The last of the pair wins, because a line that says both means the second.
	quiet := parse(['-z', 'execstack', '-z', 'noexecstack', 'x.o'])!
	assert quiet.noexecstack && !quiet.execstack
	assert parse(['-z', 'defs', 'x.o'])!.no_undefined
	assert parse(['--no-undefined', 'x.o'])!.no_undefined
}

fn test_a_z_keyword_that_is_not_implemented_is_refused_by_name() {
	origin := refusal_message(['-z', 'origin', 'x.o'])
	assert origin.contains('origin')
	assert origin.contains('now')
	undefs := refusal_message(['-z', 'undefs', 'x.o'])
	assert undefs.contains('undefs')
}

fn test_the_default_library_is_dropped_by_the_two_spellings_that_ask() {
	assert parse(['-nostdlib', 'x.o'])!.no_default_libraries
	assert parse(['-nodefaultlibs', 'x.o'])!.no_default_libraries
	assert !parse(['x.o'])!.no_default_libraries
}

fn test_an_emulation_is_recorded_for_the_link_to_judge() {
	assert parse(['-m', 'elf_x86_64', 'x.o'])!.emulation == 'elf_x86_64'
	assert parse(['--emulation=elf_x86_64', 'x.o'])!.emulation == 'elf_x86_64'
}

fn test_the_flavor_is_gnu_and_another_one_is_refused() {
	assert parse(['-flavor', 'gnu', 'x.o'])!.flavor == 'gnu'
	assert parse(['--flavor=gnu', 'x.o'])!.flavor == 'gnu'
	assert refusal_message(['--flavor=darwin', 'x.o']).contains('darwin')
}

fn test_a_question_needs_no_input_file() {
	assert parse(['--help'])!.show_help
	assert parse(['-help'])!.show_help
	assert parse(['--version'])!.show_version
	assert parse(['-V'])!.show_version
	assert parse(['-v'])!.show_version
	assert parse(['--stats', 'x.o'])!.stats
	assert parse(['--verbose', 'x.o'])!.verbose
}

fn test_a_line_with_no_input_is_refused() {
	assert refusal_message([]).contains('no input files')
}

fn test_a_flag_this_frontend_does_not_implement_is_refused_by_name() {
	assert refusal_message(['-r', 'a.o', 'b.o']).contains('relocatable')
	assert refusal_message(['-pie', 'a.o']).contains('-pie')
}

// Each spelling in the refusal table answers with the option as it was written
// and a reason, which is the whole point of the table: a build that wrote the flag
// is told rather than served a link it did not ask for.
fn test_every_refused_spelling_in_the_table_answers_with_its_reason() {
	for group in refusals {
		for spelling in group.spellings {
			written := if spelling.ends_with('=') { '${spelling}value' } else { spelling }
			answer := refused(written) or { '' }
			assert answer.contains(written), '${written} was not refused'
			assert answer.contains(group.reason), answer
		}
	}
}

fn test_a_flag_nothing_knows_is_an_unknown_argument() {
	answer := refusal_message(['-Qunused', 'x.o'])
	assert answer.contains('unknown argument')
	assert answer.contains('-Qunused')
}

fn test_a_flag_that_needs_a_value_is_refused_without_one() {
	spellings := ['-o', '-e', '-l', '-L', '-h', '-z', '-m', '--dynamic-linker']
	for spelling in spellings {
		assert refusal_message([spelling]).contains('${spelling} needs a value'), spelling
	}
}

fn test_a_word_after_two_dashes_is_an_input() {
	opts := parse(['--', '-o', 'x.o'])!
	assert opts.inputs == ['-o', 'x.o']
	assert opts.output == default_output
}

fn test_a_response_file_is_spliced_where_it_stands() {
	path := scratch('args.rsp', '-o prog "spaced name.o" -lm')
	opts := parse(['first.o', '@${path}', 'last.o'])!
	assert opts.inputs == ['first.o', 'spaced name.o', 'last.o']
	assert opts.output == 'prog'
	assert opts.libraries == ['m']
}

fn test_a_response_file_can_name_another() {
	inner := scratch('inner.rsp', 'b.o -e start')
	outer := scratch('outer.rsp', 'a.o @${inner}')
	opts := parse(['@${outer}'])!
	assert opts.inputs == ['a.o', 'b.o']
	assert opts.entry == 'start'
}

fn test_a_response_file_that_names_itself_is_refused() {
	path := scratch('loop.rsp', '')
	os.write_file(path, '@${path}') or { panic(err) }
	assert refusal_message(['@${path}']).contains('nested')
}

fn test_an_unclosed_quote_in_a_response_file_is_refused() {
	path := scratch('unclosed.rsp', '"a.o')
	assert refusal_message(['@${path}']).contains('quote')
}

fn test_a_response_file_that_is_not_there_is_refused_by_name() {
	path := os.join_path(os.temp_dir(), 'vvd_cli_missing_${os.getpid()}.rsp')
	assert refusal_message(['@${path}']).contains(path)
}

fn test_usage_names_the_flags_a_build_writes() {
	text := usage()
	assert text.contains('-o <file>')
	assert text.contains('--entry=')
	assert text.contains('--library=')
	assert text.contains('-shared')
	assert text.contains('-static')
	assert text.contains('--stats')
	assert text.contains('--version')
	assert text.contains('--help')
	// A reader of --help is told what is refused rather than finding out one
	// build at a time.
	assert text.contains('--gc-sections')
}

fn test_the_version_line_names_the_frontend_and_its_manifest_version() {
	assert version_line() == 'vvd ${version}'
	assert version != ''
}

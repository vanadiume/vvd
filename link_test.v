module main

import cli
import os
import vanadiume.vlk.elf
import vanadiume.vlk.target
import vanadiume.vlk.unit

// The frontend is checked the only way that settles a link: an image is written,
// the kernel is handed it, and the status it leaves with is read back. The inputs
// are built here as objects rather than committed, so the tree holds no fixture.

fn host() target.Target {
	return target.host() or { panic('the link tests need the host target') }
}

// exiting is a unit whose entry stops the process with a status: `mov edi, code`,
// `mov eax, 60`, `syscall`, which is x86-64 Linux's exit call written out.
fn exiting(code u8) unit.Program {
	mut part := unit.Program{}
	part.text = [u8(0xbf), code, u8(0), u8(0), u8(0), u8(0xb8), u8(60), u8(0), u8(0), u8(0), u8(0x0f),
		u8(0x05)]
	part.defined['main'] = true
	part.labels['main'] = 0
	return part
}

// function is a unit that defines a name and does nothing: a run of `nop`, so that
// a shared object has something to export.
fn function(name string) unit.Program {
	mut part := unit.Program{}
	part.text = []u8{len: 16, init: u8(0x90)}
	part.defined[name] = true
	part.labels[name] = 0
	return part
}

// calling is a unit that calls a name it does not define and then exits: `call
// name`, `mov edi, 0`, the exit call. The fixup and the import entry are both
// what make the name part of the object; a name with no reference is dropped by
// the object writer, because nothing in the object reads it.
fn calling(name string) unit.Program {
	mut part := exiting(0)
	part.text = [u8(0xe8), u8(0), u8(0), u8(0), u8(0), u8(0xbf), u8(0), u8(0), u8(0), u8(0), u8(0xb8),
		u8(60), u8(0), u8(0), u8(0), u8(0x0f), u8(0x05)]
	part.defined['main'] = true
	part.labels['main'] = 0
	part.imports << name
	part.fixups << unit.Fixup{
		start:  1
		length: 4
		kind:   .call_import
		name:   name
	}
	return part
}

fn scratch(name string) string {
	dir := os.join_path(os.temp_dir(), 'vvd_link_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	return os.join_path(dir, name)
}

fn write_object(part unit.Program, name string) string {
	path := scratch(name)
	os.write_file_array(path, elf.object(part, host()) or {
		panic('the object was not written: ${err.msg()}')
	}) or { panic(err) }
	return path
}

fn run_image(path string) int {
	os.chmod(path, 0o755) or { panic(err) }
	return os.exec([path]).exit_code
}

// The archive writer below builds an `ar` file in the test: a GNU symbol index
// first, then the member header, with the index's offsets pointing at it. The
// tree commits no binary fixture, so the container a group is checked with is
// written where the test runs.
fn ar_field(text string, width int) []u8 {
	mut field := text.bytes()
	for field.len < width {
		field << u8(` `)
	}
	return field
}

fn ar_header(name string, size int) []u8 {
	mut header := ar_field(name, 16)
	header << ar_field('0', 12)
	header << ar_field('0', 6)
	header << ar_field('0', 6)
	header << ar_field('0', 8)
	header << ar_field('${size}', 10)
	header << u8(0x60)
	header << u8(0x0a)
	return header
}

fn be32(value u32) []u8 {
	return [u8(value >> 24), u8((value >> 16) & 0xff), u8((value >> 8) & 0xff), u8(value & 0xff)]
}

fn archive_of(name string, member []u8, symbols []string) []u8 {
	mut index_size := 4 + 4 * symbols.len
	for symbol in symbols {
		index_size += symbol.len + 1
	}
	header_at := 8 + 60 + index_size + (index_size & 1)
	mut index := []u8{}
	index << be32(u32(symbols.len))
	for _ in symbols {
		index << be32(u32(header_at))
	}
	for symbol in symbols {
		index << symbol.bytes()
		index << u8(0)
	}
	mut out := '!<arch>\n'.bytes()
	out << ar_header('/', index.len)
	out << index
	if index.len & 1 == 1 {
		out << u8(0x0a)
	}
	out << ar_header('${name}/', member.len)
	out << member
	if member.len & 1 == 1 {
		out << u8(0x0a)
	}
	return out
}

// exiting_as is a unit that defines one name and stops with a status.
fn exiting_as(name string, code u8) unit.Program {
	mut part := unit.Program{}
	part.text = [u8(0xbf), code, u8(0), u8(0), u8(0), u8(0xb8), u8(60), u8(0), u8(0), u8(0), u8(0x0f),
		u8(0x05)]
	part.defined[name] = true
	part.labels[name] = 0
	return part
}

// calling_a_from_b defines `b`, calls `a`, and then stops with 9 if the call
// returned. The call is a fixup, so `a` is a name the link has to answer.
fn calling_a_from_b() unit.Program {
	mut part := exiting_as('b', 9)
	part.text = [u8(0xbf), u8(9), u8(0), u8(0), u8(0), u8(0xe8), u8(0), u8(0), u8(0), u8(0), u8(0xb8),
		u8(60), u8(0), u8(0), u8(0), u8(0x0f), u8(0x05)]
	part.imports << 'a'
	part.fixups << unit.Fixup{
		start:  6
		length: 4
		kind:   .call_import
		name:   'a'
	}
	return part
}

// A group is swept by the library, not by the frontend: the program needs `b`,
// the archive holding `a` is written before the one holding `b`, and `b` needs
// `a`. Read once each in order the earlier archive is passed first; inside the
// markers the library comes back for it. The image exits with 7, which is the
// status `a` stops with.
fn test_a_group_reaches_the_library() {
	main_path := write_object(calling('b'), 'group_main.o')
	a_path := scratch('liba.a')
	os.write_file_array(a_path, archive_of('a.o', elf.object(exiting_as('a', 7), host()) or {
		panic(err)
	}, ['a'])) or { panic(err) }
	b_path := scratch('libb.a')
	os.write_file_array(b_path, archive_of('b.o', elf.object(calling_a_from_b(), host()) or {
		panic(err)
	}, ['b'])) or { panic(err) }
	ungrouped_out := scratch('group_ungrouped')
	if _ := link(cli.parse([main_path, a_path, b_path, '-e', 'main', '-o', ungrouped_out])!) {
		assert false, 'the link answered a name from an archive it had already passed'
	} else {
		assert err.msg().contains('undefined reference')
		assert err.msg().contains('`a`')
	}
	grouped_out := scratch('grouped')
	report := link(cli.parse([main_path, '--start-group', a_path, b_path, '--end-group', '-e',
		'main', '-o', grouped_out])!) or { panic('the grouped link failed: ${err.msg()}') }
	assert report.units == 3
	assert run_image(grouped_out) == 7
}

fn test_an_object_the_frontend_links_is_an_image_that_runs() {
	out := scratch('forty_two')
	defer {
		os.rmdir_all(os.dir(out)) or {}
	}
	source := write_object(exiting(42), 'forty_two.o')
	options := cli.parse(['-e', 'main', '-o', out, source]) or { panic(err.msg()) }
	report := link(options) or { panic('the link failed: ${err.msg()}') }
	assert report.path == out
	assert report.units == 1
	assert report.pulled == 0
	assert report.bytes > 0
	assert os.is_executable(out)
	assert run_image(out) == 42
}

fn test_the_default_entry_is_what_a_start_file_defines() {
	out := scratch('starting')
	defer {
		os.rmdir_all(os.dir(out)) or {}
	}
	mut part := exiting(3)
	part.defined.delete('main')
	part.defined['_start'] = true
	part.labels['_start'] = 0
	source := write_object(part, 'starting.o')
	link(cli.parse(['-o', out, source])!)!
	assert run_image(out) == 3
}

fn test_static_writes_a_program_that_names_no_loader() {
	out := scratch('static_seven')
	defer {
		os.rmdir_all(os.dir(out)) or {}
	}
	source := write_object(exiting(7), 'static_seven.o')
	link(cli.parse(['-static', '-e', 'main', '-o', out, source])!)!
	bytes := os.read_bytes(out)!
	assert !bytes.bytestr().contains(host().interpreter)
	assert run_image(out) == 7
}

fn test_shared_writes_a_dynamic_object_and_records_its_soname() {
	out := scratch('libanswer.so.1')
	defer {
		os.rmdir_all(os.dir(out)) or {}
	}
	source := write_object(function('answer'), 'answer.o')
	report := link(cli.parse(['-shared', '--soname=libanswer.so.1', '-o', out, source])!)!
	bytes := os.read_bytes(out)!
	assert report.bytes == bytes.len
	// e_type at offset 16: ET_DYN, the shape a shared object has.
	assert bytes[16] == 3 && bytes[17] == 0
	assert bytes.bytestr().contains('libanswer.so.1')
	// A shared object is mapped rather than started, so the write gives it no
	// execute bit.
	assert !os.is_executable(out)
}

// A pie is ET_DYN like a shared object and is still started by the kernel. Its
// addresses are offsets, so a unit whose code reaches nothing by an absolute
// address needs no relocation and runs wherever the loader puts it.
fn test_pie_writes_an_image_the_kernel_places_and_runs() {
	out := scratch('pie_answer')
	defer {
		os.rmdir_all(os.dir(out)) or {}
	}
	source := write_object(exiting(37), 'pie_answer.o')
	report := link(cli.parse(['-pie', '-e', 'main', '-o', out, source])!)!
	bytes := os.read_bytes(out)!
	assert report.bytes == bytes.len
	// e_type at offset 16: ET_DYN, the shared container with an entry point.
	assert bytes[16] == 3 && bytes[17] == 0
	assert os.is_executable(out)
	assert run_image(out) == 37
}

fn test_a_named_loader_is_the_one_the_image_records() {
	out := scratch('named_loader')
	defer {
		os.rmdir_all(os.dir(out)) or {}
	}
	source := write_object(exiting(0), 'named_loader.o')
	link(cli.parse(['-e', 'main', '--dynamic-linker=/lib64/ld-vvd-test.so.1', '-o', out, source])!)!
	assert os.read_bytes(out)!.bytestr().contains('/lib64/ld-vvd-test.so.1')
}

fn test_a_shared_object_on_the_line_answers_an_import() {
	out := scratch('uses_helper')
	defer {
		os.rmdir_all(os.dir(out)) or {}
	}
	library := scratch('libhelper.so')
	os.write_file_array(library, elf.write(function('helper'), host(), .shared) or {
		panic('the shared object was not written: ${err.msg()}')
	}) or { panic(err) }
	mut part := calling('helper')
	source := write_object(part, 'uses_helper.o')
	report := link(cli.parse(['-e', 'main', '-o', out, source, library])!)!
	assert report.libraries.contains('libhelper.so')
}

fn test_a_name_no_library_defines_stops_the_run() {
	out := scratch('missing')
	defer {
		os.rmdir_all(os.dir(out)) or {}
	}
	mut part := calling('nosuchname_xyz')
	source := write_object(part, 'missing.o')
	link(cli.parse(['-e', 'main', '-o', out, source])!) or {
		assert err.msg().contains('nosuchname_xyz')
		// No file, rather than an image with a reference left at zero.
		assert !os.exists(out)
		return
	}
	assert false, 'a link accepted an import no library defines'
}

// -nostdlib names no C library in the image, so a name only the C library
// defines has no answer and the link is refused rather than written with a
// reference the loader will fail on.
fn test_no_default_library_stops_the_c_library_answering() {
	out := scratch('names_libc')
	defer {
		os.rmdir_all(os.dir(out)) or {}
	}
	source := write_object(calling('exit'), 'calls_exit.o')
	// With the default library the name is answered and the image names it.
	link(cli.parse(['-e', 'main', '-o', out, source])!)!
	assert os.read_bytes(out)!.bytestr().contains(host().base_library)
	link(cli.parse(['-nostdlib', '-e', 'main', '-o', out + '.nostdlib', source])!) or {
		assert err.msg().contains('exit')
		assert !os.exists(out + '.nostdlib')
		return
	}
	assert false, 'a name only the C library defines was linked with no default library'
}

fn test_an_emulation_for_another_machine_is_refused() {
	options := cli.parse(['-m', 'i386', 'x.o']) or { panic(err.msg()) }
	link(options) or {
		assert err.msg().contains('i386')
		return
	}
	assert false, 'a link for another machine was written'
}

fn test_a_shared_object_has_no_entry_unless_one_is_named() {
	assert entry_for(cli.parse(['-shared', 'x.o'])!, target.Format.elf) == ''
	assert entry_for(cli.parse(['x.o'])!, target.Format.elf) == '_start'
	assert entry_for(cli.parse(['-shared', '-e', 'init', 'x.o'])!, target.Format.elf) == 'init'
}

fn test_the_stats_lines_name_what_the_link_took() {
	report := Report{
		path:      'prog'
		bytes:     4096
		units:     2
		pulled:    1
		libraries: ['libc.so.6']
		micros:    120
	}
	lines := report_lines(report)
	assert lines[0] == 'output: prog'
	assert lines.contains('bytes: 4096')
	assert lines.contains('units: 2')
	assert lines.contains('pulled: 1')
	assert lines.contains('library: libc.so.6')
	assert lines.contains('microseconds: 120')
}

fn test_the_verbose_lines_keep_the_order_of_the_line() {
	options := cli.parse(['a.o', '-lm', '-L/opt/lib', '-o', 'prog', '-e', 'start'])!
	lines := verbose_lines(options)
	assert lines[0] == 'flavor: gnu'
	assert lines.contains('input: a.o')
	assert lines.contains('library: m')
	assert lines.contains('library path: /opt/lib')
	assert lines.contains('entry: start')
	assert lines.contains('output: prog')
}

// A Windows link through the frontend: `-m i386pep` is the emulation, the inputs
// are COFF objects a compiler wrote, and the image is run the way the tree runs
// every image it writes. Nothing about the objects is built by hand here, so the
// test covers the command line, the library's COFF reader, the merge and the PE
// writer in one pass.
fn test_a_windows_link_writes_an_image_that_runs() {
	clang := '/usr/bin/clang'
	if !os.exists(clang) {
		eprintln('skipping: no clang on this machine to write COFF objects with')
		return
	}
	if !os.exists('/usr/bin/wine') {
		eprintln('skipping: no wine on this machine to run a PE image with')
		return
	}
	dir := os.join_path(os.temp_dir(), 'vvd_pe_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	first := os.join_path(dir, 'add.c')
	second := os.join_path(dir, 'main.c')
	os.write_file(first, 'int add(int a, int b) { return a + b; }\n') or { panic(err) }
	os.write_file(second, 'int add(int a, int b);\nint main(void) { return add(40, 2); }\n') or {
		panic(err)
	}
	first_object := os.join_path(dir, 'add.obj')
	second_object := os.join_path(dir, 'main.obj')
	for pair in [[first, first_object], [second, second_object]] {
		result := os.exec([clang, '--target=x86_64-pc-windows-msvc', '-c', pair[0], '-o', pair[1]])
		if result.exit_code != 0 {
			eprintln('skipping: clang could not write a COFF object: ${result.output}')
			return
		}
	}
	out := os.join_path(dir, 'pe.exe')
	options := cli.parse(['-m', 'i386pep', '-o', out, first_object, second_object]) or {
		panic(err.msg())
	}
	report := link(options) or { panic('the windows link failed: ${err.msg()}') }
	assert report.units == 2
	assert report.bytes > 0
	os.setenv('WINEDEBUG', '-all', true)
	result := os.exec(['/usr/bin/wine', out])
	assert result.exit_code == 42, 'wine left with ${result.exit_code}: ${result.output}'
}

// A PE image names no loader, so a command line that asks for one is refused
// before any input is read.
fn test_a_loader_path_is_refused_for_a_windows_image() {
	options := cli.parse(['-m', 'i386pep', '--dynamic-linker', '/lib64/ld-linux-x86-64.so.2', '-o',
		scratch('pe_loader.exe'), 'nothing.obj']) or { panic(err.msg()) }
	link(options) or {
		assert err.msg().contains('-dynamic-linker')
		return
	}
	assert false, 'a PE image has no interpreter field'
}

// The emulation the frontend does not know is still refused by name, so a cross
// link to a machine vlk does not describe stops at the command line.
fn test_an_emulation_this_frontend_does_not_know_is_refused() {
	options := cli.parse(['-m', 'aarch64linux', '-o', scratch('arm.out'), 'nothing.o']) or {
		panic(err.msg())
	}
	link(options) or {
		assert err.msg().contains('aarch64linux')
		return
	}
	assert false, 'an emulation with no target behind it is refused'
}

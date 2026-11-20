module main

import cli
import time
import vanadiume.vlk
import vanadiume.vlk.input
import vanadiume.vlk.output
import vanadiume.vlk.target

// Report is what a run came to, in the terms a build system asks for: the file,
// how long it is, how many inputs the merge took, and the libraries the image
// names.
struct Report {
	path      string
	bytes     int
	units     int
	pulled    int
	libraries []string
	// micros is the wall time of the link, from the first read to the last byte
	// written. It is the frontend's own measurement and not a claim about the
	// library: the process around it is not in the number.
	micros i64
}

// link is one link as the command line asked for it. The library answers with
// the image written to the file the options name; what this function decides is
// the shape of the request, which is what a frontend is for.
fn link(options cli.Options) !Report {
	machine := machine_for(options)!
	// A loader path is a name the ELF kernel reads out of the image. A PE image
	// has no such field, so a command line that asks for one is told rather than
	// linked.
	if machine.format == .pe && options.dynamic_linker != '' {
		return error('-dynamic-linker is a path the ELF kernel reads, and a PE image names no loader')
	}
	target_for_link := if options.dynamic_linker != '' {
		loader_target(machine, options.dynamic_linker)
	} else {
		machine
	}
	kind := if options.shared {
		output.Kind.shared
	} else if options.static_link {
		output.Kind.static_program
	} else if options.pie {
		output.Kind.pie
	} else {
		output.Kind.program
	}
	container := output.Options{
		execstack:   options.execstack
		noexecstack: options.noexecstack
		bind_now:    options.bind_now
		relro:       options.relro
		soname:      options.soname
	}
	started := time.now()
	report := vlk.link_files(options.inputs, vlk.Options{
		entry:                entry_for(options, target_for_link.format)
		target:               target_for_link
		libraries:            options.libraries
		library_dirs:         options.library_dirs
		groups:               link_groups(options.groups)
		no_default_libraries: options.no_default_libraries
		output:               options.output
		kind:                 kind
		container:            container
	})!
	return Report{
		path:      report.path
		bytes:     report.bytes
		units:     report.units
		pulled:    report.pulled
		libraries: report.libraries
		micros:    (time.now() - started).microseconds()
	}
}

// link_groups is the command line's groups in the shape the library reads: the
// paths and the -l names of one run, without the marker that separated them.
// `cli` keeps the items in the order the line wrote them and knows no linker
// fact, which is why the split into two lists happens here.
fn link_groups(groups []cli.Group) []input.Group {
	mut out := []input.Group{cap: groups.len}
	for group in groups {
		mut paths := []string{}
		mut libraries := []string{}
		for item in group.items {
			if item.library {
				libraries << item.value
			} else {
				paths << item.value
			}
		}
		out << input.Group{
			paths:     paths
			libraries: libraries
		}
	}
	return out
}

// machine_for is the target the command line asked for. `-m` names an emulation,
// and the two this frontend knows are the machine it runs on and 64-bit Windows:
// `elf_x86_64` and `i386pep` are GNU ld's spellings for them. A spelling outside
// the table is refused rather than recorded, because an emulation accepted into a
// field and acted on by nothing is a link that believes it is for another system.
fn machine_for(options cli.Options) !target.Target {
	if options.emulation == 'i386pep' {
		return target.windows_x86_64()
	}
	machine := target.host() or {
		return error('vvd links for the machine it runs on, and vlk describes no target for this one')
	}
	if options.emulation != '' && options.emulation != emulation_name(machine) {
		return error('-m ${options.emulation} names another machine: this frontend links for ${emulation_name(machine)} and i386pep')
	}
	return machine
}

// entry_for is the name the image starts at. A shared object is mapped rather
// than started, so the default name is dropped for one; a name the command line
// wrote is kept, because asking for it is a decision.
fn entry_for(options cli.Options, format target.Format) string {
	if options.shared && !options.entry_given {
		return ''
	}
	// A PE program's start is not the C library's `_start`; a compiler that
	// targets Windows writes `main`, and a command line that writes no entry
	// gets that name rather than one no Windows object defines.
	if format == .pe && !options.entry_given {
		return 'main'
	}
	return options.entry
}

// emulation_name is the -m spelling for a target. The emulation names are GNU
// ld's, and the frontend knows the x86-64 one because that is the machine vlk
// describes today; a second machine adds its own row here.
fn emulation_name(machine target.Target) string {
	if machine.elf_machine == 62 {
		return 'elf_x86_64'
	}
	return machine.name
}

// loader_target is the host target with another loader named in it. The fields
// are copied because a Target's are values a caller fills and does not rewrite:
// this is a second value, not an edit of the library's answer. A field the
// library adds later arrives here as its zero value, and the gate's end-to-end
// link is the test that would fail if it mattered.
fn loader_target(machine target.Target, loader string) target.Target {
	return target.Target{
		name:                       machine.name
		word_size:                  machine.word_size
		elf_machine:                machine.elf_machine
		page_size:                  machine.page_size
		load_base:                  machine.load_base
		interpreter:                loader
		base_library:               machine.base_library
		library_dirs:               machine.library_dirs
		registers:                  machine.registers
		float_registers:            machine.float_registers
		relocation_call:            machine.relocation_call
		relocation_pc_relative:     machine.relocation_pc_relative
		relocation_got_pc_relative: machine.relocation_got_pc_relative
		encoders:                   machine.encoders
	}
}

// requested_format is the container the command line asked for, which is what
// decides the default entry name before a target exists.
fn requested_format(options cli.Options) target.Format {
	return if options.emulation == 'i386pep' { target.Format.pe } else { target.Format.elf }
}

// verbose_lines is what --verbose prints before the link: the request, in the
// order the command line wrote it. It is on stderr so that it cannot be mistaken
// for what the run wrote.
fn verbose_lines(options cli.Options) []string {
	mut lines := ['flavor: ${options.flavor}', 'output: ${options.output}',
		'entry: ${entry_for(options, requested_format(options))}']
	for item in options.link_items {
		if item.library {
			lines << 'library: ${item.value}'
		} else {
			lines << 'input: ${item.value}'
		}
	}
	for dir in options.library_dirs {
		lines << 'library path: ${dir}'
	}
	return lines
}

// report_lines is what --stats prints: one fact per line, so a build can read one
// without parsing a sentence.
fn report_lines(report Report) []string {
	mut lines := ['output: ${report.path}', 'bytes: ${report.bytes}', 'units: ${report.units}',
		'pulled: ${report.pulled}', 'microseconds: ${report.micros}']
	for library in report.libraries {
		lines << 'library: ${library}'
	}
	return lines
}

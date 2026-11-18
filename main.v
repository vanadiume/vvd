module main

import cli
import os

// vvd is the command line frontend over vlk: it reads a link's flags the way a
// GNU linker reads them, asks the library for the image, and reports what the
// link came to. Everything a link is, is in the library; what is here is the
// command line and the exit status.
fn main() {
	options := cli.parse(os.args[1..]) or {
		eprintln('${program_name()}: error: ${err.msg()}')
		exit(1)
	}
	// A question is answered instead of a link, and no input file is needed for
	// one: a build tool asks before it has anything to link.
	if options.show_help {
		println(cli.usage())
		return
	}
	if options.show_version {
		println(cli.version_line())
		return
	}
	if options.verbose {
		for line in verbose_lines(options) {
			eprintln(line)
		}
	}
	report := link(options) or {
		eprintln('${program_name()}: error: ${err.msg()}')
		exit(1)
	}
	// The build asked for the run's numbers, so it gets them on stdout where it
	// can read them without parsing a sentence.
	if options.stats {
		for line in report_lines(report) {
			println(line)
		}
	}
}

// program_name is what the run calls itself in a diagnostic: the name it was
// started under, the way ld.lld reports the name it was invoked by. A copy
// installed as `ld.vvd` therefore reports that name and not this one.
fn program_name() string {
	return os.file_name(os.args[0])
}

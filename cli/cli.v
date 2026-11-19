module cli

import os
import v.vmod

// version is this frontend's own version, the one v.mod names. The manifest is
// the single source: its text is embedded when the frontend is compiled, so a
// binary copied somewhere without its source still answers, and a release tag
// cannot disagree with what --version prints.
pub const version = vmod_version()

fn vmod_version() string {
	manifest := vmod.decode(@VMOD_FILE) or { panic('v.mod is not readable: ${err}') }
	if manifest.version == '' {
		panic('v.mod names no version')
	}
	return manifest.version
}

// The defaults a command line starts from, named once so that the usage text and
// the parser cannot describe different links.
pub const default_output = 'a.out'
pub const default_entry = '_start'
pub const default_flavor = 'gnu'

// The number of response files one command line may nest inside another. A file
// that names itself would otherwise be read until the path is too long to be a
// file, so the loop is answered rather than followed.
const response_depth = 8

pub fn version_line() string {
	return 'vvd ${version}'
}

// Item is one word of a link in the place the command line wrote it: an input
// path, or a -l name. The two lists beside it cannot say this between
// themselves, and --verbose reports the line in the order it was written.
//
// The link itself takes the paths and the names as two lists, and vlk resolves
// the names after every path. A library written before the object that needs it
// is therefore still searched, which is a difference from GNU ld that belongs to
// the library and not to this frontend.
pub struct Item {
pub:
	value   string
	library bool
}

// Group is one run of inputs the command line wrapped in --start-group and
// --end-group. The library sweeps every archive in a group again while a sweep
// pulls a member, so two libraries that answer each other's names are both read.
// Outside the markers an archive is swept once, in the order it was written.
pub struct Group {
pub:
	// items are the paths and -l names inside the markers, in the order the
	// command line wrote them.
	items []Item
}

// Options is the command line after it has been read, in the terms a link uses.
// A flag this frontend implements fills a field here; a flag it does not is
// refused where it is read, so nothing in this struct is a hope that something
// else applies it.
pub struct Options {
pub mut:
	// inputs are the paths of the link's inputs, in the order they were written:
	// relocatable objects, `ar` archives, and shared objects.
	inputs []string
	// libraries are the -l names, in order and as they were written: `m` for
	// `-lm`, because that is the name the search takes.
	libraries []string
	// library_dirs are the -L directories, in order. They are searched before the
	// target's own directories, which the link adds itself.
	library_dirs []string
	// link_items is the same command line as one list, in order, for a report.
	link_items []Item
	// groups are the runs of inputs wrapped in --start-group and --end-group, in
	// the order the markers appeared. Their items are not in inputs or
	// libraries: the group is where they sit, and reading them twice would put
	// every member in the image twice.
	groups []Group
	// output is the file the image is written to, `a.out` unless -o says
	// otherwise.
	output string
	// entry is the name the image starts at, `_start` unless -e says otherwise.
	entry string
	// entry_given says -e was written, because a shared object has no entry and
	// the default is dropped for one while a name the caller wrote is kept.
	entry_given bool
	// shared is -shared: the file is a shared object another program loads rather
	// than a program the kernel starts.
	shared bool
	// static_link is -static: every library is resolved into the file, which then
	// names no loader and no library.
	static_link bool
	// no_default_libraries is -nostdlib or -nodefaultlibs: the image names no C
	// library, and an import nothing in the link answers is left to the loader
	// instead of being refused.
	no_default_libraries bool
	// soname is the name a shared object records as its own, written by --soname
	// or -h. Empty records none.
	soname string
	// execstack and noexecstack are -z execstack and -z noexecstack: the stack's
	// execute permission. The last of the two written wins, because a command line
	// that says both means the second one.
	execstack   bool
	noexecstack bool
	// bind_now is -z now: every imported name is resolved before the first
	// instruction runs.
	bind_now bool
	// relro is -z relro, and -z norelro turns it off again: the image carries a
	// PT_GNU_RELRO segment over the tables the loader writes and nothing writes
	// again.
	relro bool
	// no_undefined is -z defs or --no-undefined. The link refuses every name no
	// library answers whether the flag is written or not, so the flag states the
	// behaviour rather than changing it; -z undefs asks for the opposite and is
	// refused.
	no_undefined bool
	// dynamic_linker is --dynamic-linker: the loader path the image names in place
	// of the target's own.
	dynamic_linker string
	// emulation is the -m value as it was written, e.g. `elf_x86_64`. Only the one
	// spelling this frontend can honor is accepted, and whether the machine
	// matches is asked where the target is known.
	emulation string
	// flavor is the driver the command line named, `gnu`. vvd has one driver, and
	// the flag is here so that a build that writes `lld -flavor gnu` can point at
	// this binary instead.
	flavor string
	// stats is --stats: print what the link took, after it is written.
	stats bool
	// verbose is --verbose: print what the run is about to do, on stderr.
	verbose bool
	// show_help and show_version are questions rather than links: they answer and
	// stop, so neither needs an input file.
	show_help    bool
	show_version bool
}

// Cursor walks the arguments. It exists because V has no mutable scalar
// parameters, and a flag that takes a value has to move the reader past it.
struct Cursor {
mut:
	args []string
	pos  int
}

fn (c Cursor) at_end() bool {
	return c.pos >= c.args.len
}

fn (mut c Cursor) next() string {
	arg := c.args[c.pos]
	c.pos++
	return arg
}

// value_of answers the value of a flag, whether it was written joined to the
// flag or as the next word: `-oprogram` and `-o program` mean the same thing to
// every linker, and `--output=program` is the long spelling of the same request.
// The cursor has already moved past the flag when this is called.
fn (mut c Cursor) value_of(spelling string, joined string) !string {
	if joined != '' {
		return joined
	}
	if c.at_end() {
		return error('${spelling} needs a value')
	}
	return c.next()
}

// parse reads a command line in the shape ld.lld reads one: GNU ld's spellings,
// because that is the command line a linker in this slot is handed.
pub fn parse(args []string) !Options {
	expanded := expand_response_files(args, 0)!
	mut opts := Options{
		output: default_output
		entry:  default_entry
		flavor: default_flavor
	}
	mut positional := []string{}
	mut items := []Item{}
	// A --start-group ... --end-group run is followed as it is read: its items
	// are kept together and its -l names stay out of the top-level library list,
	// because the group is where they sit on the command line.
	mut groups := []Group{}
	mut group_items := []Item{}
	mut in_group := false
	mut end_of_flags := false
	mut cursor := Cursor{
		args: expanded
	}
	for !cursor.at_end() {
		arg := cursor.next()
		if end_of_flags || arg == '-' || !arg.starts_with('-') {
			if in_group {
				group_items << Item{
					value: arg
				}
			} else {
				positional << arg
			}
			items << Item{
				value: arg
			}
			continue
		}
		if arg == '--' {
			end_of_flags = true
			continue
		}
		// A flag this frontend knows and does not implement is refused before
		// anything else reads it, so its value never becomes an input and the
		// message names the option rather than a file that is not one.
		if refusal := refused(arg) {
			return error(refusal)
		}
		if arg == '--help' || arg == '-help' {
			opts.show_help = true
		} else if arg == '--version' || arg == '-V' || arg == '-v' {
			opts.show_version = true
		} else if arg == '--stats' {
			opts.stats = true
		} else if arg == '--verbose' {
			opts.verbose = true
		} else if arg == '--start-group' || arg == '-(' {
			if in_group {
				return error('--start-group inside a group: the two markers do not nest')
			}
			in_group = true
			group_items = []
		} else if arg == '--end-group' || arg == '-)' {
			if !in_group {
				return error('--end-group without --start-group')
			}
			groups << Group{
				items: group_items
			}
			group_items = []
			in_group = false
		} else if arg == '-shared' || arg == '--shared' || arg == '-Bshareable' {
			opts.shared = true
		} else if arg == '-static' || arg == '--static' {
			opts.static_link = true
		} else if arg == '-nostdlib' || arg == '--nostdlib' || arg == '-nodefaultlibs'
			|| arg == '--nodefaultlibs' {
			opts.no_default_libraries = true
		} else if arg == '--no-undefined' || arg == '-zdefs' {
			opts.no_undefined = true
		} else if arg == '-no-pie' {
			// The image is placed at a fixed load base, so the flag states what
			// the link already does. -pie asks for the other shape and is
			// refused, because no pass here writes a position-independent image.
			continue
		} else if arg == '-s' || arg == '-S' || arg == '--strip-all' || arg == '--strip-debug' {
			// The image carries no static symbol table and no debug information,
			// so the strip flags state the write that already happens.
			continue
		} else if arg == '-nostartfiles' || arg == '--nostartfiles' {
			// No start files are added to a link here: the inputs are the link,
			// which is what this flag asks for.
			continue
		} else if arg == '--eh-frame-hdr' {
			// The image writes a .eh_frame_hdr built from the units' function
			// ranges, which is the table the flag asks for.
			continue
		} else if arg == '-o' {
			opts.output = cursor.value_of('-o', '')!
		} else if arg.starts_with('-o') {
			opts.output = cursor.value_of('-o', arg[2..])!
		} else if arg == '--output' {
			opts.output = cursor.value_of('--output', '')!
		} else if arg.starts_with('--output=') {
			opts.output = cursor.value_of('--output', arg['--output='.len..])!
		} else if arg == '-e' {
			opts.entry = cursor.value_of('-e', '')!
			opts.entry_given = true
		} else if arg.starts_with('-e') {
			opts.entry = cursor.value_of('-e', arg[2..])!
			opts.entry_given = true
		} else if arg == '--entry' {
			opts.entry = cursor.value_of('--entry', '')!
			opts.entry_given = true
		} else if arg.starts_with('--entry=') {
			opts.entry = cursor.value_of('--entry', arg['--entry='.len..])!
			opts.entry_given = true
		} else if arg == '-l' {
			name := cursor.value_of('-l', '')!
			items << Item{
				value:   name
				library: true
			}
			if in_group {
				group_items << Item{
					value:   name
					library: true
				}
			} else {
				opts.libraries << name
			}
		} else if arg.starts_with('-l') {
			name := cursor.value_of('-l', arg[2..])!
			items << Item{
				value:   name
				library: true
			}
			if in_group {
				group_items << Item{
					value:   name
					library: true
				}
			} else {
				opts.libraries << name
			}
		} else if arg == '--library' {
			name := cursor.value_of('--library', '')!
			items << Item{
				value:   name
				library: true
			}
			if in_group {
				group_items << Item{
					value:   name
					library: true
				}
			} else {
				opts.libraries << name
			}
		} else if arg.starts_with('--library=') {
			name := cursor.value_of('--library', arg['--library='.len..])!
			items << Item{
				value:   name
				library: true
			}
			if in_group {
				group_items << Item{
					value:   name
					library: true
				}
			} else {
				opts.libraries << name
			}
		} else if arg == '-L' {
			opts.library_dirs << cursor.value_of('-L', '')!
		} else if arg.starts_with('-L') {
			opts.library_dirs << cursor.value_of('-L', arg[2..])!
		} else if arg == '--library-path' {
			opts.library_dirs << cursor.value_of('--library-path', '')!
		} else if arg.starts_with('--library-path=') {
			opts.library_dirs << cursor.value_of('--library-path', arg['--library-path='.len..])!
		} else if arg == '-soname' || arg == '-h' || arg == '--soname' {
			opts.soname = cursor.value_of(arg, '')!
		} else if arg.starts_with('-soname=') {
			opts.soname = cursor.value_of('-soname', arg['-soname='.len..])!
		} else if arg.starts_with('--soname=') {
			opts.soname = cursor.value_of('--soname', arg['--soname='.len..])!
		} else if arg == '-z' {
			apply_z(mut opts, cursor.value_of('-z', '')!)!
		} else if arg.starts_with('-z') {
			apply_z(mut opts, arg[2..])!
		} else if arg == '--dynamic-linker' {
			opts.dynamic_linker = cursor.value_of('--dynamic-linker', '')!
		} else if arg.starts_with('--dynamic-linker=') {
			opts.dynamic_linker = cursor.value_of('--dynamic-linker', arg['--dynamic-linker='.len..])!
		} else if arg == '-m' {
			opts.emulation = cursor.value_of('-m', '')!
		} else if arg.starts_with('-m') {
			opts.emulation = cursor.value_of('-m', arg[2..])!
		} else if arg == '--emulation' {
			opts.emulation = cursor.value_of('--emulation', '')!
		} else if arg.starts_with('--emulation=') {
			opts.emulation = cursor.value_of('--emulation', arg['--emulation='.len..])!
		} else if arg == '-flavor' || arg == '--flavor' {
			opts.flavor = flavor_name(cursor.value_of('-flavor', '')!)!
		} else if arg.starts_with('-flavor=') {
			opts.flavor = flavor_name(arg['-flavor='.len..])!
		} else if arg.starts_with('--flavor=') {
			opts.flavor = flavor_name(arg['--flavor='.len..])!
		} else {
			return error('unknown argument: ${arg}')
		}
	}
	opts.inputs = positional
	opts.link_items = items
	if in_group {
		return error('--start-group without --end-group: the markers close the run of inputs they wrap')
	}
	opts.groups = groups
	// The pairs are judged once the whole line has been read, so a line that
	// carries both of a pair is told about the pair rather than about whichever
	// flag came first.
	if opts.shared && opts.static_link {
		return error('-shared and -static are two different files: one is loaded by another program and one is started by the kernel')
	}
	if opts.soname != '' && !opts.shared {
		return error('--soname names a shared object, and this line writes a program')
	}
	if opts.dynamic_linker != '' && opts.static_link {
		return error('--dynamic-linker names the program that loads the image, and -static writes an image with no loader')
	}
	if opts.dynamic_linker != '' && opts.shared {
		return error('--dynamic-linker names the loader of a program, and a shared object is mapped rather than started')
	}
	if !opts.show_help && !opts.show_version && opts.inputs.len == 0 && opts.libraries.len == 0
		&& opts.groups.len == 0 {
		return error('no input files')
	}
	return opts
}

// apply_z reads one -z keyword. The ones this frontend implements are the ones
// vlk can put in an image; the rest are refused with the list, because a -z
// keyword dropped in silence is a promise to a loader that the image does not
// keep.
fn apply_z(mut opts Options, keyword string) ! {
	match keyword {
		'now' {
			opts.bind_now = true
		}
		'relro' {
			opts.relro = true
		}
		'norelro' {
			opts.relro = false
		}
		'execstack' {
			opts.execstack = true
			opts.noexecstack = false
		}
		'noexecstack' {
			opts.noexecstack = true
			opts.execstack = false
		}
		'defs' {
			// The link already refuses every name no library answers, so the
			// keyword states the behaviour. -z undefs asks for the other one.
			opts.no_undefined = true
		}
		'undefs' {
			return error('-z undefs asks for an image with names left unresolved, and this link refuses every name no library answers')
		}
		else {
			return error('-z ${keyword}: vvd implements now, relro, norelro, execstack, noexecstack and defs')
		}
	}
}

// flavor_name reads the driver a -flavor flag names. vvd has one driver, so a
// second name is a refusal rather than a dispatch that does nothing.
fn flavor_name(name string) !string {
	if name == default_flavor {
		return name
	}
	return error('-flavor ${name}: vvd has one driver, ${default_flavor}, which reads the command line a GNU linker is given')
}

// Refusal is a group of spellings this frontend reads and does not implement,
// with the reason the group shares. A spelling that ends with `=` matches the
// value written joined to it as well: `--sysroot=/x` and `--sysroot /x` are both
// refused, and the second one is refused on its own flag.
struct Refusal {
	spellings []string
	reason    string
}

const refusals = [
	Refusal{
		spellings: ['-r', '-i', '--relocatable', '--emit-relocs']
		reason:    'vvd writes a program or a shared object, and no relocatable file'
	},
	Refusal{
		spellings: ['-pie', '--pic-executable', '--pic']
		reason:    'the image is placed at a fixed load base, and a position-independent program is not written'
	},
	Refusal{
		spellings: ['-T', '--script', '--default-script', '--version-script=', '--dynamic-list=']
		reason:    'vvd places the sections itself and reads no linker script'
	},
	Refusal{
		spellings: ['-M', '--print-map', '-Map', '-Map=']
		reason:    'vvd prints what the link took with --stats and writes no map file'
	},
	Refusal{
		spellings: ['--gc-sections', '--no-gc-sections', '--icf', '--no-icf', '--icf=',
			'--print-gc-sections']
		reason:    "nothing in the image is dropped or folded yet, which is the library's 0.2.0 work"
	},
	Refusal{
		spellings: ['--whole-archive', '--no-whole-archive']
		reason:    'an archive gives up the members that answer a name nothing defines, and reading every member is not implemented'
	},
	Refusal{
		spellings: ['--as-needed', '--no-as-needed']
		reason:    'every library named is recorded as needed, and an as-needed mode is not implemented'
	},
	Refusal{
		spellings: ['--build-id', '--build-id=']
		reason:    'the image records no build-id note'
	},
	Refusal{
		spellings: ['--hash-style=']
		reason:    'the image writes a SysV hash table, which is what --hash-style=sysv names; gnu and both are not written'
	},
	Refusal{
		spellings: ['--threads=']
		reason:    'the link runs on one thread'
	},
	Refusal{
		spellings: ['--sysroot', '--sysroot=']
		reason:    'the -L search uses the directories as written, and a sysroot is not implemented'
	},
	Refusal{
		spellings: ['-N', '--omagic', '-n', '--nmagic']
		reason:    'the layout fixes the segment alignment, and the page size comes from the target'
	},
	Refusal{
		spellings: ['-Xlinker', '--push-state', '--pop-state']
		reason:    'vvd is the linker, so the option a wrapper would pass on can be written directly'
	},
	Refusal{
		spellings: ['--allow-shlib-undefined', '--no-allow-shlib-undefined']
		reason:    'every name left to the loader is checked against the libraries, and a link that allows one is not written'
	},
]

// refused answers with the option and the reason when the argument names
// something a GNU ld command line carries and this frontend does not implement.
fn refused(arg string) ?string {
	for group in refusals {
		for spelling in group.spellings {
			if arg == spelling || (spelling.ends_with('=') && arg.starts_with(spelling)) {
				return '${arg}: ${group.reason}'
			}
		}
	}
	return none
}

// expand_response_files splices each @file argument where it stands, and follows
// an @file inside one to the depth a command line is allowed to nest.
fn expand_response_files(args []string, depth int) ![]string {
	mut out := []string{}
	for arg in args {
		if !arg.starts_with('@') || arg.len == 1 {
			out << arg
			continue
		}
		path := arg[1..]
		if depth >= response_depth {
			return error('response files are nested more than ${response_depth} deep: ${path}')
		}
		text := os.read_file(path) or { return error('cannot read the response file ${path}: ${err}') }
		words := response_words(text) or { return error('${path}: ${err.msg()}') }
		nested := expand_response_files(words, depth + 1)!
		out << nested
	}
	return out
}

// response_words splits a response file into the words a command line would hold.
// Whitespace separates words, a word may be quoted with '...' or "..." so that a
// path can carry a space, and a backslash makes the next byte part of the word in
// either kind of quoting except the single one, the way a shell reads one.
fn response_words(text string) ![]string {
	mut words := []string{}
	mut word := []u8{}
	mut quote := u8(0)
	mut i := 0
	for i < text.len {
		c := text[i]
		if quote == 0 && (c == ` ` || c == `\t` || c == `\n` || c == `\r`) {
			if word.len > 0 {
				words << word.bytestr()
				word.clear()
			}
			i++
			continue
		}
		if c == `\\` && quote != `'` && i + 1 < text.len {
			word << text[i + 1]
			i += 2
			continue
		}
		if quote == 0 && (c == `"` || c == `'`) {
			quote = c
			i++
			continue
		}
		if quote != 0 && c == quote {
			quote = 0
			i++
			continue
		}
		word << c
		i++
	}
	if quote != 0 {
		return error('a quoted word is not closed')
	}
	if word.len > 0 {
		words << word.bytestr()
	}
	return words
}

// usage is what --help prints: the flag surface, in the shape ld.lld prints one,
// with the flags this frontend refuses named at the end so that a reader does not
// discover them one build at a time.
pub fn usage() string {
	mut lines := []string{}
	lines << 'OVERVIEW: vvd, the command line frontend over the vlk linker library'
	lines << ''
	lines << 'USAGE: vvd [options] file...'
	lines << ''
	lines << 'The inputs are relocatable object files, `ar` archives, and shared objects.'
	lines << 'The image is an ELF program or a shared object for the machine vvd runs on.'
	lines << ''
	lines << 'OPTIONS:'
	lines << '  -o <file>, --output=<file>         Write the image to <file> (default: a.out)'
	lines << '  -e <sym>, --entry=<sym>            Start the program at <sym> (default: _start)'
	lines << '  -l <name>, --library=<name>        Search for a library named <name>'
	lines << '  -L <dir>, --library-path=<dir>     Add <dir> to the library search path'
	lines << '  -shared, --shared                  Write a shared object rather than a program'
	lines << '  -static, --static                 Resolve every library into the file'
	lines << '  -nostdlib, -nodefaultlibs          Name no default library in the image'
	lines << "  --soname=<name>, -h <name>         Record <name> as the shared object's own"
	lines << '  -z now                             Bind every imported name before the first'
	lines << '                                     instruction runs'
	lines << '  -z relro | norelro                 Carry a PT_GNU_RELRO segment, or not'
	lines << "  -z execstack | noexecstack         Set the stack's execute permission"
	lines << '  -z defs, --no-undefined            Refuse every name no library answers, which'
	lines << '                                     is what the link already does'
	lines << '  --dynamic-linker=<path>            Name <path> as the loader instead of the'
	lines << "                                     target's own"
	lines << '  -m <emulation>                     The machine: elf_x86_64 only'
	lines << '  -flavor <flavor>                   The driver: gnu only'
	lines << '  --start-group, --end-group         Search the archives between the markers'
	lines << '                                     again while a search pulls a member'
	lines << '  -s, -S, --strip-all, --strip-debug Accepted: the image carries no static symbol'
	lines << '                                     table and no debug information'
	lines << '  --stats                            Print what the link took, after it is written'
	lines << '  --verbose                          Print what the run is about to do, on stderr'
	lines << "  -V, --version, -v                  Print vvd's version and stop"
	lines << '  --help, -help                      Print this message and stop'
	lines << ''
	lines << 'A response file is @file, and its words may be quoted so that a path can'
	lines << 'carry a space. A word after -- is an input, even when it starts with a dash.'
	lines << ''
	lines << 'Flags a GNU ld command line carries that this frontend does not implement are'
	lines << 'refused by name rather than dropped: -r, -pie, -T, -M, --gc-sections,'
	lines << '--whole-archive, --as-needed, --build-id, --hash-style,'
	lines << '--threads, --sysroot, -N, -Xlinker and --allow-shlib-undefined.'
	return lines.join('\n')
}

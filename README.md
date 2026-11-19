# vvd

VVD is the command line frontend over [vlk](https://github.com/vanadiume/vlk):
it reads a link the way a GNU linker reads one, asks the library for the image,
and writes it. The flags follow `ld.lld`'s spelling, because a build that already
writes a command line for `ld.lld` should be able to point at this binary instead.

The split is the point of the project. vlk holds every decision a link makes: the
names, the layout, the references, the container. This tree holds the flag
surface, the request the library is handed, and the exit status. A frontend that
starts deciding what a link means has taken work back out of the library.

## Building

```sh
v -gc none -o vvd .
./vvd --help
```

The frontend imports vlk as `vanadiume.vlk`. Install the library with
`v install vanadiume.vlk`, or work against a checkout with a link, the way vlk's
own README describes:

```sh
ln -sfn ~/vanadium/vlk ~/.vmodules/vanadiume/vlk
```

## Using it

```sh
vvd -o prog start.o main.o -lc
vvd -shared --soname=libhelper.so.1 -o libhelper.so helper.o
vvd --stats -e _start -o prog a.o libb.a -L/opt/lib -lm
```

`--stats` prints what the link took, one fact per line, on stdout:

```
output: prog
bytes: 4096
units: 3
pulled: 1
microseconds: 2711
library: libc.so.6
```

## The flag surface

| Flag | What it asks for |
|---|---|
| `-o <file>`, `--output=<file>`, `-o<file>` | where the image goes, `a.out` when none is written |
| `-e <sym>`, `--entry=<sym>` | the name the image starts at, `_start` by default |
| `-l <name>`, `--library=<name>`, `-l<name>` | a library the search resolves |
| `-L <dir>`, `--library-path=<dir>`, `-L<dir>` | a directory the `-l` search reads before the target's own |
| `-shared`, `--shared`, `-Bshareable` | a shared object rather than a program |
| `-static`, `--static` | every library resolved into the file, with no loader in the image |
| `-nostdlib`, `-nodefaultlibs` | no C library is named in the image, so nothing outside the link answers an import |
| `--soname=<name>`, `-soname <name>`, `-h <name>` | the name a shared object records as its own |
| `-z now` | bind every imported name before the first instruction runs |
| `-z relro`, `-z norelro` | carry a `PT_GNU_RELRO` segment, or not |
| `-z execstack`, `-z noexecstack` | the stack's execute permission; the last of the two written wins |
| `-z defs`, `--no-undefined` | refuse every name no library answers, which is what the link already does |
| `--dynamic-linker=<path>` | the loader path the image names, in place of the target's own |
| `-m <emulation>`, `--emulation=` | the machine; `elf_x86_64` is the one spelling, and another one is refused where the target is known |
| `-flavor <flavor>`, `--flavor=` | the driver; `gnu` is the one this frontend has |
| `--start-group`, `--end-group`, `-(`, `-)` | search the archives between the markers again while a search pulls a member |
| `--stats` | the report above, after the image is written |
| `--verbose` | what the run is about to do, on stderr |
| `-V`, `--version`, `-v` | the frontend's version, and stop |
| `--help`, `-help` | the flag surface, and stop |
| `-s`, `-S`, `--strip-all`, `--strip-debug` | accepted: the image carries no static symbol table and no debug information |
| `--eh-frame-hdr` | accepted: the image writes the table from the units' function ranges |
| `-no-pie`, `-nostartfiles` | accepted: the image is placed at a fixed base and no start file is added |

`-h` is the shared object's name, the way GNU ld spells it. The help is
`--help` and `-help`, so a build that writes `-h` for help gets the refusal that
says it needs a value.

A word after `--` is an input even when it starts with a dash. An argument of the
form `@file` reads words from a file, and a word in one may be quoted with `...`
or `"..."` so that a path can carry a space. Response files nest, to eight deep,
and a file that names itself is refused.

The binary reports the name it was started under, the way ld.lld does, so an
install can call it `ld.vvd`, `vvd`, or any other name and the diagnostics follow.

## What it refuses

A flag this frontend cannot honor is refused by name, with the reason, at the
point it is read. It is never accepted into a list and dropped: a build told
nothing by a flag believes something happened that did not.

| Flag | Why |
|---|---|
| `-r`, `-i`, `--relocatable`, `--emit-relocs` | the image is a program or a shared object; no relocatable file is written |
| `-pie`, `--pic-executable`, `--pic` | the image is placed at a fixed load base; nothing here writes a position-independent program |
| `-T`, `--script`, `--default-script`, `--version-script=`, `--dynamic-list=` | vlk places the sections itself and reads no linker script |
| `-M`, `--print-map`, `-Map` | `--stats` reports what the link took; no map file is written |
| `--gc-sections`, `--icf`, `--print-gc-sections` | nothing is dropped or folded yet |
| `--whole-archive`, `--no-whole-archive` | an archive gives up the members that answer a name nothing defines; reading every member is not implemented |
| `--as-needed`, `--no-as-needed` | every library named is recorded as needed |
| `--build-id` | the image records no build-id note |
| `--hash-style=` | the image writes a SysV hash table, which is `--hash-style=sysv` |
| `--threads=` | the link runs on one thread |
| `--sysroot`, `--sysroot=` | the `-L` search uses the directories as written |
| `-N`, `--omagic`, `-n`, `--nmagic` | the layout fixes the segment alignment and the page size comes from the target |
| `-Xlinker`, `--push-state`, `--pop-state` | vvd is the linker, so the wrapped option can be written directly |
| `--allow-shlib-undefined`, `--no-allow-shlib-undefined` | every name left to the loader is checked against the libraries |

A flag nothing knows is an unknown argument, which is also a refusal.

## Order, and where it differs from GNU ld

vlk resolves the `-l` names after every path on the line. A library written
before the object that needs it is still searched, which GNU ld would not do
without a group. The order the names were written in is kept for the report and
for the order the image records them, and the frontend does not pretend to a
search order the library does not have.

## What it links

One container and one machine: ELF for x86-64 Linux, because that is what vlk
describes today. A second machine, a second container, or a shared object an
object file reaches through the global offset table are the library's work before
they can be this frontend's flags.

## Verification

```sh
v test .                 # the suite
v -gc none test .        # the same with no collector, which is how a consumer is built
v run tools/gate.vsh     # formatting, pure V, build, both suites, links in the documents
```

The suite writes the objects it links rather than committing them, links them
through the frontend's own `link` function, and runs the images: the exit status
the kernel hands back is part of what says a link worked. A shared link is checked
by reading `e_type` out of the file, a named loader and a soname by reading the
string back out of it, and a refused link by checking that no file was written.

## Related

- [vlk](https://github.com/vanadiume/vlk) is the library this frontend drives.
- [vcc](https://github.com/vanadiume/vcc) is the C compiler that links through
  the same library.
- [libvcc](https://github.com/vanadiume/libvcc) is vcc's runtime library.

## Licence

BSD 3-Clause. See [LICENSE](LICENSE).

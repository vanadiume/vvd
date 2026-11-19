# Changelog

Changes a user of the frontend can see. The tree follows Semantic Versioning, and
a version number moves when a released tag does.

## Unreleased

### Added

- The repository: the manifest `vpm` reads, the licence, and the documents that
  say what the frontend is, what it refuses, and how a change is checked.
- `cli/`: the flag surface in `ld.lld`'s spelling. `-o`, `-e`, `-l`, `-L`,
  `-shared`, `-pie`, `-static`, `-nostdlib`, `-soname`, `-z` (now, relro,
  norelro, execstack, noexecstack, defs), `--dynamic-linker`, `-m`, `-flavor`,
  `--stats`, `--verbose`, `--version` and `--help`, with the joined and long
  spellings of the ones that take a value.
- `-pie` and `--pic-executable`: a position-independent executable, a program
  the kernel starts and the loader may place anywhere. `-no-pie` asks for the
  fixed-base program again, and the flag is refused with `-shared` and
  `-static` because those are different files. `-static-pie` is refused by
  name: vlk writes a pie that names a loader.
- Response files: `@file` is spliced where it stands, a word in one may be quoted
  so that a path can carry a space, and nesting is followed eight deep.
- The refusal table: a GNU ld flag this frontend does not implement answers with
  its name and its reason rather than being dropped, and `--help` names the
  groups at the end.
- `link.v`: the command line as a `vlk.Options`, with the entry a shared object
  does not have, the container options, and a loader the line may name.
- `--stats`: the file, its length, how many units the merge took, how many came
  out of an archive, the libraries the image names, and the wall time of the
  link.
- The suite writes the objects it links and runs the images it writes: an object
  the frontend links exits with the status its code asks for, a static link names
  no loader, a shared link is `ET_DYN` and carries the soname it was given, a
  shared object on the line answers an import, and a name no library defines
  leaves no file behind.
- `tools/gate.vsh`: formatting, the pure-V rule, a build that answers `--version`
  and `--help`, the suite with and without a garbage collector, and the relative
  links in the documents, in one command.

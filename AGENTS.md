# AGENTS.md

Instructions for coding agents working in this repository. They are the rules a
person follows, written where a tool will read it.

## What this repository is

vvd is the command line frontend over the vlk linker library. A link is the
library's work: the names, the layout, the references, the container, the bytes.
This tree reads a command line, builds the request vlk takes, and reports what
came back. The command line follows `ld.lld`'s spelling, so a build written for
`ld.lld` can point at this binary.

A frontend, not a linker. A change that decides what a link means belongs in
`vlk`, and a change here that has to ask the library a question it cannot answer
is a change to the wrong tree. The library is at `github.com/vanadiume/vlk`, and
the copy vcc links through is the one that changes first.

## The three constraints

1. **Pure V.** No C source, no `#include`, no `#flag`, no `C.`, and no outside
   linker invoked to do the work. The tests write the objects they link, so the
   tree commits no binary fixture.

2. **A flag works or is refused, and there is no third answer.** A flag this
   frontend implements fills a field of `cli.Options` and reaches the library. A
   flag it does not is refused where it is read, by name, with the reason. A flag
   accepted into a list and acted on by nothing is the one bug this tree exists
   not to have: the build is told nothing and believes the option landed. The
   `refusals` table in `cli/cli.v` is that rule made explicit, and a flag
   implemented later comes out of it in the same commit.

3. **An error is part of the interface.** A refusal names the option or the input
   and says why. A link that fails writes no file, because an image with a
   reference left at zero is the worst outcome available.

The library uses no garbage collector, and a consumer may be built with
`-gc none`. Nothing here may depend on a collection running either, and the gate
runs the suite both ways.

## Commands

```sh
v -gc none -o vvd .        # build
v test .                   # the suite
v -gc none test .          # the same with no collector
v run tools/gate.vsh       # formatting, pure V, build, both suites, doc links
v fmt -w .                 # format before committing
./vvd --help               # the flag surface
```

The gate is what a pull request has to pass. Run it before claiming a change is
done rather than after CI says otherwise. Compiling a tree you did not just write,
cap the compiler the way the other trees here do:

```sh
systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 v test .
```

## Where things go

| Path | Rule |
|---|---|
| `main.v` | the run: the exit status, and what `--help`, `--version`, `--verbose` and `--stats` print. Decides nothing about a link. |
| `link.v` | the request as vlk takes it: the target, the kind, the container, the entry. The only file that imports the library. |
| `cli/` | the flag surface. Knows the shape of a request and no linker fact, so it can be read and tested without a target. |
| `tools/` | the gate. Not part of the frontend and not imported by it. |

Tests sit beside what they test. `cli/cli_test.v` reads the flag surface, and
`link_test.v` writes objects, links them through `link`, and runs the images.

## Verification

- Run the artifact, do not infer it. A link is verified by running the program the
  image describes and reading its exit status; a shared object by reading
  `e_type` out of the file; a loader or a soname by reading the string back out.
- Build into a scratch directory. A binary from an earlier edit reports the
  previous source's problems, so use `-nocache` on a probe.
- A refusal is verified by the text of the refusal and by the file that was not
  written. Check both.
- The library is the ground truth for what a link can do. When the frontend's
  comment and vlk's code disagree, the code is right and the comment is a bug in
  the frontend's prose.

## Agent working state

Anything written for one agent run lives in `.omh/`, which is git-ignored: plans,
probes, capture scripts and scratch notes. None of it is committed, and no
harness written to check a single change belongs in this tree. A repository keeps
the tests its maintainers will run.

## Prose

Comments, commit bodies, pull request text and the markdown here are read by
people. Write them the way you would say them out loud: plain sentences, specific
claims.

- No em dashes. A comma, a colon, or a full stop is usually what was meant.
- No "serves as", "stands as", or vocabulary that inflates what code does into
  what it means.
- No three-item list assembled to sound thorough, and no synonym carousel where
  one thing is first a layer, then a stage, then a component.
- No bolded label at the start of every bullet, and no signposting before the
  point.
- When the claim is a measurement, print the number and the command that produced
  it. An adjective is not evidence.

## Commits

`area: what changed`, lowercase, no trailing period, and a body that says why.
One logical change per commit, each one building on its own. Areas in use:
`cli`, `link`, `vvd`, `tools`, `tree`, `docs`.

## Do not

- Accept a flag and act on nothing, in either direction: not a `-z` keyword, not
  a `-Wl,` payload, not a spelling accepted "for compatibility".
- Let `cli/` learn a linker fact, or `link.v` learn how a flag is spelled.
- Weaken a test, an assertion, or a refusal to make a change land.
- Commit a binary fixture, or a generator written to check one change.
- Add a dependency to `v.mod` without raising it first.

# x-git

git on x-lang, as a lang bundle.

    x -l git -- [-C <path>] <command> [<args>]

The reference is git itself (`/usr/bin/git`): output, refusals and exit
statuses are compared with it, and the spec suite makes its fixture
repository with it.  The digests and compression git needs are x-lang
codecs, written in x and compiled, so the bundle runs where nothing but
the kernel and x are installed (x-os).

## Served

- `--version`, `-v`, `version`; `-C <path>`
- `hash-object [-t <type>] [-w] [--stdin] <file>...`: an object's name,
  and with `-w` the object written loose, as a zlib stream of stored
  blocks (git reads it; the writer does not compress yet)
- `cat-file (-t | -s | -p | -e) <object>` and `cat-file <type> <object>`
  on loose and packed objects (OFS and REF deltas applied), named in full or by a unique hex prefix of four
  digits or more; a tree printed as git prints one
- the repository found from the working directory or any parent
- an unknown command or option, refused as git refuses it

Not served yet: refs (`HEAD`, branch names), and every
other command.

## Install and test

    make install          # into <share>/langs/git
    make test             # the spec suite
    make check            # the suite against tests/contract/known-failures.txt

Set `X=/path/to/x` to use a particular x.  The suite needs `git` on the
path for its fixture and as the reference.

## Layout

    lang.xon          what the bundle is: lang, dialect, required release, entry
    run.x             the entry
    git/base.x        the parts, assembled
    git/objects.x     the object store: loose objects read and written, names, trees
    git/packs.x       packed objects: the index, entries, deltas
    git/commands.x    cat-file, hash-object
    git/cli.x         the command line: git-options, git-plan, git-run, git-main
    tests/            the spec suite and its runner, gate and harness

## Licence

MIT No Attribution (MIT-0).

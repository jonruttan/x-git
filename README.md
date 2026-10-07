# x-git

git on x-lang, as a lang bundle.

    x -l git -- COMMAND [ARGS]

The reference is git itself (`/usr/bin/git`): output, refusals and exit
statuses are compared with it.  The digests and compression git needs are
x-lang codecs, written in x and compiled, so the bundle runs where nothing
but the kernel and x are installed (x-os).

## Served

- `--version`, `-v`, `version`
- an unknown command, refused as git refuses it

## Install and test

    make install          # into <share>/langs/git
    make test             # the spec suite
    make check            # the suite against tests/contract/known-failures.txt

Set `X=/path/to/x` to use a particular x.

## Layout

    lang.xon          what the bundle is: lang, dialect, required release, entry
    run.x             the entry
    git/base.x        the parts, assembled
    git/cli.x         the command line: git-argv, git-plan, git-main
    tests/            the spec suite and its runner, gate and harness

## Licence

MIT No Attribution (MIT-0).

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
  on loose and packed objects (OFS and REF deltas applied); a tree printed
  as git prints one
- `rev-parse <revision>...`
- `ls-tree [-r] [-t] [-l] [--name-only] <tree-ish> [<path>...]`
- `log [--oneline] [-n <number>] [<revision>]`, newest committer time first
- `ls-files [--stage]` and `status [-s | --porcelain]` from the index
  (.gitignore is not read)
- `add [-A] <pathspec>...`: the blobs written, the index written (version 2)
- `commit -m <message> [-q]`: the trees from the index, the commit with the
  identity `.git/config` holds (the global config is not read) and the
  clock's time in the local offset, the branch moved; the summary as git
  prints it, its line counts from a line diff
- `diff [--cached] [--stat] [<revision> [<revision>]] [--] [<path>...]`:
  git's unified form, hunks with three lines of context; the edit script
  is by longest common subsequence, so where several are shortest the
  hunks may differ from git's (Myers)
- `init [-b <branch>] [<directory>]` (the hints git prints for an unnamed
  first branch are not printed), `branch [-d] [<branch> [<start>]]`,
  `tag [-d] [<tag> [<object>]]` (lightweight tags only)
- `checkout <branch> | <commit>`, `checkout -b <new> [<start>]`, `switch [-c <new>] <branch>`:
  the working directory and index set to the tree, a path with changes of
  its own stopping the move in git's words; `checkout -- <path>...` and
  `restore <path>...` from the index
- `clone <repository> [<directory>]` from a local path or a `file://`
  url: the objects copied, or brought as one pack over git's pack
  protocol from `git-upload-pack`; the source's branches as
  `refs/remotes/origin/*`, its tags, one local branch for its HEAD
  branch, the remote and branch config, the tree checked out
- `fetch [<repository>]`: every branch of the remote to
  `refs/remotes/<remote>/*`, the tags that point into what it now has,
  `FETCH_HEAD`; by path, or by url over the pack protocol, negotiating
  what this repository has so only the rest is sent
- `push [<repository> [<branch>]]` to a path: one branch, refused as git
  refuses a push that is not a fast-forward, one whose remote has work
  this repository has not seen, or one into a non-bare remote's checked-out
  branch
- `ls-remote [<repository>]`: what the remote's service advertises
- `rm [-r] [--cached] [-f] <pathspec>...`, `mv <source>... <destination>`;
  `.gitignore`, `.git/info/exclude` and `core.excludesFile` as
  gitignore(5) reads them
- an object named in full, by a unique hex prefix of four digits or more,
  or by a revision: `HEAD`, a branch or tag (loose or in `packed-refs`,
  looked up as gitrevisions(7) does), with `~N`, `^N`, `^{tree}`,
  `^{commit}`, `^{}` and `:PATH`
- the repository found from the working directory or any parent
- an unknown command or option, refused as git refuses it

Not served yet: reflogs (`@{N}`), `:/text`, and every other command.

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
    git/refs.x        refs, loose and packed; revision names to objects
    git/commands.x    cat-file, hash-object, rev-parse
    git/history.x     ls-tree, log
    git/index.x       the index read; ls-files, status
    git/stage.x       the index written; add, commit
    git/diff.x        lines compared: diff, and the summary commit prints
    git/repo.x        init, branch, tag
    git/checkout.x    the working directory set to a tree: checkout, switch, restore
    git/clone.x       a repository copied from a path or fetched by url
    git/remote.x      fetch, push and ls-remote, by path or by wire
    git/protocol.x    the client side of git's pack protocol
    git/wire.x        a git service on two pipes, spoken in pkt-lines
    git/paths.x       rm, mv
    git/ignore.x      gitignore(5)
    git/cli.x         the command line: git-options, git-plan, git-run, git-main
    tests/            the spec suite and its runner, gate and harness

## Licence

MIT No Attribution (MIT-0).

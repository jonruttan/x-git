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
- a remote by path, or by url: `file:///path`, `ssh://[user@]host[:port]/path`
  or scp's `[user@]host:path`.  Over ssh the service is run on the host
  as git runs it, `ssh [-p port] host "git-upload-pack '/path'"`, the
  ssh chosen as git chooses one: `GIT_SSH_COMMAND`, `core.sshCommand`,
  `GIT_SSH`, then `ssh` -- on x-os, x-ssh's client
- `clone <repository> [<directory>]` from a local path or a url: the
  objects copied, or brought as one pack over git's pack protocol from
  `git-upload-pack`; the source's branches as
  `refs/remotes/origin/*`, its tags, one local branch for its HEAD
  branch, the remote and branch config, the tree checked out
- `fetch [<repository>]`: every branch of the remote to
  `refs/remotes/<remote>/*`, the tags that point into what it now has,
  `FETCH_HEAD`; by path, or by url over the pack protocol, negotiating
  what this repository has so only the rest is sent
- `merge [--ff-only] [<commit>]` and `pull [--ff-only] [<repository>
  [<branch>]]` by fast-forward: the working directory, the index and the
  branch moved to the commit -- the upstream when none is named, what the
  fetch marks for merging for pull -- with git's report and diffstat; a
  change of the working directory's own in the way, and histories that
  have diverged, refused in git's words (no merge commits yet)
- `push [<repository> [<branch>]]`: one branch, by path or by url to
  `git-receive-pack` with the pack of what the remote lacks and its
  report read back; refused as git refuses a push that is not a
  fast-forward, one whose remote has work this repository has not seen,
  or one into a non-bare remote's checked-out branch
- `ls-remote [<repository>]`: what the remote's service advertises
- `upload-pack <directory>` and `receive-pack <directory>`: the services
  git runs on the far end of a fetch or a push, on standard input and
  output -- `git clone --upload-pack='x -l git -- upload-pack' file://...`
  and `git push --receive-pack='x -l git -- receive-pack' ...` take them
  as they take git's own; refusals (HEAD's branch deleted, a non-bare
  repository's checked-out branch updated) in receive-pack's words
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

`tests/oracle/ssh.sh` is the live test over ssh, x at every hop: x-git
clones, fetches and pushes through x-ssh's client and server, with
x-git's own services on the far side, and git checks what lands.

    X=/path/to/x X_LANG_DIR=DIR/ sh tests/oracle/ssh.sh [PORT]

DIR holds this tree as `git` and x-ssh as `ssh`.

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
    git/serve.x       upload-pack and receive-pack, the services
    git/merge.x       merge and pull, by fast-forward
    git/paths.x       rm, mv
    git/ignore.x      gitignore(5)
    git/cli.x         the command line: git-options, git-plan, git-run, git-main
    tests/            the spec suite and its runner, gate and harness

## Licence

MIT No Attribution (MIT-0).

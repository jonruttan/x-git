# x-git

git on x-lang, as a lang bundle.

    x -l git -- [-C <path>] <command> [<args>]

The reference is git itself (`/usr/bin/git`): output, refusals and exit
statuses are compared with it, and the spec suite makes its fixture
repository with it.  The digests and compression git needs are x-lang
codecs, written in x and compiled, so the bundle runs where nothing but
the kernel and x are installed (x-os).

## Served

- `--version`, `-v`, `version`; `-C <path>`; `-c <name>=<value>`
- `config`: get, set, `--add`, `--unset`, `--unset-all`,
  `--remove-section`, `--list`, with `--global`, `--system`, `--local` or
  `-f <file>`, `--bool`/`--int`, `--show-origin`, `--show-scope`; and the
  `get`, `set`, `unset`, `list` and `remove-section` subcommands.  Every
  command reads configuration as git does: the system's file, the
  user's (`~/.gitconfig` and the XDG one), the repository's, then `-c`
  and `GIT_CONFIG_COUNT`, the last value winning; files parsed and
  written as git parses and writes them (includes are not followed)
- `hash-object [-t <type>] [-w] [--stdin] <file>...`: an object's name,
  and with `-w` the object written loose, as a zlib stream of stored
  blocks (git reads it; the writer does not compress yet)
- `cat-file (-t | -s | -p | -e) <object>` and `cat-file <type> <object>`
  on loose and packed objects (OFS and REF deltas applied); a tree printed
  as git prints one
- `rev-parse <revision>...`
- `ls-tree [-r] [-t] [-l] [--name-only] <tree-ish> [<path>...]`
- `log [--oneline] [-n <number>] [<revision>]`, newest committer time first
- `show [-s] [--stat] [--oneline | --pretty=<format> | --format=<format>]
  [<object>...]`: a commit with its patch or --stat against its first
  parent, an annotated tag then what it tags, a tree's entries, a blob's
  text; git's placeholders for --format (%H %h %T %t %P %p %s %b %B %an
  %ae %ad %cn %ce %cd %n %%).  A merge's combined diff is not drawn
- `ls-files [--stage]` and `status [-s | --porcelain]` from the index
  (.gitignore is not read)
- `add [-A] <pathspec>...`: the blobs written, the index written (version 2)
- `commit -m <message> [-q] [--no-edit]`: the trees from the index, the
  commit with the identity and time git takes -- `GIT_AUTHOR_*` and
  `GIT_COMMITTER_*`, then `user.name` and `user.email` from the
  configuration, and the clock -- the branch moved; the summary as git prints it, its
  line counts from a line diff.  A merge in progress is concluded: its
  second parent from `MERGE_HEAD`, its message from `MERGE_MSG` when no
  `-m` is given; a path still in conflict refuses it
- `diff [--cached] [--stat] [<revision> [<revision>]] [--] [<path>...]`:
  git's unified form, hunks with three lines of context; the edit script
  is by longest common subsequence, so where several are shortest the
  hunks may differ from git's (Myers)
- `init [-b <branch>] [<directory>]`, the first branch `init.defaultBranch`
  when no `-b` is given (the hints git prints for an unnamed first branch
  are not printed), `branch [-d] [<branch> [<start>]]`,
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
- `merge [--ff-only] [<commit>] | --abort` and `pull [--ff-only |
  --no-rebase] [<repository> [<branch>]]`: a fast-forward when the commit
  -- the upstream when none is named, what the fetch marks for merging for
  pull -- has the branch in its history; otherwise a three-way merge from
  the merge base (several merged into one first, as git's ort does), into
  a merge commit, or with the conflicts marked in the
  files, staged 1, 2 and 3 in the index and `MERGE_HEAD` left for `commit`
  (content, add/add, modify/delete, rename/delete and rename/rename
  conflicts).  A file renamed on one side is merged under its new name,
  renames found as git finds them (the same blob, else half or more alike
  by git's measure).  A file added to a directory the other side renamed
  follows it as `merge.directoryRenames` says -- in conflict at its new
  path by default, moved with `true`, left with `false` -- and a
  directory split between new homes stops the merge.  git's report,
  diffstat (renames as `OLD => NEW`) and messages; a change of the working
  directory's own in the way refused in git's words; pull merges diverged
  histories when `--no-rebase` or `pull.rebase=false` says to
- `push [-f] [-d] [--tags] [-u] [<repository> [<refspec>...]]`: refspecs
  as git takes them (`src`, `src:dst`, `:dst` to delete, `+src:dst` to
  force, a revision to a full ref), by path or by url to
  `git-receive-pack`, every update in one batch with the pack of what the
  remote lacks and its report read back; a ref refused as git refuses it
  -- not a fast-forward, work the remote has that this repository has
  not seen, a tag that exists, the checked-out branch of a non-bare
  remote -- unless forced; git's line for each ref and its hint; the
  tracking refs moved, and with `-u` each branch's upstream recorded
- `ls-remote [<repository>]`: what the remote's service advertises
- `upload-pack <directory>` and `receive-pack <directory>`: the services
  git runs on the far end of a fetch or a push, on standard input and
  output -- `git clone --upload-pack='x -l git -- upload-pack' file://...`
  and `git push --receive-pack='x -l git -- receive-pack' ...` take them
  as they take git's own; refusals (HEAD's branch deleted, a non-bare
  repository's checked-out branch updated) in receive-pack's words
- packs written with deltas, bases chosen as git's pack-objects chooses
  them; thin packs both ways: a push or a served fetch builds on what
  the far end has, and a thin pack that arrives is completed with its
  bases from this repository, as `index-pack --fix-thin` completes one
- `reset [--soft | --mixed | --hard] [-q] [<commit>] [[--] <pathspec>...]`:
  HEAD's branch (or HEAD, detached) moved and `ORIG_HEAD` left; the index
  set too (mixed) or the index and the working directory (hard), a merge
  in progress given up; with paths, their index entries alone.  git's
  report of the changes left unstaged, or of where a hard reset lands
- `revert [--no-edit] [-n] <commit>`, `revert --continue | --abort`: a
  commit's change undone by merge's three-way merge and committed with
  git's message (`Revert "..."`, `Reapply "..."` for a revert of a
  revert), edited first in git's editor unless `--no-edit`; a conflict
  left with `REVERT_HEAD` and `MERGE_MSG` for `--continue` or `commit`.
  One commit at a time; a merge, which needs `-m`, is refused
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
    git/delta.x       deltas made, as git's diff-delta makes them
    git/refs.x        refs, loose and packed; revision names to objects
    git/commands.x    cat-file, hash-object, rev-parse
    git/history.x     ls-tree, log, show
    git/index.x       the index read; ls-files, status
    git/stage.x       the index written; add, commit
    git/config.x      configuration read and written; config
    git/diff.x        lines compared: diff, and the summary commit prints
    git/repo.x        init, branch, tag
    git/checkout.x    the working directory set to a tree: checkout, switch, restore
    git/clone.x       a repository copied from a path or fetched by url
    git/remote.x      fetch, push and ls-remote, by path or by wire
    git/protocol.x    the client side of git's pack protocol
    git/wire.x        a git service on two pipes, spoken in pkt-lines
    git/serve.x       upload-pack and receive-pack, the services
    git/merge.x       merge and pull
    git/reset.x       reset
    git/revert.x      revert
    git/threeway.x    the merge base, files and trees merged three ways
    git/renames.x     renames, as git finds them
    git/paths.x       rm, mv
    git/ignore.x      gitignore(5)
    git/cli.x         the command line: git-options, git-plan, git-run, git-main
    tests/            the spec suite and its runner, gate and harness

## Licence

MIT No Attribution (MIT-0).

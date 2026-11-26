# x-git card

## Run

```sh
x -l git -- [-C PATH] [-c NAME=VALUE] COMMAND [ARG ...]
x -l git -- clone https://example.org/project.git
x -l git -- -C project log --oneline -5
x -l git -- COMMAND -h                    # a command's usage
x -l git -- --version -> git version 0.1.0 (x-git)
```

```git
git init > /dev/null
echo one > a.txt
git status -s                             # -> ?? a.txt
git add a.txt
git status -s                             # -> A  a.txt
git commit -q -m 'add a'
git log --oneline                         # -> d72dcef add a
```

| On this page           | Is                                               |
|------------------------|--------------------------------------------------|
| a program              | shell, in a new empty directory                  |
| `git` in it            | `x -l git --`                                    |
| the identity, the clock | fixed, so a commit's name is the same anywhere  |
| the configuration      | none of the user's or the system's; `main` first |

## Changes

```git
git init > /dev/null
echo one > a.txt; git add a.txt; git commit -q -m 'add a'
echo two >> a.txt
git diff --name-only                      # -> a.txt
git diff | tail -1                        # -> +two
git commit -q -a -m 'more a'
git log --oneline                         # -> 42a9116 more a
                                          # -> d72dcef add a
git mv a.txt b.txt
git status -s                             # -> D  a.txt
                                          # -> A  b.txt
git reset -q --hard HEAD
git ls-files                              # -> a.txt
echo junk >> a.txt
git restore a.txt
cat a.txt | tail -1                       # -> two
git rm -q a.txt
git status -s                             # -> D  a.txt
```

| Command                            | Does                                  |
|------------------------------------|---------------------------------------|
| `init [-b BRANCH] [DIR]`           | a new repository                      |
| `status [-s]` `status --porcelain` | what has changed; `--ignored` too     |
| `add PATH ...` `add -A`            | stage                                 |
| `rm PATH` `mv OLD NEW`             | remove; rename, staged                |
| `commit -m MESSAGE` `commit -a -m MESSAGE` | commit; tracked files first |
| `restore PATH` `restore -S PATH`   | a file from the index; it from HEAD   |
| `restore -s TREE PATH`             | from a commit or tree                 |
| `reset [--soft` `--mixed` `--hard] [COMMIT]` | move the branch back        |
| `clean -n` `clean -f`              | say what is untracked; remove it      |
| `config NAME [VALUE]` `config --list` | read, set, list settings; `--global` |

## History

```git
git init > /dev/null
echo one > a.txt; git add a.txt; git commit -q -m 'add a'
echo two >> a.txt; git commit -q -a -m 'more a'
git log -1 --format='%an %s'              # -> Ada more a
git show -s --format=%ad                  # -> Sat Jan 31 12:00:00 2026 +0000
git show --stat --oneline | head -1       # -> 42a9116 more a
git rev-parse HEAD^         # -> d72dcef5c60e37b02b5cb4c6057e0ee3053337f2
git cat-file -t HEAD                      # -> commit
git cat-file -p HEAD^ | head -1
                            # -> tree 20e50a07feffafe7699bf38ff4027a606f406eaa
git ls-tree --name-only HEAD              # -> a.txt
git hash-object a.txt       # -> 814f4a422927b82f5f8a43f8fab6d3839e3983f2
```

| Command                            | Does                                  |
|------------------------------------|---------------------------------------|
| `log [-N] [--oneline] [-p] [--stat]` | the commits, newest first           |
| `log --format=FORMAT`              | `%H %h %s %an %ae %ad %cn %cd %b %n`  |
| `show [OBJECT]` `show -s` `show --stat` | a commit, a tree or a blob       |
| `diff` `diff --cached` `diff A B` `diff A..B` | changes, as a patch        |
| `diff --stat` `--numstat` `--raw` `--name-only` `--name-status` | or counted |
| `reflog`                           | where HEAD has been                   |
| `describe [--tags]`                | the nearest tag, and how far          |
| `rev-parse REVISION`               | a revision's full name                |
| `cat-file -t` `-s` `-p` `-e OBJECT` | its type, size or text; is it there |
| `hash-object [-w] FILE`            | a file's name as a blob; `-w` writes it |
| `ls-tree [-r] TREE` `ls-files [-s]` | a tree's entries; the index's        |
| `check-ignore PATH`                | is a path ignored                     |

## Branches and tags

```git
git init > /dev/null
echo one > a.txt; git add a.txt; git commit -q -m 'add a'
git switch -c topic 2>&1           # -> Switched to a new branch 'topic'
echo t > t.txt; git add t.txt; git commit -q -m 'add t'
git switch main 2>&1               # -> Switched to branch 'main'
git merge topic | sed -n 2p               # -> Fast-forward
git log --format=%s                       # -> add t
                                          # -> add a
git tag v1
git tag                                   # -> v1
echo x > b.txt; git add b.txt; git commit -q -m 'add b'
git describe --tags | cut -d- -f1,2       # -> v1-1
git revert --no-edit HEAD > /dev/null
git log -1 --format=%s                    # -> Revert "add b"
```

| Command                            | Does                                  |
|------------------------------------|---------------------------------------|
| `branch` `branch NAME [START]` `branch -d NAME` | list; make; delete       |
| `switch NAME` `switch -c NEW`      | change branch; make one and change    |
| `checkout NAME` `checkout -b NEW` `checkout -- PATH` | the older spelling  |
| `switch --detach [COMMIT]`         | HEAD on a commit, no branch           |
| `merge NAME`                       | fast-forward, or a merge commit       |
| `tag` `tag NAME [OBJECT]` `tag -d NAME` | lightweight tags                 |
| `revert COMMIT` `cherry-pick COMMIT` | undo a commit; copy one here        |
| `--continue` `--abort` on those    | after a conflict                      |

## Remotes

```git
git init > /dev/null
echo one > a.txt; git add a.txt; git commit -q -m 'add a'
git clone . ../copy > /dev/null
git -C ../copy log -1 --format=%s         # -> add a
echo n > n.txt; git add n.txt; git commit -q -m 'add n'
git -C ../copy pull > /dev/null 2>&1
git -C ../copy log -1 --format=%s         # -> add n
git ls-remote . | cut -f2 | head -2       # -> HEAD
                                          # -> refs/heads/main
```

| Form                               | Is                                    |
|------------------------------------|---------------------------------------|
| `clone REPOSITORY [DIR]`           | a copy, its branches as `origin/*`    |
| `fetch` `pull` `push`              | bring; bring and merge; send          |
| `push --set-upstream origin BRANCH` | send, and remember where             |
| `ls-remote REPOSITORY`             | a repository's refs                   |
| a path, `file:///PATH`             | a repository on this machine          |
| `ssh://HOST/PATH` `HOST:PATH`      | over ssh, by `GIT_SSH_COMMAND` or `ssh` |
| `http://` `https://`               | git's smart protocol; no login sent   |
| `upload-pack` `receive-pack`       | the services a remote runs            |

## Differs

```git
git init > /dev/null
git stash 2>&1    # -> git: 'stash' is not a git command. See 'git --help'.
git rev-parse --short HEAD 2>&1 | head -1 # -> error: unknown option `short'
git log --graph 2>&1 | head -1            # -> error: unknown option `graph'
git commit --amend -m x 2>&1 | head -1    # -> error: unknown option `amend'
git init -q ../other 2>&1 | head -1       # -> error: unknown switch `q'
```

| Here                                        | In git                        |
|---------------------------------------------|-------------------------------|
| no `rebase` `stash` `blame` `bisect` `grep` `remote` | commands             |
| no `submodule` `worktree` `gc` `apply` `am` `archive` `notes` | commands    |
| `status -s` after `mv` shows `D` and `A`    | `R  OLD -> NEW`               |
| an option not served is refused, with the usage | taken                     |
| `tag` makes lightweight tags only           | annotated and signed too      |
| repositories are SHA-1, the index version 2 | SHA-256 and later indexes too |
| no login is sent over http or https         | a credential helper, a prompt |
| a merge's combined diff is not drawn        | drawn                         |

## More

| Where                          | What                                     |
|--------------------------------|------------------------------------------|
| `README.md`, Served            | each command and option, in full         |
| `README.md`, Security          | what has and has not been checked        |
| `tests/specs/`                 | each command, held to git itself         |
| `tests/card-run.sh`            | runs a program of this page              |

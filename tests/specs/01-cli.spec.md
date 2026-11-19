# @weight 1

The command line.  git-options is one declaration: what --help prints and
what a line is parsed against.  git-plan turns a line into a plan without
doing it, and git-run does the plan, answering (STREAM TEXT STATUS); the
refusals and statuses are git's own.

## plan

### --help prints the declaration, status 0

```git
(display (first (rest (git-run (git-plan (list "--help"))))))
```
---
```output
Usage: git [-v | --version] [-C <path>] [-c <name>=<value>] <command> [<args>]

	-v,--version		Print the version
	-C <path>		Run as if started in <path>
	-c <name>=<value>	Set a configuration value for this command
```

### the version, by option or by command, status 0

```git
(write (List map (fn (_ w) (git-run (git-plan (list w)))) (list "--version" "-v" "version")))
```
---
    (('out "git version 0.1.0 (x-git)\n" 0) ('out "git version 0.1.0 (x-git)\n" 0) ('out "git version 0.1.0 (x-git)\n" 0))

### no command prints the usage, status 1

```git
(write (first (rest (rest (git-run (git-plan ()))))))
```
---
    1

### an unknown command is refused in git's words, status 1

```git
(write (git-run (git-plan (list "frob"))))
```
---
    ('err "git: 'frob' is not a git command. See 'git --help'.\n" 1)

### an unknown option names itself, status 129

```git
(def %gp (git-run (git-plan (list "--frob" "status"))))
(write (list (first %gp) (Str8 sub 0 22 (first (rest %gp))) (first (rest (rest %gp)))))
```
---
    ('err "unknown option: --frob" 129)

### options after the command are the command's

```git
(write (git-run (git-plan (list "frob" "-v"))))
```
---
    ('err "git: 'frob' is not a git command. See 'git --help'.\n" 1)

### a command's options read as git reads them: --no-NAME takes NAME back, a flag takes no value

Twin repositories, a commit and a change in each, x-git running in one
and git in the other: each case answers its status and whether x-git
said what git said.  The last word wins (`-q --no-quiet` is not quiet,
`--no-message` drops the -m before it); a flag given a value, as
`--quiet=x` or `--no-short=1`, is refused in git's words, status 129.

```git
(def %nf-env
  (list (pair "GIT_CONFIG_GLOBAL" "/dev/null") (pair "GIT_CONFIG_NOSYSTEM" "1")
        (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c")
        (pair "GIT_COMMITTER_NAME" "A") (pair "GIT_COMMITTER_EMAIL" "a@b.c")
        (pair "GIT_AUTHOR_DATE" "2026-01-01T00:00:00Z") (pair "GIT_COMMITTER_DATE" "2026-01-01T00:00:00Z")))
(List for-each (fn (_ e) (Sys setenv (first e) (rest e))) %nf-env)
(def %nf-mk
  (fn (_)
    (def d (let ((t (File temp "/tmp/x-git-opts-"))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t))))
    (Proc run! (list "/bin/sh" "-c" "cd \"$0\" && git init -q -b main && echo a>f && git add f && git commit -qm one && echo b>>f && git add f" d))
    d))
(def %nf
  (fn (_ . ops)
    (def x (%nf-mk))
    (def g (%nf-mk))
    (def xr (apply git-text-in (pair x ops)))
    (def gr (apply git-oracle-in (pair g ops)))
    (if (equal? xr gr) (pair (first xr) #t) (list xr gr))))
(write (list
  (%nf "commit" "--quiet=x" "-m" "two")
  (%nf "commit" "--no-quiet=x" "-m" "two")
  (%nf "status" "--no-short=1")
  (%nf "commit" "-q" "--no-quiet" "-m" "two")
  (%nf "commit" "-m" "x" "--no-message" "-m" "two")
  (%nf "status" "-s" "--no-short")
  (%nf "switch" "-q" "--no-quiet" "-c" "side")
  (%nf "cherry-pick" "--abort=x")))
(List for-each (fn (_ e) (Sys unsetenv (first e))) %nf-env)
```
---
    ((129 . #t) (129 . #t) (129 . #t) (0 . #t) (0 . #t) (0 . #t) (0 . #t) (129 . #t))

### -C, -c and the command's arguments ride the plan

```git
(write (list (git-plan (list "-C" "/somewhere" "cat-file" "-t" "abc"))
             (git-plan (list "-c" "a.b=1" "-c" "c.d=2" "status"))))
```
---
    (('run "/somewhere" "cat-file" ("-t" "abc") ()) ('run () "status" () ("a.b=1" "c.d=2")))

## main

### what main writes and exits through is bound in its module

main exits the process, so a spec cannot call it; this holds the names it
reaches for, from inside the module, as main sees them.

```git
(write (List map (fn (_ s) (not (null? (eval s (module git/cli))))) (list (lit File) (lit Sys))))
```
---
    (#t #t)

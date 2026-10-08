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
Usage: git [-v | --version] [-C <path>] <command> [<args>]

	-v,--version	Print the version
	-C <path>	Run as if started in <path>
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

### -C and the command's arguments ride the plan

```git
(write (git-plan (list "-C" "/somewhere" "cat-file" "-t" "abc")))
```
---
    ('run "/somewhere" "cat-file" ("-t" "abc"))

## main

### what main writes and exits through is bound in its module

main exits the process, so a spec cannot call it; this holds the names it
reaches for, from inside the module, as main sees them.

```git
(write (List map (fn (_ s) (not (null? (eval s (module git/cli))))) (list (lit File) (lit Sys))))
```
---
    (#t #t)

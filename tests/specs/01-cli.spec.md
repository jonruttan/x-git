# @weight 1

The command line.  git-options is one declaration: what --help prints and
what a line is parsed against.  git-plan turns a line into (STREAM TEXT
STATUS) without doing it; the refusals and statuses are git's own.

## plan

### --help prints the declaration, status 0

```git
(display (first (rest (git-plan (list "--help")))))
```
---
```output
Usage: git [-v | --version] <command> [<args>]

	-v,--version	Print the version
```

### the version, by option or by command, status 0

```git
(write (List map (fn (_ w) (git-plan (list w))) (list "--version" "-v" "version")))
```
---
    ((out "git version 0.1.0 (x-git)\n" 0) (out "git version 0.1.0 (x-git)\n" 0) (out "git version 0.1.0 (x-git)\n" 0))

### no command prints the usage, status 1

```git
(write (List map (fn (_ l) (first (rest (rest (git-plan l))))) (list () (list "-v" "--help"))))
```
---
    (1 0)

### an unknown command is refused in git's words, status 1

```git
(write (git-plan (list "frob")))
```
---
    (err "git: 'frob' is not a git command. See 'git --help'.\n" 1)

### an unknown option names itself, status 129

```git
(def %gp (git-plan (list "--frob" "status")))
(write (list (first %gp) (Str8 sub 0 22 (first (rest %gp))) (first (rest (rest %gp)))))
```
---
    (err "unknown option: --frob" 129)

### options after the command are the command's

```git
(write (git-plan (list "frob" "-v")))
```
---
    (err "git: 'frob' is not a git command. See 'git --help'.\n" 1)

## argv

### the launcher's flags and the -- are dropped

```git
(write (git-argv (list "run.x" "--batch" "--" "status" "-s")))
```
---
    ("status" "-s")

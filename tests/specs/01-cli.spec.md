# @weight 1

The command line.  git-plan turns a line into (STREAM TEXT STATUS) without
doing it; the words and statuses are git's own.

## plan

### no command prints the usage line, status 1

```git
(display (git-plan ()))
```
---
```output
(out usage: git [-v | --version] <command> [<args>]
 1)
```

### --version, -v and version name the version, status 0

```git
(display (List map (fn (_ w) (first (rest (rest (git-plan (list w)))))) (list "--version" "-v" "version")))
```
---
    (0 0 0)

### an unknown command is refused in git's words, status 1

```git
(display (git-plan (list "frob")))
```
---
```output
(err git: 'frob' is not a git command. See 'git --help'.
 1)
```

## argv

### the launcher's flags and the -- are dropped

```git
(display (git-argv (list "run.x" "--batch" "--" "status" "-s")))
```
---
    (status -s)

# @weight 3
# @timeout-scale 2

restore's sources and targets, against git itself.  `--staged` (`-S`)
puts paths back in the index, from HEAD; `--worktree` (`-W`), or
neither, puts them back in the working directory, from the index;
`--source` (`-s`) names the commit or tree they come from instead.  A
path the source lacks goes from where it is put back.  Each case builds
twin repositories, x/r for x-git and g/r for git, from the same two
commits (f, g and d/h, then f changed) and the same setup, at the same
dates; then the same lines run in both, x-git's in x/r and git's in g/r.
What each prints and exits with is compared, then what each leaves: the
index, the status, and every file in the working tree with what it
holds.  Each line answers #t when the two agree, else both answers.

## the index put back

### --staged: from HEAD, the working directory left alone; a new path taken out

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "C") (pair "GIT_COMMITTER_EMAIL" "c@d.e") (pair "GIT_COMMITTER_DATE" "1767229200 +0000")))
(def %rs-d (let ((t (File temp "/tmp/x-git-rs-"))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t))))
(def %rs-sh (fn (_ dir script) (Proc capture (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
; the twins made afresh, each from the same two commits and setup
(def %rs-twin
  (fn (_ setup)
    (%rs-sh %rs-d "rm -rf x g && mkdir x g")
    (List for-each
      (fn (_ w)
        (%rs-sh (Str8 append %rs-d "/" w)
          (Str8 append "git init -q -b main r && cd r && echo a > f && echo c > g && mkdir d && echo x > d/h"
                       " && git add . && git commit -qm one && echo a2 > f && git commit -qam two && " setup)))
      (list "x" "g"))))
; what a twin leaves: the index, the status, its files and what they hold
(def %rs-left
  (fn (_ w)
    (%rs-sh (Str8 append %rs-d "/" w "/r")
      "git ls-files -s && git status --porcelain && find . -path ./.git -prune -o -type f -print | sort | while read f; do echo \"$f: $(cat \"$f\")\"; done")))
; a line run in both: #t when the answers and what they leave agree
(def %rs-run
  (fn (_ . ops)
    (let ((x (apply git-text-in (pair (Str8 append %rs-d "/x/r") ops)))
          (g (apply git-oracle-in (pair (Str8 append %rs-d "/g/r") ops))))
      (let ((xl (%rs-left "x")) (gl (%rs-left "g")))
        (if (and (equal? x g) (equal? xl gl)) #t (list ops x g xl gl))))))
(%rs-twin "echo b >> f && echo n > n && git add f n && echo w >> f")
(write (list (%rs-run "restore" "--staged" "f") (%rs-run "restore" "-S" "n") (%rs-run "status")))
```
---
    (#t #t #t)

### a directory, ".", -q, and a path taken out of the index put back

```git
(%rs-twin "echo b >> f && echo y >> d/h && git add . && git rm -q g")
(write (list (%rs-run "restore" "--staged" "d/") (%rs-run "restore" "-q" "--staged" "g")
             (%rs-run "restore" "--staged" ".") (%rs-run "status" "-s")))
```
---
    (#t #t #t #t)

### a path in conflict: put back from HEAD, the conflict gone

```git
(%rs-twin "git checkout -qb o HEAD~1 && echo o > f && git commit -qam o && git checkout -q main && { git merge o >/dev/null; true; }")
(write (list (%rs-run "restore" "f") (%rs-run "restore" "--staged" "f") (%rs-run "status" "-s")))
```
---
    (#t #t #t)

## the working directory put back

### from the index, from a commit, and both at once

```git
(%rs-twin "echo b >> f && git add f && echo w >> f && echo y >> d/h && echo z >> g")
(write (list (%rs-run "restore" "f") (%rs-run "restore" "--worktree" "d")
             (%rs-run "restore" "--source=HEAD~1" "g") (%rs-run "restore" "-s" "HEAD~1" "f")
             (%rs-run "restore" "-SW" "f") (%rs-run "status" "-s")))
```
---
    (#t #t #t #t #t #t)

### a path the source lacks: gone from the working directory, and from the index with --staged

```git
(%rs-twin "echo n > n && git add n")
(def %rs-one (%rs-run "restore" "--source=HEAD" "n"))
(%rs-twin "echo n > n && git add n")
(write (list %rs-one (%rs-run "restore" "--source" "HEAD" "--staged" "--worktree" "n") (%rs-run "status" "-s")))
```
---
    (#t #t #t)

## refused, in git's words

### no paths, a pathspec matching nothing, and a source that is no commit

```git
(%rs-twin "echo b >> f && git add f")
(write (list (%rs-run "restore" "--staged") (%rs-run "restore" "--staged" "nope")
             (%rs-run "restore" "--staged" "f" "nope") (%rs-run "restore" "--source=nope" "f")
             (git-text-in (Str8 append %rs-d "/x/r") "restore" "--staged" "nope")
             (git-text-in (Str8 append %rs-d "/x/r") "restore" "--source=nope" "f")))
```
---
    (#t #t #t #t (1 . "error: pathspec 'nope' did not match any file(s) known to git\n") (128 . "fatal: could not resolve 'nope'\n"))

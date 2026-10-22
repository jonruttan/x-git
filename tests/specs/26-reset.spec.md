# @weight 4
# @timeout-scale 3

git reset, against git itself.  Each case builds twin repositories the
same way, at the same dates -- two commits of a, b and c, then a change
staged, one not staged and a file untracked -- and runs the same reset
lines in both, x-git's in x/r and git's in g/r.  What each prints, on
standard output and error apart, and what it exits with is compared,
then what each leaves: HEAD, ORIG_HEAD, the index, the status and the
files.

## moving HEAD

### mixed, the default: the index set, the working directory kept

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "A") (pair "GIT_COMMITTER_EMAIL" "a@b.c") (pair "GIT_COMMITTER_DATE" "1767225600 +0000")))
(def %rs-d ())
(def %rs-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
(def %rs-build
  (Str8 append
    "git init -q -b main r && cd r && printf 'a\\n' > a && printf 'b\\n' > b && git add . && git commit -qm one"
    " && printf 'a2\\n' > a && printf 'c\\n' > c && git add . && git commit -qm two"
    " && printf 'a3\\n' > a && printf 'b3\\n' > b && git add b && printf 'u\\n' > untracked"))
(def %rs-twins
  (fn (_ more)
    (def t (File temp "/tmp/x-git-rs-"))
    (File close (first t)) (File unlink (rest t)) (File mkdir (rest t))
    (set! %rs-d (rest t))
    (%rs-sh %rs-d (Str8 append "mkdir x g && cd x && " %rs-build more " && cd ../../g && " %rs-build more))))
(def %rs-x
  (fn (_ ops)
    (def r (git-run (git-plan (pair "-C" (pair (Str8 append %rs-d "/x/r") ops)))))
    (def text (first (rest r)))
    (def more (rest (rest (rest r))))
    (if (eq? (first r) (lit out)) (list (first (rest (rest r))) text "")
      (list (first (rest (rest r))) (if (null? more) "" (first more)) text))))
(def %rs-g
  (fn (_ ops)
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git \"$@\" 2>../git.err" (pair (Str8 append %rs-d "/g/r") ops))))))
    (list (first r) (rest r) (File read-all (Str8 append %rs-d "/g/git.err")))))
; the lines whose answers differ, as (OPS X GIT)
(def %rs-steps
  (fn (_ lines)
    (List flat-map (fn (_ ops) (let ((x (%rs-x ops)) (g (%rs-g ops))) (if (equal? x g) () (list (list ops x g))))) lines)))
(def %rs-file (fn (_ side path) (let ((p (Str8 append %rs-d "/" side "/r/" path))) (if (File exists? p) (File read-all p) ()))))
(def %rs-same
  (fn (_)
    (List filter (fn (_ c) (not (equal? (first (rest c)) (first (rest (rest c))))))
      (List append
        (List map (fn (_ args) (list args (apply git-oracle-in (pair (Str8 append %rs-d "/x/r") args)) (apply git-oracle-in (pair (Str8 append %rs-d "/g/r") args))))
          (list (list "rev-parse" "HEAD") (list "ls-files" "-s") (list "status" "--porcelain")))
        (List map (fn (_ p) (list p (%rs-file "x" p) (%rs-file "g" p)))
          (list "a" "b" "c" "untracked" ".git/ORIG_HEAD" ".git/HEAD"))))))
(%rs-twins "")
(write (list (%rs-steps (list (list "reset" "HEAD~1"))) (%rs-same)))
```
---
    (() ())

### soft: HEAD alone

```git
(%rs-twins "")
(write (list (%rs-steps (list (list "reset" "--soft" "HEAD~1") (list "status" "--short"))) (%rs-same)))
```
---
    (() ())

### hard: the index and the working directory, untracked files kept

```git
(%rs-twins " && printf 'n\\n' > new && git add new")
(write (list (%rs-steps (list (list "reset" "--hard") (list "reset" "--hard" "HEAD~1"))) (%rs-same)))
```
---
    (() ())

### -q says nothing; a detached HEAD moves itself

```git
(%rs-twins " && git checkout -q --detach")
(write (list (%rs-steps (list (list "reset" "-q" "HEAD~1") (list "reset" "--hard" "-q" "main"))) (%rs-same)))
```
---
    (() ())

## paths

### the named paths' entries set from the commit, HEAD where it is

```git
(%rs-twins "")
(write (list (%rs-steps (list (list "reset" "--" "b") (list "reset" "HEAD~1" "a") (list "reset" "-q" "HEAD" "--" "a")
                              (list "reset" "--mixed" "HEAD" "--" "c")))
             (%rs-same)))
```
---
    (() ())

## a merge in progress

### a hard reset gives it up; a soft one is refused

```git
(%rs-twins " && git checkout -q -- a b && git checkout -qb side && printf 'x\\n' > a && git commit -qam side && git checkout -q main && printf 'y\\n' > a && git commit -qam mainx && { git merge side >/dev/null 2>&1; true; }")
(write (list (%rs-steps (list (list "reset" "--soft" "HEAD~1") (list "reset" "--hard")))
             (%rs-same)
             (list (File exists? (Str8 append %rs-d "/x/r/.git/MERGE_HEAD")) (File exists? (Str8 append %rs-d "/g/r/.git/MERGE_HEAD")))))
```
---
    (() () (#f #f))

## refusals

### no such revision, paths with --hard or --soft, a bad tree

```git
(%rs-twins "")
(write (list (%rs-steps (list (list "reset" "nonsense") (list "reset" "HEAD~5") (list "reset" "--hard" "--" "a")
                              (list "reset" "--soft" "--" "a") (list "reset" "nope" "--" "a")))
             (%rs-same)))
```
---
    (() ())

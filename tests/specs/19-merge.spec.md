# @weight 4
# @timeout-scale 2

merge and pull by fast-forward.  git makes a source and clones it twice,
into x/w and g/w; x-git acts in the first and git in the second, and what
each prints -- standard output and standard error apart -- and leaves --
the refs, ORIG_HEAD, the index, the files -- is compared.  Commits carry
a fixed date, so the twins name the same objects.  git's `hint:` lines
come and go with its advice settings, so they are left out.

## merge

### a fast-forward: a file changed, one made, one deleted

```git
(def %mp-dir (fn (_) (def t (File temp "/tmp/x-git-mp-")) (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t)))
(def %mp-env "export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' GIT_AUTHOR_NAME=A GIT_AUTHOR_EMAIL=a@b.c GIT_COMMITTER_NAME=A GIT_COMMITTER_EMAIL=a@b.c; ")
(def %mp-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append %mp-env "cd \"$0\" && " script) dir))))
(def %mp-plain (fn (_ s) (Str8 join "\n" (List filter (fn (_ l) (not (Str8 starts? "hint:" l))) (Str8 split "\n" s)))))
; x-git's answer as (STATUS OUT ERR)
(def %mp-x
  (fn (_ dir . ops)
    (def r (git-run (git-plan (pair "-C" (pair dir ops)))))
    (def text (first (rest r)))
    (def more (rest (rest (rest r))))
    (if (eq? (first r) (lit out))
      (list (first (rest (rest r))) text "")
      (list (first (rest (rest r))) (if (null? more) "" (first more)) (%mp-plain text)))))
; git's, the same way
(def %mp-g
  (fn (_ dir . ops)
    (def err (Str8 append dir "/../git.err"))
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair (Str8 append "cd \"$0\" && exec git \"$@\" 2>\"$0/../git.err\"") (pair dir ops))))))
    (list (first r) (rest r) (%mp-plain (File read-all err)))))
(def %mp-d (%mp-dir))
(%mp-sh %mp-d "git init -q -b main src && cd src && printf 'one\\n' > f && printf 'old\\n' > gone && git add . && git commit -qm one && cd .. && mkdir x g && git clone -q src x/w && git clone -q src g/w")
(def %mp-src (Str8 append %mp-d "/src"))
(def %mp-xw (Str8 append %mp-d "/x/w"))
(def %mp-gw (Str8 append %mp-d "/g/w"))
(def %mp-both (fn (_ script) (do (%mp-sh %mp-xw script) (%mp-sh %mp-gw script))))
(def %mp-same?
  (fn (_)
    (and (equal? (git-oracle-in %mp-xw "for-each-ref") (git-oracle-in %mp-gw "for-each-ref"))
         (equal? (git-oracle-in %mp-xw "status" "--porcelain") (git-oracle-in %mp-gw "status" "--porcelain"))
         (equal? (git-oracle-in %mp-xw "ls-files" "-s") (git-oracle-in %mp-gw "ls-files" "-s"))
         (equal? (git-oracle-in %mp-xw "rev-parse" "HEAD") (git-oracle-in %mp-gw "rev-parse" "HEAD")))))
(%mp-sh %mp-src "printf 'two\\n' >> f && printf 'new\\n' > g && git rm -q gone && git add . && git commit -qm two")
(%mp-both "git fetch -q")
(def %mp-x1 (%mp-x %mp-xw "merge" "origin/main"))
(def %mp-g1 (%mp-g %mp-gw "merge" "origin/main"))
(write (list (equal? %mp-x1 %mp-g1) (first %mp-x1) (%mp-same?)
             (equal? (git-oracle-in %mp-xw "rev-parse" "ORIG_HEAD") (git-oracle-in %mp-gw "rev-parse" "ORIG_HEAD"))
             (File read-all (Str8 append %mp-xw "/g"))
             (File exists? (Str8 append %mp-xw "/gone"))))
```
---
    (#t 0 #t #t "new\n" #f)

### already up to date, and a name that is no commit

```git
(write (list (equal? (%mp-x %mp-xw "merge" "origin/main") (%mp-g %mp-gw "merge" "origin/main"))
             (%mp-x %mp-xw "merge" "origin/main")
             (equal? (%mp-x %mp-xw "merge" "nosuch") (%mp-g %mp-gw "merge" "nosuch"))
             (first (%mp-x %mp-xw "merge" "nosuch"))))
```
---
    (#t (0 "Already up to date.\n" "") #t 1)

### no commit named: the branch's upstream

```git
(%mp-sh %mp-src "printf 'three\\n' >> f && git commit -qam three")
(%mp-both "git fetch -q")
(def %mp-x2 (%mp-x %mp-xw "merge"))
(write (list (equal? %mp-x2 (%mp-g %mp-gw "merge")) (first %mp-x2) (%mp-same?)))
```
---
    (#t 0 #t)

### a change of the working directory's own in the way stops it, and nothing moves

```git
(%mp-sh %mp-src "printf 'four\\n' >> f && git commit -qam four")
(%mp-both "git fetch -q && printf 'mine\\n' >> f")
(def %mp-x3 (%mp-x %mp-xw "merge" "origin/main"))
(write (list (equal? %mp-x3 (%mp-g %mp-gw "merge" "origin/main")) (first %mp-x3) (%mp-same?)
             (Str8 includes? "mine" (File read-all (Str8 append %mp-xw "/f")))))
```
---
    (#t 1 #t #t)

### histories that have diverged are refused, as --ff-only refuses them

```git
(%mp-both "git checkout -q -- f && git commit -q --allow-empty -m local")
(def %mp-x4 (%mp-x %mp-xw "merge" "--ff-only" "origin/main"))
(write (list (equal? %mp-x4 (%mp-g %mp-gw "merge" "--ff-only" "origin/main")) %mp-x4 (%mp-same?)))
```
---
    (#t (128 "" "fatal: Not possible to fast-forward, aborting.\n") #t)

## pull

### a fetch, then a fast-forward

```git
(%mp-both "git reset -q --hard origin/main~1")
(%mp-sh %mp-src "printf 'five\\n' >> f && git commit -qam five")
(def %mp-x5 (%mp-x %mp-xw "pull"))
(def %mp-g5 (%mp-g %mp-gw "pull"))
(write (list (equal? %mp-x5 %mp-g5) (first %mp-x5) (%mp-same?)
             (str=? (File read-all (Str8 append %mp-xw "/.git/FETCH_HEAD")) (File read-all (Str8 append %mp-gw "/.git/FETCH_HEAD")))))
```
---
    (#t 0 #t #t)

### nothing new: already up to date

```git
(write (list (equal? (%mp-x %mp-xw "pull") (%mp-g %mp-gw "pull")) (%mp-x %mp-xw "pull")))
```
---
    (#t (0 "Already up to date.\n" ""))

### diverged: refused in pull's words

```git
(%mp-both "git commit -q --allow-empty -m local")
(%mp-sh %mp-src "printf 'six\\n' >> f && git commit -qam six")
(def %mp-x6 (%mp-x %mp-xw "pull"))
(def %mp-g6 (%mp-g %mp-gw "pull"))
(write (list (equal? %mp-x6 %mp-g6) (first %mp-x6)
             (Str8 includes? "fatal: Need to specify how to reconcile divergent branches." (first (rest (rest %mp-x6))))
             (%mp-same?)))
```
---
    (#t 128 #t #t)

### a branch with no upstream: neither pull nor a bare merge knows what to take

```git
(%mp-both "git checkout -q -b topic")
(def %mp-x7 (%mp-x %mp-xw "pull"))
(def %mp-x8 (%mp-x %mp-xw "merge"))
(write (list (equal? %mp-x7 (%mp-g %mp-gw "pull")) (first %mp-x7)
             (equal? %mp-x8 (%mp-g %mp-gw "merge")) %mp-x8))
```
---
    (#t 1 #t (128 "" "fatal: No remote for the current branch.\n"))

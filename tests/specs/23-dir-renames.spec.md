# @weight 4
# @timeout-scale 3

Merges across a renamed directory.  Each case starts from a fresh source
holding old/ (three files, and old/sub/s) and keep, cloned twice into
x/w and g/w; the source and both twins commit the same changes at the
same dates, and x-git merges in one twin and git in the other.  What
each prints -- standard output and error apart -- and leaves -- the
commit, the index with its stages, the status, the files, MERGE_MSG --
is compared.  git's `hint:` lines, its "Please commit your changes"
advice and standard error's empty lines are left out.

## a file added to a renamed directory

### theirs renamed old to new, ours added old/d: moved, in conflict

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "A") (pair "GIT_COMMITTER_EMAIL" "a@b.c") (pair "GIT_COMMITTER_DATE" "1767225600 +0000")))
(def %dr-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
(def %dr-plain
  (fn (_ s)
    (def kept (List filter (fn (_ l) (not (or (= (Str8 length l) 0) (Str8 starts? "hint:" l) (Str8 starts? "Please commit your changes" l)))) (Str8 split "\n" s)))
    (Str8 join "" (List map (fn (_ l) (Str8 append l "\n")) kept))))
(def %dr-x
  (fn (_ dir . ops)
    (def r (git-run (git-plan (pair "-C" (pair dir ops)))))
    (def text (first (rest r)))
    (def more (rest (rest (rest r))))
    (if (eq? (first r) (lit out))
      (list (first (rest (rest r))) text "")
      (list (first (rest (rest r))) (if (null? more) "" (first more)) (%dr-plain text)))))
(def %dr-g
  (fn (_ dir . ops)
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git \"$@\" 2>\"$0/../git.err\"" (pair dir ops))))))
    (list (first r) (rest r) (%dr-plain (File read-all (Str8 append dir "/../git.err"))))))
(def %dr-d ())
(def %dr-xw ())
(def %dr-gw ())
; a fresh source and twins; theirs made in the source, ours in both twins
(def %dr-case
  (fn (_ theirs ours)
    (def t (File temp "/tmp/x-git-dr-"))
    (File close (first t)) (File unlink (rest t)) (File mkdir (rest t))
    (set! %dr-d (rest t))
    (set! %dr-xw (Str8 append %dr-d "/x/w"))
    (set! %dr-gw (Str8 append %dr-d "/g/w"))
    (%dr-sh %dr-d (Str8 append "git init -q -b main src && cd src && mkdir -p old/sub"
                    " && for f in a b c; do seq 1 20 | sed \"s/^/$f /\" > old/$f; done"
                    " && seq 1 20 | sed 's/^/s /' > old/sub/s && seq 101 120 > keep"
                    " && git add . && git commit -qm base && cd .. && mkdir x g && git clone -q src x/w && git clone -q src g/w"))
    (%dr-sh (Str8 append %dr-d "/src") (Str8 append theirs " && git commit -qm theirs"))
    (%dr-sh %dr-xw (Str8 append ours " && git commit -qm ours && git fetch -q"))
    (%dr-sh %dr-gw (Str8 append ours " && git commit -qm ours && git fetch -q"))
    (list (%dr-x %dr-xw "merge" "origin/main") (%dr-g %dr-gw "merge" "origin/main"))))
(def %dr-file (fn (_ dir path) (let ((p (Str8 append dir "/" path))) (if (File exists? p) (File read-all p) ()))))
(def %dr-same?
  (fn (_ . paths)
    (and (equal? (git-oracle-in %dr-xw "rev-parse" "HEAD") (git-oracle-in %dr-gw "rev-parse" "HEAD"))
         (equal? (git-oracle-in %dr-xw "ls-files" "-s") (git-oracle-in %dr-gw "ls-files" "-s"))
         (equal? (git-oracle-in %dr-xw "status" "--porcelain") (git-oracle-in %dr-gw "status" "--porcelain"))
         (equal? (%dr-file %dr-xw ".git/MERGE_MSG") (%dr-file %dr-gw ".git/MERGE_MSG"))
         (List all? (fn (_ p) (equal? (%dr-file %dr-xw p) (%dr-file %dr-gw p))) paths))))
(def %dr-add-d "seq 1 20 | sed 's/^/d /' > old/d && git add old/d")
(def %dr-1 (%dr-case "git mv old new" %dr-add-d))
(write (list (equal? (first %dr-1) (first (rest %dr-1))) (first (first %dr-1)) (%dr-same? "old/d" "new/d")
             (rest (git-oracle-in %dr-xw "status" "--porcelain"))))
```
---
    (#t 1 #t "R  old/a -> new/a\nR  old/b -> new/b\nR  old/c -> new/c\nAU new/d\nR  old/sub/s -> new/sub/s\nD  old/d\n")

### ours renamed old to new, theirs added old/d: moved, in conflict on their side

```git
(def %dr-2 (%dr-case %dr-add-d "git mv old new"))
(write (list (equal? (first %dr-2) (first (rest %dr-2))) (first (first %dr-2)) (%dr-same? "old/d" "new/d")
             (rest (git-oracle-in %dr-xw "status" "--porcelain"))))
```
---
    (#t 1 #t "UA new/d\n")

### a file added under a subdirectory follows it

```git
(def %dr-3 (%dr-case "git mv old new" "seq 1 20 | sed 's/^/t /' > old/sub/t && git add old/sub/t"))
(write (list (equal? (first %dr-3) (first (rest %dr-3))) (first (first %dr-3)) (%dr-same? "old/sub/t" "new/sub/t")))
```
---
    (#t 1 #t)

### a file ours renamed into old follows it too

```git
(def %dr-4 (%dr-case "git mv old new" "git mv keep old/keep"))
(write (list (equal? (first %dr-4) (first (rest %dr-4))) (first (first %dr-4)) (%dr-same? "keep" "old/keep" "new/keep")))
```
---
    (#t 1 #t)

## as merge.directoryRenames says

### true: moved, and the merge made

```git
(def %dr-5 (%dr-case "git mv old new" (Str8 append "git config merge.directoryRenames true && " %dr-add-d)))
(write (list (equal? (first %dr-5) (first (rest %dr-5))) (first (first %dr-5)) (%dr-same? "old/d" "new/d")))
```
---
    (#t 0 #t)

### false: left where it was added

```git
(def %dr-6 (%dr-case "git mv old new" (Str8 append "git config merge.directoryRenames false && " %dr-add-d)))
(write (list (equal? (first %dr-6) (first (rest %dr-6))) (first (first %dr-6)) (%dr-same? "old/d" "new/d")))
```
---
    (#t 0 #t)

## no directory rename

### some of old moved, the rest kept: nothing follows

```git
(def %dr-7 (%dr-case "mkdir new && git mv old/a old/b new/" %dr-add-d))
(write (list (equal? (first %dr-7) (first (rest %dr-7))) (first (first %dr-7)) (%dr-same? "old/d" "new/d")))
```
---
    (#t 0 #t)

### old split two ways: the merge stops, with nothing in conflict

```git
(def %dr-8 (%dr-case "mkdir x y && git mv old/a old/b x/ && git mv old/c old/sub y/" %dr-add-d))
(write (list (equal? (first %dr-8) (first (rest %dr-8))) (first (first %dr-8)) (%dr-same? "old/d")
             (equal? (git-oracle-in %dr-xw "status") (git-oracle-in %dr-gw "status"))))
```
---
    (#t 1 #t #t)

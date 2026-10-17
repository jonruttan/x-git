# @weight 4
# @timeout-scale 3

merges across renames.  Each case starts from a fresh source with two
files, a (twenty numbered lines) and keep, cloned twice into x/w and
g/w; the source and both twins commit the same changes at the same
dates, and x-git merges in one twin and git in the other.  What each
prints -- standard output and error apart -- and leaves -- the commit, the
files, the index with its stages, the status -- is compared.  git's
`hint:` lines, its "Please commit your changes" advice and standard
error's empty lines are left out.

## renames found

### theirs renamed a to b, ours changed a: the change lands in b

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "A") (pair "GIT_COMMITTER_EMAIL" "a@b.c") (pair "GIT_COMMITTER_DATE" "1767225600 +0000")))
(def %rn-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
(def %rn-plain
  (fn (_ s)
    (def kept (List filter (fn (_ l) (not (or (= (Str8 length l) 0) (Str8 starts? "hint:" l) (Str8 starts? "Please commit your changes" l)))) (Str8 split "\n" s)))
    (Str8 join "" (List map (fn (_ l) (Str8 append l "\n")) kept))))
(def %rn-x
  (fn (_ dir . ops)
    (def r (git-run (git-plan (pair "-C" (pair dir ops)))))
    (def text (first (rest r)))
    (def more (rest (rest (rest r))))
    (if (eq? (first r) (lit out))
      (list (first (rest (rest r))) text "")
      (list (first (rest (rest r))) (if (null? more) "" (first more)) (%rn-plain text)))))
(def %rn-g
  (fn (_ dir . ops)
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git \"$@\" 2>\"$0/../git.err\"" (pair dir ops))))))
    (list (first r) (rest r) (%rn-plain (File read-all (Str8 append dir "/../git.err"))))))
(def %rn-d ())
(def %rn-xw ())
(def %rn-gw ())
; a fresh source and twins; theirs made in the source, ours in both twins
(def %rn-case
  (fn (_ theirs ours)
    (def t (File temp "/tmp/x-git-rn-"))
    (File close (first t)) (File unlink (rest t)) (File mkdir (rest t))
    (set! %rn-d (rest t))
    (set! %rn-xw (Str8 append %rn-d "/x/w"))
    (set! %rn-gw (Str8 append %rn-d "/g/w"))
    (%rn-sh %rn-d "git init -q -b main src && cd src && seq 1 20 > a && seq 101 120 > keep && git add . && git commit -qm base && cd .. && mkdir x g && git clone -q src x/w && git clone -q src g/w")
    (%rn-sh (Str8 append %rn-d "/src") (Str8 append theirs " && git commit -qam theirs"))
    (%rn-sh %rn-xw (Str8 append ours " && git commit -qam ours && git fetch -q"))
    (%rn-sh %rn-gw (Str8 append ours " && git commit -qam ours && git fetch -q"))
    (list (%rn-x %rn-xw "merge" "origin/main") (%rn-g %rn-gw "merge" "origin/main"))))
(def %rn-file (fn (_ dir path) (let ((p (Str8 append dir "/" path))) (if (File exists? p) (File read-all p) ()))))
(def %rn-same?
  (fn (_ . paths)
    (and (equal? (git-oracle-in %rn-xw "rev-parse" "HEAD") (git-oracle-in %rn-gw "rev-parse" "HEAD"))
         (equal? (git-oracle-in %rn-xw "ls-files" "-s") (git-oracle-in %rn-gw "ls-files" "-s"))
         (equal? (git-oracle-in %rn-xw "status" "--porcelain") (git-oracle-in %rn-gw "status" "--porcelain"))
         (List all? (fn (_ p) (equal? (%rn-file %rn-xw p) (%rn-file %rn-gw p))) paths))))
(def %rn-1 (%rn-case "git mv a b" "sed -i.bak 's/^3$/three/' a && rm a.bak"))
(write (list (equal? (first %rn-1) (first (rest %rn-1))) (first (first %rn-1)) (%rn-same? "a" "b")
             (rest (git-oracle-in %rn-xw "log" "-1" "--format=%s"))))
```
---
    (#t 0 #t "Merge remote-tracking branch 'origin/main'\n")

### ours renamed a to b, theirs changed a: the change lands in b

```git
(def %rn-2 (%rn-case "sed -i.bak 's/^3$/three/' a && rm a.bak" "git mv a b"))
(write (list (equal? (first %rn-2) (first (rest %rn-2))) (first (first %rn-2)) (%rn-same? "a" "b")))
```
---
    (#t 0 #t)

### both renamed a to b and changed different lines: merged there

```git
(def %rn-3 (%rn-case "git mv a b && sed -i.bak 's/^2$/two/' b && rm b.bak" "git mv a b && sed -i.bak 's/^9$/nine/' b && rm b.bak"))
(write (list (equal? (first %rn-3) (first (rest %rn-3))) (first (first %rn-3)) (%rn-same? "a" "b")))
```
---
    (#t 0 #t)

### a rename with an edit still found: twenty lines, one changed

```git
(def %rn-4 (%rn-case "git mv a b && sed -i.bak 's/^20$/twenty/' b && rm b.bak" "sed -i.bak 's/^3$/three/' a && rm a.bak"))
(write (list (equal? (first %rn-4) (first (rest %rn-4))) (first (first %rn-4)) (%rn-same? "a" "b")))
```
---
    (#t 0 #t)

### too little left alike is no rename: a modify/delete conflict instead

Twelve of twenty lines kept and eight new: under half of the bytes are
the source's, by git's measure.

```git
(def %rn-5 (%rn-case "git mv a b && seq 1 12 > b && seq 201 208 >> b && git add b" "sed -i.bak 's/^3$/three/' a && rm a.bak"))
(write (list (equal? (first %rn-5) (first (rest %rn-5))) (first (first %rn-5)) (%rn-same? "a" "b")))
```
---
    (#t 1 #t)

## conflicts across renames

### the same line changed both ways across a rename: the markers name the paths

```git
(def %rn-6 (%rn-case "git mv a b && sed -i.bak 's/^5$/FIVE-T/' b && rm b.bak" "sed -i.bak 's/^5$/FIVE-O/' a && rm a.bak"))
(write (list (equal? (first %rn-6) (first (rest %rn-6))) (first (first %rn-6)) (%rn-same? "a" "b")
             (Str8 includes? "<<<<<<< HEAD:a\nFIVE-O\n=======\nFIVE-T\n>>>>>>> origin/main:b\n" (%rn-file %rn-xw "b"))))
```
---
    (#t 1 #t #t)

### renamed on one side, deleted on the other

```git
(def %rn-7 (%rn-case "git rm -q a" "git mv a b"))
(write (list (equal? (first %rn-7) (first (rest %rn-7))) (first %rn-7) (%rn-same? "a" "b")
             (equal? (%rn-file %rn-xw ".git/MERGE_MSG") (%rn-file %rn-gw ".git/MERGE_MSG"))))
```
---
    (#t (1 "CONFLICT (rename/delete): a renamed to b in HEAD, but deleted in origin/main.\nAutomatic merge failed; fix conflicts and then commit the result.\n" "") #t #t)

### renamed both ways, to two names

```git
(def %rn-8 (%rn-case "git mv a b" "git mv a c"))
(write (list (equal? (first %rn-8) (first (rest %rn-8))) (first %rn-8) (%rn-same? "a" "b" "c")))
```
---
    (#t (1 "CONFLICT (rename/rename): a renamed to c in HEAD and to b in origin/main.\nAutomatic merge failed; fix conflicts and then commit the result.\n" "") #t)

## the diffstat

### a fast-forward over a rename and an edit, into a directory

```git
(%rn-case "true" "true")
(%rn-sh (Str8 append %rn-d "/src") "mkdir d && git mv a d/a2 && sed -i.bak 's/^7$/seven/' d/a2 && rm d/a2.bak && git add . && git commit -qm moved")
(%rn-sh %rn-xw "git fetch -q")
(%rn-sh %rn-gw "git fetch -q")
(def %rn-9 (list (%rn-x %rn-xw "merge" "origin/main") (%rn-g %rn-gw "merge" "origin/main")))
(write (list (equal? (first %rn-9) (first (rest %rn-9))) (first (first %rn-9))))
```
---
    (#t 0)

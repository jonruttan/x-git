# @weight 4
# @timeout-scale 3

merges that need a merge commit: diverged histories merged from their
merge base.  git makes a source and clones it twice, into x/w and g/w;
both twins commit the same changes with the same dates, so they name the
same objects; x-git merges in the first and git in the second, and what
each prints -- standard output and error apart -- and leaves -- the merge
commit, byte for byte, the files, the index with its stages, MERGE_HEAD
and MERGE_MSG -- is compared.  git's `hint:` lines, its "Please commit
your changes" advice and standard error's empty lines come and go with
its advice settings, so they are left out.

## a merge commit

### both sides changed f, theirs added t and ours deleted k: merged clean

```git
(def %m3-env (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
                   (pair "GIT_COMMITTER_NAME" "A") (pair "GIT_COMMITTER_EMAIL" "a@b.c") (pair "GIT_COMMITTER_DATE" "1767225600 +0000")))
(List for-each (fn (_ e) (Sys setenv (first e) (rest e))) %m3-env)
(def %m3-dir (fn (_) (def t (File temp "/tmp/x-git-m3-")) (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t)))
(def %m3-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
(def %m3-plain
  (fn (_ s)
    (def kept (List filter (fn (_ l) (not (or (= (Str8 length l) 0) (Str8 starts? "hint:" l) (Str8 starts? "Please commit your changes" l)))) (Str8 split "\n" s)))
    (Str8 join "" (List map (fn (_ l) (Str8 append l "\n")) kept))))
(def %m3-x
  (fn (_ dir . ops)
    (def r (git-run (git-plan (pair "-C" (pair dir ops)))))
    (def text (first (rest r)))
    (def more (rest (rest (rest r))))
    (if (eq? (first r) (lit out))
      (list (first (rest (rest r))) text "")
      (list (first (rest (rest r))) (if (null? more) "" (first more)) (%m3-plain text)))))
(def %m3-g
  (fn (_ dir . ops)
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git \"$@\" 2>\"$0/../git.err\"" (pair dir ops))))))
    (list (first r) (rest r) (%m3-plain (File read-all (Str8 append dir "/../git.err"))))))
(def %m3-d (%m3-dir))
(%m3-sh %m3-d "git init -q -b main src && cd src && printf '1\\n2\\n3\\n4\\n5\\n6\\n7\\n8\\n9\\n' > f && printf 'k\\n' > k && git add . && git commit -qm base && cd .. && mkdir x g && git clone -q src x/w && git clone -q src g/w")
(def %m3-src (Str8 append %m3-d "/src"))
(def %m3-xw (Str8 append %m3-d "/x/w"))
(def %m3-gw (Str8 append %m3-d "/g/w"))
(def %m3-both (fn (_ script) (do (%m3-sh %m3-xw script) (%m3-sh %m3-gw script))))
(def %m3-file (fn (_ dir path) (let ((p (Str8 append dir "/" path))) (if (File exists? p) (File read-all p) ()))))
(def %m3-same?
  (fn (_ . paths)
    (and (equal? (git-oracle-in %m3-xw "rev-parse" "HEAD") (git-oracle-in %m3-gw "rev-parse" "HEAD"))
         (equal? (git-oracle-in %m3-xw "ls-files" "-s") (git-oracle-in %m3-gw "ls-files" "-s"))
         (equal? (git-oracle-in %m3-xw "status" "--porcelain") (git-oracle-in %m3-gw "status" "--porcelain"))
         (List all? (fn (_ p) (equal? (%m3-file %m3-xw p) (%m3-file %m3-gw p))) paths))))
(%m3-sh %m3-src "sed -i.bak 's/^2$/two/' f && rm f.bak && printf 'theirs\\n' > t && git add . && git commit -qm theirs")
(%m3-both "sed -i.bak 's/^8$/eight/' f && rm f.bak && git rm -q k && git commit -qam ours && git fetch -q")
(def %m3-x1 (%m3-x %m3-xw "merge" "origin/main"))
(def %m3-g1 (%m3-g %m3-gw "merge" "origin/main"))
(write (list (equal? %m3-x1 %m3-g1) (first %m3-x1) (%m3-same? "f" "t" "k")
             (equal? (git-oracle-in %m3-xw "cat-file" "-p" "HEAD") (git-oracle-in %m3-gw "cat-file" "-p" "HEAD"))
             (rest (git-oracle-in %m3-xw "log" "-1" "--format=%s"))
             (List length (Str8 split " " (Str8 trim (rest (git-oracle-in %m3-xw "log" "-1" "--format=%P")))))))
```
---
    (#t 0 #t #t "Merge remote-tracking branch 'origin/main'\n" 2)

## conflicts

### the same line changed both ways: marked, staged 1 2 3, MERGE_HEAD and MERGE_MSG left

```git
(%m3-sh %m3-src "sed -i.bak 's/^5$/FIVE-THEIRS/' f && rm f.bak && git commit -qam c1")
(%m3-both "sed -i.bak 's/^5$/FIVE-OURS/' f && rm f.bak && git commit -qam c2 && git fetch -q")
(def %m3-x2 (%m3-x %m3-xw "merge" "origin/main"))
(def %m3-g2 (%m3-g %m3-gw "merge" "origin/main"))
(write (list (equal? %m3-x2 %m3-g2) %m3-x2 (%m3-same? "f")
             (equal? (%m3-file %m3-xw ".git/MERGE_MSG") (%m3-file %m3-gw ".git/MERGE_MSG"))
             (equal? (%m3-file %m3-xw ".git/MERGE_HEAD") (%m3-file %m3-gw ".git/MERGE_HEAD"))
             (Str8 includes? "<<<<<<< HEAD\nFIVE-OURS\n=======\nFIVE-THEIRS\n>>>>>>> origin/main\n" (%m3-file %m3-xw "f"))
             (Str8 includes? "\tboth modified:   f\n" (rest (git-text-in %m3-xw "status")))))
```
---
    (#t (1 "Auto-merging f\nCONFLICT (content): Merge conflict in f\nAutomatic merge failed; fix conflicts and then commit the result.\n" "") #t #t #t #t #t)

### a commit with paths still in conflict is refused

```git
(write (list (equal? (%m3-x %m3-xw "commit" "-m" "x") (%m3-g %m3-gw "commit" "-m" "x")) (first (%m3-x %m3-xw "commit" "-m" "x"))))
```
---
    (#t 128)

### resolved and added, commit concludes the merge with the message it left

```git
(%m3-both "printf '1\\ntwo\\n3\\n4\\nFIVE\\n6\\n7\\neight\\n9\\n' > f && git add f")
(def %m3-x3 (%m3-x %m3-xw "commit" "--no-edit"))
(def %m3-g3 (%m3-g %m3-gw "commit" "--no-edit"))
(write (list (equal? %m3-x3 %m3-g3) (first %m3-x3) (%m3-same? "f")
             (equal? (git-oracle-in %m3-xw "cat-file" "-p" "HEAD") (git-oracle-in %m3-gw "cat-file" "-p" "HEAD"))
             (File exists? (Str8 append %m3-xw "/.git/MERGE_HEAD"))))
```
---
    (#t 0 #t #t #f)

### deleted on one side and changed on the other, then abandoned with --abort

```git
(%m3-sh %m3-src "git rm -q t && git commit -qm drop")
(%m3-both "printf 'mine\\n' >> t && git commit -qam modt && git fetch -q")
(def %m3-x4 (%m3-x %m3-xw "merge" "origin/main"))
(def %m3-g4 (%m3-g %m3-gw "merge" "origin/main"))
(def %m3-same4 (%m3-same? "t"))
(def %m3-xa (%m3-x %m3-xw "merge" "--abort"))
(def %m3-ga (%m3-g %m3-gw "merge" "--abort"))
(write (list (equal? %m3-x4 %m3-g4) (first %m3-x4) %m3-same4
             (equal? %m3-xa %m3-ga) (%m3-same? "t" "f") (File exists? (Str8 append %m3-xw "/.git/MERGE_HEAD"))
             (equal? (%m3-x %m3-xw "merge" "--abort") (%m3-g %m3-gw "merge" "--abort"))))
```
---
    (#t 1 #t #t #t #f #t)

### the same new path added both ways

Both twins first delete t as theirs did, so its conflict is gone; n's
texts share nothing with t's, so git finds no rename, which x-git does
not look for.

```git
(%m3-both "git rm -q t && git commit -qm drop-t")
(%m3-sh %m3-src "printf 'added by them\\n' > n && git add n && git commit -qm n-theirs")
(%m3-both "printf 'added by us\\n' > n && git add n && git commit -qm n-ours && git fetch -q")
(def %m3-x5 (%m3-x %m3-xw "merge" "origin/main"))
(def %m3-g5 (%m3-g %m3-gw "merge" "origin/main"))
(def %m3-same5 (%m3-same? "n"))
(%m3-x %m3-xw "merge" "--abort")
(%m3-g %m3-gw "merge" "--abort")
(write (list (equal? %m3-x5 %m3-g5) (first %m3-x5) %m3-same5))
```
---
    (#t 1 #t)

### a change of the working directory's own in the way stops the merge

```git
(%m3-both "printf 'dirty\\n' >> n")
(def %m3-x6 (%m3-x %m3-xw "merge" "origin/main"))
(write (list (equal? %m3-x6 (%m3-g %m3-gw "merge" "origin/main")) (first %m3-x6) (%m3-same? "n")))
```
---
    (#t 2 #t)

## pull

### --no-rebase merges what the fetch brought, its message naming the branch and the url

```git
(%m3-both "git checkout -q -- n")
(%m3-sh %m3-src "printf 'pulled\\n' > p && git add p && git commit -qm p")
(%m3-both "git rm -q n && git commit -qm drop-n")
(def %m3-x7 (%m3-x %m3-xw "pull" "--no-rebase"))
(def %m3-g7 (%m3-g %m3-gw "pull" "--no-rebase"))
(write (list (equal? %m3-x7 %m3-g7) (first %m3-x7) (%m3-same? "p" "n")
             (equal? (git-oracle-in %m3-xw "cat-file" "-p" "HEAD") (git-oracle-in %m3-gw "cat-file" "-p" "HEAD"))))
```
---
    (#t 0 #t #t)

### into a branch other than main, the message says so

```git
(%m3-sh %m3-src "printf 'topic\\n' > q && git add q && git commit -qm q")
(%m3-both "git checkout -q -b topic && printf 'local\\n' > r && git add r && git commit -qm r && git fetch -q")
(def %m3-x8 (%m3-x %m3-xw "merge" "origin/main"))
(def %m3-g8 (%m3-g %m3-gw "merge" "origin/main"))
(write (list (equal? %m3-x8 %m3-g8) (first %m3-x8) (%m3-same? "q" "r")
             (rest (git-oracle-in %m3-xw "log" "-1" "--format=%s"))))
```
---
    (#t 0 #t "Merge remote-tracking branch 'origin/main' into topic\n")

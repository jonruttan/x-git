# @weight 3
# @timeout-scale 2

Symbolic links, against git itself.  git keeps a link as itself: a blob
of the text it holds, mode 120000, whatever it points at -- a file, a
directory or nothing.  Each case builds twin repositories, x/r for x-git
and g/r for git, from the same first commit (f and g, two files) and the
same setup, at the same dates; then the same lines run in both, x-git's
in x/r and git's in g/r.  What each prints and exits with is compared,
then what each leaves: the index, the status, and every link in the
working tree with the text it holds.  Each line answers #t when the two
agree, else both answers.

## kept as links

### a link to a file, to a directory and to nothing: added, listed and committed as links

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "C") (pair "GIT_COMMITTER_EMAIL" "c@d.e") (pair "GIT_COMMITTER_DATE" "1767229200 +0000")))
(def %lk-d (let ((t (File temp "/tmp/x-git-lk-"))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t))))
(def %lk-sh (fn (_ dir script) (Proc capture (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
; the twins made afresh, each from the same first commit and setup
(def %lk-twin
  (fn (_ setup)
    (%lk-sh %lk-d "rm -rf x g && mkdir x g")
    (List for-each
      (fn (_ w)
        (%lk-sh (Str8 append %lk-d "/" w)
          (Str8 append "git init -q -b main r && cd r && echo a > f && echo c > g && git add f g && git commit -qm one && " setup)))
      (list "x" "g"))))
; what a twin leaves: the index, the status, its links and what they hold
(def %lk-left
  (fn (_ w)
    (%lk-sh (Str8 append %lk-d "/" w "/r")
      "git ls-files -s && git status --porcelain && find . -path ./.git -prune -o -type l -print | sort | while read l; do echo \"$l -> $(readlink \"$l\")\"; done")))
; a line run in both: #t when the answers and what they leave agree
(def %lk-run
  (fn (_ . ops)
    (let ((x (apply git-text-in (pair (Str8 append %lk-d "/x/r") ops)))
          (g (apply git-oracle-in (pair (Str8 append %lk-d "/g/r") ops))))
      (let ((xl (%lk-left "x")) (gl (%lk-left "g")))
        (if (and (equal? x g) (equal? xl gl)) #t (list ops x g xl gl))))))
(%lk-twin "ln -s f l && ln -s nope d && mkdir dd && echo q > dd/h && ln -s dd ld")
(write (list (%lk-run "status") (%lk-run "status" "-s") (%lk-run "add" "l" "d") (%lk-run "add" "-A")
             (%lk-run "diff" "--cached") (%lk-run "commit" "-m" "links") (%lk-run "status")))
```
---
    (#t #t #t #t #t #t #t)

### a link retargeted: clean until it is, then modified, diffed and committed with -a

```git
(%lk-twin "ln -s f l && git add l && git commit -qm l")
(def %lk-clean (list (%lk-run "status") (%lk-run "diff")))
(%lk-sh (Str8 append %lk-d "/x/r") "ln -sfn g l")
(%lk-sh (Str8 append %lk-d "/g/r") "ln -sfn g l")
(write (list %lk-clean (%lk-run "status" "-s") (%lk-run "diff") (%lk-run "diff" "--stat")
             (%lk-run "commit" "-a" "-m" "re") (%lk-run "show")))
```
---
    ((#t #t) #t #t #t #t #t)

## typechanges

### a link turned into a file and a file into a link: T, typechange, a deletion and a creation

```git
(%lk-twin "ln -s f l && git add l && git commit -qm l && rm l && echo t > l && rm g && ln -s f g")
(write (list (%lk-run "status") (%lk-run "status" "-s") (%lk-run "diff") (%lk-run "diff" "--stat")
             (%lk-run "add" "l") (%lk-run "status") (%lk-run "diff" "--cached")
             (%lk-run "commit" "-a" "-m" "types") (%lk-run "show") (%lk-run "diff" "HEAD~1" "HEAD")))
```
---
    (#t #t #t #t #t #t #t #t #t #t)

## the working tree written

### checkout, merge, reset, cherry-pick, mv, rm, restore and clean leave links as links

```git
(%lk-twin
  (Str8 append "git checkout -qb s && ln -s f l && mkdir dd && echo q > dd/h && ln -s dd ld && ln -s nope d"
    " && git add . && git commit -qm links && git checkout -q main && mkdir ee && echo e > ee/k && ln -s ee le"))
(write (list (%lk-run "checkout" "s") (%lk-run "checkout" "main") (%lk-run "merge" "s")
             (%lk-run "reset" "--hard" "HEAD~1") (%lk-run "cherry-pick" "s")
             (%lk-run "mv" "d" "e") (%lk-run "rm" "l") (%lk-run "reset" "-q" "HEAD" "--" "l") (%lk-run "restore" "l")
             (%lk-run "clean" "-n" "-d") (%lk-run "clean" "-f" "-d")))
(List for-each (fn (_ k) (Sys unsetenv k))
  (list "GIT_AUTHOR_NAME" "GIT_AUTHOR_EMAIL" "GIT_AUTHOR_DATE" "GIT_COMMITTER_NAME" "GIT_COMMITTER_EMAIL" "GIT_COMMITTER_DATE"))
```
---
    (#t #t #t #t #t #t #t #t #t #t #t)

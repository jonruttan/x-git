# @weight 4
# @timeout-scale 3

Cherry-picks and reverts of several commits, against git itself: the
commits named in the order given, a range in git's order, and git's
sequencer kept between the steps in .git/sequencer.  Each case builds
twin repositories as 36-cherry-pick builds them, at the same dates: on
main a first commit of a and d/f, a second that changes a, adds new and
deletes d/f; on side, from the first, a commit by another author that
changes a's last line and adds s, then one that adds t; on conf, from
main, one that changes a's last line another way; on tr, from main, an
empty commit with a trailer and a plain empty one; orph a root of its
own and mm a merge.  side~1 conflicts on main, where it meets main's
change to the line before.  The same lines run in both, x-git's in x/r
and git's in g/r, with GIT_EDITOR=true.  What each prints, standard
output and error apart, and exits with is compared, then what each
leaves: HEAD, its message and author, the index, the status, the files,
the pick's state, the sequencer's files, ORIG_HEAD and HEAD's reflog.
Each line's garbage is collected after it.

## sequences

### a range oldest first, commits named in the order given and each once; a revert's range newest first

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "C") (pair "GIT_COMMITTER_EMAIL" "c@d.e") (pair "GIT_COMMITTER_DATE" "1767229200 +0000")
        (pair "GIT_EDITOR" "true")))
(def %sq-d ())
(def %sq-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
(def %sq-build
  (Str8 append
    "git init -q -b main r && cd r && printf 'a\\nb\\nc\\n' > a && mkdir d && printf 'x\\n' > d/f && git add . && git commit -qm one"
    " && git checkout -qb side && printf 'a\\nb\\nC\\n' > a && printf 's\\n' > s && git add . "
    " && GIT_AUTHOR_NAME=Other GIT_AUTHOR_DATE='1767222000 +0100' git commit -qm 'side change' -m 'body line'"
    " && printf 't\\n' > t && git add t && git commit -qm 'add t'"
    " && git checkout -q main && printf 'a\\nB\\nc\\n' > a && printf 'n\\n' > new && git rm -q d/f && git add . && git commit -qm two"
    " && git checkout -qb conf && printf 'a\\nB\\nQ\\n' > a && git commit -qam conf"
    " && git checkout -qb tr main && git commit -q --allow-empty -m T -m 'Signed-off-by: X <x@y>' && git commit -q --allow-empty -m 'plain empty'"
    " && git checkout -q --orphan orph && git rm -qrf . && printf 'z\\n' > z && git add z && git commit -qm rootz"
    " && git checkout -qb mm side~2 && git merge -q --no-ff -m merged side~1"
    " && git checkout -q main"))
(def %sq-twins
  (fn (_ more)
    (def t (File temp "/tmp/x-git-sq-"))
    (File close (first t)) (File unlink (rest t)) (File mkdir (rest t))
    (set! %sq-d (rest t))
    (%sq-sh %sq-d (Str8 append "mkdir x g && cd x && " %sq-build more " && cd ../../g && " %sq-build more))))
; standard error without git's hint: lines, which an advice.* setting
; (macOS runners turn them off) leaves out
(def %sq-plain
  (fn (_ s)
    (Str8 join "" (List map (fn (_ l) (Str8 append l "\n"))
                    (List filter (fn (_ l) (not (or (= (Str8 length l) 0) (Str8 starts? "hint:" l)))) (Str8 split "\n" s))))))
(def %sq-x
  (fn (_ ops)
    (def r (git-run (git-plan (pair "-C" (pair (Str8 append %sq-d "/x/r") ops)))))
    (def text (first (rest r)))
    (def more (rest (rest (rest r))))
    (if (eq? (first r) (lit out)) (list (first (rest (rest r))) text "")
      (list (first (rest (rest r))) (if (null? more) "" (first more)) (%sq-plain text)))))
; git, asked for the hints x-git always gives, which the macOS runners
; turn off
(def %sq-g
  (fn (_ ops)
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git -c advice.statusHints=true -c advice.commitBeforeMerge=true \"$@\" 2>../git.err" (pair (Str8 append %sq-d "/g/r") ops))))))
    (list (first r) (rest r) (%sq-plain (File read-all (Str8 append %sq-d "/g/git.err"))))))
; the lines whose answers differ, as (OPS X GIT)
(def %sq-steps
  (fn (_ lines)
    (List flat-map
      (fn (_ ops) (let ((x (%sq-x ops)) (g (%sq-g ops))) (do (Heap collect) (if (equal? x g) () (list (list ops x g))))))
      lines)))
; the same shell line run in both
(def %sq-both
  (fn (_ script) (do (%sq-sh (Str8 append %sq-d "/x/r") script) (%sq-sh (Str8 append %sq-d "/g/r") script))))
(def %sq-file (fn (_ side path) (let ((p (Str8 append %sq-d "/" side "/r/" path))) (if (File exists? p) (File read-all p) ()))))
; what differs in what the twins leave
(def %sq-same
  (fn (_)
    (List filter (fn (_ c) (not (equal? (first (rest c)) (first (rest (rest c))))))
      (List append
        (List map (fn (_ args) (list args (apply git-oracle-in (pair (Str8 append %sq-d "/x/r") args)) (apply git-oracle-in (pair (Str8 append %sq-d "/g/r") args))))
          (list (list "rev-parse" "HEAD") (list "log" "-1" "--format=%an <%ae> %ad%n%cn%n%B") (list "ls-files" "-s") (list "status" "--porcelain")))
        (List map (fn (_ p) (list p (%sq-file "x" p) (%sq-file "g" p)))
          (list "a" "s" "t" "z" "new" "d/f" ".git/CHERRY_PICK_HEAD" ".git/REVERT_HEAD" ".git/MERGE_MSG" ".git/ORIG_HEAD"
                ".git/sequencer/head" ".git/sequencer/todo" ".git/sequencer/opts" ".git/sequencer/abort-safety" ".git/logs/HEAD"))))))
(%sq-twins "")
; side's commits picked where they apply cleanly: on b1, from the first commit
(%sq-both "git checkout -qb b1 side~2")
(write (list (%sq-steps (list (list "cherry-pick" "side~2..side") (list "reset" "-q" "--hard" "side~2")
                              (list "cherry-pick" "orph" "side" "side~1" "side") (list "reset" "-q" "--hard" "side~2")
                              (list "cherry-pick" "side~1..side" "orph") (list "reset" "-q" "--hard" "side~2")
                              (list "cherry-pick" "orph" "^main" "side")))
             (%sq-same)
             (%sq-steps (list (list "revert" "--no-edit" "HEAD~3..HEAD") (list "revert" "--no-edit" "HEAD~2" "HEAD~1")))
             (%sq-same)))
```
---
    (() () () ())

### a conflict stops it, and status tells of it; --continue commits it and goes on

```git
(%sq-twins "")
(def %sq-c1 (%sq-steps (list (list "cherry-pick" "side~2..side") (list "status"))))
(def %sq-c2 (%sq-same))
(%sq-both "printf 'a\\nB\\nboth\\n' > a && git add a")
(write (list %sq-c1 %sq-c2 (%sq-steps (list (list "status") (list "cherry-pick" "--continue"))) (%sq-same)))
```
---
    (() () () ())

### --skip leaves a commit out and goes on, --abort goes back where it began, --quit forgets it

```git
(%sq-twins "")
(def %sq-k1 (%sq-steps (list (list "cherry-pick" "side" "side~1" "orph") (list "cherry-pick" "--skip"))))
(def %sq-k2 (%sq-same))
(%sq-both "git reset -q --hard conf~1")
(def %sq-k3 (%sq-steps (list (list "cherry-pick" "side" "side~1" "orph") (list "cherry-pick" "--abort"))))
(def %sq-k4 (%sq-same))
(write (list %sq-k1 %sq-k2 %sq-k3 %sq-k4
             (%sq-steps (list (list "cherry-pick" "side" "side~1" "orph") (list "cherry-pick" "--quit") (list "status")))
             (%sq-same)))
```
---
    (() () () () () ())

### a commit concludes a step, and --continue goes on; with HEAD moved, nothing to skip and --abort leaves it be

```git
(%sq-twins "")
(%sq-steps (list (list "cherry-pick" "side~1" "side" "orph")))
(%sq-both "printf 'a\\nB\\nboth\\n' > a && git add a")
(def %sq-m1 (%sq-steps (list (list "commit" "-m" "mine") (list "status") (list "cherry-pick" "--skip")
                             (list "revert" "--skip") (list "revert" "--continue"))))
(def %sq-m2 (%sq-same))
(def %sq-m3 (%sq-steps (list (list "cherry-pick" "--continue"))))
(def %sq-m4 (%sq-same))
(%sq-steps (list (list "cherry-pick" "-x" "side~1" "orph")))
(%sq-both "git reset -q --hard && git commit -q --allow-empty -m moved")
(write (list %sq-m1 %sq-m2 %sq-m3 %sq-m4 (%sq-steps (list (list "status") (list "cherry-pick" "--abort") (list "status"))) (%sq-same)))
```
---
    (() () () () () ())

### a merge in a range stops it with nothing stopped, for status to tell of and --skip to pass

```git
(%sq-twins "")
(%sq-both "git checkout -qb b1 side~2")
(write (list (%sq-steps (list (list "cherry-pick" "main..mm") (list "status") (list "cherry-pick" "--skip"))) (%sq-same)))
```
---
    (() ())

## options

### -n stages them all, each merged onto what is staged; -x notes each; --ff fast-forwards those it can

```git
(%sq-twins "")
(%sq-both "git checkout -qb b1 side~2")
(def %sq-o1 (%sq-steps (list (list "cherry-pick" "-n" "side~2..side" "orph") (list "status"))))
(def %sq-o2 (%sq-same))
(%sq-both "git reset -q --hard")
(def %sq-o3 (%sq-steps (list (list "cherry-pick" "-x" "side~2..side"))))
(def %sq-o4 (%sq-same))
(%sq-both "git reset -q --hard side~2")
(write (list %sq-o1 %sq-o2 %sq-o3 %sq-o4 (%sq-steps (list (list "cherry-pick" "--ff" "side~1" "side" "orph"))) (%sq-same)))
```
---
    (() () () () () ())

### -n's conflict stops it, its options kept; empty commits stop it unless --allow-empty

```git
(%sq-twins "")
(def %sq-n1 (%sq-steps (list (list "cherry-pick" "-n" "-x" "side" "side~1" "orph") (list "status") (list "cherry-pick" "--continue"))))
(def %sq-n2 (%sq-same))
(def %sq-n3 (%sq-steps (list (list "cherry-pick" "--abort") (list "cherry-pick" "conf~1..tr" "orph") (list "cherry-pick" "--skip"))))
(def %sq-n4 (%sq-same))
(%sq-steps (list (list "cherry-pick" "--abort")))
(write (list %sq-n1 %sq-n2 %sq-n3 %sq-n4
             (%sq-steps (list (list "cherry-pick" "--allow-empty" "conf~1..tr" "orph") (list "cherry-pick" "--skip"))) (%sq-same)))
```
---
    (() () () () () ())

## reverts

### a conflict stops a revert's sequence; one that changes nothing stops it too; -n stages each

```git
(%sq-twins " && git checkout -q side && printf 'a\\nb\\nX\\n' > a && git commit -qam x")
(def %sq-r1 (%sq-steps (list (list "revert" "--no-edit" "HEAD~1" "HEAD~2") (list "status") (list "revert" "--skip"))))
(def %sq-r2 (%sq-same))
(def %sq-r3 (%sq-steps (list (list "revert" "--no-edit" "side~3..side~1") (list "status") (list "revert" "--skip"))))
(def %sq-r4 (%sq-same))
(%sq-both "git reset -q --hard side~2")
(write (list %sq-r1 %sq-r2 %sq-r3 %sq-r4 (%sq-steps (list (list "revert" "-n" "HEAD") (list "revert" "-n" "HEAD~1") (list "status"))) (%sq-same)))
```
---
    (() () () () () ())

## refusals

### already in progress, no commits, a bad revision, --ff with -x, -n or -e, the other command's sequence

```git
(%sq-twins "")
(def %sq-f1 (%sq-steps (list (list "cherry-pick" "side..side") (list "cherry-pick" "nope..side") (list "cherry-pick" "^nope" "side")
                             (list "cherry-pick" "side" "nope") (list "cherry-pick" "--ff" "-x" "side")
                             (list "cherry-pick" "--ff" "-n" "side") (list "cherry-pick" "--ff" "-e" "side"))))
(def %sq-f2 (%sq-same))
(%sq-steps (list (list "cherry-pick" "side~1" "side")))
(write (list %sq-f1 %sq-f2
             (%sq-steps (list (list "cherry-pick" "side~2..side") (list "revert" "side~2..side") (list "revert" "--continue")
                              (list "revert" "--skip") (list "cherry-pick" "orph")))
             (%sq-same)))
```
---
    (() () () ())

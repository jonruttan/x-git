# @weight 4
# @timeout-scale 3

git cherry-pick, against git itself.  Each case builds twin repositories
the same way, at the same dates: on main a first commit of a and d/f, a
second that changes a, adds new and deletes d/f; on side, from the
first, a commit by another author, dated an hour east, that changes a's
last line and adds s, then one that adds t; on conf, from main, one
that changes a's last line another way; on tr, from main, an empty
commit with a trailer and a plain empty one; orph a root of its own and
mm a merge.  The same lines run in both, x-git's in x/r and git's in
g/r, with GIT_EDITOR=true so an edit leaves the message as git wrote
it.  What each prints, standard output and error apart, and exits with
is compared, then what each leaves: HEAD, its message and author, the
index, the status, the files, the pick's state and HEAD's reflog.  Each
line's garbage is collected after it.

## picking

### a clean pick keeps its author and message; -x notes it; --ff moves the branch

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "C") (pair "GIT_COMMITTER_EMAIL" "c@d.e") (pair "GIT_COMMITTER_DATE" "1767229200 +0000")
        (pair "GIT_EDITOR" "true")))
(def %cp-d ())
(def %cp-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
(def %cp-build
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
(def %cp-twins
  (fn (_ more)
    (def t (File temp "/tmp/x-git-cp-"))
    (File close (first t)) (File unlink (rest t)) (File mkdir (rest t))
    (set! %cp-d (rest t))
    (%cp-sh %cp-d (Str8 append "mkdir x g && cd x && " %cp-build more " && cd ../../g && " %cp-build more))))
; standard error without git's hint: lines, which an advice.* setting
; (macOS runners turn them off) leaves out
(def %cp-plain
  (fn (_ s)
    (Str8 join "" (List map (fn (_ l) (Str8 append l "\n"))
                    (List filter (fn (_ l) (not (or (= (Str8 length l) 0) (Str8 starts? "hint:" l)))) (Str8 split "\n" s))))))
(def %cp-x
  (fn (_ ops)
    (def r (git-run (git-plan (pair "-C" (pair (Str8 append %cp-d "/x/r") ops)))))
    (def text (first (rest r)))
    (def more (rest (rest (rest r))))
    (if (eq? (first r) (lit out)) (list (first (rest (rest r))) text "")
      (list (first (rest (rest r))) (if (null? more) "" (first more)) (%cp-plain text)))))
(def %cp-g
  (fn (_ ops)
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git \"$@\" 2>../git.err" (pair (Str8 append %cp-d "/g/r") ops))))))
    (list (first r) (rest r) (%cp-plain (File read-all (Str8 append %cp-d "/g/git.err"))))))
; the lines whose answers differ, as (OPS X GIT)
(def %cp-steps
  (fn (_ lines)
    (List flat-map
      (fn (_ ops) (let ((x (%cp-x ops)) (g (%cp-g ops))) (do (Heap collect) (if (equal? x g) () (list (list ops x g))))))
      lines)))
; the same shell line run in both
(def %cp-both
  (fn (_ script) (do (%cp-sh (Str8 append %cp-d "/x/r") script) (%cp-sh (Str8 append %cp-d "/g/r") script))))
(def %cp-file (fn (_ side path) (let ((p (Str8 append %cp-d "/" side "/r/" path))) (if (File exists? p) (File read-all p) ()))))
; what differs in what the twins leave
(def %cp-same
  (fn (_)
    (List filter (fn (_ c) (not (equal? (first (rest c)) (first (rest (rest c))))))
      (List append
        (List map (fn (_ args) (list args (apply git-oracle-in (pair (Str8 append %cp-d "/x/r") args)) (apply git-oracle-in (pair (Str8 append %cp-d "/g/r") args))))
          (list (list "rev-parse" "HEAD") (list "log" "-1" "--format=%an <%ae> %ad%n%cn%n%B") (list "ls-files" "-s") (list "status" "--porcelain")))
        (List map (fn (_ p) (list p (%cp-file "x" p) (%cp-file "g" p)))
          (list "a" "s" "t" "z" "new" "d/f" ".git/CHERRY_PICK_HEAD" ".git/MERGE_MSG" ".git/logs/HEAD"))))))
(%cp-twins "")
; side~1 picked where it applies cleanly: on b1, from the first commit
(%cp-both "git checkout -qb b1 side~2")
(write (list (%cp-steps (list (list "cherry-pick" "side~1") (list "reset" "-q" "--hard" "HEAD~1")
                              (list "cherry-pick" "-x" "side~1") (list "cherry-pick" "side")))
             (%cp-same)
             (%cp-steps (list (list "checkout" "-b" "ffb" "side~2") (list "cherry-pick" "--ff" "side~1")))
             (%cp-same)))
```
---
    (() () () ())

### -n: the change staged and the message left, nothing committed

```git
(%cp-twins "")
(%cp-both "git checkout -qb b1 side~2")
(write (list (%cp-steps (list (list "cherry-pick" "-n" "side~1") (list "status"))) (%cp-same)))
```
---
    (() ())

### a root commit, and an edited message

```git
(%cp-twins "")
(%cp-both "git checkout -qb b1 side~2")
(Sys setenv "GIT_EDITOR" "printf 'edited\\n' >")
(def %cp-e (%cp-steps (list (list "cherry-pick" "orph") (list "cherry-pick" "-e" "side~1"))))
(Sys setenv "GIT_EDITOR" "true")
(write (list %cp-e (%cp-same)))
```
---
    (() ())

## conflicts

### a conflict stops it; --continue commits it by its author once resolved

```git
(%cp-twins "")
(def %cp-c1 (%cp-steps (list (list "cherry-pick" "side~1") (list "status"))))
(def %cp-c2 (%cp-same))
(%cp-both "printf 'a\\nB\\nboth\\n' > a && git add a")
(write (list %cp-c1 %cp-c2 (%cp-steps (list (list "status") (list "cherry-pick" "--continue"))) (%cp-same)))
```
---
    (() () () ())

### or a commit concludes it, by its author with its own message

```git
(%cp-twins "")
(%cp-steps (list (list "cherry-pick" "side~1")))
(%cp-both "printf 'a\\nB\\nboth\\n' > a && git add a")
(write (list (%cp-steps (list (list "commit" "-m" "my msg"))) (%cp-same)))
```
---
    (() ())

### --abort and --skip give it up, --quit forgets it; -n's conflict leaves no pick

```git
(%cp-twins "")
(def %cp-q
  (list (%cp-steps (list (list "cherry-pick" "side~1") (list "cherry-pick" "--abort")))
        (%cp-same)
        (%cp-steps (list (list "cherry-pick" "side~1") (list "cherry-pick" "--skip")))
        (%cp-same)
        (%cp-steps (list (list "cherry-pick" "side~1") (list "cherry-pick" "--quit") (list "status")))
        (%cp-same)))
(%cp-both "git reset -q --hard")
(write (List append %cp-q
  (list (%cp-steps (list (list "cherry-pick" "-n" "side~1") (list "status") (list "cherry-pick" "--abort"))) (%cp-same))))
```
---
    (() () () () () () () ())

## empty picks

### a pick that changes nothing stops; --allow-empty keeps a commit that changed nothing itself

```git
(%cp-twins "")
(write (list (%cp-steps (list (list "cherry-pick" "-x" "tr~1") (list "cherry-pick" "tr") (list "status") (list "cherry-pick" "--skip")))
             (%cp-same)
             (%cp-steps (list (list "cherry-pick" "--allow-empty" "-x" "tr~1") (list "cherry-pick" "side") (list "cherry-pick" "side")))
             (%cp-same)))
```
---
    (() () () ())

## refusals

### nothing in progress, no such commit, a merge, staged changes, unmerged files

```git
(%cp-twins "")
(def %cp-r1 (%cp-steps (list (list "cherry-pick" "--continue") (list "cherry-pick" "--abort") (list "cherry-pick" "--skip")
                              (list "cherry-pick" "nope") (list "cherry-pick" "mm"))))
(%cp-both "printf 'z\\n' > new && git add new")
(def %cp-r2 (%cp-steps (list (list "cherry-pick" "side~1"))))
(%cp-both "git reset -q --hard && printf 'dirty\\n' >> a")
(def %cp-r3 (%cp-steps (list (list "cherry-pick" "side~1"))))
(%cp-both "git checkout -q a")
; side~1 conflicts on main, and leaves a unmerged
(%cp-steps (list (list "cherry-pick" "side~1")))
(write (list %cp-r1 %cp-r2 %cp-r3 (%cp-steps (list (list "cherry-pick" "side"))) (%cp-same)))
```
---
    (() () () () ())

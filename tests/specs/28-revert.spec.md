# @weight 4
# @timeout-scale 3

git revert, against git itself.  Each case builds twin repositories the
same way, at the same dates -- a first commit of a and d/f, a second
that changes a, adds new and deletes d/f, then a third that changes a
again -- and runs the same lines in both, x-git's in x/r and git's in
g/r, with GIT_EDITOR=true so an edit leaves the message as git wrote
it.  What each prints, standard output and error apart, and exits with
is compared, then what each leaves: HEAD and its message, the index,
the status, the files, and the revert state.  Each line's garbage is
collected after it.

## reverting

### a clean revert, edited or not; a revert of a revert reapplies

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "A") (pair "GIT_COMMITTER_EMAIL" "a@b.c") (pair "GIT_COMMITTER_DATE" "1767225600 +0000")
        (pair "GIT_EDITOR" "true")))
(def %rv-d ())
(def %rv-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
(def %rv-build
  (Str8 append
    "git init -q -b main r && cd r && printf 'a\\nb\\nc\\n' > a && mkdir d && printf 'x\\n' > d/f && git add . && git commit -qm one"
    " && printf 'a\\nB\\nc\\n' > a && printf 'n\\n' > new && git rm -q d/f && git add . && git commit -qm two -m 'body line'"))
(def %rv-twins
  (fn (_ more)
    (def t (File temp "/tmp/x-git-rv-"))
    (File close (first t)) (File unlink (rest t)) (File mkdir (rest t))
    (set! %rv-d (rest t))
    (%rv-sh %rv-d (Str8 append "mkdir x g && cd x && " %rv-build more " && cd ../../g && " %rv-build more))))
; standard error without git's hint: lines, which an advice.* setting
; (macOS runners turn them off) leaves out
(def %rv-plain
  (fn (_ s)
    (Str8 join "" (List map (fn (_ l) (Str8 append l "\n"))
                    (List filter (fn (_ l) (not (or (= (Str8 length l) 0) (Str8 starts? "hint:" l)))) (Str8 split "\n" s))))))
(def %rv-x
  (fn (_ ops)
    (def r (git-run (git-plan (pair "-C" (pair (Str8 append %rv-d "/x/r") ops)))))
    (def text (first (rest r)))
    (def more (rest (rest (rest r))))
    (if (eq? (first r) (lit out)) (list (first (rest (rest r))) text "")
      (list (first (rest (rest r))) (if (null? more) "" (first more)) (%rv-plain text)))))
(def %rv-g
  (fn (_ ops)
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git \"$@\" 2>../git.err" (pair (Str8 append %rv-d "/g/r") ops))))))
    (list (first r) (rest r) (%rv-plain (File read-all (Str8 append %rv-d "/g/git.err"))))))
; the lines whose answers differ, as (OPS X GIT)
(def %rv-steps
  (fn (_ lines)
    (List flat-map
      (fn (_ ops) (let ((x (%rv-x ops)) (g (%rv-g ops))) (do (Heap collect) (if (equal? x g) () (list (list ops x g))))))
      lines)))
(def %rv-file (fn (_ side path) (let ((p (Str8 append %rv-d "/" side "/r/" path))) (if (File exists? p) (File read-all p) ()))))
; what differs in what the twins leave
(def %rv-same
  (fn (_)
    (List filter (fn (_ c) (not (equal? (first (rest c)) (first (rest (rest c))))))
      (List append
        (List map (fn (_ args) (list args (apply git-oracle-in (pair (Str8 append %rv-d "/x/r") args)) (apply git-oracle-in (pair (Str8 append %rv-d "/g/r") args))))
          (list (list "rev-parse" "HEAD") (list "log" "-1" "--format=%B") (list "ls-files" "-s") (list "status" "--porcelain")))
        (List map (fn (_ p) (list p (%rv-file "x" p) (%rv-file "g" p)))
          (list "a" "new" "d/f" ".git/REVERT_HEAD" ".git/MERGE_MSG"))))))
(%rv-twins "")
(write (list (%rv-steps (list (list "revert" "--no-edit" "HEAD") (list "revert" "HEAD") (list "revert" "--no-edit" "HEAD")))
             (%rv-same)))
```
---
    (() ())

### -n: the change staged, not committed

```git
(%rv-twins "")
(write (list (%rv-steps (list (list "revert" "-n" "HEAD"))) (%rv-same)))
```
---
    (() ())

## conflicts

### a conflict stops it; --continue commits once it is resolved

```git
(%rv-twins " && printf 'a\\nCHANGED\\nc\\n' > a && git commit -qam three")
(def %rv-c1 (%rv-steps (list (list "revert" "--no-edit" "HEAD~1"))))
(def %rv-c2 (%rv-same))
(%rv-sh (Str8 append %rv-d "/x/r") "printf 'a\\nb\\nc\\n' > a && git add a")
(%rv-sh (Str8 append %rv-d "/g/r") "printf 'a\\nb\\nc\\n' > a && git add a")
(write (list %rv-c1 %rv-c2 (%rv-steps (list (list "revert" "--continue"))) (%rv-same)))
```
---
    (() () () ())

### --abort gives it up

```git
(%rv-twins " && printf 'a\\nCHANGED\\nc\\n' > a && git commit -qam three")
(write (list (%rv-steps (list (list "revert" "--no-edit" "HEAD~1") (list "revert" "--no-edit" "HEAD") (list "revert" "--abort")))
             (%rv-same)))
```
---
    (() ())

## refusals

### nothing in progress, no such commit, a merge, staged changes

```git
(%rv-twins " && git checkout -qb side HEAD~1 && printf 's\\n' > s && git add s && git commit -qm side && git checkout -q main && git merge -q --no-edit side && printf 'z\\n' > new && git add new")
(write (list (%rv-steps (list (list "revert" "--continue") (list "revert" "--abort") (list "revert" "nope")
                              (list "revert" "--no-edit" "HEAD") (list "revert" "--no-edit" "HEAD~1")))
             (%rv-same)))
```
---
    (() ())

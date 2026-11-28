# @weight 4
# @timeout-scale 3

git show, against git itself, on one repository git made: a first
commit of a and d/f; a second that changes a, adds new and deletes d/f,
with a body to its message; an annotated tag and a lightweight one on
it; a side branch merged back.  Each line is run by x-git and by git in
it, and what each prints, standard output and error apart, and exits
with is compared.

## objects

### commits, tags, trees and blobs

```git
(Sys setenv "GIT_AUTHOR_NAME" "A")
(Sys setenv "GIT_AUTHOR_EMAIL" "a@b.c")
(Sys setenv "GIT_COMMITTER_NAME" "A")
(Sys setenv "GIT_COMMITTER_EMAIL" "a@b.c")
(Sys setenv "GIT_AUTHOR_DATE" "1767225600 +0000")
(Sys setenv "GIT_COMMITTER_DATE" "1767225600 +0000")
(def %sw-d (let ((t (File temp "/tmp/x-git-sw-"))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t))))
(Proc run! (list "/bin/sh" "-c"
  (Str8 append "cd \"$0\" && git init -q -b main r && cd r"
    " && printf 'a\\nb\\n' > a && mkdir d && printf 'x\\n' > d/f && git add . && git commit -qm one"
    " && printf 'a\\nB\\n' > a && printf 'n\\n' > new && git rm -q d/f && git add . && git commit -qm two -m 'body line'"
    " && git tag -a v1 -m 'tag msg' && git tag light"
    " && git checkout -qb side HEAD~1 && printf 's\\n' > s && git add s"
    " && GIT_AUTHOR_DATE='1767225601 +0000' GIT_COMMITTER_DATE='1767225601 +0000' git commit -qm side"
    " && git checkout -q main && GIT_AUTHOR_DATE='1767225602 +0000' GIT_COMMITTER_DATE='1767225602 +0000' git merge -q --no-edit side")
  %sw-d))
(def %sw-r (Str8 append %sw-d "/r"))
(def %sw-x
  (fn (_ ops)
    (def r (git-run (git-plan (pair "-C" (pair %sw-r ops)))))
    (def text (first (rest r)))
    (if (eq? (first r) (lit out)) (list (first (rest (rest r))) text "") (list (first (rest (rest r))) "" text))))
(def %sw-g
  (fn (_ ops)
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git \"$@\" 2>../git.err" (pair %sw-r ops))))))
    (list (first r) (rest r) (File read-all (Str8 append %sw-d "/git.err")))))
; the lines whose answers differ, as (OPS X GIT); each line's garbage
; collected after it, so a file of many lines stays the size of one
(def %sw-steps
  (fn (_ lines)
    (List flat-map
      (fn (_ ops) (let ((x (%sw-x ops)) (g (%sw-g ops))) (do (Heap collect) (if (equal? x g) () (list (list ops x g))))))
      lines)))
(write
  (%sw-steps
    (list (list "show" "HEAD~1")
          (list "show" "HEAD~2")
          (list "show" "v1")
          (list "show" "light")
          (list "show" "HEAD")
          (list "show" "HEAD~1:a")
          (list "show" "HEAD~1^{tree}")
          (list "show" "HEAD~2^{tree}")
          (list "show" "HEAD~2:d")
          (list "show" "HEAD~2" "HEAD~1")
          (list "show" "HEAD~1" "HEAD~1:a"))))
```
---
    ()

## how much is shown

### -s, --stat, --oneline, --pretty and --format, git's forms and a user's

```git
(write
  (%sw-steps
    (list (list "show" "-s" "HEAD~1")
          (list "show" "--no-patch" "HEAD")
          (list "show" "--stat" "HEAD~1")
          (list "show" "--stat" "HEAD")
          (list "show" "--oneline" "HEAD~1")
          (list "show" "--oneline" "-s" "HEAD~2" "HEAD~1")
          (list "show" "--stat" "--oneline" "HEAD~1")
          (list "show" "--pretty=oneline" "-s" "HEAD~1")
          (list "show" "-s" "--format=%H|%h|%T|%t|%P|%p|%s|%b|%an|%ae|%cn|%ce|%ad|%cd|%%|%x" "HEAD~1")
          (list "show" "-s" "--format=%B" "HEAD~1")
          (list "show" "-s" "--format=%s" "HEAD~2" "HEAD~1")
          (list "show" "-s" "--pretty=format:%s" "HEAD~2" "HEAD~1")
          (list "show" "--format=%s" "HEAD~1")
          (list "show" "--pretty=format:%s" "HEAD~1")
          (list "show" "-s" "--pretty=short" "HEAD~2" "HEAD~1")
          (list "show" "-s" "--pretty=full" "HEAD~1")
          (list "show" "--pretty=fuller" "HEAD~1")
          (list "show" "-s" "--format=oneline" "HEAD~1")
          (list "show" "-s" "--pretty=%h" "HEAD~1"))))
```
---
    ()

### log -p and --stat, and both with show: each commit's change, a merge's not drawn by log

The root commit's change is against nothing; with both, `---` (none in a
form of one line), the stat, a blank line, then the patch.

```git
(write
  (%sw-steps
    (list (list "log" "-p")
          (list "log" "--patch" "-2")
          (list "log" "--stat")
          (list "log" "-p" "--stat")
          (list "log" "--oneline" "-p")
          (list "log" "--oneline" "-p" "--stat")
          (list "log" "--pretty=oneline" "--stat")
          (list "log" "--pretty=short" "-p")
          (list "log" "--pretty=fuller" "--stat" "-p")
          (list "log" "--format=%s" "-p")
          (list "log" "--format=tformat:%h %s" "-p" "--stat")
          (list "log" "-p" "-n" "1" "side")
          (list "show" "-p" "--stat" "HEAD~1")
          (list "show" "--stat" "-p" "HEAD")
          (list "show" "--oneline" "-p" "--stat" "HEAD~1")
          (list "show" "-p" "HEAD~2"))))
```
---
    ()

### --raw, and the empty format: the change alone, no separator before it

The raw lines first, then the stat, then a blank line and the patch; a
merge's raw lines, of its combined diff, not drawn.  `--format=` (and
`tformat:` and `format:` with nothing after) draws no header, and no
blank line or `---` after it.

```git
(write
  (%sw-steps
    (list (list "show" "--raw" "HEAD~1")
          (list "show" "--raw" "-p" "HEAD~1")
          (list "show" "--raw" "--stat" "-p" "HEAD~1")
          (list "show" "--oneline" "--raw" "--stat" "-p" "HEAD~1")
          (list "show" "--raw" "HEAD")
          (list "show" "--raw" "--stat" "HEAD")
          (list "show" "--raw" "-s" "HEAD~1")
          (list "log" "--raw")
          (list "log" "--oneline" "--raw" "--stat")
          (list "log" "--format=%s" "--raw" "-p" "-3")
          (list "show" "--format=" "HEAD~1")
          (list "show" "--format=" "--stat" "HEAD" "HEAD~1")
          (list "show" "--format=" "-s" "HEAD~2" "HEAD~1")
          (list "show" "--pretty=format:" "HEAD~2" "HEAD~1")
          (list "log" "--format=" "--stat")
          (list "log" "--pretty=tformat:" "--raw")
          (list "log" "--format=format:" "-p" "--stat"))))
```
---
    ()

### --numstat, --name-only and --name-status, and -s read in order

`--numstat` between the raw lines and the stat; a name form in place of
every other, the patch too, and a merge's not drawn; a merge's counts
against its first parent.  `-s` clears the forms before it, not those
after; a name form after it, or both name forms, refused.

```git
(write
  (%sw-steps
    (list (list "show" "--numstat" "HEAD~1")
          (list "show" "--raw" "--numstat" "--stat" "-p" "HEAD~1")
          (list "show" "--name-only" "HEAD~1")
          (list "show" "--name-status" "-p" "--stat" "HEAD~1")
          (list "show" "--oneline" "--name-status" "HEAD~2" "HEAD~1")
          (list "show" "--numstat" "HEAD")
          (list "show" "--name-status" "HEAD")
          (list "log" "--name-status")
          (list "log" "--oneline" "--name-only")
          (list "log" "--format=%s" "--numstat" "--stat")
          (list "show" "-s" "--stat" "HEAD~1")
          (list "show" "--stat" "-s" "HEAD~1")
          (list "show" "-s" "-p" "HEAD~1")
          (list "show" "--name-only" "-s" "HEAD~1")
          (list "log" "-p" "-s" "-1")
          (list "show" "-s" "--name-status" "HEAD~1")
          (list "log" "--name-only" "--name-status"))))
```
---
    ()

## refusals

### no such revision, no such path, no such format

```git
(write (%sw-steps (list (list "show" "nope") (list "show" "HEAD:nope") (list "show" "-s" "--pretty=nope") (list "show" "-s" "--format=nope"))))
```
---
    ()

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

### -s, --stat, --oneline, --pretty and --format

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
          (list "show" "--pretty=format:%s" "HEAD~1"))))
```
---
    ()

## refusals

### no such revision, no such path

```git
(write (%sw-steps (list (list "show" "nope") (list "show" "HEAD:nope"))))
```
---
    ()

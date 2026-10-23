# @weight 4
# @timeout-scale 3

git push's refspecs and options, against git itself.  Each case makes
twins under x/ and g/, the same way at the same dates: a bare remote,
and a working repository of three commits on main with a branch b1 at
the second, a lightweight tag t2 and an annotated tag t3, main pushed to
the remote once as origin (a path), and the same remote again as wire,
a file:// url.  The same push lines run in both -- x-git's in x/w,
git's in g/w -- and what each prints, standard output and error apart
(git's hint: lines aside), and exits with is compared, then the refs
each side ends with, the remote's and its own, and its branch config.
Each line's garbage is collected after it.

## what is pushed

### several refspecs at once: a branch, src:dst, a revision to a full ref

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "A") (pair "GIT_COMMITTER_EMAIL" "a@b.c") (pair "GIT_COMMITTER_DATE" "1767225600 +0000")))
(def %ps-d ())
(def %ps-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
(def %ps-build
  (Str8 append
    "git init -q --bare remote.git && git init -q -b main w && cd w"
    " && printf 'a\\n' > a && git add a && git commit -qm one"
    " && printf 'b\\n' >> a && git commit -qam two && git branch b1 && git tag t2 && git tag -a t3 -m 'tag three'"
    " && printf 'c\\n' >> a && git commit -qam three"
    " && git remote add origin ../remote.git && git remote add wire \"file://$(cd .. && pwd)/remote.git\""
    " && git push -q origin main 2>/dev/null"))
(def %ps-twins
  (fn (_ more)
    (def t (File temp "/tmp/x-git-ps-"))
    (File close (first t)) (File unlink (rest t)) (File mkdir (rest t))
    (set! %ps-d (rest t))
    (%ps-sh %ps-d (Str8 append "mkdir x g && cd x && " %ps-build more " && cd ../../g && " %ps-build more))))
(def %ps-plain
  (fn (_ s side)
    (Str8 replace (Str8 append %ps-d "/" side "/") "TWIN/"
      (Str8 join "" (List map (fn (_ l) (Str8 append l "\n"))
                      (List filter (fn (_ l) (not (or (= (Str8 length l) 0) (Str8 starts? "hint:" l)))) (Str8 split "\n" s)))))))
(def %ps-x
  (fn (_ ops)
    (def r (git-run (git-plan (pair "-C" (pair (Str8 append %ps-d "/x/w") ops)))))
    (def text (first (rest r)))
    (def more (rest (rest (rest r))))
    (if (eq? (first r) (lit out)) (list (first (rest (rest r))) (%ps-plain text "x") "")
      (list (first (rest (rest r))) (%ps-plain (if (null? more) "" (first more)) "x") (%ps-plain text "x")))))
(def %ps-g
  (fn (_ ops)
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git \"$@\" 2>../git.err" (pair (Str8 append %ps-d "/g/w") ops))))))
    (list (first r) (%ps-plain (rest r) "g") (%ps-plain (File read-all (Str8 append %ps-d "/g/git.err")) "g"))))
; the lines whose answers differ, as (OPS X GIT)
(def %ps-steps
  (fn (_ lines)
    (List flat-map
      (fn (_ ops) (let ((x (%ps-x ops)) (g (%ps-g ops))) (do (Heap collect) (if (equal? x g) () (list (list ops x g))))))
      lines)))
; what differs in what the twins end with
(def %ps-same
  (fn (_)
    (List filter (fn (_ c) (not (equal? (first (rest c)) (first (rest (rest c))))))
      (List map (fn (_ c) (list c (git-oracle-in (Str8 append %ps-d "/x/" (first c)) (first (rest c)) (first (rest (rest c))))
                                 (git-oracle-in (Str8 append %ps-d "/g/" (first c)) (first (rest c)) (first (rest (rest c))))))
        (list (list "remote.git" "for-each-ref" "--format=%(refname) %(objectname)")
              (list "w" "for-each-ref" "--format=%(refname) %(objectname)")
              (list "w" "config" "--get-regexp=^branch\\."))))))
(%ps-twins "")
(write (list (%ps-steps (list (list "push" "origin" "b1" "main:other" "HEAD~2:refs/heads/oldest")
                              (list "push" "origin" "main" "b1")))
             (%ps-same)))
```
---
    (() ())

### tags: one by name, every one with --tags

```git
(%ps-twins "")
(write (list (%ps-steps (list (list "push" "origin" "t2") (list "push" "--tags" "origin") (list "push" "--tags" "origin")))
             (%ps-same)))
```
---
    (() ())

## what is refused, and forced

### not a fast-forward: refused, then -f and +src:dst force it

```git
(%ps-twins "")
(write (list (%ps-steps (list (list "push" "origin" "main~2:main") (list "push" "-f" "origin" "main~2:main")
                              (list "push" "origin" "+main:main") (list "push" "origin" "b1:main")))
             (%ps-same)))
```
---
    (() ())

### a tag that exists is refused unless forced; an unknown source fails the push

```git
(%ps-twins " && git push -q origin t2 2>/dev/null && git tag -f t2 HEAD")
(write (list (%ps-steps (list (list "push" "origin" "t2") (list "push" "--force" "origin" "t2")
                              (list "push" "origin" "nope") (list "push" "origin" "b1" "nope")))
             (%ps-same)))
```
---
    (() ())

## deleting

### :dst and --delete; a ref the remote lacks

```git
(%ps-twins " && git push -q origin b1 main:other t2 2>/dev/null")
(write (list (%ps-steps (list (list "push" "origin" ":other") (list "push" "--delete" "origin" "b1" "t2")
                              (list "push" "origin" ":nothere") (list "push" "-d" "origin")))
             (%ps-same)))
```
---
    (() ())

## over the wire

### the same, to receive-pack: several refs, a delete, a refusal

```git
(%ps-twins " && git push -q origin b1 2>/dev/null")
(write (list (%ps-steps (list (list "push" "wire" "main:other" "t3") (list "push" "wire" ":b1" "main~1:main")
                              (list "push" "-f" "wire" "main~1:main" ":other")))
             (%ps-same)))
```
---
    (() ())

## tracking

### -u records the upstream of each branch pushed

```git
(%ps-twins "")
(write (list (%ps-steps (list (list "push" "-u" "origin" "b1") (list "push" "--set-upstream" "origin" "main:trunk")))
             (%ps-same)))
```
---
    (() ())

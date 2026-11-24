# @weight 2

describe, against git itself.  The refs fixture tags its first commit
with the annotated v1 and its second with the lightweight light; a
repository of the case's own serves the work tree and the history git
walks with a merge in it.

## the nearest tag

### an annotated tag counted to, a lightweight one with --tags, a tag's own commit

```git
(def %rf (git-fixture-refs))
(def %dc (fn (_ . args) (equal? (apply git-text-in (pair %rf (pair "describe" args)))
                                (apply git-oracle-in (pair %rf (pair "describe" args))))))
(write (list (Str8 starts? "v1-1-g" (rest (git-text-in %rf "describe")))
             (%dc) (%dc "--tags") (%dc "HEAD~1") (%dc "--long" "HEAD~1") (%dc "--abbrev=0")
             (%dc "--abbrev=10") (%dc "--tags" "--long")))
```
---
    (#t #t #t #t #t #t #t #t)

### the refusals: no such commit, and a lightweight tag only without --tags

```git
(def %rf (git-fixture-refs))
(write (list (equal? (git-text-in %rf "describe" "nope") (git-oracle-in %rf "describe" "nope"))
             (first (git-text-in %rf "describe" "nope"))))
```
---
    (#t 128)

## the walk and the work tree

### a merge: the fewest commits wins; no tags at all; --always; --dirty

```git
(def %dw-t (File temp "/tmp/x-git-dw-"))
(File close (first %dw-t))
(File unlink (rest %dw-t))
(def %dw (rest %dw-t))
(File mkdir %dw)
(Proc run! (list "/bin/sh" "-c" (Str8 append "cd " %dw
  " && git init -q -b main . && git config user.email a@b.c && git config user.name A"
  " && echo a > a && git add a && GIT_COMMITTER_DATE='1700000000 +0000' git commit -q -m a"
  " && git checkout -q -b side && echo b > b && git add b && GIT_COMMITTER_DATE='1700000100 +0000' git commit -q -m b"
  " && git checkout -q main && echo c > c && git add c && GIT_COMMITTER_DATE='1700000200 +0000' git commit -q -m c")))
(def %dc (fn (_ . args) (equal? (apply git-text-in (pair %dw (pair "describe" args)))
                                (apply git-oracle-in (pair %dw (pair "describe" args))))))
(def %none (list (%dc) (%dc "--always") (%dc "--always" "--dirty")))
(Proc run! (list "/bin/sh" "-c" (Str8 append "cd " %dw
  " && git tag -a far -m far HEAD~1 && git tag -a near -m near side"
  " && GIT_COMMITTER_DATE='1700000300 +0000' git merge -q --no-edit side"
  " && echo d > d && git add d && GIT_COMMITTER_DATE='1700000400 +0000' git commit -q -m d")))
(def %tagged (list (%dc) (%dc "HEAD^2") (%dc "--dirty")))
(File write-all (Str8 append %dw "/a") "changed\n")
(write (list %none %tagged (%dc "--dirty") (%dc "--dirty=.mod")
             (Str8 starts? "near-3-g" (rest (git-text-in %dw "describe" "--dirty")))
             (equal? (git-text-in %dw "describe" "--dirty" "HEAD") (git-oracle-in %dw "describe" "--dirty" "HEAD"))))
```
---
    ((#t #t #t) (#t #t #t) #t #t #t #t)

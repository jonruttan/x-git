# @weight 2

log, against git itself, on the refs fixture: two commits, an annotated
tag on the first.  The date line is the author's time in the author's
own offset, as git prints it.

## log

### the whole history, as git lays it out

```git
(def %rf (git-fixture-refs))
(write (equal? (git-text-in %rf "log") (git-oracle-in %rf "log")))
```
---
    #t

### --oneline, and -n

```git
(def %rf (git-fixture-refs))
(def %lg-same?
  (fn (_ . ops) (equal? (apply git-text-in (pair %rf (pair "log" ops))) (apply git-oracle-in (pair %rf (pair "log" ops))))))
(write (list (%lg-same? "--oneline") (%lg-same? "-n" "1") (%lg-same? "--oneline" "-n" "1") (%lg-same? "--max-count" "1")))
```
---
    (#t #t #t #t)

### from a revision: a tag, an older commit, a branch

```git
(def %rf (git-fixture-refs))
(def %lg-same?
  (fn (_ . ops) (equal? (apply git-text-in (pair %rf (pair "log" ops))) (apply git-oracle-in (pair %rf (pair "log" ops))))))
(write (list (%lg-same? "v1") (%lg-same? "HEAD~1") (%lg-same? "--oneline" "side")))
```
---
    (#t #t #t)

### the shape of one entry

```git
(def %rf (git-fixture-refs))
(def %lg-lines (Str8 split "\n" (rest (git-text-in %rf "log" "-n" "1" "HEAD~1"))))
(write (list (List length %lg-lines) (Str8 sub 0 7 (first %lg-lines)) (List ref 1 %lg-lines)
             (Str8 sub 0 8 (List ref 2 %lg-lines)) (List ref 3 %lg-lines) (List ref 4 %lg-lines)))
```
---
    (6 "commit " "Author: A <a@b.c>" "Date:   " "" "    one")

### a revision nothing answers to is refused in git's words

```git
(def %rf (git-fixture-refs))
(write (equal? (git-text-in %rf "log" "nosuch") (git-oracle-in %rf "log" "nosuch")))
```
---
    #t

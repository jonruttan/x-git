# @weight 4

Packed objects, against git itself.  The packed fixture is two commits of
a longish file, repacked: every object is in the one pack, nothing is
loose, and the older file is a delta against the newer.  Every expectation
is git's own answer on the same repository.

## the fixture

### everything is packed, and one object is a delta

```git
(def %pk (git-fixture-packed))
(def %pk-idx (first (List filter (fn (_ f) (Str8 ends? ".idx" f)) (File list-dir (Str8 append %pk "/.git/objects/pack")))))
(def %pk-verify (rest (git-oracle-in %pk "verify-pack" "-v" (Str8 append ".git/objects/pack/" %pk-idx))))
(write (list (List filter (fn (_ f) (not (or (str=? f "info") (str=? f "pack")))) (File list-dir (Str8 append %pk "/.git/objects")))
             (Str8 includes? "chain length = 1: 1 object" %pk-verify)))
```
---
    (() #t)

## reading through the pack

### -t, -s and -p on every kind of object, the delta among them

```git
(def %pk (git-fixture-packed))
(def %pk-same?
  (fn (_ flag rev)
    (equal? (git-text-in %pk "cat-file" flag (git-sha-in %pk rev))
            (git-oracle-in %pk "cat-file" flag (git-sha-in %pk rev)))))
(write (List map (fn (_ flag) (List map (fn (_ rev) (%pk-same? flag rev))
                                (list "HEAD" "HEAD~1" "HEAD^{tree}" "HEAD:f.txt" "HEAD:big.txt" "HEAD~1:big.txt")))
                 (list "-t" "-s" "-p")))
```
---
    ((#t #t #t #t #t #t) (#t #t #t #t #t #t) (#t #t #t #t #t #t))

### the delta's result is the older file, whole

The fixture changed the file's 200th line (index 199; the lines count
from "line 0"): the older file, which the pack holds as a delta against
the newer, has it as written; the newer has the change.

```git
(def %pk (git-fixture-packed))
(def %pk-old (rest (git-text-in %pk "cat-file" "-p" (git-sha-in %pk "HEAD~1:big.txt"))))
(write (list (List length (Str8 split "\n" %pk-old))
             (List ref 199 (Str8 split "\n" %pk-old))
             (List ref 199 (Str8 split "\n" (rest (git-text-in %pk "cat-file" "-p" (git-sha-in %pk "HEAD:big.txt")))))))
```
---
    (401 "line 199 of a longish file" "CHANGED")

### an abbreviated name resolves through the index

```git
(def %pk (git-fixture-packed))
(write (equal? (git-text-in %pk "cat-file" "-t" (Str8 sub 0 7 (git-sha-in %pk "HEAD")))
               (git-oracle-in %pk "cat-file" "-t" (Str8 sub 0 7 (git-sha-in %pk "HEAD")))))
```
---
    #t

### -e sees a packed object

```git
(def %pk (git-fixture-packed))
(write (list (git-text-in %pk "cat-file" "-e" (git-sha-in %pk "HEAD~1:big.txt"))
             (git-text-in %pk "cat-file" "-e" "0000000000000000000000000000000000000000")))
```
---
    ((0 . "") (1 . ""))

### a loose object written beside the pack reads back, by x-git and by git

```git
(def %pk (git-fixture-packed))
(File write-all (Str8 append %pk "/new.txt") "beside the pack\n")
(def %pk-sha (Str8 trim (rest (git-text-in %pk "hash-object" "-w" "new.txt"))))
(write (list (git-text-in %pk "cat-file" "-p" %pk-sha) (git-oracle-in %pk "cat-file" "-p" %pk-sha)))
```
---
    ((0 . "beside the pack\n") (0 . "beside the pack\n"))

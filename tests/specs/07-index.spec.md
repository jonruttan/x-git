# @weight 2

The index, ls-files and status, against git itself.  The loose fixture is
fresh for this file (fixtures are made once a process); the cases change
its working directory and stage with the system git, and x-git reads the
index git wrote.  Long-form status is compared without the `(use ...)`
hint lines, which git prints or not by version and configuration; the
porcelain form is compared whole.

## a clean tree

### ls-files, with and without the stage

```git
(write (list (equal? (git-text "ls-files") (git-oracle "ls-files"))
             (equal? (git-text "ls-files" "--stage") (git-oracle "ls-files" "--stage"))
             (git-text "ls-files" "-s")))
```
---
    (#t #t (0 . "100644 ce013625030ba8dba906f756967f9e9ca394464a 0\tf.txt\n100644 c1b0730e0133447badcfd47fd144e254807b06e1 0\tsub/g\n"))

### status, clean

```git
(write (list (git-text "status" "--porcelain") (equal? (git-text "status") (git-oracle "status"))))
```
---
    ((0 . "") #t)

## changes in the working directory

### a modified file, an untracked file and an untracked directory

```git
(def %ix (git-fixture))
(File write-all (Str8 append %ix "/f.txt") "changed\n")
(File write-all (Str8 append %ix "/untracked.txt") "new\n")
(File mkdir (Str8 append %ix "/newdir"))
(File write-all (Str8 append %ix "/newdir/inside") "x\n")
(def %ix-no-hints (fn (_ r) (pair (first r) (Str8 join "\n" (List filter (fn (_ l) (not (Str8 starts? "  (use" l))) (Str8 split "\n" (rest r)))))))
(write (list (git-text "status" "--porcelain")
             (equal? (git-text "status" "--porcelain") (git-oracle "status" "--porcelain"))
             (equal? (%ix-no-hints (git-text "status")) (%ix-no-hints (git-oracle "status")))))
```
---
    ((0 . " M f.txt\n?? newdir/\n?? untracked.txt\n") #t #t)

### staged by git, read by x-git: an addition, a modification, a deletion

The repository is the one the case above left: `newdir/` is still
untracked.

```git
(def %ix (git-fixture))
(File unlink (Str8 append %ix "/sub/g"))
(git-oracle "add" "untracked.txt")
(def %ix-no-hints (fn (_ r) (pair (first r) (Str8 join "\n" (List filter (fn (_ l) (not (Str8 starts? "  (use" l))) (Str8 split "\n" (rest r)))))))
(write (list (git-text "status" "--porcelain")
             (equal? (git-text "status" "--porcelain") (git-oracle "status" "--porcelain"))
             (equal? (git-text "ls-files" "--stage") (git-oracle "ls-files" "--stage"))
             (equal? (%ix-no-hints (git-text "status")) (%ix-no-hints (git-oracle "status")))))
```
---
    ((0 . " M f.txt\n D sub/g\nA  untracked.txt\n?? newdir/\n") #t #t #t)

### everything staged, nothing left unstaged

```git
(def %ix (git-fixture))
(git-oracle "add" "-A")
(def %ix-no-hints (fn (_ r) (pair (first r) (Str8 join "\n" (List filter (fn (_ l) (not (Str8 starts? "  (use" l))) (Str8 split "\n" (rest r)))))))
(write (list (git-text "status" "--porcelain")
             (equal? (git-text "status" "--porcelain") (git-oracle "status" "--porcelain"))
             (equal? (%ix-no-hints (git-text "status")) (%ix-no-hints (git-oracle "status")))))
```
---
    ((0 . "M  f.txt\nA  newdir/inside\nD  sub/g\nA  untracked.txt\n") #t #t)

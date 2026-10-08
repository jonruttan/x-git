# @weight 2

init, branch and tag, against git itself.  The refs fixture (packed tags
and branches, one loose branch) serves branch and tag; init makes a
repository of its own.

## init

### a repository made by x-git, grown by x-git, read by git

```git
(def %rp-t (File temp "/tmp/x-git-in-"))
(File close (first %rp-t))
(File unlink (rest %rp-t))
(def %rp (rest %rp-t))
(def %rp-r (git-run (git-plan (list "init" "-b" "main" %rp))))
(File write-all (Str8 append %rp "/a.txt") "a\n")
(Proc run! (list "/bin/sh" "-c" (Str8 append "cd " %rp " && git config user.email a@b.c && git config user.name A")))
(git-text-in %rp "add" "a.txt")
(def %rp-c (git-text-in %rp "commit" "-m" "first"))
(write (list (first (rest (rest %rp-r)))
             (str=? (first (rest %rp-r)) (Str8 append "Initialized empty Git repository in " %rp "/.git/\n"))
             (Str8 trim (File read-all (Str8 append %rp "/.git/HEAD")))
             (Str8 starts? "[main (root-commit) " (rest %rp-c))
             (git-oracle-in %rp "log" "--format=%s")
             (first (git-oracle-in %rp "fsck" "--strict"))
             (git-oracle-in %rp "status" "--porcelain")
             (git-text-in %rp "branch")
             (str=? (first (rest (git-run (git-plan (list "init" "-b" "main" %rp)))))
                    (Str8 append "Reinitialized existing Git repository in " %rp "/.git/\n"))))
```
---
    (0 #t "ref: refs/heads/main" #t (0 . "first\n") 0 (0 . "") (0 . "* main\n") #t)

## branch

### the list, packed and loose branches together, the current one starred

```git
(def %rf (git-fixture-refs))
(write (list (git-text-in %rf "branch") (equal? (git-text-in %rf "branch") (git-oracle-in %rf "branch"))))
```
---
    ((0 . "  loose\n* main\n  side\n") #t)

### a branch made by x-git at a revision, seen by git; made twice, refused

```git
(def %rf (git-fixture-refs))
(write (list (git-text-in %rf "branch" "feat" "HEAD~1")
             (git-oracle-in %rf "branch")
             (equal? (git-oracle-in %rf "rev-parse" "feat") (git-oracle-in %rf "rev-parse" "HEAD~1"))
             (equal? (git-text-in %rf "branch" "feat") (git-oracle-in %rf "branch" "feat"))))
```
---
    ((0 . "") (0 . "  feat\n  loose\n* main\n  side\n") #t #t)

### deleted: a loose branch, and a packed one taken out of packed-refs

```git
(def %rf (git-fixture-refs))
(def %rp-short (fn (_ rev) (Str8 sub 0 7 (Str8 trim (rest (git-oracle-in %rf "rev-parse" rev))))))
(def %rp-feat (%rp-short "feat"))
(def %rp-side (%rp-short "side"))
(write (list (str=? (rest (git-text-in %rf "branch" "-d" "feat")) (Str8 append "Deleted branch feat (was " %rp-feat ").\n"))
             (str=? (rest (git-text-in %rf "branch" "-d" "side")) (Str8 append "Deleted branch side (was " %rp-side ").\n"))
             (git-oracle-in %rf "branch")
             (first (git-oracle-in %rf "rev-parse" "--verify" "-q" "side"))
             (first (git-text-in %rf "branch" "-d" "main"))
             (first (git-oracle-in %rf "branch" "-d" "main"))))
```
---
    (#t #t (0 . "  loose\n* main\n") 1 1 1)

## tag

### the list, a tag made at a revision and seen by git, a tag deleted

```git
(def %rf (git-fixture-refs))
(write (list (git-text-in %rf "tag") (equal? (git-text-in %rf "tag") (git-oracle-in %rf "tag"))
             (git-text-in %rf "tag" "t2" "HEAD~1")
             (equal? (git-oracle-in %rf "rev-parse" "t2") (git-oracle-in %rf "rev-parse" "HEAD~1"))
             (git-oracle-in %rf "tag")
             (str=? (rest (git-text-in %rf "tag" "-d" "t2"))
                    (Str8 append "Deleted tag 't2' (was " (Str8 sub 0 7 (Str8 trim (rest (git-oracle-in %rf "rev-parse" "HEAD~1")))) ")\n"))
             (git-oracle-in %rf "tag")))
```
---
    ((0 . "light\nv1\n") #t (0 . "") #t (0 . "light\nt2\nv1\n") #t (0 . "light\nv1\n"))

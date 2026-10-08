# @weight 3

add and commit, against git itself: x-git writes the index, the blobs,
the trees, the commit and the ref, and the system git reads every one of
them back.  The loose fixture is fresh for this file and its state is
cumulative down the cases.

## add

### a pathspec nothing matches is refused in git's words

```git
(write (list (git-text "add" "nosuch") (git-oracle "add" "nosuch")))
```
---
    ((128 . "fatal: pathspec 'nosuch' did not match any files\n") (128 . "fatal: pathspec 'nosuch' did not match any files\n"))

### a new file and a changed one staged by x-git, read by git

```git
(def %cm (git-fixture))
(File write-all (Str8 append %cm "/n.txt") "new\n")
(File write-all (Str8 append %cm "/f.txt") "hello\nmore\n")
(write (list (git-text "add" "n.txt" "f.txt")
             (git-oracle "status" "--porcelain")
             (equal? (git-text "ls-files" "--stage") (git-oracle "ls-files" "--stage"))
             (git-oracle "cat-file" "-p" (Str8 trim (rest (git-oracle "rev-parse" ":n.txt"))))))
```
---
    ((0 . "") (0 . "M  f.txt\nA  n.txt\n") #t (0 . "new\n"))

## commit

### the commit git reads back: its summary, its object, the log, a clean tree

```git
(def %cm (git-fixture))
(def %cm-r (git-text "commit" "-m" "two"))
(def %cm-head (Str8 trim (rest (git-oracle "rev-parse" "HEAD"))))
(def %cm-lines (Str8 split "\n" (rest %cm-r)))
(write (list (first %cm-r)
             (str=? (first %cm-lines) (Str8 append "[main " (Str8 sub 0 7 %cm-head) "] two"))
             (List ref 1 %cm-lines) (List ref 2 %cm-lines)
             (git-oracle "log" "--oneline" "--format=%s")
             (git-oracle "log" "-1" "--format=%an <%ae>")
             (git-oracle "status" "--porcelain")
             (first (git-oracle "fsck" "--strict"))))
```
---
    (0 #t " 2 files changed, 2 insertions(+)" " create mode 100644 n.txt" (0 . "two\ninit\n") (0 . "A <a@b.c>\n") (0 . "") 0)

### the commit object as git prints it

```git
(def %cm (git-fixture))
(def %cm-obj (Str8 split "\n" (rest (git-oracle "cat-file" "-p" "HEAD"))))
(write (list (Str8 sub 0 5 (first %cm-obj)) (Str8 sub 0 7 (List ref 1 %cm-obj))
             (Str8 starts? "author A <a@b.c> " (List ref 2 %cm-obj))
             (Str8 starts? "committer A <a@b.c> " (List ref 3 %cm-obj))
             (List ref 4 %cm-obj) (List ref 5 %cm-obj)
             (equal? (git-oracle "rev-parse" "HEAD^{tree}") (git-oracle "rev-parse" "HEAD^{tree}"))
             (equal? (git-text "ls-tree" "-r" "HEAD") (git-oracle "ls-tree" "-r" "HEAD"))))
```
---
    ("tree " "parent " #t #t "" "two" #t #t)

### a removal staged with add, committed: the deletion line

```git
(def %cm (git-fixture))
(File unlink (Str8 append %cm "/n.txt"))
(def %cm-add (git-text "add" "n.txt"))
(def %cm-r (git-text "commit" "-m" "drop it"))
(write (list %cm-add (first %cm-r) (rest (Str8 split "\n" (rest %cm-r)))
             (git-oracle "status" "--porcelain")
             (equal? (git-text "ls-tree" "HEAD") (git-oracle "ls-tree" "HEAD"))))
```
---
    ((0 . "") 0 (" 1 file changed, 1 deletion(-)" " delete mode 100644 n.txt" "") (0 . "") #t)

### nothing to commit prints the status, status 1; -q prints nothing

```git
(def %cm (git-fixture))
(def %cm-r (git-text "commit" "-m" "again"))
(File write-all (Str8 append %cm "/f.txt") "quiet\n")
(git-text "add" "f.txt")
(write (list %cm-r (git-text "commit" "-q" "-m" "quietly") (git-oracle "log" "--format=%s")))
```
---
    ((1 . "On branch main\nnothing to commit, working tree clean\n") (0 . "") (0 . "quietly\ndrop it\ntwo\ninit\n"))

### add -A stages everything, in a subdirectory too; git's commit follows x-git's

```git
(def %cm (git-fixture))
(File mkdir (Str8 append %cm "/deep"))
(File write-all (Str8 append %cm "/deep/one") "1\n")
(File write-all (Str8 append %cm "/sub/g") "changed\n")
(git-text "add" "-A")
(def %cm-r (git-text "commit" "-m" "deep"))
(File write-all (Str8 append %cm "/deep/two") "2\n")
(git-oracle "add" "-A")
(git-oracle "commit" "-q" "-m" "by git")
(write (list (rest (Str8 split "\n" (rest %cm-r)))
             (equal? (git-text "log" "--oneline") (git-oracle "log" "--oneline"))
             (equal? (git-text "ls-tree" "-r" "HEAD") (git-oracle "ls-tree" "-r" "HEAD"))
             (git-oracle "status" "--porcelain")))
```
---
    ((" 2 files changed, 2 insertions(+), 1 deletion(-)" " create mode 100644 deep/one" "") #t #t (0 . ""))

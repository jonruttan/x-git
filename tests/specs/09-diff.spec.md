# @weight 2

diff, against git itself: the working directory against the index, the
index against HEAD, revisions against each other, --stat.  The loose
fixture is fresh for this file and its state is cumulative.

## hunks

### the edit script and a hunk

```git
(write (list (git-edit-script (list "a" "b" "c") (list "a" "x" "c"))
             (git-hunks "a\nb\nc\n" "a\nx\nc\n")))
```
---
    ((('keep . "a") ('del . "b") ('ins . "x") ('keep . "c")) "@@ -1,3 +1,3 @@\n a\n-b\n+x\n c\n")

### no newline at the end is marked

```git
(display (git-hunks "a\n" "a\nb"))
```
---
```output
@@ -1 +1,2 @@
 a
+b
\ No newline at end of file
```

## the working directory against the index

### a changed line, as git prints it

```git
(def %df (git-fixture))
(File write-all (Str8 append %df "/f.txt") "hello\nmore\n")
(write (list (equal? (git-text "diff") (git-oracle "diff")) (git-text "diff")))
```
---
    (#t (0 . "diff --git a/f.txt b/f.txt\nindex ce01362..2227cdd 100644\n--- a/f.txt\n+++ b/f.txt\n@@ -1 +1,2 @@\n hello\n+more\n"))

### --stat, and a path that limits it

```git
(def %df (git-fixture))
(File write-all (Str8 append %df "/sub/g") "y\n")
(write (list (equal? (git-text "diff" "--stat") (git-oracle "diff" "--stat"))
             (equal? (git-text "diff" "sub/g") (git-oracle "diff" "sub/g"))
             (git-text "diff" "--stat")))
```
---
    (#t #t (0 . " f.txt | 1 +\n sub/g | 2 +-\n 2 files changed, 2 insertions(+), 1 deletion(-)\n"))

## the index against HEAD

### --cached after git stages a new file and a change

```git
(def %df (git-fixture))
(File write-all (Str8 append %df "/n.txt") "new\n")
(git-oracle "add" "n.txt" "f.txt")
(write (list (equal? (git-text "diff" "--cached") (git-oracle "diff" "--cached"))
             (equal? (git-text "diff" "--cached" "--stat") (git-oracle "diff" "--cached" "--stat"))
             (equal? (git-text "diff") (git-oracle "diff"))))
```
---
    (#t #t #t)

## revisions

### two commits, and a commit against the working directory

```git
(def %rf (git-fixture-refs))
(write (list (equal? (git-text-in %rf "diff" "HEAD~1" "HEAD") (git-oracle-in %rf "diff" "HEAD~1" "HEAD"))
             (equal? (git-text-in %rf "diff" "HEAD~1") (git-oracle-in %rf "diff" "HEAD~1"))
             (equal? (git-text-in %rf "diff" "--stat" "v1" "main") (git-oracle-in %rf "diff" "--stat" "v1" "main"))
             (git-text-in %rf "diff" "HEAD" "HEAD")))
```
---
    (#t #t #t (0 . ""))

### a deleted file

```git
(def %df (git-fixture))
(File unlink (Str8 append %df "/sub/g"))
(write (equal? (git-text "diff") (git-oracle "diff")))
```
---
    #t

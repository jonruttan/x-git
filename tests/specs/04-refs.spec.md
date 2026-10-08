# @weight 4

Refs and revision names, against git itself.  The refs fixture has two
commits, an annotated tag on the first, a lightweight tag and a branch --
all of them packed into .git/packed-refs -- and one loose branch made
after; HEAD is symbolic.  Every expectation is git's own answer on it.

## rev-parse

### every spelling of a revision answers as git does

```git
(def %rf (git-fixture-refs))
(def %rf-same?
  (fn (_ rev) (equal? (git-text-in %rf "rev-parse" rev) (git-oracle-in %rf "rev-parse" rev))))
(write (List map %rf-same?
  (list "HEAD" "HEAD~1" "HEAD^" "HEAD~2" "main" "side" "loose" "refs/heads/main" "heads/main" "tags/v1"
        "v1" "light" "v1^{}" "v1^{commit}" "HEAD^{tree}" "HEAD^{commit}" "light^{tree}" "HEAD~1^{tree}"
        "HEAD:f.txt" "HEAD:sub" "HEAD:sub/g" "HEAD~1:f.txt" "v1:f.txt" "HEAD:")))
```
---
    (#t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t)

### the annotated tag is its own object; peeled, it is the commit

```git
(def %rf (git-fixture-refs))
(write (list (git-text-in %rf "cat-file" "-t" "v1")
             (git-text-in %rf "cat-file" "-t" "v1^{}")
             (equal? (git-text-in %rf "cat-file" "-p" "v1") (git-oracle-in %rf "cat-file" "-p" "v1"))
             (equal? (git-text-in %rf "rev-parse" "v1^{}") (git-text-in %rf "rev-parse" "HEAD~1"))))
```
---
    ((0 . "tag\n") (0 . "commit\n") #t #t)

### the packed and the loose branch both resolve, to the same commit

```git
(def %rf (git-fixture-refs))
(write (list (File exists? (Str8 append %rf "/.git/refs/heads/side"))
             (File exists? (Str8 append %rf "/.git/refs/heads/loose"))
             (equal? (git-text-in %rf "rev-parse" "side") (git-text-in %rf "rev-parse" "loose"))))
```
---
    (#f #t #t)

### several revisions, a line each

```git
(def %rf (git-fixture-refs))
(write (equal? (git-text-in %rf "rev-parse" "HEAD" "v1" "HEAD:f.txt") (git-oracle-in %rf "rev-parse" "HEAD" "v1" "HEAD:f.txt")))
```
---
    #t

### a revision nothing answers to is refused in git's words

```git
(def %rf (git-fixture-refs))
(write (list (equal? (git-text-in %rf "rev-parse" "nosuch") (git-oracle-in %rf "rev-parse" "nosuch"))
             (first (git-text-in %rf "rev-parse" "HEAD~9"))
             (first (git-oracle-in %rf "rev-parse" "HEAD~9"))))
```
---
    (#t 128 128)

## cat-file through a revision

### a commit by its branch, a blob by its path

```git
(def %rf (git-fixture-refs))
(write (list (equal? (git-text-in %rf "cat-file" "-p" "main") (git-oracle-in %rf "cat-file" "-p" "main"))
             (git-text-in %rf "cat-file" "-p" "HEAD~1:f.txt")
             (git-text-in %rf "cat-file" "-p" "HEAD:f.txt")))
```
---
    (#t (0 . "hello\n") (0 . "hello\nmore\n"))

### a path the tree does not have is refused in git's words

```git
(def %rf (git-fixture-refs))
(write (list (git-text-in %rf "cat-file" "-p" "HEAD:nosuch") (git-oracle-in %rf "cat-file" "-p" "HEAD:nosuch")))
```
---
    ((128 . "fatal: path 'nosuch' does not exist in 'HEAD'\n") (128 . "fatal: path 'nosuch' does not exist in 'HEAD'\n"))

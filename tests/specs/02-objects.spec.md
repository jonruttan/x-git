# @weight 4

Loose objects, against git itself.  The harness makes a repository with the
system git (a blob, a tree with a subdirectory, a commit); `git-oracle` runs
git in it and `git-text` runs x-git's plan the same way, each answering
(STATUS . OUTPUT), so a case holds the two equal.

## hash-object

### a file's name is git's

```git
(write (list (git-text "hash-object" "f.txt") (git-oracle "hash-object" "f.txt")))
```
---
    ((0 . "ce013625030ba8dba906f756967f9e9ca394464a\n") (0 . "ce013625030ba8dba906f756967f9e9ca394464a\n"))

### several files, a line each

```git
(write (equal? (git-text "hash-object" "f.txt" "sub/g") (git-oracle "hash-object" "f.txt" "sub/g")))
```
---
    #t

### a file that is not there is refused in git's words

```git
(write (list (git-text "hash-object" "nosuch") (git-oracle "hash-object" "nosuch")))
```
---
    ((128 . "fatal: could not open 'nosuch' for reading: No such file or directory\n") (128 . "fatal: could not open 'nosuch' for reading: No such file or directory\n"))

### -w writes an object git reads back

The object is written as a zlib stream of stored blocks; git reads it with
libz, so this holds the stream to be one libz takes.

```git
(do
  (File write-all (Str8 append (git-fixture) "/new.txt") "written by x-git\n")
  (def %ob-r (git-text "hash-object" "-w" "new.txt"))
  (def %ob-sha (Str8 trim (rest %ob-r)))
  (write (list (first %ob-r) (= (Str8 length %ob-sha) 40)
               (str=? (rest %ob-r) (rest (git-oracle "hash-object" "new.txt")))
               (git-oracle "cat-file" "-p" %ob-sha)
               (git-oracle "cat-file" "-t" %ob-sha))))
```
---
    (0 #t #t (0 . "written by x-git\n") (0 . "blob\n"))

## cat-file

### -t, -s and -p on a blob, a tree and a commit

```git
(def %ob-same?
  (fn (_ flag rev) (equal? (git-text "cat-file" flag (git-sha rev)) (git-oracle "cat-file" flag (git-sha rev)))))
(write (List map (fn (_ flag) (List map (fn (_ rev) (%ob-same? flag rev)) (list "HEAD:f.txt" "HEAD^{tree}" "HEAD")))
                 (list "-t" "-s" "-p")))
```
---
    ((#t #t #t) (#t #t #t) (#t #t #t))

### a tree, as git lays it out

```git
(display (rest (git-text "cat-file" "-p" (git-sha "HEAD^{tree}"))))
```
---
```output
100644 blob ce013625030ba8dba906f756967f9e9ca394464a	f.txt
040000 tree 51f85781c9e5c4b9b04501df1c498c332fb6511a	sub
```

### <type> <object> prints the body

```git
(write (git-text "cat-file" "blob" (git-sha "HEAD:f.txt")))
```
---
    (0 . "hello\n")

### an abbreviated name resolves

```git
(write (git-text "cat-file" "-p" (Str8 sub 0 7 (git-sha "HEAD:f.txt"))))
```
---
    (0 . "hello\n")

### a name no object has is refused in git's words

```git
(write (list (git-text "cat-file" "-p" "nonesuch") (git-oracle "cat-file" "-p" "nonesuch")))
```
---
    ((128 . "fatal: Not a valid object name nonesuch\n") (128 . "fatal: Not a valid object name nonesuch\n"))

### -e answers in the status alone

```git
(write (list (git-text "cat-file" "-e" (git-sha "HEAD:f.txt"))
             (git-text "cat-file" "-e" "0000000000000000000000000000000000000000")
             (git-oracle "cat-file" "-e" "0000000000000000000000000000000000000000")))
```
---
    ((0 . "") (1 . "") (1 . ""))

### no object with -p, and no arguments at all: status 129

The usage text is x-git's layout; the leading line and the status are git's.

```git
(def %ob-r (git-text "cat-file" "-p"))
(write (list (first %ob-r) (first (Str8 split "\n" (rest %ob-r))) (first (git-text "cat-file"))))
```
---
    (129 "fatal: <object> required with '-p'" 129)

### an unknown option, in git's words

```git
(def %ob-r (git-text "cat-file" "--frob"))
(write (list (first %ob-r) (first (Str8 split "\n" (rest %ob-r)))))
```
---
    (129 "error: unknown option `frob'")

## the repository

### outside one, a command that needs it says so

```git
(def %ob-r (git-run (git-plan (list "-C" "/" "cat-file" "-t" "ce013625030ba8dba906f756967f9e9ca394464a"))))
(write (list (first (rest (rest %ob-r))) (first (rest %ob-r))))
```
---
    (128 "fatal: not a git repository (or any of the parent directories): .git\n")

### the repository is found from a subdirectory

```git
(write (git-run (git-plan (list "-C" (Str8 append (git-fixture) "/sub") "cat-file" "-t" (git-sha "HEAD")))))
```
---
    ('out "commit\n" 0)

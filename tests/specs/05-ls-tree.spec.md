# @weight 2

ls-tree, against git itself, on the loose fixture (a blob and a
subdirectory) and the refs fixture (two commits).

## ls-tree

### a tree, its entries recursed, trees among them, sizes, names alone

```git
(def %lt-same?
  (fn (_ . ops) (equal? (apply git-text (pair "ls-tree" ops)) (apply git-oracle (pair "ls-tree" ops)))))
(write (list (%lt-same? "HEAD") (%lt-same? "-r" "HEAD") (%lt-same? "-r" "-t" "HEAD")
             (%lt-same? "-l" "HEAD") (%lt-same? "-r" "-l" "HEAD") (%lt-same? "--name-only" "HEAD")
             (%lt-same? "-r" "--name-only" "HEAD")))
```
---
    (#t #t #t #t #t #t #t)

### the layout, as git lays it out

```git
(display (rest (git-text "ls-tree" "-l" "HEAD")))
```
---
```output
100644 blob ce013625030ba8dba906f756967f9e9ca394464a       6	f.txt
040000 tree 51f85781c9e5c4b9b04501df1c498c332fb6511a       -	sub
```

### a path names an entry; a path with a slash names a tree's contents

```git
(def %lt-same?
  (fn (_ . ops) (equal? (apply git-text (pair "ls-tree" ops)) (apply git-oracle (pair "ls-tree" ops)))))
(write (list (%lt-same? "HEAD" "sub") (%lt-same? "HEAD" "sub/") (%lt-same? "HEAD" "f.txt")
             (%lt-same? "HEAD" "nosuch") (%lt-same? "-r" "HEAD" "sub")))
```
---
    (#t #t #t #t #t)

### any tree-ish: a tag, a tree, an older commit

```git
(def %rf (git-fixture-refs))
(def %lt-same-in?
  (fn (_ . ops) (equal? (apply git-text-in (pair %rf (pair "ls-tree" ops))) (apply git-oracle-in (pair %rf (pair "ls-tree" ops))))))
(write (list (%lt-same-in? "v1") (%lt-same-in? "HEAD^{tree}") (%lt-same-in? "-r" "HEAD~1") (%lt-same-in? "HEAD:sub")))
```
---
    (#t #t #t #t)

### a revision nothing answers to, and no revision at all

```git
(write (list (git-text "ls-tree" "nosuch") (first (git-text "ls-tree")) (first (git-oracle "ls-tree"))))
```
---
    ((128 . "fatal: Not a valid object name nosuch\n") 129 129)

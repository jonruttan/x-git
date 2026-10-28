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

## as git's xdiff makes it

### a change slid where the indent heuristic scores it best

Two `}` lines in a row: the new one could be shown before or after the
old.  Without the heuristic git shows it after; with it, before, the
line above being indented more.

```git
(display (git-hunks "f()\n\tx;\n}\n\ty;\n" "f()\n\tx;\n}\n}\n\ty;\n"))
```
---
```output
@@ -1,4 +1,5 @@
 f()
 	x;
+}
 }
 	y;
```

### a hunk headed by the line that starts its function

```git
(display (git-hunks "int main(void)\n{\n  one;\n  two;\n  three;\n  four;\n  five;\n  six;\n}\n"
                    "int main(void)\n{\n  one;\n  two;\n  three;\n  four;\n  five;\n  SIX;\n}\n"))
```
---
```output
@@ -5,5 +5,5 @@ int main(void)
   three;
   four;
   five;
-  six;
+  SIX;
 }
```

### lines alike many times over, moved, added and dropped, as git shows them

```git
(def %df (git-fixture))
(def %put (fn (_ name text) (File write-all (Str8 append %df "/" name) text)))
(%put "x1" "a\nb\nc\na\nb\nc\na\nb\nc\n")
(%put "x2" "}\n{\n\treturn 0;\n}\n\n{\n\treturn 0;\n}\n")
(%put "x3" "b\nc\nline 2\nc\n\treturn 0;\n}\n\treturn 0;\nline 1\n    ")
(%put "x4" "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\n")
(git-oracle "add" "x1" "x2" "x3" "x4")
(%put "x1" "c\nb\na\nb\nc\na\nc\nb\n")
(%put "x2" "{\n\treturn 0;\n}\n\n{\n\treturn 1;\n}\n\n}\n")
(%put "x3" "b\nc\nline 2\nc\n\treturn 0;\n}\n}\n\treturn 0;\nline 1\n    \n")
(%put "x4" "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\neleven\n")
(write (list (equal? (git-text "diff" "x1" "x2" "x3" "x4") (git-oracle "diff" "x1" "x2" "x3" "x4"))
             (equal? (git-text "diff" "--stat" "x1" "x2" "x3" "x4") (git-oracle "diff" "--stat" "x1" "x2" "x3" "x4"))))
```
---
    (#t #t)

### --stat fitted to the columns, a long path cut and the bars scaled

```git
(def %df (git-fixture))
(def %long "a-rather-long-directory-name/another-rather-long-directory-name/file-with-a-long-name.txt")
(File mkdir (Str8 append %df "/a-rather-long-directory-name"))
(File mkdir (Str8 append %df "/a-rather-long-directory-name/another-rather-long-directory-name"))
(def %count (fn (self i n acc) (if (> i n) acc (self (+ i 1) n (Str8 append acc (Str8 str i) "\n")))))
(File write-all (Str8 append %df "/" %long) (%count 1 150 ""))
(git-oracle "add" %long)
(File write-all (Str8 append %df "/" %long) (%count 41 300 ""))
(write (equal? (git-text "diff" "--stat" %long) (git-oracle "diff" "--stat" %long)))
```
---
    #t

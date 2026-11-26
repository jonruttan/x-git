# @weight 2
# @timeout-scale 2

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

### A..B and its open ends; an operand neither revision nor path refused, in git's words

Before a `--` each operand must be a revision; without one, revisions
run to the first operand that is none, which and every one after must be
in the working tree.  A branch named like a file there is ambiguous.

```git
(def %rf (git-fixture-refs))
(def %rf-same? (fn (_ . ops) (equal? (apply git-text-in (pair %rf (pair "diff" ops))) (apply git-oracle-in (pair %rf (pair "diff" ops))))))
(File write-all (Str8 append %rf "/f.txt") "changed\n")
(File write-all (Str8 append %rf "/side") "a file\n")
(write (list (List map (fn (_ ops) (apply %rf-same? ops))
               (list (list "HEAD~1..HEAD") (list "HEAD~1..") (list "..HEAD~1") (list "--stat" "v1..main")
                     (list "f.txt") (list ".") (list "HEAD" "f.txt") (list "HEAD~1" "--" "nope")
                     (list "nope") (list "HEAD" "nope") (list "nope" "HEAD") (list "--cached" "nope")
                     (list "HEAD~9") (list "nope..HEAD") (list "f.txt" "nope") (list "nope" "--")
                     (list "side") (list "side" "--")))
             (git-text-in %rf "diff" "nope")
             (git-text-in %rf "diff" "f.txt" "HEAD")
             (git-text-in %rf "diff" "nope" "--" "f.txt")
             (git-text-in %rf "diff" "side")))
```
---
    ((#t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t) (128 . "fatal: ambiguous argument 'nope': unknown revision or path not in the working tree.\nUse '--' to separate paths from revisions, like this:\n'git <command> [<revision>...] -- [<file>...]'\n") (128 . "fatal: HEAD: no such path in the working tree.\nUse 'git <command> -- <path>...' to specify paths that do not exist locally.\n") (128 . "fatal: bad revision 'nope'\n") (128 . "fatal: ambiguous argument 'side': both revision and filename\nUse '--' to separate paths from revisions, like this:\n'git <command> [<revision>...] -- [<file>...]'\n"))

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

## modes

### a mode changed alone: diff's two mode lines, status's modified, staged or not, its hints as advice.statusHints says; core.fileMode false keeps none

```git
(def %df (git-fixture))
(def %mf (Str8 append %df "/moded"))
(File write-all %mf "m\n")
(git-oracle "add" "moded")
(git-oracle "commit" "-q" "-m" "moded")
(File chmod %mf 493)
(def %md-work (list (git-text "diff" "moded")
                    (equal? (git-text "status" "--porcelain") (git-oracle "status" "--porcelain"))
                    (equal? (git-text "status") (git-oracle "status"))
                    (do (git-oracle "config" "advice.statusHints" "false")
                        (equal? (git-text "status") (git-oracle "status")))))
(git-oracle "config" "--unset" "advice.statusHints")
(git-oracle "add" "moded")
(def %md-staged (list (equal? (git-text "diff" "--cached") (git-oracle "diff" "--cached"))
                      (equal? (git-text "diff" "HEAD" "--stat") (git-oracle "diff" "HEAD" "--stat"))
                      (equal? (git-text "status" "--porcelain") (git-oracle "status" "--porcelain"))))
(git-oracle "commit" "-q" "-m" "exec")
(git-oracle "config" "core.fileMode" "false")
(File chmod %mf 420)
(write (list %md-work %md-staged (equal? (git-text "status" "--porcelain") (git-oracle "status" "--porcelain"))
             (Str8 index-of "moded" (rest (git-text "status" "--porcelain")))))
(git-oracle "config" "core.fileMode" "true")
(File chmod %mf 493)
```
---
    (((0 . "diff --git a/moded b/moded\nold mode 100644\nnew mode 100755\n") #t #t #t) (#t #t #t) #t ())

## names, numbers and raw lines

A repository of its own: a binary file changed and one deleted, a file
changed, one deleted, one made executable, a link made a file, a file
staged and changed again, and one new and staged.  Each form is asked of
the working directory, of the index (`--cached`), of HEAD, and of two
commits.

### --name-only, --name-status, --numstat, --raw, and --stat beside them, as git gives them

```git
(def %fm (let ((t (File temp "/tmp/x-git-fm-"))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t))))
(def %fm-sh
  (fn (_ script)
    (Proc capture (list "/bin/sh" "-c"
      (Str8 append "export GIT_AUTHOR_NAME=A GIT_AUTHOR_EMAIL=a@b.c GIT_COMMITTER_NAME=C GIT_COMMITTER_EMAIL=c@d.e; cd \"$0\" && " script) %fm))))
(%fm-sh (Str8 append "git init -q -b main && printf 'a\\nb\\nc\\n' > f && echo c > g && mkdir d && echo x > d/h && printf 'one\\ntwo\\n' > m"
          " && ln -s f l && printf 'a\\0b' > bin && printf 'x\\0' > gone && git add . && git commit -qm one"
          " && echo z >> f && git commit -qam two"
          " && echo zz >> f && rm g gone && chmod +x m && printf 'a\\0cde' > bin && rm l && echo l > l"
          " && echo y >> d/h && git add d/h && echo w >> d/h && echo n > n && git add n"))
(def %fm-same? (fn (_ . ops) (equal? (apply git-text-in (pair %fm (pair "diff" ops))) (apply git-oracle-in (pair %fm (pair "diff" ops))))))
(write (list
  (List map
    (fn (_ form)
      (List map (fn (_ side) (apply %fm-same? (List append side form)))
        (list () (list "--cached") (list "HEAD") (list "HEAD~1" "HEAD"))))
    (list (list "--name-only") (list "--name-status") (list "--numstat") (list "--raw") (list "--stat")
          (list "--raw" "--numstat" "--stat") (list "--name-only" "--stat") (list "--name-status" "--raw")
          ()))
  (%fm-same? "--raw" "--" "f" "m")
  (git-text-in %fm "diff" "--name-status")
  (git-text-in %fm "diff" "--numstat" "--" "bin" "f")
  (git-text-in %fm "diff" "--raw" "HEAD" "--" "bin" "d" "n")
  (git-text-in %fm "diff" "--stat" "--" "bin" "f")
  (git-text-in %fm "diff" "--name-only" "--name-status")))
```
---
    (((#t #t #t #t) (#t #t #t #t) (#t #t #t #t) (#t #t #t #t) (#t #t #t #t) (#t #t #t #t) (#t #t #t #t) (#t #t #t #t) (#t #t #t #t)) #t (0 . "M\tbin\nM\td/h\nM\tf\nD\tg\nD\tgone\nT\tl\nM\tm\n") (0 . "-\t-\tbin\n1\t0\tf\n") (0 . ":100644 100644 20b5be9 0000000 M\tbin\n:100644 100644 587be6b 0000000 M\td/h\n:000000 100644 0000000 8ba3a16 A\tn\n") (0 . " bin | Bin 3 -> 5 bytes\n f   |   1 +\n 2 files changed, 1 insertion(+)\n") (128 . "fatal: options '--name-only', '--name-status', '--check', and '-s' cannot be used together\n"))

## renames

A repository of its own: a file renamed and changed, one moved within a
directory, one renamed and made executable, a binary file renamed to a
name with a space and changed, committed by git; then a rename staged
to a name that needs quoting and its file changed after, and one staged
changed and changed again.  Each form is asked of the working directory
against HEAD, of the index, and of the two commits; log and show draw
them too.  Then x-git and git each commit the staged renames, in copies
of the repository of their own.

### a file deleted and one added that is the same or alike, one change: as git shows it in each form, against the working directory and HEAD

```git
(Sys setenv "GIT_AUTHOR_NAME" "A")
(Sys setenv "GIT_AUTHOR_EMAIL" "a@b.c")
(Sys setenv "GIT_COMMITTER_NAME" "C")
(Sys setenv "GIT_COMMITTER_EMAIL" "c@d.e")
(def %rn (let ((t (File temp "/tmp/x-git-rn-"))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t))))
(Proc capture (list "/bin/sh" "-c"
  (Str8 append "cd \"$0\" && git init -q -b main r && cd r && seq 1 10 > a && mkdir d && printf 'x\\ny\\nz\\n' > d/f && echo keep > k && echo m > m"
    " && printf 'bin\\0ary\\n%.0s' 1 2 3 4 5 6 7 8 > bin && seq 1 20 > s && git add . && git commit -qm one"
    " && git mv a b && seq 1 9 > b && echo ten >> b && git mv d/f d/g && git mv m e && chmod +x e"
    " && git mv bin 'sp ace' && printf X >> 'sp ace' && git add . && git commit -qm two"
    " && e=$(printf '\\303\\251') && git mv k \"$e\" && echo more >> \"$e\""
    " && git mv s 's 2' && echo 21 >> 's 2' && git add 's 2' && echo 22 >> 's 2'"
    " && cd .. && cp -R r x && cp -R r g")
  %rn))
(def %rn-r (Str8 append %rn "/r"))
; the lines whose answers differ; each line's garbage collected after it
(def %rn-steps
  (fn (_ lines)
    (List flat-map
      (fn (_ ops)
        (let ((same? (equal? (apply git-text-in (pair %rn-r ops)) (apply git-oracle-in (pair %rn-r ops)))))
          (do (Heap collect) (if same? () (list ops)))))
      lines)))
(def %rn-forms
  (fn (_ sides)
    (List flat-map
      (fn (_ form) (List map (fn (_ side) (pair "diff" (List append side form))) sides))
      (list (list "--name-only") (list "--name-status") (list "--numstat") (list "--raw") (list "--stat")
            (list "--raw" "--numstat" "--stat") ()))))
(write (%rn-steps (%rn-forms (list () (list "HEAD")))))
```
---
    ()

### and against the index and between two commits, a path limiting them

```git
(write (%rn-steps (List append (%rn-forms (list (list "--cached") (list "HEAD~1" "HEAD")))
                    (list (list "diff" "--cached" "--" "s 2") (list "diff" "HEAD~1" "HEAD" "--" "b" "e")))))
```
---
    ()

### in log and show, and in commit's summary, made by x-git and by git in copies

```git
(def %rn-summary (fn (_ r) (rest (Str8 split "\n" (rest r)))))
(def %rn-x (%rn-summary (git-text-in (Str8 append %rn "/x") "commit" "-m" "three")))
(def %rn-g (%rn-summary (git-oracle-in (Str8 append %rn "/g") "commit" "-m" "three")))
(write (list
  (%rn-steps
    (list (list "log" "-p") (list "log" "--stat") (list "log" "--oneline" "--stat") (list "show" "HEAD") (list "show" "--stat" "HEAD")))
  (equal? %rn-x %rn-g)
  %rn-x))
```
---
    (() #t (" Author: A <a@b.c>" " 2 files changed, 1 insertion(+)" " rename s => s 2 (94%)" " rename k => \"\\303\\251\" (100%)" ""))

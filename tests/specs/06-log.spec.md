# @weight 2

log, against git itself, on the refs fixture: two commits, an annotated
tag on the first.  The date line is the author's time in the author's
own offset, as git prints it.

## log

### the whole history, as git lays it out

```git
(def %rf (git-fixture-refs))
(write (equal? (git-text-in %rf "log") (git-oracle-in %rf "log")))
```
---
    #t

### --oneline, and -n

```git
(def %rf (git-fixture-refs))
(def %lg-same?
  (fn (_ . ops) (equal? (apply git-text-in (pair %rf (pair "log" ops))) (apply git-oracle-in (pair %rf (pair "log" ops))))))
(write (list (%lg-same? "--oneline") (%lg-same? "-n" "1") (%lg-same? "--oneline" "-n" "1") (%lg-same? "--max-count" "1")))
```
---
    (#t #t #t #t)

### from a revision: a tag, an older commit, a branch

```git
(def %rf (git-fixture-refs))
(def %lg-same?
  (fn (_ . ops) (equal? (apply git-text-in (pair %rf (pair "log" ops))) (apply git-oracle-in (pair %rf (pair "log" ops))))))
(write (list (%lg-same? "v1") (%lg-same? "HEAD~1") (%lg-same? "--oneline" "side")))
```
---
    (#t #t #t)

### the shape of one entry

```git
(def %rf (git-fixture-refs))
(def %lg-lines (Str8 split "\n" (rest (git-text-in %rf "log" "-n" "1" "HEAD~1"))))
(write (list (List length %lg-lines) (Str8 sub 0 7 (first %lg-lines)) (List ref 1 %lg-lines)
             (Str8 sub 0 8 (List ref 2 %lg-lines)) (List ref 3 %lg-lines) (List ref 4 %lg-lines)))
```
---
    (6 "commit " "Author: A <a@b.c>" "Date:   " "" "    one")

### a revision nothing answers to is refused in git's words

```git
(def %rf (git-fixture-refs))
(write (equal? (git-text-in %rf "log" "nosuch") (git-oracle-in %rf "log" "nosuch")))
```
---
    #t

### merges whose commits share a time, and one dated before its parent

Commits with the same time come out as git's queue holds them, the
first queued first: a merge's first parent before its second.

```git
(def %lg-d (let ((t (File temp "/tmp/x-git-lg-"))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t))))
(Proc run! (list "/bin/sh" "-c"
  (Str8 append "cd \"$0\" && export GIT_AUTHOR_NAME=A GIT_AUTHOR_EMAIL=a@b.c GIT_COMMITTER_NAME=A GIT_COMMITTER_EMAIL=a@b.c && git init -q -b main ."
    " && c() { GIT_COMMITTER_DATE=\"@$1 +0000\" GIT_AUTHOR_DATE=\"@$1 +0000\" git commit -q --allow-empty -m \"$2\"; }"
    " && m() { GIT_COMMITTER_DATE=\"@$1 +0000\" GIT_AUTHOR_DATE=\"@$1 +0000\" git merge -q --no-ff \"$2\" -m \"$3\"; }"
    " && c 1000000 a && git branch x && c 2000000 b && git checkout -q x && c 2000000 c && c 500000 skew"
    " && git checkout -q main && m 2000000 x m1 && git checkout -q x && c 2000000 d && m 2000000 main m2"
    " && git checkout -q main && m 2000000 x m3")
  %lg-d))
(def %lg-same? (fn (_ . ops) (let ((x (apply git-text-in (pair %lg-d (pair "log" ops)))) (g (apply git-oracle-in (pair %lg-d (pair "log" ops))))) (if (equal? x g) #t (list x g)))))
(write (list (%lg-same? "--oneline") (%lg-same? "--oneline" "x") (%lg-same? "-n" "4") (%lg-same?)))
```
---
    (#t #t #t #t)

## counts and formats

### -<number>, the last count given

```git
(def %rf (git-fixture-refs))
(def %lg-same?
  (fn (_ . ops) (equal? (apply git-text-in (pair %rf (pair "log" ops))) (apply git-oracle-in (pair %rf (pair "log" ops))))))
(write (list (%lg-same? "-1") (%lg-same? "-1" "--oneline") (%lg-same? "-2" "-1") (%lg-same? "-1" "-2")
             (%lg-same? "-n" "2" "-1") (%lg-same? "-0")))
```
---
    (#t #t #t #t #t #t)

### a user's format, git's forms, and a format git has none of

A user's format ends each commit with a newline (--format, tformat:),
or sets them apart with one (format:); git's forms of several lines
set them apart with a blank line.  A subject of two lines is one line
in oneline's forms.

```git
(def %lg-d (let ((t (File temp "/tmp/x-git-lg-"))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t))))
(Proc run! (list "/bin/sh" "-c"
  (Str8 append "cd \"$0\" && export GIT_AUTHOR_NAME=A GIT_AUTHOR_EMAIL=a@b.c GIT_COMMITTER_NAME=C GIT_COMMITTER_EMAIL=c@d.e"
    " GIT_AUTHOR_DATE='1767225600 +0100' GIT_COMMITTER_DATE='1767229200 -0500' && git init -q -b main ."
    " && git commit -q --allow-empty -m one && git branch x && printf 'two\\nlines\\n\\nbody\\n' | git commit -q --allow-empty -F -"
    " && git checkout -q x && git commit -q --allow-empty -m side && git checkout -q main && git merge -q --no-ff x -m merged")
  %lg-d))
; garbage collected after each, as fourteen logs leave a lot
(def %lg-same? (fn (_ . ops) (let ((x (apply git-text-in (pair %lg-d (pair "log" ops)))) (g (apply git-oracle-in (pair %lg-d (pair "log" ops))))) (do (Heap collect) (if (equal? x g) #t (list x g))))))
(write (list (%lg-same? "--format=%h %s|%an %ae %ad|%cn %ce %cd|%p") (%lg-same? "--pretty=format:%h%n%b") (%lg-same? "--pretty=tformat:%B")
             (%lg-same? "--pretty=%H") (%lg-same? "--oneline") (%lg-same? "--pretty=oneline") (%lg-same? "--format=oneline")
             (%lg-same? "--pretty=short") (%lg-same? "--pretty=medium") (%lg-same? "--pretty=full") (%lg-same? "--pretty=fuller")
             (%lg-same? "-2" "--oneline" "--format=%s") (%lg-same? "--pretty=nope") (%lg-same? "--format=nope")))
```
---
    (#t #t #t #t #t #t #t #t #t #t #t #t #t #t)

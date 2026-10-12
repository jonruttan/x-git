# @weight 4
# @timeout-scale 2

rm, mv and .gitignore, against git itself.  Each case builds the same
repository twice with git, has x-git act on one and git on the other,
and compares what the two say and what git then sees in each.  `%pt-make`
builds a fixture in a fresh directory from a script; `%pt-twin` runs one
command line in both and answers (SAME-OUTPUT? X-GIT-OUTPUT SAME-STATUS?).

## rm

### a file, a directory with -r, --cached and -q: as git removes them

```git
(def %pt-dir (fn (_) (def t (File temp "/tmp/x-git-pt-")) (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t)))
(def %pt-git "git -c user.email=a@b.c -c user.name=A")
(def %pt-make (fn (_ script) (def d (%pt-dir)) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd " d " && git init -q -b main . && " script))) d))
(def %pt-base (Str8 append "printf 'hello\\n' > f.txt && mkdir -p sub/deep && printf x > sub/g && printf y > sub/deep/h && printf z > k.txt && git add . && " %pt-git " commit -qm init"))
; git prints rm's "(use --cached ...)" line only with advice.rmHints on, which the
; macOS runner's git has off: both sides are compared without it.
(def %pt-plain (fn (_ r) (pair (first r) (Str8 join "\n" (List filter (fn (_ l) (not (Str8 starts? "(use" l))) (Str8 split "\n" (rest r)))))))
(def %pt-twin (fn (_ script . ops)
  (def a (%pt-make script))
  (def b (%pt-make script))
  (def x (apply git-text-in (pair a ops)))
  (def g (apply git-oracle-in (pair b ops)))
  (list (equal? (%pt-plain x) (%pt-plain g)) x (equal? (git-oracle-in a "status" "--porcelain") (git-oracle-in b "status" "--porcelain"))
        (equal? (git-oracle-in a "ls-files") (git-oracle-in b "ls-files")))))
(write (list (%pt-twin %pt-base "rm" "f.txt")
             (%pt-twin %pt-base "rm" "-r" "sub")
             (%pt-twin %pt-base "rm" "--cached" "f.txt")
             (%pt-twin %pt-base "rm" "-q" "k.txt")))
```
---
    ((#t (0 . "rm 'f.txt'\n") #t #t) (#t (0 . "rm 'sub/deep/h'\nrm 'sub/g'\n") #t #t) (#t (0 . "rm 'f.txt'\n") #t #t) (#t (0 . "") #t #t))

### a directory removed whole leaves no directory behind

```git
(def %pt-r (%pt-make %pt-base))
(git-text-in %pt-r "rm" "-r" "sub")
(write (list (File exists? (Str8 append %pt-r "/sub")) (File exists? (Str8 append %pt-r "/f.txt"))))
```
---
    (#f #t)

### refusals in git's words: an unknown path, a directory without -r, a changed file

```git
(write (list (%pt-twin %pt-base "rm" "nosuch")
             (%pt-twin %pt-base "rm" "sub")
             (%pt-twin (Str8 append %pt-base " && printf more >> f.txt") "rm" "f.txt")
             (%pt-twin (Str8 append %pt-base " && printf more >> f.txt && git add f.txt") "rm" "f.txt")
             (%pt-twin (Str8 append %pt-base " && printf more >> f.txt") "rm" "-f" "f.txt")))
```
---
    ((#t (128 . "fatal: pathspec 'nosuch' did not match any files\n") #t #t) (#t (128 . "fatal: not removing 'sub' recursively without -r\n") #t #t) (#t (1 . "error: the following file has local modifications:\n    f.txt\n(use --cached to keep the file, or -f to force removal)\n") #t #t) (#t (1 . "error: the following file has changes staged in the index:\n    f.txt\n(use --cached to keep the file, or -f to force removal)\n") #t #t) (#t (0 . "rm 'f.txt'\n") #t #t))

## mv

### a file renamed, moved into a directory, a directory renamed, several moved: as git moves them

```git
(write (list (%pt-twin %pt-base "mv" "f.txt" "renamed.txt")
             (%pt-twin %pt-base "mv" "f.txt" "sub")
             (%pt-twin %pt-base "mv" "sub" "moved")
             (%pt-twin %pt-base "mv" "f.txt" "k.txt" "sub")
             (%pt-twin (Str8 append %pt-base " && printf more >> f.txt") "mv" "f.txt" "m.txt")
             (%pt-twin %pt-base "mv" "-v" "f.txt" "v.txt")))
```
---
    ((#t (0 . "") #t #t) (#t (0 . "") #t #t) (#t (0 . "") #t #t) (#t (0 . "") #t #t) (#t (0 . "") #t #t) (#t (0 . "Renaming f.txt to v.txt\n") #t #t))

### the files follow: a renamed directory's contents, and nothing left where they were

```git
(def %pt-m (%pt-make %pt-base))
(git-text-in %pt-m "mv" "sub" "moved")
(write (list (File exists? (Str8 append %pt-m "/sub")) (File read-all (Str8 append %pt-m "/moved/deep/h"))
             (git-oracle-in %pt-m "status" "--porcelain")))
```
---
    (#f "y" (0 . "R  sub/deep/h -> moved/deep/h\nR  sub/g -> moved/g\n"))

### onto a path that exists: refused, or replaced with -f

```git
(write (list (%pt-twin %pt-base "mv" "f.txt" "k.txt")
             (%pt-twin %pt-base "mv" "-f" "f.txt" "k.txt")))
```
---
    ((#t (128 . "fatal: destination exists, source=f.txt, destination=k.txt\n") #t #t) (#t (0 . "") #t #t))

### refusals in git's words

```git
(write (list (%pt-twin %pt-base "mv" "nosuch" "x")
             (%pt-twin (Str8 append %pt-base " && printf u > u.txt") "mv" "u.txt" "v.txt")
             (%pt-twin %pt-base "mv" "sub" "sub/deep")
             (%pt-twin %pt-base "mv" "f.txt" "k.txt" "sub/g")
             (%pt-twin %pt-base "mv" "f.txt" "nodir/f.txt")
             (%pt-twin %pt-base "mv" "-k" "nosuch" "x")))
```
---
    ((#t (128 . "fatal: bad source, source=nosuch, destination=x\n") #t #t) (#t (128 . "fatal: not under version control, source=u.txt, destination=v.txt\n") #t #t) (#t (128 . "fatal: can not move directory into itself, source=sub, destination=sub/deep/sub\n") #t #t) (#t (128 . "fatal: destination 'sub/g' is not a directory\n") #t #t) (#t (128 . "fatal: renaming 'f.txt' failed: No such file or directory\n") #t #t) (#t (0 . "") #t #t))

## .gitignore

### every kind of pattern, nested files and info/exclude: status as git shows it

```git
(def %pt-ig (Str8 append %pt-base
  " && printf '# comment\\n*.log\\nbuild/\\n/top.tmp\\n!keep.log\\ntmp\\nsub/*.o\\n**/gen\\n  \\nspace\\\\ name\\n' > .gitignore"
  " && mkdir -p build logs sub/x deep/tmp sub/deep/gen && printf a > a.log && printf b > keep.log && printf c > top.tmp"
  " && printf d > sub/x/top.tmp && printf e > build/out && printf f > logs/l.log && printf g > tmp && printf h > deep/tmp/z"
  " && printf i > sub/o.o && printf j > o.o && printf k > sub/deep/gen/q && printf l > 'space name' && printf m > sub/deep/n.txt"
  " && printf 'local\\nn.txt\\n' > sub/.gitignore && printf 'q.txt\\n' > .git/info/exclude && printf o > q.txt"))
(def %pt-i (%pt-make %pt-ig))
(write (list (equal? (git-text-in %pt-i "status" "--porcelain") (git-oracle-in %pt-i "status" "--porcelain"))
             (git-text-in %pt-i "status" "--porcelain")))
```
---
    (#t (0 . "?? .gitignore\n?? keep.log\n?? o.o\n?? sub/.gitignore\n?? sub/x/\n"))

### add refuses an ignored path in git's words, takes it with -f, and skips ignored files under a directory

```git
(write (list (%pt-twin %pt-ig "add" "a.log")
             (%pt-twin %pt-ig "add" "-f" "a.log")
             (%pt-twin %pt-ig "add" "logs")
             (%pt-twin %pt-ig "add" ".")))
```
---
    ((#t (1 . "The following paths are ignored by one of your .gitignore files:\na.log\nhint: Use -f if you really want to add them.\nhint: Disable this message with \"git config set advice.addIgnoredFile false\"\n") #t #t) (#t (0 . "") #t #t) (#t (0 . "") #t #t) (#t (0 . "") #t #t))

### a directory ignored takes a tracked directory's untracked files with it

```git
(def %pt-j (%pt-make (Str8 append %pt-ig " && printf 'sub/\\n' >> .gitignore")))
(write (list (equal? (git-text-in %pt-j "status" "--porcelain") (git-oracle-in %pt-j "status" "--porcelain"))
             (git-text-in %pt-j "status" "--porcelain")))
```
---
    (#t (0 . "?? .gitignore\n?? keep.log\n?? o.o\n"))

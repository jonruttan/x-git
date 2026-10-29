# @weight 3
# @timeout-scale 2

Paths quoted as git quotes them, against git itself.  A repository
holds a name with a tab, one with a multibyte character, one with a
space and a plain one, each changed in the working directory, with new
files of each kind beside them.  Every command that names a path names
these as git does -- in double quotes, C's escapes and octal for the
bytes that need them, a space quoted only in short status -- and what
x-git and git print and end with is compared.  Then what a commit, a
fast-forward's rename and a mixed reset print -- the reset's paths bare,
as git leaves them -- each done twice: once by x-git, once by git, in
two copies of one repository.

## what names a path

### status, ls-files, ls-tree, cat-file, diff, show and clean -n

```git
(List for-each (fn (_ e) (Sys setenv (first e) (rest e)))
  (list (pair "GIT_AUTHOR_NAME" "A") (pair "GIT_AUTHOR_EMAIL" "a@b.c") (pair "GIT_AUTHOR_DATE" "1767225600 +0000")
        (pair "GIT_COMMITTER_NAME" "A") (pair "GIT_COMMITTER_EMAIL" "a@b.c") (pair "GIT_COMMITTER_DATE" "1767225600 +0000")))
; a repository: the four names committed, three of them changed, new
; files beside them
(def %qt-make
  (fn (_)
    (def t (File temp "/tmp/x-git-qt-"))
    (File close (first t)) (File unlink (rest t)) (File mkdir (rest t))
    (Proc run! (list "/bin/sh" "-c"
      (Str8 append "cd \"$0\" && git init -q -b main . && te=$(printf 't\\303\\251.txt') && tab=$(printf 'q\\tt.txt')"
        " && printf 'a\\n' > \"$te\" && printf 'b\\n' > \"$tab\" && printf 'c\\n' > plain.txt && printf 's\\n' > 'sp ace.txt'"
        " && git add . && git commit -qm one"
        " && printf 'x\\n' >> \"$te\" && printf 'y\\n' >> \"$tab\" && printf 'z\\n' >> 'sp ace.txt'"
        " && printf 'd\\n' > \"$(printf 'n\\303\\251w.txt')\" && printf 'e\\n' > 'un sp.txt' && printf 'f\\n' > 'b\\\\s.txt'")
      (rest t)))
    (rest t)))
(def %qt-d (%qt-make))
(def %qt-same
  (fn (_ . ops)
    (def args (pair "-c" (pair "core.excludesFile=/dev/null" (pair "-c" (pair "advice.statusHints=true" ops)))))
    (def x (apply git-text-in (pair %qt-d args)))
    (def g (apply git-oracle-in (pair %qt-d args)))
    (if (equal? x g) #t (list x g))))
(write (list (%qt-same "status" "--porcelain")
             (%qt-same "status" "-s")
             (%qt-same "status")
             (%qt-same "ls-files")
             (%qt-same "ls-files" "-o")
             (%qt-same "ls-files" "-s")
             (%qt-same "ls-tree" "HEAD")
             (%qt-same "ls-tree" "-l" "HEAD")
             (%qt-same "ls-tree" "--name-only" "HEAD")
             (%qt-same "cat-file" "-p" "HEAD^{tree}")
             (%qt-same "diff")
             (%qt-same "diff" "--stat")
             (%qt-same "show" "--stat" "--format=%s" "HEAD")
             (%qt-same "show" "--format=%s" "HEAD")
             (%qt-same "clean" "-n")))
```
---
    (#t #t #t #t #t #t #t #t #t #t #t #t #t #t #t)

### what they look like: a short status and a diffstat

```git
(write (list (git-text-in %qt-d "status" "-s")
             (git-text-in %qt-d "diff" "--stat")))
```
---
    ((0 . " M \"q\\tt.txt\"\n M \"sp ace.txt\"\n M \"t\\303\\251.txt\"\n?? \"b\\\\\\\\s.txt\"\n?? \"n\\303\\251w.txt\"\n?? \"un sp.txt\"\n") (0 . " \"q\\tt.txt\"      | 1 +\n sp ace.txt      | 1 +\n \"t\\303\\251.txt\" | 1 +\n 3 files changed, 3 insertions(+)\n"))

## what changes say

### a commit's created files, a fast-forward's rename, a mixed reset's changes

```git
(Proc run! (list "/bin/sh" "-c" "rm -rf \"$0\"" %qt-d))
(Heap collect)
; x-git's run of ops in one copy, git's in the other, the steps before
; them done by git in both; #t when both say and end the same
(def %qt-twin
  (fn (_ before . ops)
    (def a (%qt-make))
    (def b (%qt-make))
    (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " before) a))
    (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " before) b))
    (def x (apply git-text-in (pair a ops)))
    (def g (apply git-oracle-in (pair b ops)))
    (Proc run! (list "/bin/sh" "-c" "rm -rf \"$0\" \"$1\"" a b))
    (Heap collect)
    (if (equal? x g) #t (list x g))))
(write (list (%qt-twin "git add -A" "commit" "-m" "two")
             (%qt-twin "git reset -q --hard && git clean -qfd && git checkout -q -b side && git mv \"$(printf 't\\303\\251.txt')\" 'mo ved.txt' && git commit -qm mv && git checkout -q main"
                       "merge" "side")
             (%qt-twin "git add -A" "reset")))
```
---
    (#t #t #t)

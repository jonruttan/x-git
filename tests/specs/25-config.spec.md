# @weight 4
# @timeout-scale 3

git config, against git itself.  Each case makes twins: a repository
made by git, and a home of its own, under x/ and g/; the system's file
is left out (GIT_CONFIG_NOSYSTEM).  The same command lines run in both
-- x-git's in one, git's in the other, each with HOME its own twin's --
and what each prints, on standard output and error apart, and what it
exits with, is compared, then the files they leave, byte for byte.

## reading and writing

### set, get and list, the repository's and the user's

```git
(Sys setenv "GIT_CONFIG_NOSYSTEM" "1")
(Sys unsetenv "XDG_CONFIG_HOME")
(Sys unsetenv "GIT_CONFIG_GLOBAL")
(def %cf-d ())
(def %cf-sh (fn (_ dir script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) dir))))
; twins: x/home x/r and g/home g/r
(def %cf-twins
  (fn (_)
    (def t (File temp "/tmp/x-git-cf-"))
    (File close (first t)) (File unlink (rest t)) (File mkdir (rest t))
    (set! %cf-d (rest t))
    (%cf-sh %cf-d "mkdir -p x/home g/home && git init -q x/r && git init -q g/r")))
(def %cf-x
  (fn (_ dir ops)
    (Sys setenv "HOME" (Str8 append %cf-d "/x/home"))
    (def r (git-run (git-plan (pair "-C" (pair (Str8 append %cf-d "/x/" dir) ops)))))
    (def text (first (rest r)))
    (if (eq? (first r) (lit out)) (list (first (rest (rest r))) text "") (list (first (rest (rest r))) "" text))))
(def %cf-g
  (fn (_ dir ops)
    (Sys setenv "HOME" (Str8 append %cf-d "/g/home"))
    (def r (Proc capture (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git \"$@\" 2>\"$0/../git.err\"" (pair (Str8 append %cf-d "/g/" dir) ops))))))
    (list (first r) (rest r) (File read-all (Str8 append %cf-d "/g/" dir "/../git.err")))))
; each line run in both: the lines whose answers differ, as (OPS X GIT);
; a twin's own directory, in what is printed, read as the other's
(def %cf-plain
  (fn (_ r side)
    (List map (fn (_ v) (if (str? v) (Str8 replace (Str8 append %cf-d "/" side "/") "TWIN/" v) v)) r)))
(def %cf-steps
  (fn (_ dir lines)
    (List flat-map
      (fn (_ ops)
        (let ((x (%cf-plain (%cf-x dir ops) "x")) (g (%cf-plain (%cf-g dir ops) "g")))
          (if (equal? x g) () (list (list ops x g)))))
      lines)))
(def %cf-file (fn (_ side path) (let ((p (Str8 append %cf-d "/" side "/" path))) (if (File exists? p) (File read-all p) ()))))
(def %cf-files-same? (fn (_ . paths) (List all? (fn (_ p) (equal? (%cf-file "x" p) (%cf-file "g" p))) paths)))
(%cf-twins)
(write (list
  (%cf-steps "r"
    (list (list "config" "user.name")
          (list "config" "user.name" "Ann Lee")
          (list "config" "--global" "user.email" "a@b.c")
          (list "config" "--global" "user.name" "Global Name")
          (list "config" "user.email")
          (list "config" "user.name")
          (list "config" "--global" "user.name")
          (list "config" "get" "user.name")
          (list "config" "--show-origin" "user.email")
          (list "config" "--show-scope" "--list")
          (list "config" "--show-origin" "--list" "--local")
          (list "config" "list" "--global")
          (list "config" "--list" "--name-only")
          (list "config" "Core.FileMode")
          (list "config" "--bool" "core.filemode")
          (list "config" "--int" "core.repositoryformatversion")
          (list "config" "nope.here")))
  (%cf-files-same? "r/.git/config" "home/.gitconfig")))
```
---
    (() #t)

### a file's syntax, read as git reads it

```git
(%cf-twins)
(def %cf-text
  (Str8 append
    "# a comment\n[Sec \"Sub\"]  ; and another\n\tKey = value with  spaces   # inline\n\tflag\n\tempty =\n"
    "\tcont = one \\\ntwo\n\tq = \"a;b\" c\\td \" e \"\n[sec.old]\n\tk = v\n[nums]\n\tt1 = yes\n\tt2 = off\n\tn1 = 1k\n\tn2 = -3\n"))
(File write-all (Str8 append %cf-d "/x/r/f.cfg") %cf-text)
(File write-all (Str8 append %cf-d "/g/r/f.cfg") %cf-text)
(write
  (%cf-steps "r"
    (list (list "config" "-f" "f.cfg" "--list")
          (list "config" "-f" "f.cfg" "sec.Sub.key")
          (list "config" "-f" "f.cfg" "sec.sub.key")
          (list "config" "-f" "f.cfg" "sec.Sub.flag")
          (list "config" "-f" "f.cfg" "--bool" "sec.Sub.flag")
          (list "config" "-f" "f.cfg" "--bool" "sec.Sub.empty")
          (list "config" "-f" "f.cfg" "sec.Sub.q")
          (list "config" "-f" "f.cfg" "--bool" "nums.t1")
          (list "config" "-f" "f.cfg" "--bool" "nums.t2")
          (list "config" "-f" "f.cfg" "--int" "nums.n1")
          (list "config" "-f" "f.cfg" "--int" "nums.n2")
          (list "config" "-f" "f.cfg" "--bool" "nums.n1")
          (list "config" "-f" "f.cfg" "--int" "sec.Sub.key")
          (list "config" "-f" "f.cfg" "sec.old.k"))))
```
---
    ()

### values written as git writes them

```git
(%cf-twins)
(write (list
  (%cf-steps "r"
    (list (list "config" "a.lead" " lead")
          (list "config" "a.quote" "q\"uo#te")
          (list "config" "a.semi" "x;y")
          (list "config" "a.tab" "x\ty")
          (list "config" "Core.Editor2" "vi -x")
          (list "config" "Foo.Sub.Bar" "x")
          (list "config" "NEWsec.Key" "y")
          (list "config" "a.lead" "replaced")
          (list "config" "a.lead")
          (list "config" "--bool" "flags.on" "yes")
          (list "config" "--int" "nums.big" "2k")))
  (%cf-files-same? "r/.git/config")))
```
---
    (() #t)

### several values: --add, get-all, set's refusal, --all, unset

```git
(%cf-twins)
(write (list
  (%cf-steps "r"
    (list (list "config" "--add" "m.v" "one")
          (list "config" "--add" "m.v" "two")
          (list "config" "m.v")
          (list "config" "--get-all" "m.v")
          (list "config" "get" "--all" "m.v")
          (list "config" "m.v" "three")
          (list "config" "set" "m.v" "three")
          (list "config" "--unset" "m.v")
          (list "config" "set" "--all" "m.v" "nine")
          (list "config" "--get-all" "m.v")
          (list "config" "set" "--append" "m.v" "ten")
          (list "config" "--unset-all" "m.v")
          (list "config" "--unset" "m.v")
          (list "config" "unset" "nope.x")
          (list "config" "keep.a" "1")
          (list "config" "keep.b" "2")
          (list "config" "unset" "keep.a")))
  (%cf-files-same? "r/.git/config")))
```
---
    (() #t)

### sections taken out

```git
(%cf-twins)
(write (list
  (%cf-steps "r"
    (list (list "config" "gone.a" "1")
          (list "config" "gone.Sub.b" "2")
          (list "config" "--remove-section" "gone")
          (list "config" "remove-section" "gone.Sub")
          (list "config" "--remove-section" "nope")))
  (%cf-files-same? "r/.git/config")))
```
---
    (() #t)

## refusals

### bad names, the wrong count, a file not there, no repository

```git
(%cf-twins)
(write
  (List append
    (%cf-steps "r"
      (list (list "config" "nosection")
            (list "config" "a." "v")
            (list "config" ".b" "v")
            (list "config" "a.1b" "v")
            (list "config" "bad key.x" "v")
            (list "config" "--global" "--list")
            (list "config" "--global" "user.name")))
    (%cf-steps "home"
      (list (list "config" "--local" "user.name")
            (list "config" "--unset" "user.name")))))
```
---
    ()

## from the command line

### -c, and GIT_CONFIG_COUNT

```git
(%cf-twins)
(Sys setenv "GIT_CONFIG_COUNT" "1")
(Sys setenv "GIT_CONFIG_KEY_0" "count.key")
(Sys setenv "GIT_CONFIG_VALUE_0" "from the environment")
(def %cf-c
  (%cf-steps "r"
    (list (list "-c" "foo.bar=baz" "config" "foo.bar")
          (list "-c" "foo.bar=baz" "config" "--show-origin" "foo.bar")
          (list "-c" "Foo.Bar=one" "-c" "foo.bar=two" "config" "foo.bar")
          (list "config" "count.key")
          (list "config" "--show-scope" "count.key"))))
(Sys unsetenv "GIT_CONFIG_COUNT")
(write %cf-c)
```
---
    ()

## used by the other commands

### the user's name and email, and init.defaultBranch, from the user's file

```git
(%cf-twins)
(List for-each (fn (_ v) (Sys unsetenv v)) (list "GIT_AUTHOR_NAME" "GIT_AUTHOR_EMAIL" "GIT_COMMITTER_NAME" "GIT_COMMITTER_EMAIL"))
(Sys setenv "GIT_AUTHOR_DATE" "1767225600 +0000")
(Sys setenv "GIT_COMMITTER_DATE" "1767225600 +0000")
(write (list
  (%cf-steps "r"
    (list (list "config" "--global" "user.name" "From Home")
          (list "config" "--global" "user.email" "home@b.c")
          (list "config" "--global" "init.defaultBranch" "trunk")))
  (do
    (%cf-sh (Str8 append %cf-d "/x/r") "printf 'x\\n' > f && git add f")
    (%cf-sh (Str8 append %cf-d "/g/r") "printf 'x\\n' > f && git add f")
    (%cf-steps "r" (list (list "commit" "-q" "-m" "one"))))
  (equal? (git-oracle-in (Str8 append %cf-d "/x/r") "log" "-1" "--format=%an <%ae> %cn <%ce>")
          (git-oracle-in (Str8 append %cf-d "/g/r") "log" "-1" "--format=%an <%ae> %cn <%ce>"))
  ; init's report names its own twin's path; the branch it starts on is compared
  (do (%cf-x "home" (list "init" "fresh")) (%cf-g "home" (list "init" "-q" "fresh"))
      (%cf-files-same? "home/fresh/.git/HEAD"))))
```
---
    (() () #t #t)

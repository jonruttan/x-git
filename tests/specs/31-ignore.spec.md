# @weight 3
# @timeout-scale 2

.gitignore as check-ignore reports it, against git itself.  One
repository holds every kind of pattern -- in the top .gitignore, a
nested one, info/exclude and core.excludesFile -- and a list of paths
that each touch one.  x-git and git are asked about all of them at once,
`-v -n` naming the deciding pattern of each (or none), and what each
prints and ends with is compared; then the plain form, a tracked path,
the default excludes file and the refusals.

## check-ignore

### every kind of pattern: the deciding file, line and pattern of each path

```git
(def %ci-d (let ((t (File temp "/tmp/x-git-ci-"))) (do (File close (first t)) (File unlink (rest t)) (File mkdir (rest t)) (rest t))))
(def %ci-sh (fn (_ script) (Proc run! (list "/bin/sh" "-c" (Str8 append "cd \"$0\" && " script) %ci-d))))
(%ci-sh
  (Str8 append "git init -q -b main r && cd r"
    " && printf '# comment\\n*.log\\n!keep.log\\nbuild/\\n/top.tmp\\ndoc/*.txt\\n**/gen\\na/**/z\\nlib/**\\n[abc].c\\nx?.h\\n"
    "\\\\#hash\\n\\\\!bang\\ntrail\\\\ \\nsp  \\ndeep/\\n!deep/keep\\n*.o\\n!/sub/*.o\\n' > .gitignore"
    " && mkdir -p sub/x build gen deep lib/d doc/x a/b/c x/gen logs"
    " && printf 'local\\n!*.log\\nn.txt\\n/anch\\n' > sub/.gitignore"
    " && printf 'q.txt\\n*.ex\\n' > .git/info/exclude"
    " && printf '*.user\\n!q.txt\\n' > ../user-ignore"))
(def %ci-r (Str8 append %ci-d "/r"))
(def %ci-paths
  (list "build" "build/out" "logs/a.log" "keep.log" "sub/keep.log" "top.tmp" "sub/top.tmp" "doc/a.txt" "doc/x/a.txt"
        "gen" "x/gen/q" "a/z" "a/b/c/z" "lib/q" "lib/d/q" "lib" "a.c" "d.c" "x1.h" "x12.h" "#hash" "!bang" "trail " "sp"
        "deep" "deep/keep" "deep/other" "sub/local" "sub/n.txt" "sub/anch" "sub/x/anch" "anch" "q.txt" "f.ex" "me.user"
        "sub/m.o" "m.o" "sub/d/m.o" "nothing.txt"))
; #t when x-git and git say the same, else both, to show how they differ
(def %ci-ask
  (fn (_ . ops)
    (let ((x (apply git-text-in (pair %ci-r ops))) (g (apply git-oracle-in (pair %ci-r ops))))
      (if (equal? x g) #t (list x g)))))
(def %ci-user (list "-c" (Str8 append "core.excludesFile=" %ci-d "/user-ignore")))
(write (list (apply %ci-ask (List append %ci-user (pair "check-ignore" (pair "-v" (pair "-n" (pair "--no-index" %ci-paths))))))
             (apply %ci-ask (List append %ci-user (pair "check-ignore" (pair "--no-index" %ci-paths))))
             (git-text-in %ci-r "check-ignore" "-v" "keep.log" "deep/keep" "sub/keep.log")))
```
---
    (#t #t (0 . ".gitignore:3:!keep.log\tkeep.log\n.gitignore:16:deep/\tdeep/keep\nsub/.gitignore:2:!*.log\tsub/keep.log\n"))

### a tracked path, or a directory holding one, is not asked about without --no-index

```git
(%ci-sh "cd r && printf a > a.log && mkdir -p t && printf b > t/b.log && git add -f a.log t/b.log")
(write (list (%ci-ask "check-ignore" "a.log" "t" "t/b.log" "logs/c.log")
             (%ci-ask "check-ignore" "-v" "-n" "a.log" "t")
             (%ci-ask "check-ignore" "--no-index" "a.log" "t/b.log")
             (%ci-ask "check-ignore" "a.log")
             (git-text-in %ci-r "check-ignore" "a.log" "logs/c.log")))
```
---
    (#t #t #t #t (0 . "logs/c.log\n"))

### the user's default excludes file when core.excludesFile is not set; -q

```git
; the user's own configuration set aside -- a core.excludesFile there
; would take the default's place -- and an empty one in its stead
(%ci-sh "mkdir -p xdg/git && printf '*.tmpx\\n' > xdg/git/ignore && : > empty-config")
(def %ci-env (list (pair "XDG_CONFIG_HOME" (Str8 append %ci-d "/xdg")) (pair "GIT_CONFIG_GLOBAL" (Str8 append %ci-d "/empty-config"))))
(def %ci-was (List map (fn (_ e) (pair (first e) (Sys getenv (first e)))) %ci-env))
(List for-each (fn (_ e) (Sys setenv (first e) (rest e))) %ci-env)
(def %ci-xdg (list (%ci-ask "check-ignore" "-v" "f.tmpx") (%ci-ask "check-ignore" "-q" "f.tmpx") (%ci-ask "check-ignore" "-q" "f.c")
                   (git-text-in %ci-r "check-ignore" "-v" "f.tmpx")))
(List for-each (fn (_ e) (if (null? (rest e)) (Sys unsetenv (first e)) (Sys setenv (first e) (rest e)))) %ci-was)
(write (List append (List init %ci-xdg)
         (list (Str8 ends? "/xdg/git/ignore:1:*.tmpx\tf.tmpx\n" (rest (List last %ci-xdg))))))
```
---
    (#t #t #t #t)

### refusals in git's words

```git
(def %ci-refused
  (list (%ci-ask "check-ignore")
        (%ci-ask "check-ignore" "-q" "a" "b")
        (%ci-ask "check-ignore" "-q" "-v" "a")
        (%ci-ask "check-ignore" "-n" "a")
        (git-text-in %ci-r "check-ignore" "-n" "a")))
(%ci-sh "rm -rf \"$0\"")
(write %ci-refused)
```
---
    (#t #t #t #t (128 . "fatal: --non-matching is only valid with --verbose\n"))

# @weight 3
# @timeout-scale 2

clean, against git itself.  Each case builds the same repository twice:
a tracked directory with an untracked and an ignored file in it, an
untracked directory holding an ignored one deeper down, an ignored
directory, an empty one, a repository of its own inside, and files at
the top.  x-git cleans one and git the other, with the same options; what
each prints and ends with is compared, then what is left of each tree.
core.excludesFile is set to nothing, so only the repository's own
patterns count.

## clean

### what -n says it would remove: files, -d, -x, -X, -ff, -e, pathspecs, -q

```git
(def %cl-make
  (fn (_)
    (def t (File temp "/tmp/x-git-cl-"))
    (File close (first t)) (File unlink (rest t)) (File mkdir (rest t))
    (Proc run! (list "/bin/sh" "-c"
      (Str8 append "cd \"$0\" && git init -q -b main . && printf '*.log\\nbuild/\\n' > .gitignore"
        " && mkdir -p t u/deep build emptyd nest && printf t > t/t.txt && git add ."
        " && git -c user.name=A -c user.email=a@b.c commit -qm one"
        " && printf a > a.txt && printf l > a.log && printf u > u/u.txt && printf v > u/deep/v.log && printf b > build/b"
        " && printf x > t/x.txt && printf y > t/y.log && (cd nest && git init -q && printf n > n.txt) && printf o > a-b")
      (rest t)))
    (rest t)))
(def %cl-tree
  (fn (_ d) (rest (Proc capture (list "/bin/sh" "-c" "cd \"$0\" && find . -path ./.git -prune -o -print | LC_ALL=C sort" d)))))
; #t when x-git and git say and leave the same, else what each said and
; left; each twin's garbage collected after it
(def %cl-twin
  (fn (_ . ops)
    (def a (%cl-make))
    (def b (%cl-make))
    (def args (pair "-c" (pair "core.excludesFile=/dev/null" ops)))
    (def x (apply git-text-in (pair a args)))
    (def g (apply git-oracle-in (pair b args)))
    (def r (if (and (equal? x g) (equal? (%cl-tree a) (%cl-tree b))) #t (list x g (%cl-tree a) (%cl-tree b))))
    (Proc run! (list "/bin/sh" "-c" "rm -rf \"$0\" \"$1\"" a b))
    (Heap collect)
    r))
(write (list (%cl-twin "clean" "-n")
             (%cl-twin "clean" "-n" "-d")
             (%cl-twin "clean" "-n" "-x")
             (%cl-twin "clean" "-n" "-X")
             (%cl-twin "clean" "-n" "-d" "-x")
             (%cl-twin "clean" "-n" "-d" "-X")
             (%cl-twin "clean" "-n" "-ff" "-d")
             (%cl-twin "clean" "-n" "-d" "-e" "a.txt")
             (%cl-twin "clean" "-n" "t")
             (%cl-twin "clean" "-n" "-d" "u")
             (%cl-twin "clean" "-n" "-d" "u/deep")
             (%cl-twin "clean" "-n" "nosuch")
             (%cl-twin "clean" "-n" "-q")))
```
---
    (#t #t #t #t #t #t #t #t #t #t #t #t #t)

### -f removes it: files, -d, -d -x, -d -X, -ff, -q; clean.requireForce false

```git
(write (list (%cl-twin "clean" "-f")
             (%cl-twin "clean" "-f" "-d")
             (%cl-twin "clean" "-fdx")
             (%cl-twin "clean" "-f" "-d" "-X")
             (%cl-twin "clean" "-ffd")
             (%cl-twin "clean" "-f" "-q" "-d")
             (%cl-twin "-c" "clean.requireForce=false" "clean" "-d")))
```
---
    (#t #t #t #t #t #t #t)

### refusals in git's words

```git
(def %cl-d (%cl-make))
(def %cl-said
  (list (%cl-twin "clean")
        (%cl-twin "clean" "-d")
        (%cl-twin "clean" "-n" "-x" "-X")
        (git-text-in %cl-d "clean")))
(Proc run! (list "/bin/sh" "-c" "rm -rf \"$0\"" %cl-d))
(write %cl-said)
```
---
    (#t #t #t (128 . "fatal: clean.requireForce is true and -f not given: refusing to clean\n"))

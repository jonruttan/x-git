; # x-git -- git on x-lang
;
; ## tests/harness.x -- what the spec harness adds to the dialect
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The lang kit's generator writes tests/lib/harness.gen.x: the dialect
; lang.xon declares, the bundle's root on the import path, then this file.
;
; The reference is git itself.  git-fixture makes a repository with the
; system git, once a process: a blob, a tree with a subdirectory, and a
; commit; git-oracle runs a git command in it and answers (STATUS . OUTPUT),
; and git-text runs an x-git plan the same way, for a case to compare.
(import git/base)
(import x/sys/proc)

(def %git-fx ())

(def git-fixture
  (fn (_)
    (when (null? %git-fx)
      (let ((t (File temp "/tmp/x-git-fx-")))
        (do (File close (first t))
            (File unlink (rest t))
            (File mkdir (rest t))
            (Proc run!
              (list "/bin/sh" "-c"
                (Str8 append "cd " (rest t)
                  " && git init -q . && git config user.email a@b.c && git config user.name A"
                  " && printf 'hello\\n' > f.txt && mkdir sub && printf x > sub/g"
                  " && git add . && git commit -q -m init")))
            (set! %git-fx (rest t)))))
    %git-fx))

; A second repository, packed: two commits of a longish file, so the pack
; holds a delta, and `git repack -a -d` leaves nothing loose.
(def %git-fx-packed ())

(def git-fixture-packed
  (fn (_)
    (when (null? %git-fx-packed)
      (let ((t (File temp "/tmp/x-git-pk-")))
        (do (File close (first t))
            (File unlink (rest t))
            (File mkdir (rest t))
            (Proc run!
              (list "/bin/sh" "-c"
                (Str8 append "cd " (rest t)
                  " && git init -q . && git config user.email a@b.c && git config user.name A"
                  " && awk 'BEGIN { for (i = 0; i < 400; i++) print \"line \" i \" of a longish file\" }' > big.txt"
                  " && printf 'hello\\n' > f.txt && git add . && git commit -q -m one"
                  " && awk 'NR == 200 { print \"CHANGED\"; next } { print }' big.txt > big.new && mv big.new big.txt"
                  " && git commit -q -am two && git repack -a -d -q")))
            (set! %git-fx-packed (rest t)))))
    %git-fx-packed))

; git run in a directory, its standard error joined to its output: a
; refusal is what a case compares.
(def git-oracle-in
  (fn (_ dir . args)
    (Proc capture
      (pair "/bin/sh" (pair "-c" (pair "cd \"$0\" && exec git \"$@\" 2>&1" (pair dir args)))))))

(def git-oracle
  (fn (_ . args) (apply git-oracle-in (pair (git-fixture) args))))

(def git-sha-in
  (fn (_ dir rev) (Str8 trim (rest (git-oracle-in dir "rev-parse" rev)))))

; An x-git line run in a directory, as (STATUS . OUTPUT) to set beside the
; oracle's.
(def git-text-in
  (fn (_ dir . ops)
    (def r (git-run (git-plan (pair "-C" (pair dir ops)))))
    (def text (first (rest r)))
    (pair (first (rest (rest r)))
          (if (pair? text) (Str8 sub 0 (rest text) (first text)) text))))

; A full object name from the fixture: HEAD, HEAD^{tree}, HEAD:f.txt, ...
(def git-sha
  (fn (_ rev) (git-sha-in (git-fixture) rev)))

(def git-text
  (fn (_ . ops) (apply git-text-in (pair (git-fixture) ops))))

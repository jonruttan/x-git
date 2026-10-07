; # x-git -- git on x-lang
;
; ## git/cli.x -- the command line
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; x -l git -- [--version] COMMAND [ARGS] runs COMMAND.  git-plan turns a
; line into what to do, with no side effects; git-main does it.  The words
; are git's own: its usage line, its refusal of an unknown command, and its
; exit statuses (1 for both).

(provide git/cli git-argv git-plan git-main)

(def %git-byte-len (prim-ref (lit str) (lit byte-len)))

(def %git-engine-flag?
  (fn (_ s)
    (if (str=? s "--batch") #t
      (if (str=? s "--no-color") #t (str=? s "--verbose")))))

; The operands the launcher hands the entry: its own flags dropped, and the
; "--" that ends x's options.
(def git-argv
  (fn (_ raw)
    (def ops
      (List filter (fn (_ a) (not (%git-engine-flag? a)))
        (if (pair? raw) (rest raw) ())))
    (if (if (pair? ops) (str=? (first ops) "--") #f) (rest ops) ops)))

(def %git-usage
  "usage: git [-v | --version] <command> [<args>]\n")

; A line to (LABEL TEXT STATUS): what to print, where, and the exit status.
; LABEL is out or err.
(def git-plan
  (fn (_ ops)
    (match
      ((null? ops) (list (lit out) %git-usage 1))
      ((if (str=? (first ops) "--version") #t
         (if (str=? (first ops) "-v") #t (str=? (first ops) "version")))
        (list (lit out) (Str8 append "git version " git-version " (x-git)\n") 0))
      (#t
        (list (lit err)
          (Str8 append "git: '" (first ops) "' is not a git command. See 'git --help'.\n")
          1)))))

(def git-main
  (fn (_ raw)
    (def plan (git-plan (git-argv raw)))
    (def text (first (rest plan)))
    (File write (if (eq? (first plan) (lit out)) 1 2) text (%git-byte-len text))
    (Sys exit (first (rest (rest plan))))))

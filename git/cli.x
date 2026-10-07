; # x-git -- git on x-lang
;
; ## git/cli.x -- the command line
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; x -l git -- [OPTIONS] COMMAND [ARGS] runs COMMAND.  git's own options are
; declared once, in git-options: the declaration is what --help prints and
; what the line is parsed against.  They come before the command, so the
; parse stops at the first operand; what follows belongs to the command.
; git-plan turns a line into what to do, with no side effects; git-main
; does it.  The refusals and exit statuses are git's: 1 for no command or
; an unknown one, 129 for an unknown option.

(import x/sys/opts)

(provide git/cli git-argv git-options git-plan git-main)

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

(def git-options
  (Opts declare "git" "[-v | --version] <command> [<args>]" ()
    (list
      (Opts flag "-v" "--version" "Print the version"))))

(def %git-version-line
  (fn (_) (Str8 append "git version " git-version " (x-git)\n")))

; A line to (STREAM TEXT STATUS): what to print, on out or err, and the
; exit status.
(def git-plan
  (fn (_ ops)
    (def o (Opts parse-leading git-options ops))
    (def cmd (Opts operands o))
    (match
      ((Opts help? git-options ops) (list (lit out) (Opts usage git-options) 0))
      ((not (null? (Opts unknown o)))
        (list (lit err)
          (Str8 append "unknown option: " (Opts unknown o) "\n" (Opts usage git-options))
          129))
      ((Opts on? o "-v") (list (lit out) (%git-version-line) 0))
      ((null? cmd) (list (lit out) (Opts usage git-options) 1))
      ((str=? (first cmd) "version") (list (lit out) (%git-version-line) 0))
      (#t
        (list (lit err)
          (Str8 append "git: '" (first cmd) "' is not a git command. See 'git --help'.\n")
          1)))))

(def git-main
  (fn (_ raw)
    (def plan (git-plan (git-argv raw)))
    (def text (first (rest plan)))
    (File write (if (eq? (first plan) (lit out)) 1 2) text (%git-byte-len text))
    (Sys exit (first (rest (rest plan))))))

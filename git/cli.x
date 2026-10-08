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
; git-plan turns a line into what to do, with no side effects; git-run does
; it and answers (STREAM TEXT STATUS); git-main prints and exits.  The
; refusals and exit statuses are git's: 1 for no command or an unknown one,
; 129 for an unknown option.

(module git/cli)

(import x/sys/opts Opts)
(import x/sys/file File)
(import x/sys/posix Sys)
(import git/objects git-dir)
(import git/commands git-cat-file git-hash-object)

(def %byte-len (prim-ref (lit str) (lit byte-len)))

(def git-options
  (Opts declare "git" "[-v | --version] [-C <path>] <command> [<args>]" ()
    (list
      (Opts flag "-v" "--version" "Print the version")
      (Opts arg "-C" "<path>" "Run as if started in <path>"))))

(def %version-line
  (fn (_) (Str8 append "git version " git-version " (x-git)\n")))

; The commands: each (fn (_ wd gitdir ops) -> (STREAM TEXT STATUS)), wd the
; working directory and gitdir the repository's .git, or ().
(def %commands
  (list (pair "cat-file" git-cat-file)
        (pair "hash-object" git-hash-object)))

; The command a name runs, or ().
(def %command
  (fn (_ name)
    (def hit (List find (fn (_ c) (str=? (first c) name)) %commands))
    (if (null? hit) () (rest hit))))

; A line to a plan: (help), (version), (refuse TEXT), (unknown-command NAME),
; or (run DIR COMMAND ARGS), DIR the working directory asked for or ().
(def git-plan
  (fn (_ ops)
    (def o (Opts parse-leading git-options ops))
    (def cmd (Opts operands o))
    (match
      ((Opts help? git-options ops) (list (lit help)))
      ((not (null? (Opts unknown o))) (list (lit refuse) (Opts unknown o)))
      ((Opts on? o "-v") (list (lit version)))
      ((null? cmd) (list (lit usage)))
      ((str=? (first cmd) "version") (list (lit version)))
      ((null? (%command (first cmd))) (list (lit unknown-command) (first cmd)))
      (#t (list (lit run) (Opts value o "-C" ()) (first cmd) (rest cmd))))))

; A plan done: (STREAM TEXT STATUS).
(def git-run
  (fn (_ plan)
    (def label (first plan))
    (match
      ((eq? label (lit help)) (list (lit out) (Opts usage git-options) 0))
      ((eq? label (lit usage)) (list (lit out) (Opts usage git-options) 1))
      ((eq? label (lit version)) (list (lit out) (%version-line) 0))
      ((eq? label (lit refuse))
        (list (lit err) (Str8 append "unknown option: " (first (rest plan)) "\n" (Opts usage git-options)) 129))
      ((eq? label (lit unknown-command))
        (list (lit err)
          (Str8 append "git: '" (first (rest plan)) "' is not a git command. See 'git --help'.\n")
          1))
      (#t
        (let ((dir (first (rest plan)))
              (cmd (first (rest (rest plan))))
              (args (first (rest (rest (rest plan))))))
          (let ((wd (if (null? dir) (Sys getcwd) dir)))
            ((%command cmd) wd (git-dir wd) args)))))))

; The bytes of a TEXT: a string's, or a region's count.
(def %text-count
  (fn (_ text) (if (pair? text) (rest text) (%byte-len text))))

; ops are the operands: (Sys args 'program) past the engine's path.
(def git-main
  (fn (_ ops)
    (def r (git-run (git-plan ops)))
    (def text (first (rest r)))
    (File write (if (eq? (first r) (lit out)) 1 2)
      (if (pair? text) (first text) text) (%text-count text))
    (Sys exit (first (rest (rest r))))))

(provide git/cli git-options git-plan git-run git-main)

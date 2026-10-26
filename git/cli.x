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
(import git/commands git-cat-file git-hash-object git-rev-parse-command)
(import git/history git-ls-tree git-log git-show)
(import git/index git-status git-ls-files)
(import git/stage git-add git-commit)
(import git/diff git-diff)
(import git/repo git-init git-branch git-tag)
(import git/checkout git-checkout git-switch git-restore)
(import git/clone git-clone)
(import git/remote git-fetch git-push git-ls-remote)
(import git/serve git-upload-pack git-receive-pack)
(import git/merge git-merge git-pull)
(import git/paths git-rm git-mv git-check-ignore git-clean)
(import git/config git-config git-config-parameters)
(import git/reset git-reset)
(import git/revert git-revert)

(def %byte-len (prim-ref (lit str) (lit byte-len)))

(def git-options
  (Opts declare "git" "[-v | --version] [-C <path>] [-c <name>=<value>] <command> [<args>]" ()
    (list
      (Opts flag "-v" "--version" "Print the version")
      (Opts arg "-C" "<path>" "Run as if started in <path>")
      (Opts arg "-c" "<name>=<value>" "Set a configuration value for this command"))))

(def %version-line
  (fn (_) (Str8 append "git version " git-version " (x-git)\n")))

; The commands: each (fn (_ wd gitdir ops) -> (STREAM TEXT STATUS)), wd the
; working directory and gitdir the repository's .git, or ().
(def %commands
  (list (pair "cat-file" git-cat-file)
        (pair "hash-object" git-hash-object)
        (pair "rev-parse" git-rev-parse-command)
        (pair "ls-tree" git-ls-tree)
        (pair "log" git-log)
        (pair "show" git-show)
        (pair "status" git-status)
        (pair "ls-files" git-ls-files)
        (pair "add" git-add)
        (pair "commit" git-commit)
        (pair "diff" git-diff)
        (pair "init" git-init)
        (pair "branch" git-branch)
        (pair "tag" git-tag)
        (pair "checkout" git-checkout)
        (pair "switch" git-switch)
        (pair "restore" git-restore)
        (pair "clone" git-clone)
        (pair "fetch" git-fetch)
        (pair "push" git-push)
        (pair "ls-remote" git-ls-remote)
        (pair "merge" git-merge)
        (pair "pull" git-pull)
        (pair "upload-pack" git-upload-pack)
        (pair "receive-pack" git-receive-pack)
        (pair "rm" git-rm)
        (pair "mv" git-mv)
        (pair "check-ignore" git-check-ignore)
        (pair "clean" git-clean)
        (pair "config" git-config)
        (pair "reset" git-reset)
        (pair "revert" git-revert)))

; The command a name runs, or ().
(def %command
  (fn (_ name)
    (def hit (List find (fn (_ c) (str=? (first c) name)) %commands))
    (if (null? hit) () (rest hit))))

; A line to a plan: (help), (version), (refuse TEXT), (unknown-command NAME),
; or (run DIR COMMAND ARGS SETTINGS), DIR the working directory asked for
; or (), SETTINGS the -c values.
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
      (#t (list (lit run) (Opts value o "-C" ()) (first cmd) (rest cmd) (Opts values o "-c"))))))

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
              (args (first (rest (rest (rest plan)))))
              (settings (first (rest (rest (rest (rest plan)))))))
          (let ((wd (if (null? dir) (Sys getcwd) dir)))
            ; -c's settings in GIT_CONFIG_PARAMETERS for the command, and
            ; for what it runs, as git passes them on; as they were after
            (if (null? settings) ((%command cmd) wd (git-dir wd) args)
              (let ((was (Sys getenv "GIT_CONFIG_PARAMETERS")))
                (do (Sys setenv "GIT_CONFIG_PARAMETERS"
                      (Str8 append (if (or (null? was) (= (Str8 length was) 0)) "" (Str8 append was " ")) (git-config-parameters settings)))
                    (let ((r ((%command cmd) wd (git-dir wd) args)))
                      (do (if (null? was) (Sys unsetenv "GIT_CONFIG_PARAMETERS") (Sys setenv "GIT_CONFIG_PARAMETERS" was))
                          r)))))))))))

; The bytes of a TEXT: a string's, or a region's count.
(def %text-count
  (fn (_ text) (if (pair? text) (rest text) (%byte-len text))))

; ops are the operands: (Sys args 'program) past the engine's path.  A
; result is (STREAM TEXT STATUS), or with a fourth element text for
; standard output after the stream's own, as git prints an unknown
; revision's echo after its refusal.
(def git-main
  (fn (_ ops)
    (def r (git-run (git-plan ops)))
    (def text (first (rest r)))
    ; nothing written when there is nothing to write: a service's client
    ; has closed the pipe by now, and an empty write to it is SIGPIPE
    (unless (= (%text-count text) 0)
      (File write (if (eq? (first r) (lit out)) 1 2)
        (if (pair? text) (first text) text) (%text-count text)))
    (let ((more (rest (rest (rest r)))))
      (unless (null? more) (File write 1 (first more) (%byte-len (first more)))))
    (Sys exit (first (rest (rest r))))))

(provide git/cli git-options git-plan git-run git-main)

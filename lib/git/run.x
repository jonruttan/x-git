; # x-git -- git on x-lang
;
; ## lib/git/run.x -- the entry
;
; @description git: `x -l git -- COMMAND [ARGS]` runs a git command.
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
(module git/run)
(import git/base git-version git-main)

(set! %lang-name "GIT")
(set! %lang-version git-version)
(set! %repl-prompt "git> ")

; The operands: what follows the "--" after the launcher's own options.
; With none the session goes on to the REPL.
(def main
  (fn (_)
    (let ((ops (rest (Sys args (lit program)))))
      (unless (null? ops) (git-main ops)))))

(provide git/run main)

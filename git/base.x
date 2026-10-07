; # x-git -- git on x-lang
;
; ## git/base.x -- the parts, assembled
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The parts share one flat namespace, every name led by git- (or %git- for
; the ones no caller outside the bundle needs); each part calls the others
; through those names at run time, so the order below is only the order of
; loading.

(provide git/base git-version git-main git-argv git-options git-plan)

(def git-version "0.1.0")

(import git/cli)

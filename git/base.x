; # x-git -- git on x-lang
;
; ## git/base.x -- the parts, assembled
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Each part is a module of its own: its first form names it, its private
; names are its own, and what it provides is imported here by name.  This
; file stays unscoped, so those imports bind in the root, where run.x and
; the spec harness reach them; the exports carry the git- prefix for that.

(provide git/base git-version git-main git-argv git-options git-plan git-run
  git-dir git-hash git-object-write! git-object-read git-resolve git-tree-pretty
  git-ref-read git-rev-parse git-cat-file git-hash-object git-rev-parse-command)

(def git-version "0.1.0")

(import git/objects git-dir git-hash git-object-write! git-object-read git-resolve git-tree-pretty)
(import git/refs git-ref-read git-rev-parse)
(import git/commands git-cat-file git-hash-object git-rev-parse-command)
(import git/cli git-argv git-options git-plan git-run git-main)

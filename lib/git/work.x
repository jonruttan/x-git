; # x-git -- git on x-lang
;
; ## lib/git/work.x -- the working tree's paths, as git sees them
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; git keeps a symbolic link as itself: a blob of the text it holds, mode
; 120000, never what it points at.  So the working tree is looked at
; without following links -- a link is a link though its target is a
; directory, or nothing -- and a link is written back as one.  Every
; command that reads a working file's bytes or mode, walks a directory, or
; writes a blob out asks here.

(module git/work)

(import x/sys/file File)
(import git/objects git-read-file git-write-file!)

(import x/core/doors str-byte-len)

; What is at full, links not followed: (lit file), (lit dir), (lit link),
; or () when nothing is.
(def git-work-type (fn (_ full) (File ltype full)))

; Is anything at full -- a link to nothing counts?
(def git-work-exists? (fn (_ full) (not (null? (File ltype full)))))

; Is full a directory of its own, not a link to one?
(def git-work-dir? (fn (_ full) (eq? (File ltype full) (lit dir))))

; Is full a symbolic link?
(def git-work-link? (fn (_ full) (eq? (File ltype full) (lit link))))

; The bytes git hashes for the path at full, as (REGION . SIZE): a link's
; text, else the file's contents.
(def git-work-read
  (fn (_ full)
    (if (git-work-link? full)
      (let ((t (File readlink full))) (pair t (str-byte-len t)))
      (git-read-file full))))

; The path's stat, a link's own.
(def git-work-stat (fn (_ full) (File lstat full)))

; The mode git records for the path at full, as the index spells it: 120000
; for a link, 100755 for a file with an execute bit, else 100644.
(def git-work-mode-of
  (fn (_ full)
    (match
      ((git-work-link? full) "120000")
      ((= (& (Assoc get (lit mode) (File stat full)) 73) 0) "100644")
      (#t "100755"))))

; A blob's n bytes of region r written to full as mode says: a link holding
; them for 120000, else a file, executable for 100755.  What was there
; goes first, as git replaces it.
(def git-work-write!
  (fn (_ full r n mode)
    (when (git-work-exists? full) (File unlink full))
    (if (str=? mode "120000")
      (File symlink (Str8 sub 0 n r) full)
      (do (git-write-file! full r n)
          (File chmod full (if (str=? mode "100755") 493 420))))
    ()))

(provide git/work git-work-type git-work-exists? git-work-dir? git-work-link? git-work-read
  git-work-stat git-work-mode-of git-work-write!)

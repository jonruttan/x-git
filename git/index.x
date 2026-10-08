; # x-git -- git on x-lang
;
; ## git/index.x -- the index, ls-files and status
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; .git/index (index-format(5), version 2 or 3) is `DIRC`, the version and
; the count, then an entry a tracked file: ten 32-bit stat fields, the
; blob's SHA-1, 16 bits of flags whose low twelve are the name's length,
; the name, the whole padded to eight bytes; then extensions, then the
; file's own SHA-1.  This file reads it, and from it, the HEAD tree and
; the working directory, says what status says.  It writes nothing yet.

(module git/index)

(import x/sys/opts Opts)
(import x/sys/file File)
(import git/objects git-object-read git-tree-entries git-hash git-read-file)
(import git/refs git-ref-read git-tree-of git-rev-parse)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %mul (prim-ref 'int '*))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %mem-copy (prim-ref (lit mem) (lit copy)))
(def %cvt (prim-ref (lit convert) (lit to)))
(def %string-type (Type named STRING))

(def %byte (fn (_ p i) (& (%pref p i 1) 255)))
(def %u32
  (fn (_ p i)
    (| (<< (%byte p i) 24) (| (<< (%byte p (%add i 1)) 16) (| (<< (%byte p (%add i 2)) 8) (%byte p (%add i 3)))))))
(def %u16 (fn (_ p i) (| (<< (%byte p i) 8) (%byte p (%add i 1)))))

(def %bytes->string
  (fn (_ p start k)
    (def s (%make-str k))
    (when (> k 0) (%mem-copy (%str->ptr s) (%int->ptr (%add (%ptr->int p) start)) k))
    s))

(def %hex-digits "0123456789abcdef")
(def %sha-hex
  (fn (_ p i)
    (Str8 join ""
      ((fn (self k acc)
         (if (< k 0) acc
           (let ((b (%byte p (%add i k))))
             (self (%sub k 1) (pair (Str8 append (Str8 sub (>> b 4) 1 %hex-digits) (Str8 sub (& b 15) 1 %hex-digits)) acc)))))
       19 ()))))

(def %fatal (fn (_ text) (list (lit err) (Str8 append "fatal: " text "\n") 128)))
(def %no-repo
  (fn (_) (%fatal "not a git repository (or any of the parent directories): .git")))
(def %unknown-option
  (fn (_ w usage)
    (def n (Str8 length w))
    (list (lit err)
      (Str8 append
        (if (Str8 starts? "--" w)
          (Str8 append "error: unknown option `" (Str8 sub 2 (- n 2) w))
          (Str8 append "error: unknown switch `" (Str8 sub 1 (- n 1) w)))
        "'\n" usage)
      129)))

; --- the index ---

; The index's entries, in its order: (PATH MODE SHA STAGE SIZE MTIME)
; each, MODE in octal text as git prints it.  () for a repository with
; no index yet.  A version 4 index (names prefix-compressed) is refused.
(def git-index-read
  (fn (_ gitdir)
    (def path (Str8 append gitdir "/index"))
    (if (not (File exists? path)) ()
      (let ((f (git-read-file path)))
        (let ((p (%str->ptr (first f))) (n (rest f)))
          (do (unless (and (>= n 12) (= (%byte p 0) 68) (= (%byte p 1) 73) (= (%byte p 2) 82) (= (%byte p 3) 67))
                (Err raise (lit value) "git: index file is not DIRC" ()))
              (let ((version (%u32 p 4)) (count (%u32 p 8)))
                (do (when (> version 3)
                      (Err raise (lit value) (Str8 append "git: index version " (Str8 str version) " is not read") ()))
                    ((fn (self i k acc)
                       (if (>= k count) (List reverse acc)
                         (let ((flags (%u16 p (%add i 60))))
                           (let ((extended? (and (= version 3) (not (= (& flags 16384) 0)))))
                             (let ((name-at (%add i (if extended? 64 62)))
                                   (namelen (& flags 4095)))
                               (let ((len (if (< namelen 4095) namelen
                                            ((fn (scan j) (if (= (%byte p j) 0) (%sub j name-at) (scan (%add j 1)))) name-at))))
                                 (let ((entry (list (%bytes->string p name-at len)
                                                    (%cvt (%u32 p (%add i 24)) %string-type 8)
                                                    (%sha-hex p (%add i 40))
                                                    (& (>> flags 12) 3)
                                                    (%u32 p (%add i 36))
                                                    (%u32 p (%add i 8))))
                                       (total (& (%add (%add (%sub name-at i) len) 8) (~ 7))))
                                   (self (%add i total) (%add k 1) (pair entry acc)))))))))
                     12 0 ())))))))))

; --- the HEAD tree, flat ---

; Every blob under a tree as (PATH . SHA), the paths from prefix.
(def %flat-tree
  (fn (self gitdir tree prefix)
    (def o (git-object-read gitdir tree))
    (if (or (null? o) (not (str=? (first o) "tree"))) ()
      (List flat-map
        (fn (_ e)
          (let ((path (Str8 append prefix (first (rest e)))))
            (if (str=? (first e) "40000")
              (self gitdir (first (rest (rest e))) (Str8 append path "/"))
              (list (pair path (first (rest (rest e))))))))
        (git-tree-entries o)))))

(def %head-files
  (fn (_ gitdir)
    (def tree (git-tree-of gitdir "HEAD"))
    (if (null? tree) () (%flat-tree gitdir tree ""))))

; Every blob under a tree, (PATH . SHA) each, for the commands that set
; a tree against the index.
(def git-tree-files
  (fn (_ gitdir tree) (if (null? tree) () (%flat-tree gitdir tree ""))))

; --- the working directory ---

; Does a directory hold a file anywhere beneath it?  git shows no
; directory that holds none.
(def %has-file?
  (fn (self dir)
    (List any?
      (fn (_ name)
        (let ((full (Str8 append dir "/" name)))
          (if (eq? (File type full) (lit dir)) (self full) #t)))
      (File list-dir dir))))

; What the working directory holds that the index does not know: files
; by path, and a directory with nothing tracked under it once, as
; "DIR/", as git shows it -- when it holds a file at all; .git is
; skipped.  Nothing reads .gitignore yet.
(def %untracked
  (fn (_ wd tracked)
    (def tracked-under?
      (fn (_ dir) (List any? (fn (_ t) (Str8 starts? (Str8 append dir "/") t)) tracked)))
    (def tracked? (fn (_ path) (List any? (fn (_ t) (str=? t path)) tracked)))
    ((fn (self dir prefix)
       (List flat-map
         (fn (_ name)
           (let ((full (Str8 append dir "/" name)) (path (Str8 append prefix name)))
             (match
               ((str=? name ".git") ())
               ((eq? (File type full) (lit dir))
                 (match
                   ((tracked-under? path) (self full (Str8 append path "/")))
                   ((%has-file? full) (list (Str8 append path "/")))
                   (#t ())))
               ((tracked? path) ())
               (#t (list path)))))
         (List sort (fn (_ a b) (Str8 <? a b)) (File list-dir dir))))
     wd "")))

; --- status ---

; The three lists status prints: staged ((CODE . PATH) ...) against HEAD,
; unstaged against the working directory, and the untracked paths.
(def git-status-lists
  (fn (_ wd gitdir)
    (def index (git-index-read gitdir))
    (def head (%head-files gitdir))
    (def in-index (fn (_ path) (List find (fn (_ e) (str=? (first e) path)) index)))
    (def in-head (fn (_ path) (List find (fn (_ h) (str=? (first h) path)) head)))
    (def staged
      (List append
        (List flat-map
          (fn (_ e)
            (let ((h (in-head (first e))))
              (match
                ((null? h) (list (pair "A" (first e))))
                ((not (str=? (rest h) (first (rest (rest e))))) (list (pair "M" (first e))))
                (#t ()))))
          index)
        (List flat-map (fn (_ h) (if (null? (in-index (first h))) (list (pair "D" (first h))) ())) head)))
    (def unstaged
      (List flat-map
        (fn (_ e)
          (let ((full (Str8 append wd "/" (first e))))
            (if (not (File exists? full)) (list (pair "D" (first e)))
              (let ((f (git-read-file full)))
                (if (str=? (git-hash "blob" (first f) 0 (rest f)) (first (rest (rest e)))) ()
                  (list (pair "M" (first e))))))))
        index))
    (list (List sort (fn (_ a b) (Str8 <? (rest a) (rest b))) staged)
          (List sort (fn (_ a b) (Str8 <? (rest a) (rest b))) unstaged)
          (%untracked wd (List map (fn (_ e) (first e)) index)))))

(def %branch-line
  (fn (_ gitdir)
    (def head (Str8 trim (File read-all (Str8 append gitdir "/HEAD"))))
    (if (Str8 starts? "ref: refs/heads/" head)
      (Str8 append "On branch " (Str8 sub 16 (%sub (Str8 length head) 16) head) "\n")
      (Str8 append "HEAD detached at " (Str8 sub 0 7 head) "\n"))))

(def %code-word
  (fn (_ code)
    (match ((str=? code "A") "new file:   ") ((str=? code "D") "deleted:    ") (#t "modified:   "))))

; status --porcelain: `XY PATH`, X the staged code, Y the unstaged, then
; `?? PATH` for the untracked.
(def %porcelain
  (fn (_ lists)
    (def staged (first lists))
    (def unstaged (first (rest lists)))
    (def code-of (fn (_ l path) (let ((e (List find (fn (_ c) (str=? (rest c) path)) l))) (if (null? e) " " (first e)))))
    (def paths
      (List sort (fn (_ a b) (Str8 <? a b))
        ((fn (self ps acc)
           (if (null? ps) acc
             (self (rest ps) (if (List any? (fn (_ a) (str=? a (first ps))) acc) acc (pair (first ps) acc)))))
         (List map (fn (_ c) (rest c)) (List append staged unstaged)) ())))
    (Str8 join ""
      (List append
        (List map (fn (_ p) (Str8 append (code-of staged p) (code-of unstaged p) " " p "\n")) paths)
        (List map (fn (_ p) (Str8 append "?? " p "\n")) (first (rest (rest lists))))))))

; status as git lays it out, hints and all -- also what commit prints when
; there is nothing to commit.
(def git-long-status
  (fn (_ gitdir lists) (%long-status gitdir lists)))

(def %long-status
  (fn (_ gitdir lists)
    (def staged (first lists))
    (def unstaged (first (rest lists)))
    (def untracked (first (rest (rest lists))))
    (def section
      (fn (_ title hints items)
        (if (null? items) ""
          (Str8 append title "\n"
            (Str8 join "" (List map (fn (_ h) (Str8 append "  (use \"" h "\")\n")) hints))
            (Str8 join "" (List map (fn (_ c) (Str8 append "\t" (%code-word (first c)) (rest c) "\n")) items))
            "\n"))))
    (Str8 append
      (%branch-line gitdir)
      (section "Changes to be committed:" (list "git restore --staged <file>... to unstage") staged)
      (section "Changes not staged for commit:"
        (list "git add <file>... to update what will be committed"
              "git restore <file>... to discard changes in working directory")
        unstaged)
      (if (null? untracked) ""
        (Str8 append "Untracked files:\n  (use \"git add <file>...\" to include in what will be committed)\n"
          (Str8 join "" (List map (fn (_ p) (Str8 append "\t" p "\n")) untracked))
          "\n"))
      (match
        ((not (null? staged)) "")
        ((not (null? unstaged)) "no changes added to commit (use \"git add\" and/or \"git commit -a\")\n")
        ((not (null? untracked)) "nothing added to commit but untracked files present (use \"git add\" to track)\n")
        (#t "nothing to commit, working tree clean\n")))))

(def git-status-options
  (Opts declare "git status" "[-s | --porcelain]" ()
    (list
      (Opts flag "-s" "--short" "--porcelain" "A line a path: two status letters, then the path"))))

(def git-status
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-status-options ops))
    (match
      ((Opts help? git-status-options ops) (list (lit out) (Opts usage git-status-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-status-options)))
      ((null? gitdir) (%no-repo))
      (#t
        (let ((lists (git-status-lists wd gitdir)))
          (list (lit out) (if (Opts on? o "-s") (%porcelain lists) (%long-status gitdir lists)) 0))))))

; --- ls-files ---

(def git-ls-files-options
  (Opts declare "git ls-files" "[-s | --stage]" ()
    (list
      (Opts flag "-s" "--stage" "Show the mode, the object name and the stage with each path"))))

(def git-ls-files
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-ls-files-options ops))
    (match
      ((Opts help? git-ls-files-options ops) (list (lit out) (Opts usage git-ls-files-options) 0))
      ((not (null? (Opts unknown o))) (%unknown-option (Opts unknown o) (Opts usage git-ls-files-options)))
      ((null? gitdir) (%no-repo))
      (#t
        (list (lit out)
          (Str8 join ""
            (List map
              (fn (_ e)
                (if (Opts on? o "-s")
                  (Str8 append (first (rest e)) " " (first (rest (rest e))) " " (Str8 str (first (rest (rest (rest e))))) "\t" (first e) "\n")
                  (Str8 append (first e) "\n")))
              (git-index-read gitdir)))
          0)))))

; The untracked paths under wd, given the tracked ones, as status lists
; them.
(def git-untracked
  (fn (_ wd tracked) (%untracked wd tracked)))

(provide git/index git-index-read git-status-lists git-status git-ls-files git-tree-files git-untracked git-long-status)

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
(import git/commands git-no-repo git-unknown-option)
(import git/refs git-ref-read git-tree-of git-rev-parse)
(import git/ignore git-ignorer)

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

; Does a directory hold a file anywhere beneath it that is not ignored?
(def %has-shown-file?
  (fn (self dir prefix ignored?)
    (List any?
      (fn (_ name)
        (let ((full (Str8 append dir "/" name)) (path (Str8 append prefix name)))
          (if (eq? (File type full) (lit dir))
            (if (ignored? path #t) #f (self full (Str8 append path "/") ignored?))
            (not (ignored? path #f)))))
      (File list-dir dir))))

; What the working directory holds that the index does not know: files
; by path, and a directory with nothing tracked under it once, as
; "DIR/", as git shows it -- when it holds a file at all; .git is
; skipped, and so is what .gitignore says to (ignored? a path and whether
; it is a directory, from git/ignore).
(def %untracked
  (fn (_ wd tracked ignored?)
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
                   ((ignored? path #t) ())
                   ((%has-shown-file? full (Str8 append path "/") ignored?) (list (Str8 append path "/")))
                   (#t ())))
               ((tracked? path) ())
               ((ignored? path #f) ())
               (#t (list path)))))
         (List sort (fn (_ a b) (Str8 <? a b)) (File list-dir dir))))
     wd "")))

; --- status ---

; The three lists status prints: staged ((CODE . PATH) ...) against HEAD,
; unstaged against the working directory, and the untracked paths.
; The paths a merge left in conflict, as (CODE . PATH), CODE the two
; letters status gives them from the stages there: 1 the base, 2 ours, 3
; theirs.
(def %unmerged
  (fn (_ all)
    (def paths
      ((fn (self es acc)
         (if (null? es) (List reverse acc)
           (self (rest es)
             (if (and (> (first (rest (rest (rest (first es))))) 0)
                      (not (List any? (fn (_ p) (str=? p (first (first es)))) acc)))
               (pair (first (first es)) acc) acc))))
       all ()))
    (List map
      (fn (_ p)
        (def stages (List map (fn (_ e) (first (rest (rest (rest e))))) (List filter (fn (_ e) (str=? (first e) p)) all)))
        (def has (fn (_ n) (List any? (fn (_ s) (= s n)) stages)))
        (pair
          (match
            ((and (has 2) (has 3)) (if (has 1) "UU" "AA"))
            ((and (has 1) (has 2)) "UD")
            ((and (has 1) (has 3)) "DU")
            ((has 2) "AU")
            ((has 3) "UA")
            (#t "DD"))
          p))
      paths)))

(def git-status-lists
  (fn (_ wd gitdir)
    (def all (git-index-read gitdir))
    (def unmerged (%unmerged all))
    ; a path in conflict is shown as unmerged and nowhere else
    (def index (List filter (fn (_ e) (not (List any? (fn (_ u) (str=? (rest u) (first e))) unmerged))) all))
    (def head (List filter (fn (_ h) (not (List any? (fn (_ u) (str=? (rest u) (first h))) unmerged))) (%head-files gitdir)))
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
          (%untracked wd (List map (fn (_ e) (first e)) all) (git-ignorer wd gitdir))
          unmerged)))

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
    (def unmerged (first (rest (rest (rest lists)))))
    (def code-of (fn (_ l path) (let ((e (List find (fn (_ c) (str=? (rest c) path)) l))) (if (null? e) " " (first e)))))
    (def paths
      (List sort (fn (_ a b) (Str8 <? a b))
        ((fn (self ps acc)
           (if (null? ps) acc
             (self (rest ps) (if (List any? (fn (_ a) (str=? a (first ps))) acc) acc (pair (first ps) acc)))))
         (List map (fn (_ c) (rest c)) (List append staged (List append unstaged unmerged))) ())))
    (Str8 join ""
      (List append
        (List map
          (fn (_ p)
            (let ((u (List find (fn (_ c) (str=? (rest c) p)) unmerged)))
              (if (null? u) (Str8 append (code-of staged p) (code-of unstaged p) " " p "\n")
                (Str8 append (first u) " " p "\n"))))
          paths)
        (List map (fn (_ p) (Str8 append "?? " p "\n")) (first (rest (rest lists))))))))

; status as git lays it out, hints and all -- also what commit prints when
; there is nothing to commit.
(def git-long-status
  (fn (_ gitdir lists) (%long-status gitdir lists)))

(def %unmerged-word
  (fn (_ code)
    (match
      ((str=? code "UU") "both modified:   ") ((str=? code "AA") "both added:      ")
      ((str=? code "UD") "deleted by them: ") ((str=? code "DU") "deleted by us:   ")
      ((str=? code "AU") "added by us:     ") ((str=? code "UA") "added by them:   ")
      (#t "both deleted:    "))))

(def %long-status
  (fn (_ gitdir lists)
    (def staged (first lists))
    (def unstaged (first (rest lists)))
    (def untracked (first (rest (rest lists))))
    (def unmerged (first (rest (rest (rest lists)))))
    (def merging? (File exists? (Str8 append gitdir "/MERGE_HEAD")))
    (def section
      (fn (_ title hints items)
        (if (null? items) ""
          (Str8 append title "\n"
            (Str8 join "" (List map (fn (_ h) (Str8 append "  (use \"" h "\")\n")) hints))
            (Str8 join "" (List map (fn (_ c) (Str8 append "\t" (%code-word (first c)) (rest c) "\n")) items))
            "\n"))))
    (Str8 append
      (%branch-line gitdir)
      (match
        ((not merging?) "")
        ((not (null? unmerged))
          "You have unmerged paths.\n  (fix conflicts and run \"git commit\")\n  (use \"git merge --abort\" to abort the merge)\n\n")
        (#t "All conflicts fixed but you are still merging.\n  (use \"git commit\" to conclude merge)\n\n"))
      ; during a merge, what is staged carries no hint to unstage it
      (section "Changes to be committed:" (if merging? () (list "git restore --staged <file>... to unstage")) staged)
      (if (null? unmerged) ""
        (Str8 append "Unmerged paths:\n"
          (if (List all? (fn (_ u) (or (str=? (first u) "UU") (str=? (first u) "AA"))) unmerged)
            "  (use \"git add <file>...\" to mark resolution)\n"
            "  (use \"git add/rm <file>...\" as appropriate to mark resolution)\n")
          (Str8 join "" (List map (fn (_ u) (Str8 append "\t" (%unmerged-word (first u)) (rest u) "\n")) unmerged))
          "\n"))
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
        ((or (not (null? unstaged)) (not (null? unmerged))) "no changes added to commit (use \"git add\" and/or \"git commit -a\")\n")
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
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-status-options)))
      ((null? gitdir) (git-no-repo))
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
      ((not (null? (Opts unknown o))) (git-unknown-option (Opts unknown o) (Opts usage git-ls-files-options)))
      ((null? gitdir) (git-no-repo))
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
; them: .gitignore honoured.
(def git-untracked
  (fn (_ wd gitdir tracked) (%untracked wd tracked (git-ignorer wd gitdir))))

; The same, with the caller's own ignored?: add -f takes everything.
(def git-untracked-with
  (fn (_ wd tracked ignored?) (%untracked wd tracked ignored?)))

(provide git/index git-index-read git-status-lists git-status git-ls-files git-tree-files git-untracked
  git-untracked-with git-long-status)

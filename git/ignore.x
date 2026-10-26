; # x-git -- git on x-lang
;
; ## git/ignore.x -- .gitignore
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The patterns of every .gitignore above a path, of .git/info/exclude and
; of core.excludesFile -- $XDG_CONFIG_HOME/git/ignore or
; ~/.config/git/ignore when it is not set -- read as git reads them
; (gitignore(5)): a line a pattern, blank and `#` lines nothing, trailing
; spaces dropped unless escaped, a leading `!` negating, a trailing `/`
; matching a directory alone, a `/` anywhere else anchoring the pattern
; at its file's directory, and `*`, `?`, `[...]` and `**` as in a shell,
; `*` never crossing a `/`.  A directory above the path that is ignored
; takes everything in it with it, past any `!`; otherwise, of the
; patterns that match the path, the one in the deepest .gitignore, and
; latest in it, decides, then info/exclude's, then core.excludesFile's.
;
; (git-ignore-matcher wd gitdir) answers a function of a path and whether
; it is a directory: the rule that decides, or () -- the rule's file,
; line and text for check-ignore -v.  (git-ignorer wd gitdir) answers
; whether it is ignored.  Each directory's .gitignore is read the first
; time a path under it is asked about.

(module git/ignore)

(import x/sys/file File)
(import x/sys/posix Sys)
(import git/config git-config-value)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))

; --- a glob on one path segment ---

; Does the bracket class at i of p (just past the `[`) take the char c?
; Answers (TAKEN? . NEXT), NEXT the index past the `]`.
(def %class
  (fn (_ p i np c)
    (def negated (if (< i np) (if (or (= (Str8 ref i p) #\!) (= (Str8 ref i p) #\^)) #t #f) #f))
    (def start (if negated (%add i 1) i))
    ((fn (self k hit first?)
       (if (>= k np) (pair #f np)
         (do (def ch (Str8 ref k p))
             (match
               ((and (= ch #\]) (not first?)) (pair (if negated (not hit) hit) (%add k 1)))
               ((and (< (%add k 2) np) (= (Str8 ref (%add k 1) p) #\-) (not (= (Str8 ref (%add k 2) p) #\])))
                 (self (%add k 3)
                       (or hit (and (>= (Char ->int c) (Char ->int ch))
                                    (<= (Char ->int c) (Char ->int (Str8 ref (%add k 2) p)))))
                       #f))
               (#t (self (%add k 1) (or hit (= ch c)) #f))))))
     start #f #t)))

; Does the glob p match the whole of s?  Characters, so a multibyte name
; is one character to a `?`.
(def %glob?
  (fn (self p i np s j ns)
    (if (>= i np) (>= j ns)
      (do (def c (Str8 ref i p))
          (match
            ((= c #\*)
              (if (self p (%add i 1) np s j ns) #t
                (if (< j ns) (self p i np s (%add j 1) ns) #f)))
            ((>= j ns) #f)
            ((= c #\?) (self p (%add i 1) np s (%add j 1) ns))
            ((= c #\[)
              (do (def r (%class p (%add i 1) np (Str8 ref j s)))
                  (if (first r) (self p (rest r) np s (%add j 1) ns) #f)))
            ((= c #\\)
              (if (< (%add i 1) np)
                (if (= (Str8 ref (%add i 1) p) (Str8 ref j s)) (self p (%add i 2) np s (%add j 1) ns) #f)
                #f))
            (#t (if (= c (Str8 ref j s)) (self p (%add i 1) np s (%add j 1) ns) #f)))))))

(def %segment? (fn (_ p s) (%glob? p 0 (Str8 length p) s 0 (Str8 length s))))

; --- a pattern against a path ---

; Do the pattern's segments match the path's from its start, `**` taking
; any number -- at least one when it ends the pattern, which matches what
; is inside a directory and not the directory?  Answers how many path
; segments they took, or () -- a match of a prefix is a match of the
; directory that prefix names.
(def %prefix-match
  (fn (self ps segs taken)
    (match
      ((null? ps) taken)
      ((str=? (first ps) "**")
        (if (null? (rest ps)) (if (null? segs) () (%add taken (List length segs)))
          ((fn (try ss k)
             (if (null? ss) ()
               (do (def r (self (rest ps) ss k))
                   (if (null? r) (try (rest ss) (%add k 1)) r))))
           segs taken)))
      ((null? segs) ())
      ((%segment? (first ps) (first segs)) (self (rest ps) (rest segs) (%add taken 1)))
      (#t ()))))

; A rule: (NEGATED? DIR-ONLY? ANCHORED? SEGMENTS BASE SOURCE LINE TEXT),
; BASE the directory of the file it came from, "" or "sub/", SOURCE that
; file as check-ignore names it, LINE its line there, TEXT the pattern as
; written, its trailing spaces dropped.
(def %rule
  (fn (_ line base source at)
    (def l (%trim-trailing line))
    (if (or (= (Str8 length l) 0) (Str8 starts? "#" l)) ()
      (do (def negated (Str8 starts? "!" l))
          (def body0 (if negated (Str8 sub 1 (%sub (Str8 length l) 1) l)
                       (if (Str8 starts? "\\!" l) (Str8 sub 1 (%sub (Str8 length l) 1) l)
                         (if (Str8 starts? "\\#" l) (Str8 sub 1 (%sub (Str8 length l) 1) l) l))))
          (def dir-only (Str8 ends? "/" body0))
          (def body1 (if dir-only (Str8 sub 0 (%sub (Str8 length body0) 1) body0) body0))
          (def anchored (not (null? (Str8 index-of "/" body1))))
          (def body (if (Str8 starts? "/" body1) (Str8 sub 1 (%sub (Str8 length body1) 1) body1) body1))
          (if (= (Str8 length body) 0) ()
            (list negated dir-only anchored (Str8 split "/" body) base source at l))))))

(def git-ignore-rule-negated? (fn (_ rule) (first rule)))
(def git-ignore-rule-source (fn (_ rule) (List ref 5 rule)))
(def git-ignore-rule-line (fn (_ rule) (List ref 6 rule)))
(def git-ignore-rule-text (fn (_ rule) (List ref 7 rule)))

; Trailing spaces dropped, unless the last is escaped.
(def %trim-trailing
  (fn (self s)
    (def n (Str8 length s))
    (if (= n 0) s
      (if (= (Str8 ref (%sub n 1) s) #\space)
        (if (and (> n 1) (= (Str8 ref (%sub n 2) s) #\\)) s (self (Str8 sub 0 (%sub n 1) s)))
        s))))

; Does the rule match the path (relative to the repository), which is a
; directory when dir?
(def %matches?
  (fn (_ rule path dir?)
    (def base (first (rest (rest (rest (rest rule))))))
    (if (not (Str8 starts? base path)) #f
      (do (def rel (Str8 sub (Str8 length base) (%sub (Str8 length path) (Str8 length base)) path))
          (def segs (Str8 split "/" rel))
          (def n (List length segs))
          (def dir-only (first (rest rule)))
          (def ps (first (rest (rest (rest rule)))))
          (if (first (rest (rest rule)))
            ; anchored: from the start; a prefix matched names a directory
            (do (def k (%prefix-match ps segs 0))
                (if (null? k) #f (if (< k n) #t (if dir-only dir? #t))))
            ; a name at any depth: a directory on the way, or the path itself
            ((fn (self ss i)
               (if (null? ss) #f
                 (if (%segment? (first ps) (first ss))
                   (if (< i (%sub n 1)) #t (if dir-only dir? #t))
                   (self (rest ss) (%add i 1)))))
             segs 0))))))

; The rules of a file, latest first, or () when there is no file; source
; is the file as check-ignore names it.
(def %rules-of
  (fn (_ path base source)
    (if (not (File exists? path)) ()
      ((fn (self lines at acc)
         (if (null? lines) acc
           (let ((r (%rule (first lines) base source at)))
             (self (rest lines) (%add at 1) (if (null? r) acc (pair r acc))))))
       (Str8 split "\n" (File read-all path)) 1 ()))))

; core.excludesFile, ~/ for the home directory, or git's default in the
; user's configuration directory; () when there is none.
(def %excludes-file
  (fn (_ gitdir)
    (def env (fn (_ n) (let ((v (Sys getenv n))) (if (or (null? v) (= (Str8 length v) 0)) () v))))
    (def named (git-config-value gitdir "core.excludesFile"))
    (def home (env "HOME"))
    (match
      ((not (null? named))
        (if (and (Str8 starts? "~/" named) (not (null? home))) (Str8 append home (Str8 sub 1 (%sub (Str8 length named) 1) named)) named))
      ((not (null? (env "XDG_CONFIG_HOME"))) (Str8 append (env "XDG_CONFIG_HOME") "/git/ignore"))
      ((not (null? home)) (Str8 append home "/.config/git/ignore"))
      (#t ()))))

; The directories above a path, deepest first: "a/b/" "a/" "" for a/b/c.
(def %dirs-above
  (fn (_ path)
    ((fn (self i acc)
       (def j (Str8 last-index-of "/" (Str8 sub 0 i path)))
       (if (null? j) (pair "" acc)
         (self j (pair (Str8 sub 0 (%add j 1) path) acc))))
     (Str8 length path) ())))

(def git-ignore-matcher
  (fn (_ wd gitdir)
    ; the rules by directory, read once each; info/exclude's then
    ; core.excludesFile's under every file's
    (def info (Str8 append gitdir "/info/exclude"))
    (def user (%excludes-file gitdir))
    (def global
      (List append
        (%rules-of info "" (if (str=? gitdir (Str8 append wd "/.git")) ".git/info/exclude" info))
        (if (null? user) () (%rules-of (if (Str8 starts? "/" user) user (Str8 append wd "/" user)) "" user))))
    (def cache ())
    (def rules-for
      (fn (_ dir)
        (def hit (Assoc entry dir cache))
        (if (not (null? hit)) (rest hit)
          (do (def r (%rules-of (Str8 append wd "/" dir ".gitignore") dir (Str8 append dir ".gitignore")))
              (set! cache (pair (pair dir r) cache))
              r))))
    ; the first rule, deepest file and latest line first, that matches
    (def decide
      (fn (_ path dir?)
        ((fn (self rs)
           (match
             ((null? rs) ())
             ((%matches? (first rs) path dir?) (first rs))
             (#t (self (rest rs)))))
         (List append (List flat-map rules-for (List reverse (%dirs-above path))) global))))
    ; a directory above the path ignored takes it with it, the shallowest
    ; first, as git looks; then the path's own rule
    (fn (_ path dir?)
      ((fn (self ds)
         (if (null? ds) (decide path dir?)
           (if (str=? (first ds) "") (self (rest ds))
             (do (def r (decide (Str8 sub 0 (%sub (Str8 length (first ds)) 1) (first ds)) #t))
                 (if (or (null? r) (first r)) (self (rest ds)) r)))))
       (%dirs-above path)))))

(def git-ignorer
  (fn (_ wd gitdir)
    (def rule-of (git-ignore-matcher wd gitdir))
    (fn (_ path dir?) (let ((r (rule-of path dir?))) (if (null? r) #f (not (first r)))))))

(provide git/ignore git-ignorer git-ignore-matcher git-ignore-rule-negated? git-ignore-rule-source
  git-ignore-rule-line git-ignore-rule-text)

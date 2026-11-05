; # x-git -- git on x-lang
;
; ## git/refs.x -- refs and revision names
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A ref is a file under .git holding a name (`ref: refs/heads/main`) or an
; object's SHA-1, or a line of .git/packed-refs, where an annotated tag's
; line may be followed by `^` and the object it peels to.  A revision
; (gitrevisions(7)) is a ref or an object name, with suffixes: `~N` the
; Nth first parent, `^N` the Nth parent, `^{TYPE}` peeled to that type,
; `^{}` peeled through tags, and `:PATH` the entry at PATH in the tree.
; Everything here answers a full SHA-1 or (); the words of a refusal are
; the command's.

(module git/refs)

(import x/sys/file File)
(import git/objects git-object-read git-resolve git-tree-entries git-object-text)
(import git/reflog git-reflog-entries)
(import git/config git-config-reader)
(import x/type/regex Regex)
(import x/type/vector Vector)
(import x/sys/posix Sys)
(import git/when git-approxidate git-rfc2822-date)

(import x/core/doors int+ int-)

; --- refs ---

; The text of a ref file, trimmed, or () when there is none.
(def %ref-file
  (fn (_ gitdir name)
    (def path (Str8 append gitdir "/" name))
    (if (File exists? path) (Str8 trim (File read-all path)) ())))

; packed-refs as ((NAME . SHA) ...), a tag's peeled line folded into its
; entry's cdr as (SHA . PEELED).
(def %packed-refs
  (fn (_ gitdir)
    (def text (%ref-file gitdir "packed-refs"))
    (if (null? text) ()
      ((fn (self lines acc)
         (match
           ((null? lines) (List reverse acc))
           ((= (Str8 length (first lines)) 0) (self (rest lines) acc))
           ((Str8 starts? "#" (first lines)) (self (rest lines) acc))
           ((Str8 starts? "^" (first lines))
             (if (null? acc) (self (rest lines) acc)
               (let ((e (first acc)))
                 (self (rest lines) (pair (pair (first e) (pair (rest e) (Str8 sub 1 40 (first lines)))) (rest acc))))))
           (#t
             (self (rest lines)
               (pair (pair (Str8 sub 41 (int- (Str8 length (first lines)) 41) (first lines))
                           (Str8 sub 0 40 (first lines)))
                     acc)))))
       (Str8 split "\n" text) ()))))

; What a ref holds: its SHA-1, following symbolic refs, loose before
; packed; () when there is no such ref.
(def git-ref-read
  (fn (self gitdir name)
    (def loose (%ref-file gitdir name))
    (match
      ((and (not (null? loose)) (Str8 starts? "ref: " loose))
        (self gitdir (Str8 trim (Str8 sub 5 (int- (Str8 length loose) 5) loose))))
      ((not (null? loose)) loose)
      (#t
        (let ((hit (List find (fn (_ e) (str=? (first e) name)) (%packed-refs gitdir))))
          (match
            ((null? hit) ())
            ((pair? (rest hit)) (first (rest hit)))
            (#t (rest hit))))))))

; The refs under a prefix (refs/heads/, refs/tags/), by name, loose and
; packed together, each once, sorted.
(def git-ref-names
  (fn (_ gitdir prefix)
    (def dir (Str8 append gitdir "/" prefix))
    (def loose
      (if (File exists? dir)
        ((fn (self d p)
           (List flat-map
             (fn (_ name)
               (let ((full (Str8 append d "/" name)))
                 (if (eq? (File type full) (lit dir)) (self full (Str8 append p name "/")) (list (Str8 append p name)))))
             (File list-dir d)))
         dir "")
        ()))
    (def packed-path (Str8 append gitdir "/packed-refs"))
    (def packed
      (if (not (File exists? packed-path)) ()
        (List flat-map
          (fn (_ l)
            (if (and (> (Str8 length l) 41) (not (Str8 starts? "#" l)) (not (Str8 starts? "^" l))
                     (Str8 starts? prefix (Str8 sub 41 (int- (Str8 length l) 41) l)))
              (list (Str8 sub (int+ 41 (Str8 length prefix)) (int- (Str8 length l) (int+ 41 (Str8 length prefix))) l))
              ()))
          (Str8 split "\n" (File read-all packed-path)))))
    (List sort (fn (_ a b) (Str8 <? a b))
      ((fn (self ns acc) (if (null? ns) acc (self (rest ns) (if (List any? (fn (_ a) (str=? a (first ns))) acc) acc (pair (first ns) acc)))))
       (List append loose packed) ()))))

; A short name tried as gitrevisions does: as given, under refs/, tags/,
; heads/, remotes/, and remotes/NAME/HEAD.
(def %ref-lookup
  (fn (_ gitdir name)
    ((fn (self cands)
       (if (null? cands) ()
         (let ((sha (git-ref-read gitdir (first cands))))
           (if (null? sha) (self (rest cands)) sha))))
     (list name
           (Str8 append "refs/" name)
           (Str8 append "refs/tags/" name)
           (Str8 append "refs/heads/" name)
           (Str8 append "refs/remotes/" name)
           (Str8 append "refs/remotes/" name "/HEAD")))))

; --- objects behind a revision ---

; The header lines of a commit or tag, as ((KEY . VALUE) ...), up to the
; blank line.
(def %headers
  (fn (_ gitdir sha)
    (def o (git-object-read gitdir sha))
    (if (null? o) ()
      ((fn (self lines acc)
         (if (or (null? lines) (= (Str8 length (first lines)) 0)) (List reverse acc)
           (let ((i (Str8 index-of " " (first lines))))
             (if (null? i) (self (rest lines) acc)
               (self (rest lines)
                 (pair (pair (Str8 sub 0 i (first lines))
                             (Str8 sub (int+ i 1) (int- (Str8 length (first lines)) (int+ i 1)) (first lines)))
                       acc))))))
       (Str8 split "\n" (git-object-text o)) ()))))

(def %type-of
  (fn (_ gitdir sha)
    (def o (git-object-read gitdir sha))
    (if (null? o) () (first o))))

; A tag peeled once: the object it names.
(def %peel-tag
  (fn (_ gitdir sha)
    (def h (%headers gitdir sha))
    (def e (List find (fn (_ kv) (str=? (first kv) "object")) h))
    (if (null? e) () (rest e))))

; Peeled through every tag to what is not one.
(def %peel-tags
  (fn (self gitdir sha)
    (if (and (not (null? sha)) (str=? (%type-of gitdir sha) "tag"))
      (self gitdir (%peel-tag gitdir sha))
      sha)))

; A commit's Nth parent (1 the first), or ().
(def %parent
  (fn (_ gitdir sha n)
    (def c (%peel-tags gitdir sha))
    (if (or (null? c) (not (str=? (%type-of gitdir c) "commit"))) ()
      (let ((parents (List filter (fn (_ kv) (str=? (first kv) "parent")) (%headers gitdir c))))
        (if (> n (List length parents)) () (rest (List ref (int- n 1) parents)))))))

; A commit's tree, a tag's through the tag; a tree is itself.
(def %tree-of
  (fn (_ gitdir sha)
    (def c (%peel-tags gitdir sha))
    (if (null? c) ()
      (let ((type (%type-of gitdir c)))
        (match
          ((str=? type "tree") c)
          ((str=? type "commit")
            (let ((e (List find (fn (_ kv) (str=? (first kv) "tree")) (%headers gitdir c))))
              (if (null? e) () (rest e))))
          (#t ()))))))

; The entry at PATH in a tree: one component at a time; "" is the tree.
(def %path-in
  (fn (self gitdir tree path)
    (if (or (null? tree) (= (Str8 length path) 0)) tree
      (let ((i (Str8 index-of "/" path)))
        (let ((head (if (null? i) path (Str8 sub 0 i path)))
              (tail (if (null? i) "" (Str8 sub (int+ i 1) (int- (Str8 length path) (int+ i 1)) path))))
          (let ((o (git-object-read gitdir tree)))
            (if (or (null? o) (not (str=? (first o) "tree"))) ()
              (let ((e (List find (fn (_ ent) (str=? (first (rest ent)) head)) (git-tree-entries o))))
                (if (null? e) () (self gitdir (first (rest (rest e))) tail))))))))))

; --- commits by message ---

; A commit's committer time, its epoch, to order the search.
(def %commit-time
  (fn (_ gitdir sha)
    (def e (List find (fn (_ kv) (str=? (first kv) "committer")) (%headers gitdir sha)))
    (def words (if (null? e) () (Str8 split " " (rest e))))
    (if (< (List length words) 2) 0 (%str->number (List ref (int- (List length words) 2) words) 10))))

; A commit's message: what follows its headers' blank line, or ().
(def %message
  (fn (_ gitdir sha)
    (def o (git-object-read gitdir sha))
    (def text (if (null? o) "" (git-object-text o)))
    (def i (Str8 index-of "\n\n" text))
    (if (null? i) () (Str8 sub (int+ i 2) (int- (Str8 length text) (int+ i 2)) text))))

; (TIME . SHA) put into a list newest first, after those as new.
(def %by-date
  (fn (self item pending)
    (if (or (null? pending) (> (first item) (first (first pending)))) (pair item pending)
      (pair (first pending) (self item (rest pending))))))

; The newest commit, by committer time, reachable from the commits tips
; whose message the pattern matches, as gitrevisions(7) finds one for
; :/TEXT and REV^{/TEXT}: an extended regular expression, a leading `!-`
; making it the commits that do not match, `!!` a literal `!`; any other
; leading `!` is no pattern.  Each commit is looked at once, the newest
; queued first; () when none matches.
(def %search
  (fn (_ gitdir tips pattern)
    (def bang? (Str8 starts? "!" pattern))
    (def negate? (Str8 starts? "!-" pattern))
    (def text (if negate? (Str8 sub 2 (int- (Str8 length pattern) 2) pattern)
                (if (Str8 starts? "!!" pattern) (Str8 sub 1 (int- (Str8 length pattern) 1) pattern) pattern)))
    (def rx (if (and bang? (not negate?) (not (Str8 starts? "!!" pattern))) ()
              (guard (e ()) (Regex compile text))))
    (def matches?
      (fn (_ sha)
        (def m (%message gitdir sha))
        (def hit (if (null? m) #f (not (null? (Regex search m rx)))))
        (if negate? (not hit) hit)))
    (def queue (fn (_ shas pending) (List fold (fn (_ acc s) (%by-date (pair (%commit-time gitdir s) s) acc)) pending shas)))
    (if (null? rx) ()
      ((fn (self pending seen)
         (match
           ((null? pending) ())
           ((matches? (rest (first pending))) (rest (first pending)))
           (#t
             (let ((parents (List filter (fn (_ p) (not (List any? (fn (_ s) (str=? s p)) seen)))
                              (List map rest (List filter (fn (_ kv) (str=? (first kv) "parent")) (%headers gitdir (rest (first pending))))))))
               (self (queue parents (rest pending)) (List append parents seen))))))
       (queue tips ()) tips))))

; The commits every ref and HEAD reach first, for :/TEXT: tags peeled,
; what is not a commit left out, in the order git takes them, HEAD first
; and the refs by name, last first.
(def %all-tips
  (fn (_ gitdir)
    (def shas (pair (git-ref-read gitdir "HEAD")
                    (List reverse (List map (fn (_ n) (git-ref-read gitdir (Str8 append "refs/" n))) (git-ref-names gitdir "refs/")))))
    (List filter (fn (_ c) (and (not (null? c)) (str=? (%type-of gitdir c) "commit")))
      (List map (fn (_ s) (%peel-tags gitdir s)) shas))))

; --- revisions ---

; A suffix's count: its digits as a number, 1 when there are none, ()
; when it is not digits.
(def %count
  (fn (_ s)
    (def n (Str8 length s))
    (def digits?
      ((fn (self i)
         (if (>= i n) #t
           (let ((c (Char ->int (Str8 ref i s))))
             (if (and (>= c 48) (<= c 57)) (self (int+ i 1)) #f))))
       0))
    (match
      ((= n 0) 1)
      (digits? (%str->number s 10))
      (#t ()))))

; The ref a name's log is under, as gitrevisions finds one: the first of
; the short-name candidates that exists; HEAD's branch (or HEAD, detached)
; for an empty name.
(def %log-ref
  (fn (_ gitdir name)
    (def head (%ref-file gitdir "HEAD"))
    (if (= (Str8 length name) 0)
      (if (and (not (null? head)) (Str8 starts? "ref: " head)) (Str8 trim (Str8 sub 5 (int- (Str8 length head) 5) head)) "HEAD")
      (List find (fn (_ c) (not (null? (git-ref-read gitdir c))))
        (list name (Str8 append "refs/" name) (Str8 append "refs/tags/" name)
              (Str8 append "refs/heads/" name) (Str8 append "refs/remotes/" name))))))

; The branch checked out n switches ago, from HEAD's log of checkouts
; ("checkout: moving from A to B"), or ().
(def %previous-branch
  (fn (_ gitdir n)
    (def froms
      (List flat-map
        (fn (_ e)
          (def m (first (rest (rest (rest e)))))
          (if (not (Str8 starts? "checkout: moving from " m)) ()
            (let ((tail (Str8 sub 22 (int- (Str8 length m) 22) m)))
              (let ((to (Str8 index-of " to " tail)))
                (if (null? to) () (list (Str8 sub 0 to tail)))))))
        (git-reflog-entries gitdir "HEAD")))
    (if (> n (List length froms)) () (List ref (int- n 1) froms))))

; --- upstreams ---

; Whether a reflog spec is @{upstream}'s: u or upstream, in any case.
(def %upstream-spec?
  (fn (_ spec)
    (def s (Str8 downcase spec))
    (if (str=? s "u") #t (str=? s "upstream"))))

; A ref name mapped through one fetch refspec, `[+]SRC:DST`, SRC and DST
; each with at most one `*`; () when SRC does not match it.
(def %through-refspec
  (fn (_ spec name)
    (def s (if (Str8 starts? "+" spec) (Str8 sub 1 (int- (Str8 length spec) 1) spec) spec))
    (def colon (Str8 index-of ":" s))
    (def src (if (null? colon) s (Str8 sub 0 colon s)))
    (def dst (if (null? colon) "" (Str8 sub (int+ colon 1) (int- (Str8 length s) (int+ colon 1)) s)))
    (def star (Str8 index-of "*" src))
    (match
      ((or (Str8 starts? "^" s) (= (Str8 length dst) 0)) ())
      ((null? star) (if (str=? src name) dst ()))
      (#t
        (let ((pre (Str8 sub 0 star src))
              (post (Str8 sub (int+ star 1) (int- (Str8 length src) (int+ star 1)) src)))
          (if (or (< (Str8 length name) (int+ (Str8 length pre) (Str8 length post)))
                  (not (Str8 starts? pre name)) (not (Str8 ends? post name)))
            ()
            (let ((mid (Str8 sub (Str8 length pre) (int- (int- (Str8 length name) (Str8 length pre)) (Str8 length post)) name))
                  (dstar (Str8 index-of "*" dst)))
              (if (null? dstar) dst
                (Str8 append (Str8 sub 0 dstar dst) mid
                  (Str8 sub (int+ dstar 1) (int- (Str8 length dst) (int+ dstar 1)) dst))))))))))

; The ref a branch's upstream is, as gitrevisions(7) finds it for
; BRANCH@{upstream}: its branch.<name>.merge, through the fetch refspecs
; of its branch.<name>.remote to where fetch stores it (as it is, for the
; remote `.`).  An empty name or HEAD is the branch checked out.  Answers
; (ok REF), or (no WORDS), git's words for why there is none.
(def %upstream
  (fn (_ gitdir name)
    (def head (%ref-file gitdir "HEAD"))
    (def current?
      (if (= (Str8 length name) 0) #t (str=? name "HEAD")))
    (def branch
      (if current?
        (if (and (not (null? head)) (Str8 starts? "ref: refs/heads/" head))
          (Str8 trim (Str8 sub 16 (int- (Str8 length head) 16) head))
          ())
        name))
    (def config (if (null? branch) () (git-config-reader gitdir)))
    (def last (fn (_ name) (let ((vs (config name))) (if (null? vs) () (List last vs)))))
    (def merge (if (null? branch) () (last (Str8 append "branch." branch ".merge"))))
    (def remote (if (null? branch) () (last (Str8 append "branch." branch ".remote"))))
    (match
      ((null? branch) (list (lit no) "HEAD does not point to a branch"))
      ((and (not current?) (null? (git-ref-read gitdir (Str8 append "refs/heads/" branch))))
        (list (lit no) (Str8 append "no such branch: '" branch "'")))
      ((or (null? merge) (null? remote))
        (list (lit no) (Str8 append "no upstream configured for branch '" branch "'")))
      ((str=? remote ".") (list (lit ok) merge))
      (#t
        (let ((ref ((fn (self specs)
                      (if (null? specs) ()
                        (let ((r (%through-refspec (first specs) merge))) (if (null? r) (self (rest specs)) r))))
                    (config (Str8 append "remote." remote ".fetch")))))
          (if (null? ref)
            (list (lit no) (Str8 append "upstream branch '" merge "' not stored as a remote-tracking branch"))
            (list (lit ok) ref)))))))

; --- warnings ---

; What git warns of as a revision resolves, said once the command is
; done: the lines gathered since they were last taken.
(def %warnings (Vector make 1 ""))

(def %warn! (fn (_ line) (Vector set! 0 (Str8 append (Vector ref 0 %warnings) "warning: " line "\n") %warnings)))

; The warnings gathered, taken: "" when there are none.
(def git-rev-warnings!
  (fn (_)
    (def w (Vector ref 0 %warnings))
    (Vector set! 0 "" %warnings)
    w))

; --- reflogs ---

; A log entry's time and zone, from its `NAME <EMAIL> EPOCH ZONE`.
(def %entry-when
  (fn (_ e)
    (def who (first (rest (rest e))))
    (def gt (Str8 last-index-of ">" who))
    (def tail (Str8 split " " (Str8 trim (Str8 sub (int+ gt 1) (int- (Str8 length who) (int+ gt 1)) who))))
    (pair (%str->number (first tail) 10) (first (rest tail)))))

; The value name's log gave it at a time: the newest entry's from then or
; before; for a time older than the log, the oldest's earlier value, as
; git takes it, with git's warning that the log goes back no further.
(def %reflog-when
  (fn (_ gitdir name ref time)
    (def entries (git-reflog-entries gitdir ref))
    (def hit (List find (fn (_ e) (<= (first (%entry-when e)) time)) entries))
    (match
      ((null? entries) ())
      ((not (null? hit)) (first (rest hit)))
      (#t
        (let ((oldest (List last entries)))
          (let ((w (%entry-when oldest)))
            (%warn! (Str8 append "log for '"
                      (if (> (Str8 length name) 0) name
                        (if (Str8 starts? "refs/heads/" ref) (Str8 sub 11 (int- (Str8 length ref) 11) ref) ref))
                      "' only goes back to " (git-rfc2822-date (first w) (rest w))))
            (if (str=? (first oldest) "0000000000000000000000000000000000000000") (first (rest oldest)) (first oldest))))))))

; name@{spec}: the Nth prior value in name's log (@{0} its newest), its
; value at a time (a date, or a number of 100000000 or more, git's line
; between the two), or with an empty name and -N, the Nth branch checked
; out before this one.
(def %reflog-at
  (fn (_ gitdir name spec)
    (def neg? (Str8 starts? "-" spec))
    (def digits (if neg? (Str8 sub 1 (int- (Str8 length spec) 1) spec) spec))
    (def k (if (= (Str8 length digits) 0) () (%count digits)))
    (match
      (neg?
        (if (or (null? k) (> (Str8 length name) 0) (= k 0)) ()
          (let ((b (%previous-branch gitdir k)))
            (if (null? b) () (or (git-resolve gitdir b) (%ref-lookup gitdir b))))))
      ((and (not (null? k)) (< k 100000000))
        (let ((ref (%log-ref gitdir name)))
          (let ((entries (if (null? ref) () (git-reflog-entries gitdir ref))))
            (if (>= k (List length entries)) () (first (rest (List ref k entries)))))))
      (#t
        (let ((ref (%log-ref gitdir name))
              (time (if (null? k) (git-approxidate spec (Sys now)) k)))
          (if (or (null? ref) (null? time)) () (%reflog-when gitdir name ref time)))))))

; A revision without a `:PATH` tail, to a SHA-1: the suffixes peeled off
; the right end and applied after the base resolves.
(def %rev-base
  (fn (self gitdir rev)
    (def n (Str8 length rev))
    (match
      ((= n 0) ())
      ; ^{TYPE} and ^{}
      ((and (Str8 ends? "}" rev) (not (null? (Str8 last-index-of "^{" rev))))
        (let ((i (Str8 last-index-of "^{" rev)))
          (let ((inner (self gitdir (Str8 sub 0 i rev)))
                (want (Str8 sub (int+ i 2) (int- (int- n i) 3) rev)))
            (match
              ((null? inner) ())
              ((= (Str8 length want) 0) (%peel-tags gitdir inner))
              ((str=? want "tree") (%tree-of gitdir inner))
              ((str=? want "commit")
                (let ((c (%peel-tags gitdir inner)))
                  (if (and (not (null? c)) (str=? (%type-of gitdir c) "commit")) c ())))
              ((str=? want "tag") (if (str=? (%type-of gitdir inner) "tag") inner ()))
              ((str=? want "blob")
                (let ((c (%peel-tags gitdir inner)))
                  (if (and (not (null? c)) (str=? (%type-of gitdir c) "blob")) c ())))
              ; ^{/TEXT}: the newest commit it reaches whose message matches
              ((Str8 starts? "/" want)
                (let ((c (%peel-tags gitdir inner)))
                  (if (and (not (null? c)) (str=? (%type-of gitdir c) "commit"))
                    (%search gitdir (list c) (Str8 sub 1 (int- (Str8 length want) 1) want))
                    ())))
              (#t ())))))
      ; BRANCH@{upstream}, then REF@{N}, @{N} and @{-N}: from the reflog
      ((and (Str8 ends? "}" rev) (not (null? (Str8 last-index-of "@{" rev))))
        (let ((i (Str8 last-index-of "@{" rev)))
          (let ((name (Str8 sub 0 i rev)) (spec (Str8 sub (int+ i 2) (int- (int- n i) 3) rev)))
            (if (%upstream-spec? spec)
              (let ((u (%upstream gitdir name)))
                (if (eq? (first u) (lit ok)) (git-ref-read gitdir (first (rest u))) ()))
              (%reflog-at gitdir name spec)))))
      ; @ alone is HEAD
      ((str=? rev "@") (self gitdir "HEAD"))
      ; ~N: N first parents
      ((not (null? (Str8 last-index-of "~" rev)))
        (let ((i (Str8 last-index-of "~" rev)))
          (let ((cnt (%count (Str8 sub (int+ i 1) (int- n (int+ i 1)) rev))))
            (if (null? cnt) ()
              ((fn (walk sha k) (if (or (null? sha) (= k 0)) sha (walk (%parent gitdir sha 1) (int- k 1))))
               (self gitdir (Str8 sub 0 i rev)) cnt)))))
      ; ^N: the Nth parent
      ((not (null? (Str8 last-index-of "^" rev)))
        (let ((i (Str8 last-index-of "^" rev)))
          (let ((cnt (%count (Str8 sub (int+ i 1) (int- n (int+ i 1)) rev))))
            (let ((base (if (null? cnt) () (self gitdir (Str8 sub 0 i rev)))))
              (if (null? base) () (%parent gitdir base cnt))))))
      (#t
        (let ((sha (git-resolve gitdir rev)))
          (if (null? sha) (%ref-lookup gitdir rev) sha))))))

; Where a revision's `:PATH` starts: its first colon outside braces, as
; git looks for it, so ^{/TEXT} may hold one; () when there is none.
(def %path-colon
  (fn (_ rev)
    (def n (Str8 length rev))
    ((fn (self i depth)
       (if (>= i n) ()
         (let ((c (Str8 sub i 1 rev)))
           (match
             ((str=? c "{") (self (int+ i 1) (int+ depth 1)))
             ((and (str=? c "}") (> depth 0)) (self (int+ i 1) (int- depth 1)))
             ((and (str=? c ":") (= depth 0)) i)
             (#t (self (int+ i 1) depth))))))
     0 0)))

; A revision to a full SHA-1, or (): an object name or a ref with any of
; the suffixes, and `REV:PATH` the entry at PATH in REV's tree.
(def git-rev-parse
  (fn (_ gitdir rev)
    (def i (%path-colon rev))
    (match
      ; :/TEXT: the rest is the pattern, suffixes and all
      ((and (Str8 starts? ":/" rev) (> (Str8 length rev) 2))
        (%search gitdir (%all-tips gitdir) (Str8 sub 2 (int- (Str8 length rev) 2) rev)))
      ((null? i) (%rev-base gitdir rev))
      (#t
        (let ((base (%rev-base gitdir (Str8 sub 0 i rev)))
              (path (Str8 sub (int+ i 1) (int- (Str8 length rev) (int+ i 1)) rev)))
          (if (null? base) () (%path-in gitdir (%tree-of gitdir base) path)))))))

; Is the trouble with `REV:PATH` the path, given REV itself resolves?
; Answers REV when so, else ().
(def git-rev-path-missing
  (fn (_ gitdir rev)
    (def i (if (Str8 starts? ":/" rev) () (%path-colon rev)))
    (if (null? i) ()
      (let ((base (%rev-base gitdir (Str8 sub 0 i rev))))
        (if (null? base) () (Str8 sub 0 i rev))))))

; Is the trouble with a revision a log too short for its @{N}?  Answers
; git's words for it, "log for 'NAME' only has N entries", else ().
(def git-rev-log-short
  (fn (_ gitdir rev)
    (def at (Str8 index-of "@{" rev))
    (def close (if (null? at) () (Str8 index-of "}" (Str8 sub at (int- (Str8 length rev) at) rev))))
    (if (or (null? at) (null? close)) ()
      (let ((name (Str8 sub 0 at rev))
            (k (let ((d (Str8 sub (int+ at 2) (int- close 2) rev))) (if (= (Str8 length d) 0) () (%count d)))))
        (let ((ref (if (null? k) () (%log-ref gitdir name))))
          (let ((have (if (null? ref) 0 (List length (git-reflog-entries gitdir ref)))))
            (if (or (null? ref) (= have 0) (< k have)) ()
              (Str8 append "log for '"
                (if (> (Str8 length name) 0) name
                  (if (Str8 starts? "refs/heads/" ref) (Str8 sub 11 (int- (Str8 length ref) 11) ref) ref))
                "' only has " (Str8 str have) " entries"))))))))

; Why a revision does not resolve, in git's words, when it is not simply
; unknown: an @{upstream} with none to name (the first in the revision),
; or a log too short for its @{N}.  Answers the words, else ().
(def git-rev-trouble
  (fn (_ gitdir rev)
    (def n (Str8 length rev))
    (def upstream
      ((fn (self from)
         (let ((at (if (>= from n) () (Str8 index-of "@{" (Str8 sub from (int- n from) rev)))))
           (if (null? at) ()
             (let ((i (int+ from at)))
               (let ((close (Str8 index-of "}" (Str8 sub i (int- n i) rev))))
                 (if (null? close) ()
                   (let ((u (if (%upstream-spec? (Str8 sub (int+ i 2) (int- close 2) rev))
                              (%upstream gitdir (Str8 sub 0 i rev))
                              (list (lit ok)))))
                     (if (eq? (first u) (lit no)) (first (rest u)) (self (int+ i 2))))))))))
       0))
    (if (null? upstream) (git-rev-log-short gitdir rev) upstream)))

; A revision's tree: a commit's, a tag's through the tag, a tree itself;
; () when the revision does not resolve or has no tree.
(def git-tree-of
  (fn (_ gitdir rev)
    (def sha (git-rev-parse gitdir rev))
    (if (null? sha) () (%tree-of gitdir sha))))

; A revision's commit: itself, or what its tag peels to; () when the
; revision does not resolve or does not reach a commit.
(def git-commit-of
  (fn (_ gitdir rev)
    (def c (%peel-tags gitdir (git-rev-parse gitdir rev)))
    (if (and (not (null? c)) (str=? (%type-of gitdir c) "commit")) c ())))

; A commit's header lines, ((KEY . VALUE) ...), for the commands that
; print them; () for a name that is not a commit or tag.
(def git-headers
  (fn (_ gitdir sha) (%headers gitdir sha)))

; The ref a name's log is under, as @{N} finds it, or ().
(def git-log-ref (fn (_ gitdir name) (%log-ref gitdir name)))

; The branch @{-N} names: the Nth checked out before this one, or ().
(def git-previous-branch
  (fn (_ gitdir spec)
    (def k (%count (Str8 sub 3 (int- (Str8 length spec) 4) spec)))
    (if (or (null? k) (not (Str8 ends? "}" spec)) (= k 0)) () (%previous-branch gitdir k))))

(provide git/refs git-ref-read git-ref-names git-rev-warnings! git-rev-parse git-rev-path-missing git-rev-log-short git-rev-trouble git-log-ref git-previous-branch git-tree-of git-commit-of git-headers)

; # x-git -- git on x-lang
;
; ## git/config.x -- configuration
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; git's configuration, read from where git reads it, in its order, the
; last value of a name winning: the system's file (/etc/gitconfig, or
; GIT_CONFIG_SYSTEM; none under GIT_CONFIG_NOSYSTEM), the user's
; ($XDG_CONFIG_HOME/git/config or ~/.config/git/config, then
; ~/.gitconfig; or GIT_CONFIG_GLOBAL alone), the repository's
; (.git/config), then the command line's (GIT_CONFIG_COUNT and its pairs,
; then GIT_CONFIG_PARAMETERS, where -c puts what it is given).
;
; A file is read as git's parser reads it: `[section]`, `[section
; "subsection"]` and the old `[section.subsection]`; `name = value`,
; or a name alone, which is true; comments from `#` or `;`; a value's
; quotes, its escapes (\" \\ \n \t \b), its lines joined by a backslash
; at their end, its runs of blanks made spaces and its ends trimmed.  A
; section's and a name's case do not matter; a subsection's does.  A
; name is written back as git writes one: into the last block of its
; section, quoted only when a blank ends it or it holds ; or #, and a
; section left empty by an unset taken out.
;
; Includes (include.path, includeIf) are not followed.

(module git/config)

(import x/sys/file File)
(import x/sys/opts Opts)

(def %add (prim-ref (lit int) (lit +)))
(def %sub (prim-ref (lit int) (lit -)))
(def %lt (prim-ref (lit int) (lit <)))
(def %int->char (prim-ref (lit int) (lit ->char)))

(def %in? (fn (_ c lo hi) (if (%lt c lo) #f (not (%lt hi c)))))
(def %blank? (fn (_ c) (or (= c #\space) (= c #\tab) (= c #\return))))
(def %alpha? (fn (_ c) (or (%in? c #\a #\z) (%in? c #\A #\Z))))
(def %key-char? (fn (_ c) (or (%alpha? c) (%in? c #\0 #\9) (= c #\-))))

; --- reading a file ---

; A file's text as its items, in order:
;   (sec SECTION START END)          a header; SECTION its name for
;                                    matching, START..END its line
;   (key NAME VALUE START END SECTION) a name's line(s), NAME the full name
;                                    for matching, VALUE () for one given
;                                    alone
; or (bad LINE) for the first line git would refuse.
(def %parse
  (fn (_ s)
    (def n (Str8 length s))
    (def ch (fn (_ i) (if (%lt i n) (Str8 ref i s) #\newline)))
    (def eol (fn (self i) (if (%lt i n) (if (= (Str8 ref i s) #\newline) (%add i 1) (self (%add i 1))) n)))
    (def skip (fn (self i) (if (and (%lt i n) (%blank? (Str8 ref i s))) (self (%add i 1)) i)))
    (def word-end
      (fn (self i dots?)
        (if (and (%lt i n) (or (%key-char? (Str8 ref i s)) (and dots? (= (Str8 ref i s) #\.)))) (self (%add i 1) dots?) i)))
    (def line-of
      (fn (_ i) ((fn (self k count) (if (%lt k i) (self (%add k 1) (if (= (Str8 ref k s) #\newline) (%add count 1) count)) count)) 0 1)))
    ; a header from just past its [: (SECTION . NEXT), or ()
    (def header
      (fn (_ i)
        (def e (word-end i #t))
        (def name (Str8 sub i (%sub e i) s))
        (match
          ((= (%sub e i) 0) ())
          ((= (ch e) #\]) (pair (Str8 downcase name) (%add e 1)))
          ((%blank? (ch e))
            (let ((j (skip e)))
              (if (not (= (ch j) #\")) ()
                ((fn (self k acc)
                   (let ((c (ch k)))
                     (match
                       ((not (%lt k n)) ())
                       ((= c #\newline) ())
                       ((= c #\") (if (= (ch (%add k 1)) #\])
                                    (pair (Str8 append (Str8 downcase name) "." (Str8 join "" (List reverse acc))) (%add k 2))
                                    ()))
                       ((= c #\\) (self (%add k 2) (pair (Str8 sub (%add k 1) 1 s) acc)))
                       (#t (self (%add k 1) (pair (Str8 sub k 1 s) acc))))))
                 (%add j 1) ()))))
          (#t ()))))
    ; a value from i, just past its =: (TEXT . NEXT), or ()
    (def value
      (fn (self i quote space acc any)
        (def c (ch i))
        (def text (fn (_) (Str8 join "" (List reverse acc))))
        (match
          ((= c #\newline) (if quote () (pair (text) (if (%lt i n) (%add i 1) n))))
          ((and (not quote) (%blank? c)) (self (%add i 1) quote (if any (%add space 1) space) acc any))
          ((and (not quote) (or (= c #\;) (= c #\#))) (pair (text) (eol i)))
          (#t
            (let ((acc2 (if (= space 0) acc (pair (Str8 repeat space " ") acc))))
              (match
                ((= c #\\)
                  (let ((d (ch (%add i 1))))
                    (match
                      ((= d #\newline) (self (%add i 2) quote 0 acc2 any))
                      ((= d #\t) (self (%add i 2) quote 0 (pair "\t" acc2) #t))
                      ((= d #\n) (self (%add i 2) quote 0 (pair "\n" acc2) #t))
                      ((= d #\b) (self (%add i 2) quote 0 (pair (Str8 str (%int->char 8)) acc2) #t))
                      ((or (= d #\") (= d #\\)) (self (%add i 2) quote 0 (pair (Str8 sub (%add i 1) 1 s) acc2) #t))
                      (#t ()))))
                ((= c #\") (self (%add i 1) (not quote) 0 acc2 any))
                (#t (self (%add i 1) quote 0 (pair (Str8 sub i 1 s) acc2) #t))))))))
    ((fn (self i start section acc)
       (if (not (%lt i n)) (List reverse acc)
         (let ((c (Str8 ref i s)))
           (match
             ((= c #\newline) (self (%add i 1) (%add i 1) section acc))
             ((%blank? c) (self (%add i 1) start section acc))
             ((or (= c #\#) (= c #\;)) (let ((e (eol i))) (self e e section acc)))
             ((= c #\[)
               (let ((h (header (%add i 1))))
                 (if (null? h) (list (list (lit bad) (line-of i)))
                   ; a header ends its line, a comment aside; a name may follow it on the line
                   (let ((j (skip (rest h))))
                     (if (or (= (ch j) #\newline) (= (ch j) #\#) (= (ch j) #\;))
                       (let ((e (eol j))) (self e e (first h) (pair (list (lit sec) (first h) start e) acc)))
                       (self j start (first h) (pair (list (lit sec) (first h) start (rest h)) acc)))))))
             ((and (%alpha? c) (not (null? section)))
               (let ((k (word-end i #f)))
                 (let ((name (Str8 append section "." (Str8 downcase (Str8 sub i (%sub k i) s)))) (j (skip k)))
                   (match
                     ((= (ch j) #\=)
                       (let ((v (value (%add j 1) #f 0 () #f)))
                         (if (null? v) (list (list (lit bad) (line-of i)))
                           (self (rest v) (rest v) section (pair (list (lit key) name (first v) start (rest v) section) acc)))))
                     ((or (= (ch j) #\newline) (= (ch j) #\#) (= (ch j) #\;))
                       (let ((e (eol j))) (self e e section (pair (list (lit key) name () start e section) acc))))
                     (#t (list (list (lit bad) (line-of i))))))))
             (#t (list (list (lit bad) (line-of i))))))))
     0 0 () ())))

(def %bad? (fn (_ items) (and (not (null? items)) (eq? (first (first items)) (lit bad)))))

; --- names ---

; A name as given, checked as git checks one: (ok FULL SECTION SUB KEY),
; FULL its form for matching -- section and key in lower case, the
; subsection as it is -- SUB () when there is none; or (no-section) or
; (no-variable) or (invalid).
(def %name
  (fn (_ s)
    (def n (Str8 length s))
    (def last (Str8 last-index-of "." s))
    (def first-dot (Str8 index-of "." s))
    (def all?
      (fn (_ t) ((fn (self i) (if (%lt i (Str8 length t)) (if (%key-char? (Str8 ref i t)) (self (%add i 1)) #f) #t)) 0)))
    (match
      ((null? last) (list (lit no-section)))
      ((= first-dot 0) (list (lit no-section)))
      ((= last (%sub n 1)) (list (lit no-variable)))
      (#t
        (let ((section (Str8 sub 0 first-dot s))
              (key (Str8 sub (%add last 1) (%sub n (%add last 1)) s))
              (sub (if (= first-dot last) () (Str8 sub (%add first-dot 1) (%sub last (%add first-dot 1)) s))))
          (if (or (not (all? section)) (not (all? key)) (not (%alpha? (Str8 ref 0 key)))
                  (and (not (null? sub)) (not (null? (Str8 index-of "\n" sub)))))
            (list (lit invalid))
            (list (lit ok)
                  (Str8 append (Str8 downcase section) (if (null? sub) "" (Str8 append "." sub)) "." (Str8 downcase key))
                  section sub key)))))))

; A full name's section part, the name's last part dropped.
(def %section-of
  (fn (_ full) (Str8 sub 0 (Str8 last-index-of "." full) full)))

; --- where it is read from ---

(def %env (fn (_ name) (let ((v (Sys getenv name))) (if (or (null? v) (= (Str8 length v) 0)) () v))))

(def %true-word?
  (fn (_ v) (List any? (fn (_ w) (Str8 ci=? v w)) (list "true" "yes" "on" "1"))))

; The user's files, in the order they are read: the XDG one, then
; ~/.gitconfig; GIT_CONFIG_GLOBAL alone when it is set.
(def %global-paths
  (fn (_)
    (def home (%env "HOME"))
    (def xdg (%env "XDG_CONFIG_HOME"))
    (match
      ((not (null? (%env "GIT_CONFIG_GLOBAL"))) (list (%env "GIT_CONFIG_GLOBAL")))
      ((null? home) (if (null? xdg) () (list (Str8 append xdg "/git/config"))))
      (#t (list (if (null? xdg) (Str8 append home "/.config/git/config") (Str8 append xdg "/git/config"))
                (Str8 append home "/.gitconfig"))))))

; The file --global writes: ~/.gitconfig, unless only the XDG one exists.
(def %global-file
  (fn (_)
    (def paths (%global-paths))
    (match
      ((null? paths) ())
      ((null? (rest paths)) (first paths))
      ((and (not (File exists? (first (rest paths)))) (File exists? (first paths))) (first paths))
      (#t (first (rest paths))))))

(def %system-file (fn (_) (or (%env "GIT_CONFIG_SYSTEM") "/etc/gitconfig")))

; GIT_CONFIG_PARAMETERS's pairs: 'name=value' each, or 'name'='value',
; quoted as the shell quotes; (NAME . VALUE) each, VALUE () for a name
; alone.
(def %parameters
  (fn (_ s)
    (def n (Str8 length s))
    ; a quoted word from i: (TEXT . NEXT), a '\'' inside it a quote
    (def word
      (fn (self i acc)
        (match
          ((not (%lt i n)) (pair (Str8 join "" (List reverse acc)) i))
          ((= (Str8 ref i s) #\')
            ((fn (inner k acc2)
               (match
                 ((not (%lt k n)) (pair (Str8 join "" (List reverse acc2)) k))
                 ((= (Str8 ref k s) #\') (self (%add k 1) acc2))
                 (#t (inner (%add k 1) (pair (Str8 sub k 1 s) acc2)))))
             (%add i 1) acc))
          ((= (Str8 ref i s) #\\) (self (%add i 2) (pair (Str8 sub (%add i 1) 1 s) acc)))
          (#t (pair (Str8 join "" (List reverse acc)) i)))))
    ((fn (self i acc)
       (match
         ((not (%lt i n)) (List reverse acc))
         ((%blank? (Str8 ref i s)) (self (%add i 1) acc))
         (#t
           (let ((w (word i ())))
             (if (and (%lt (rest w) n) (= (Str8 ref (rest w) s) #\=))
               (let ((v (word (%add (rest w) 1) ()))) (self (rest v) (pair (pair (first w) (first v)) acc)))
               (let ((eq (Str8 index-of "=" (first w))))
                 (self (rest w)
                       (pair (if (null? eq) (pair (first w) ())
                               (pair (Str8 sub 0 eq (first w)) (Str8 sub (%add eq 1) (%sub (Str8 length (first w)) (%add eq 1)) (first w))))
                             acc))))))))
     0 ())))

; The command line's settings, as items.
(def %command-items
  (fn (_)
    (def count (%env "GIT_CONFIG_COUNT"))
    (def counted
      (if (null? count) ()
        (List map (fn (_ k) (pair (Sys getenv (Str8 append "GIT_CONFIG_KEY_" (Str8 str k)))
                                  (Sys getenv (Str8 append "GIT_CONFIG_VALUE_" (Str8 str k)))))
          (List range 0 (%str->number count 10)))))
    (def given (if (null? (%env "GIT_CONFIG_PARAMETERS")) () (%parameters (%env "GIT_CONFIG_PARAMETERS"))))
    (List flat-map
      (fn (_ p)
        (def nm (if (null? (first p)) (list (lit invalid)) (%name (first p))))
        (if (eq? (first nm) (lit ok)) (list (list (lit key) (first (rest nm)) (rest p) 0 0 (%section-of (first (rest nm))))) ()))
      (List append counted given))))

; Where configuration is read from, in order: (SCOPE ORIGIN PATH) each,
; ORIGIN as --show-origin names it, PATH () for the command line.
(def %sources
  (fn (_ wd gitdir)
    (List append
      (if (null? (%env "GIT_CONFIG_NOSYSTEM")) (list (list "system" (Str8 append "file:" (%system-file)) (%system-file))) ())
      (List append
        (List map (fn (_ p) (list "global" (Str8 append "file:" p) p)) (%global-paths))
        (List append
          (if (null? gitdir) ()
            (let ((p (Str8 append gitdir "/config")))
              (list (list "local" (Str8 append "file:" (if (str=? gitdir (Str8 append wd "/.git")) ".git/config" p)) p))))
          (list (list "command" "command line:" ())))))))

; A source's items, () for a file that is not there; a refusal raised
; for one git would refuse.
(def %items
  (fn (_ source)
    (def path (first (rest (rest source))))
    (if (null? path) (%command-items)
      (if (not (File exists? path)) ()
        (let ((items (%parse (File read-all path))))
          (if (%bad? items)
            (Err raise (lit value) (Str8 append "fatal: bad config line " (Str8 str (first (rest (first items)))) " in file " path "\n") ())
            items))))))

; Every setting the sources hold, in order: (NAME VALUE SCOPE ORIGIN).
(def %settings
  (fn (_ sources)
    (List flat-map
      (fn (_ src)
        (List flat-map
          (fn (_ it) (if (eq? (first it) (lit key)) (list (list (first (rest it)) (first (rest (rest it))) (first src) (first (rest src)))) ()))
          (%items src)))
      sources)))

; --- for the other commands ---

; A name's value, the last one set, or () when none is; a name given
; alone reads "true".  name is a full name: "user.name",
; "remote.origin.url".
(def git-config-value
  (fn (_ gitdir name)
    (def nm (%name name))
    (def hits (List filter (fn (_ s) (str=? (first s) (first (rest nm)))) (%settings (%sources "" gitdir))))
    (if (null? hits) () (let ((v (first (rest (List last hits))))) (if (null? v) "true" v)))))

; --- values ---

; A value as a boolean, as git reads one: (ok . BOOL), or (bad).
(def %bool
  (fn (_ v)
    (match
      ((null? v) (pair (lit ok) #t))
      ((= (Str8 length v) 0) (pair (lit ok) #f))
      ((%true-word? v) (pair (lit ok) #t))
      ((List any? (fn (_ w) (Str8 ci=? v w)) (list "false" "no" "off" "0")) (pair (lit ok) #f))
      (#t (let ((i (%int v))) (if (eq? (first i) (lit ok)) (pair (lit ok) (not (= (rest i) 0))) (list (lit bad))))))))

; A value as an integer, a k, m or g after it a power of 1024: (ok . N),
; or (bad . WHY).
(def %int
  (fn (_ v)
    (def n (if (null? v) 0 (Str8 length v)))
    (def last (if (= n 0) #\0 (Str8 ref (%sub n 1) v)))
    (def scale
      (match ((or (= last #\k) (= last #\K)) 1024) ((or (= last #\m) (= last #\M)) 1048576)
             ((or (= last #\g) (= last #\G)) 1073741824) (#t 1)))
    (def digits (if (= scale 1) (or v "") (Str8 sub 0 (%sub n 1) v)))
    (def ok?
      ((fn (self i) (if (%lt i (Str8 length digits))
                      (if (or (%in? (Str8 ref i digits) #\0 #\9) (and (= i 0) (= (Str8 ref i digits) #\-))) (self (%add i 1)) #f)
                      (%lt 0 (Str8 length digits))))
       0))
    (if ok? (pair (lit ok) (* scale (%str->number digits 10))) (pair (lit bad) "invalid unit"))))

; Where a setting came from, as a refusal of its value names it.
(def %where
  (fn (_ origin)
    (if (Str8 starts? "file:" origin) (Str8 append " in file " (Str8 sub 5 (%sub (Str8 length origin) 5) origin)) " in command line")))

; A value shown as --type asks: (ok . TEXT) or (err . TEXT); where is
; what %where says of it, or "".
(def %typed
  (fn (_ type name v where)
    (match
      ((null? type) (pair (lit ok) (or v "")))
      ((str=? type "bool")
        (let ((b (%bool v)))
          (if (eq? (first b) (lit ok)) (pair (lit ok) (if (rest b) "true" "false"))
            (pair (lit err) (Str8 append "fatal: bad boolean config value '" v "' for '" name "'\n")))))
      ((str=? type "int")
        (let ((i (%int v)))
          (if (eq? (first i) (lit ok)) (pair (lit ok) (Str8 str (rest i)))
            (pair (lit err) (Str8 append "fatal: bad numeric config value '" (or v "") "' for '" name "'" where ": " (rest i) "\n")))))
      (#t (pair (lit ok) (or v ""))))))

; --- writing a file ---

; A value as git writes it: quoted when a blank starts or ends it or it
; holds ; or #; a newline, a tab, a quote and a backslash escaped.
(def %quote-value
  (fn (_ v)
    (def n (Str8 length v))
    (def quote?
      (or (and (%lt 0 n) (or (= (Str8 ref 0 v) #\space) (= (Str8 ref (%sub n 1) v) #\space)))
          (not (null? (Str8 index-of ";" v))) (not (null? (Str8 index-of "#" v))) (not (null? (Str8 index-of "\r" v)))))
    (def body
      (Str8 join ""
        (List map
          (fn (_ i)
            (def c (Str8 ref i v))
            (match ((= c #\newline) "\\n") ((= c #\tab) "\\t") ((= c #\") "\\\"") ((= c #\\) "\\\\") (#t (Str8 sub i 1 v))))
          (List range 0 n))))
    (if quote? (Str8 append "\"" body "\"") body)))

(def %line (fn (_ key v) (Str8 append "\t" key " = " (%quote-value v) "\n")))

(def %header
  (fn (_ section sub)
    (if (null? sub) (Str8 append "[" section "]\n")
      (Str8 append "[" section " \""
        (Str8 join "" (List map (fn (_ i) (let ((c (Str8 ref i sub))) (if (or (= c #\") (= c #\\)) (Str8 append "\\" (Str8 sub i 1 sub)) (Str8 sub i 1 sub))))
                        (List range 0 (Str8 length sub))))
        "\"]\n"))))

; text with the spans (START . END) cut out and (AT . TEXT) put in; what
; is put at a cut's start goes before it.
(def %edit
  (fn (_ text cuts puts)
    (def marks
      (List sort (fn (_ a b) (or (%lt (first a) (first b)) (and (= (first a) (first b)) (%lt (first (rest a)) (first (rest b))))))
        (List append (List map (fn (_ c) (list (first c) (rest c) "")) cuts)
          (List map (fn (_ p) (list (first p) (first p) (rest p))) puts))))
    ((fn (self ms i acc)
       (if (null? ms)
         (Str8 join "" (List reverse (pair (Str8 sub i (%sub (Str8 length text) i) text) acc)))
         (let ((m (first ms)))
           (self (rest ms) (first (rest m))
                 (pair (first (rest (rest m))) (pair (Str8 sub i (%sub (first m) i) text) acc))))))
     marks 0 ())))

; Headers whose blocks hold no names once cuts are made, and nothing but
; blanks: their spans, to be cut too.
(def %emptied
  (fn (_ text items cuts)
    (def cut? (fn (_ it) (List any? (fn (_ c) (= (first c) (first (rest (rest (rest it)))))) cuts)))
    ((fn (self its acc)
       (if (null? its) acc
         (let ((it (first its)))
           (if (not (eq? (first it) (lit sec))) (self (rest its) acc)
             (let ((body ((fn (take l b) (if (or (null? l) (eq? (first (first l)) (lit sec))) (List reverse b) (take (rest l) (pair (first l) b)))) (rest its) ())))
               (let ((end (if (null? (rest its)) (Str8 length text)
                            (let ((nx (List find (fn (_ x) (eq? (first x) (lit sec))) (rest its))))
                              (if (null? nx) (Str8 length text) (first (rest (rest nx))))))))
                 (if (and (not (null? (List filter (fn (_ b) (cut? b)) body)))
                          (List all? cut? body)
                          (= (Str8 length (Str8 trim (%edit (Str8 sub (first (rest (rest (rest it)))) (%sub end (first (rest (rest (rest it))))) text)
                                                       (List map (fn (_ b) (pair (%sub (first (rest (rest (rest b)))) (first (rest (rest (rest it)))))
                                                                                 (%sub (first (rest (rest (rest (rest b))))) (first (rest (rest (rest it)))))))
                                                         body)
                                                       ())))
                             0))
                   (self (rest its) (pair (pair (first (rest (rest it))) (first (rest (rest (rest it))))) acc))
                   (self (rest its) acc))))))))
     items ())))

; The file at path changed, written as git writes a config, through
; PATH.lock renamed into place.
(def %write!
  (fn (_ path text)
    (def lock (Str8 append path ".lock"))
    (File write-all lock text)
    (File rename lock path)))

; A change to the file at path: (ok) or (err TEXT STATUS).  op is one of
;   (set NAME-PARTS VALUE ALL? ADD?)  NAME-PARTS as %name answers them
;   (unset NAME-PARTS ALL? MULTIPLE-TEXT)
;   (remove-section SECTION-NAME)
(def %change!
  (fn (_ path op)
    (def text (if (File exists? path) (File read-all path) ""))
    (def items (%parse text))
    (if (%bad? items)
      (list (lit err) (Str8 append "fatal: bad config line " (Str8 str (first (rest (first items)))) " in file " path "\n") 128)
      (let ((kind (first op)))
        (match
          ((eq? kind (lit set))
            (let ((nm (first (rest op))) (v (first (rest (rest op)))) (all? (first (rest (rest (rest op))))) (add? (first (rest (rest (rest (rest op)))))))
              (let ((full (first (rest nm))) (key (first (rest (rest (rest (rest nm)))))))
                (let ((hits (List filter (fn (_ it) (and (eq? (first it) (lit key)) (str=? (first (rest it)) full))) items))
                      (span (fn (_ it) (pair (first (rest (rest (rest it)))) (first (rest (rest (rest (rest it)))))))))
                  (match
                    ((and (not add?) (not all?) (%lt 1 (List length hits)))
                      (list (lit err) (first (rest (rest (rest (rest (rest op)))))) 5))
                    ((and (not add?) (not (null? hits)))
                      ; the first one's line replaced, any others cut
                      (do (%write! path (%edit text (List map span hits) (list (pair (first (span (first hits))) (%line key v)))))
                          (list (lit ok))))
                    (#t
                      (let ((section (%section-of full)))
                        (let ((block-ends
                                (List flat-map
                                  (fn (_ it)
                                    (match
                                      ((and (eq? (first it) (lit sec)) (str=? (first (rest it)) section)) (list (first (rest (rest (rest it))))))
                                      ((and (eq? (first it) (lit key)) (str=? (first (rest (rest (rest (rest (rest it)))))) section)) (list (first (rest (rest (rest (rest it)))))))
                                      (#t ())))
                                  items)))
                          (do (%write! path
                                (if (null? block-ends)
                                  (Str8 append text (if (or (= (Str8 length text) 0) (Str8 ends? "\n" text)) "" "\n")
                                    (%header (first (rest (rest nm))) (first (rest (rest (rest nm))))) (%line key v))
                                  (%edit text () (list (pair (List last block-ends) (%line key v))))))
                              (list (lit ok)))))))))))
          ((eq? kind (lit unset))
            (let ((nm (first (rest op))) (all? (first (rest (rest op)))))
              (let ((hits (List filter (fn (_ it) (and (eq? (first it) (lit key)) (str=? (first (rest it)) (first (rest nm))))) items)))
                (match
                  ((null? hits) (list (lit err) "" 5))
                  ((and (not all?) (%lt 1 (List length hits))) (list (lit err) (first (rest (rest (rest op)))) 5))
                  (#t
                    (let ((cuts (List map (fn (_ it) (pair (first (rest (rest (rest it)))) (first (rest (rest (rest (rest it))))))) hits)))
                      (do (%write! path (%edit text (List append cuts (%emptied text items cuts)) ()))
                          (list (lit ok)))))))))
          (#t
            (let ((section (first (rest op))))
              (let ((secs (List filter (fn (_ it) (and (eq? (first it) (lit sec)) (str=? (first (rest it)) section))) items)))
                (if (null? secs) (list (lit err) (Str8 append "fatal: no such section: " section "\n") 128)
                  (let ((cuts (List flat-map
                                (fn (_ it)
                                  (match
                                    ((and (eq? (first it) (lit sec)) (str=? (first (rest it)) section))
                                      (list (pair (first (rest (rest it))) (first (rest (rest (rest it)))))))
                                    ((and (eq? (first it) (lit key)) (str=? (first (rest (rest (rest (rest (rest it)))))) section))
                                      (list (pair (first (rest (rest (rest it)))) (first (rest (rest (rest (rest it))))))))
                                    (#t ())))
                                items)))
                    (do (%write! path (%edit text cuts ())) (list (lit ok)))))))))))))

; --- git config ---

(def git-config-options
  (Opts declare "git config" "[<file-option>] [<type>] [--show-origin] [--show-scope] <name> [<value>] | <command> ..." ()
    (list
      (Opts flag "--global" "The user's file")
      (Opts flag "--system" "The system's file")
      (Opts flag "--local" "The repository's file")
      (Opts arg "-f" "--file" "<file>" "The file named")
      (Opts flag "--get" "A name's value")
      (Opts flag "--get-all" "Every value of a name")
      (Opts flag "--add" "Another value for a name")
      (Opts flag "--replace-all" "Every value of a name made one")
      (Opts flag "--unset" "A name taken out")
      (Opts flag "--unset-all" "Every value of a name taken out")
      (Opts flag "-l" "--list" "Every setting")
      (Opts flag "--remove-section" "A section taken out")
      (Opts flag "--bool" "Values read as true or false")
      (Opts flag "--int" "Values read as integers")
      (Opts arg "--type" "<type>" "bool or int")
      (Opts flag "--show-origin" "Where each setting is from")
      (Opts flag "--show-scope" "Each setting's scope")
      (Opts flag "--name-only" "Names alone")
      (Opts flag "--all" "Every value (get, set, unset)")
      (Opts flag "--append" "Another value (set)"))))

(def %subcommands (list "get" "set" "unset" "list" "remove-section"))

(def %name-refusal
  (fn (_ nm given setting?)
    (match
      ((eq? (first nm) (lit no-section))
        (list (lit err) (Str8 append "error: key does not contain a section: " given "\n") (if setting? 2 1)))
      ((eq? (first nm) (lit no-variable))
        (list (lit err) (Str8 append "error: key does not contain variable name: " given "\n") 2))
      (#t (list (lit err) (Str8 append "error: invalid key: " given "\n") 1)))))

(def git-config
  (fn (_ wd gitdir ops)
    (def o (Opts parse git-config-options ops))
    (def args (Opts operands o))
    (def sub (if (and (not (null? args)) (List any? (fn (_ s) (str=? s (first args))) %subcommands)) (first args) ()))
    (def operands (if (null? sub) args (rest args)))
    (def on? (fn (_ f) (Opts on? o f)))
    (def type (match ((on? "--bool") "bool") ((on? "--int") "int") (#t (Opts value o "--type" ()))))
    (def file (let ((f (Opts value o "-f" ()))) (if (or (null? f) (Str8 starts? "/" f)) f (Str8 append wd "/" f))))
    (def action
      (match
        ((not (null? sub)) (if (str=? sub "list") (lit list) (Str8 ->sym sub)))
        ((on? "-l") (lit list))
        ((on? "--remove-section") (lit remove-section))
        ((or (on? "--unset") (on? "--unset-all")) (lit unset))
        ((or (on? "--get") (on? "--get-all")) (lit get))
        ((on? "--add") (lit set))
        ((= (List length operands) 1) (lit get))
        ((%lt 1 (List length operands)) (lit set))
        (#t ())))
    ; what is read: every source, or the one the options name
    (def scoped
      (match
        ((not (null? file)) (list (list "file" (Str8 append "file:" (Opts value o "-f" ())) file)))
        ((on? "--global") (List map (fn (_ p) (list "global" (Str8 append "file:" p) p)) (%global-paths)))
        ((on? "--system") (list (list "system" (Str8 append "file:" (%system-file)) (%system-file))))
        ((on? "--local") (if (null? gitdir) () (list (list "local" (Str8 append "file:" (if (str=? gitdir (Str8 append wd "/.git")) ".git/config" (Str8 append gitdir "/config"))) (Str8 append gitdir "/config")))))
        (#t ())))
    (def explicit? (or (not (null? file)) (on? "--global") (on? "--system") (on? "--local")))
    ; what is written: the one file the options name, the repository's by default
    (def target
      (match
        ((not (null? file)) file)
        ((on? "--global") (%global-file))
        ((on? "--system") (%system-file))
        ((null? gitdir) ())
        (#t (Str8 append gitdir "/config"))))
    (def shown
      (fn (_ s text)
        (Str8 append (if (on? "--show-scope") (Str8 append (first (rest (rest s))) "\t") "")
          (if (on? "--show-origin") (Str8 append (first (rest (rest (rest s)))) "\t") "") text "\n")))
    (guard (e (if (Str8 starts? "fatal: " (e msg)) (list (lit err) (e msg) 128) (Err raise (Err label e) (e msg) ())))
      (match
        ((Opts help? git-config-options ops) (list (lit out) (Opts usage git-config-options) 0))
        ((and (on? "--local") (null? gitdir)) (list (lit err) "fatal: --local can only be used inside a git repository\n" 128))
        ((null? action) (list (lit err) (Opts usage git-config-options) 129))
        ; a listing
        ((eq? action (lit list))
          ; a file named and not there is refused; the user's, when none of them is
          (let ((missing (and explicit? (List all? (fn (_ s) (not (File exists? (first (rest (rest s)))))) scoped))))
            (if missing
              (list (lit err) (Str8 append "fatal: unable to read config file '" (if (on? "--global") (%global-file) (first (rest (rest (first scoped)))))
                                "': No such file or directory\n") 128)
              (list (lit out)
                (Str8 join ""
                  (List map
                    (fn (_ s)
                      (shown s (if (or (on? "--name-only") (null? (first (rest s)))) (first s) (Str8 append (first s) "=" (first (rest s))))))
                    (%settings (if explicit? scoped (%sources wd gitdir)))))
                0))))
        ; a name's value, or every one
        ((eq? action (lit get))
          (if (not (= (List length operands) 1))
            (list (lit err) "error: wrong number of arguments, should be 1\n" 129)
            (let ((nm (%name (first operands))))
              (if (not (eq? (first nm) (lit ok))) (%name-refusal nm (first operands) #f)
                (let ((hits (List filter (fn (_ s) (str=? (first s) (first (rest nm)))) (%settings (if explicit? scoped (%sources wd gitdir))))))
                  (if (null? hits) (list (lit out) "" 1)
                    (let ((typed (List map (fn (_ s) (pair s (%typed type (first operands) (first (rest s)) (%where (first (rest (rest (rest s))))))))
                                   (if (or (on? "--get-all") (on? "--all")) hits (list (List last hits))))))
                      (let ((bad (List find (fn (_ t) (eq? (first (rest t)) (lit err))) typed)))
                        (if (not (null? bad)) (list (lit err) (rest (rest bad)) 128)
                          (list (lit out) (Str8 join "" (List map (fn (_ t) (shown (first t) (rest (rest t)))) typed)) 0))))))))))
        ; a value set
        ((eq? action (lit set))
          (match
            ((not (= (List length operands) 2)) (list (lit err) "error: wrong number of arguments, should be 2\n" 129))
            ((null? target) (list (lit err) "fatal: not in a git directory\n" 128))
            (#t
              (let ((nm (%name (first operands))))
                (if (not (eq? (first nm) (lit ok))) (%name-refusal nm (first operands) #t)
                  (let ((v (%typed type (first operands) (first (rest operands)) "")))
                    (if (eq? (first v) (lit err)) (list (lit err) (rest v) 128)
                      (let ((r (%change! target
                                 (list (lit set) nm (rest v) (or (on? "--replace-all") (on? "--all")) (or (on? "--add") (on? "--append"))
                                       (Str8 append "warning: " (first operands) " has multiple values\n"
                                         "error: cannot overwrite multiple values with a single value\n       "
                                         (if (null? sub) "Use a regexp, --add or --replace-all" "Use --value=<pattern>, --append or --all")
                                         " to change " (first operands) ".\n")))))
                        (if (eq? (first r) (lit ok)) (list (lit out) "" 0) r)))))))))
        ; a name taken out
        ((eq? action (lit unset))
          (match
            ((not (= (List length operands) 1)) (list (lit err) "error: wrong number of arguments, should be 1\n" 129))
            ((null? target) (list (lit err) "fatal: not in a git directory\n" 128))
            (#t
              (let ((nm (%name (first operands))))
                (if (not (eq? (first nm) (lit ok))) (%name-refusal nm (first operands) #t)
                  (let ((r (%change! target (list (lit unset) nm (or (on? "--unset-all") (on? "--all"))
                                                  (Str8 append "warning: " (first operands) " has multiple values\n")))))
                    (if (eq? (first r) (lit ok)) (list (lit out) "" 0) r)))))))
        ; a section taken out
        (#t
          (match
            ((not (= (List length operands) 1)) (list (lit err) "error: wrong number of arguments, should be 1\n" 129))
            ((null? target) (list (lit err) "fatal: not in a git directory\n" 128))
            (#t
              (let ((given (first operands)))
                (let ((dot (Str8 index-of "." given)))
                  (let ((section (if (null? dot) (Str8 downcase given)
                                   (Str8 append (Str8 downcase (Str8 sub 0 dot given)) (Str8 sub dot (%sub (Str8 length given) dot) given)))))
                    (let ((r (%change! target (list (lit remove-section) section))))
                      (if (eq? (first r) (lit ok)) (list (lit out) "" 0)
                        (list (lit err) (Str8 append "fatal: no such section: " given "\n") 128)))))))))))))

; The command line's -c settings, as git passes them on to what it runs:
; GIT_CONFIG_PARAMETERS, each 'name=value' quoted for the shell.
(def git-config-parameters
  (fn (_ settings)
    (Str8 join " "
      (List map (fn (_ s) (Str8 append "'" (Str8 replace "'" "'\\''" s) "'")) settings))))

(provide git/config git-config-value git-config git-config-options git-config-parameters)

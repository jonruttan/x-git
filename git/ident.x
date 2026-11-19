; # x-git -- git on x-lang
;
; ## git/ident.x -- who and when
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A role's identity as git finds it, for commits and the reflog:
; (git-signature gitdir role), role "AUTHOR" or "COMMITTER", answers
; `NAME <EMAIL> EPOCH +HHMM` for a commit, or () when git would refuse it;
; (git-signature-loose gitdir role) the same for the reflog, which takes
; any guess.  git-ident-refusal and git-ident-note say what git says.

(module git/ident)

(import x/sys/posix Sys)
(import x/sys/date Date)
(import x/sys/file File)
(import git/config git-config-value git-config-reader)

(import x/core/doors int+ int- int* int/ int%)

; The clock's time as a commit records it: `EPOCH +HHMM`.
(def %timestamp
  (fn (_)
    (def now (Sys now))
    (def off (Assoc get (lit offset) (Date local now)))
    (def a (if (< off 0) (int- 0 off) off))
    (Str8 append (Str8 str now) " " (if (< off 0) "-" "+")
      (Str8 pad-left 2 #\0 (Str8 str (int/ a 3600)))
      (Str8 pad-left 2 #\0 (Str8 str (int/ (int% a 3600) 60))))))



; Days since 1970-01-01 of a civil date (Howard Hinnant's days_from_civil).
(def %floor-div (fn (_ a b) (if (>= a 0) (int/ a b) (int- 0 (int/ (int- (int- b 1) a) b)))))
(def %days-from-civil
  (fn (_ y m d)
    (def y2 (if (<= m 2) (int- y 1) y))
    (def era (%floor-div y2 400))
    (def yoe (int- y2 (int* era 400)))
    (def doy (int+ (int/ (int+ (int* 153 (if (> m 2) (int- m 3) (int+ m 9))) 2) 5) (int- d 1)))
    (def doe (int+ (int- (int+ (int* yoe 365) (int/ yoe 4)) (int/ yoe 100)) doy))
    (int- (int+ (int* era 146097) doe) 719468)))

(def %digits (fn (_ s start n) (%str->number (Str8 sub start n s) 10)))

; A date as git takes one from GIT_AUTHOR_DATE or GIT_COMMITTER_DATE, as
; a commit records it, `EPOCH +HHMM`: the raw form `EPOCH +HHMM` (or
; `@EPOCH`), or ISO 8601, `YYYY-MM-DDTHH:MM:SS` then Z, +HH:MM or +HHMM.
; () for a form not read here.
(def %parse-date
  (fn (_ s)
    (def t (Str8 trim s))
    (def raw (if (Str8 starts? "@" t) (Str8 sub 1 (int- (Str8 length t) 1) t) t))
    (def parts (Str8 split " " raw))
    (match
      ((and (>= (Str8 length t) 19) (str=? (Str8 sub 4 1 t) "-") (str=? (Str8 sub 10 1 t) "T"))
        (let ((zone (Str8 sub 19 (int- (Str8 length t) 19) t)))
          (let ((sign (if (Str8 starts? "-" zone) -1 1))
                (zdigits (Str8 join "" (Str8 split ":" (if (or (= (Str8 length zone) 0) (str=? zone "Z")) "+0000" zone)))))
            (let ((zh (%digits zdigits 1 2)) (zm (%digits zdigits 3 2)))
              (let ((offset (int* sign (int+ (int* zh 3600) (int* zm 60))))
                    (local (int+ (int* (%days-from-civil (%digits t 0 4) (%digits t 5 2) (%digits t 8 2)) 86400)
                                 (int+ (int* (%digits t 11 2) 3600) (int+ (int* (%digits t 14 2) 60) (%digits t 17 2))))))
                (Str8 append (Str8 str (int- local offset)) " " (if (< sign 0) "-" "+")
                  (Str8 pad-left 2 #\0 (Str8 str zh)) (Str8 pad-left 2 #\0 (Str8 str zm))))))))
      ((and (not (null? parts)) (> (Str8 length (first parts)) 0)
            (List all? (fn (_ i) (let ((c (Str8 sub i 1 (first parts)))) (and (Str8 >=? c "0") (Str8 <=? c "9"))))
              (List range 0 (Str8 length (first parts)))))
        (Str8 append (first parts) " " (if (null? (rest parts)) "+0000" (first (rest parts)))))
      (#t ()))))

(def %env (fn (_ name) (let ((v (Sys getenv name))) (if (or (null? v) (= (Str8 length v) 0)) () v))))

; The real user's password entry, or () when there is none.
(def %passwd (fn (_) (Sys getpwuid (Sys getuid))))

; A name from a gecos field as git takes it: up to its first comma, each
; `&` the login name with its first letter in capitals.
(def %gecos-name
  (fn (_ gecos login)
    (def i (Str8 index-of "," gecos))
    (def upto (if (null? i) gecos (Str8 sub 0 i gecos)))
    (def cap (if (= (Str8 length login) 0) ""
               (Str8 append (Str8 upcase (Str8 sub 0 1 login)) (Str8 sub 1 (int- (Str8 length login) 1) login))))
    (Str8 join cap (Str8 split "&" upto))))

; git's guess at a name, (NAME . BOGUS?): the gecos name, or "Unknown",
; bogus, when the user has no password entry.
(def %find-name
  (fn (_)
    (def pw (%passwd))
    (if (null? pw) (pair "Unknown" #t)
      (pair (Str8 trim (%gecos-name (or (Assoc get (lit gecos) pw) "") (or (Assoc get (lit name) pw) ""))) #f))))

; The login name, "unknown" when the user has no password entry.
(def %login
  (fn (_) (let ((pw (%passwd))) (if (null? pw) "unknown" (or (Assoc get (lit name) pw) "")))))

; x-lang's Socket, loaded the first time a host's canonical name is
; looked up and not before: loaded with this module, it leaves the state
; image words it cannot name on Linux, and the image is not kept.
(def %Socket ())
(def %load-socket!
  (fn (_)
    (when (null? %Socket)
      (do (import x/sys/socket Socket)
          (set! %Socket Socket)))))

; git's guess at an email, (EMAIL . BOGUS?): login@host, the host the
; host name when it has a dot, else its canonical name when that has
; one; else login@host.(none), bogus.
(def %find-email
  (fn (_)
    (def login (%login))
    (def host (guard (e ()) (Sys gethostname)))
    (def canon (fn (_) (guard (e ()) (do (%load-socket!) (%Socket canonical-name host)))))
    (match
      ((null? host) (pair (Str8 append login "@(none)") #t))
      ((Str8 includes? "." host) (pair (Str8 append login "@" host) #f))
      (#t (let ((c (canon)))
            (if (and (not (null? c)) (Str8 includes? "." c)) (pair (Str8 append login "@" c) #f)
              (pair (Str8 append login "@" host ".(none)") #t)))))))

; The guesses made once a process, as git makes them: the host's
; canonical name is a resolver's lookup, slow where the host is unknown
; to it, and every reflog line with no email given takes the guess.
(def %name-guessed ())
(def %email-guessed ())
(def %guess-name
  (fn (_)
    (when (null? %name-guessed) (set! %name-guessed (%find-name)))
    %name-guessed))
(def %guess-email
  (fn (_)
    (when (null? %email-guessed) (set! %email-guessed (%find-email)))
    %email-guessed))

(def %full (fn (_ v) (if (or (null? v) (= (Str8 length v) 0)) () v)))

; A role's identity, role AUTHOR or COMMITTER, found as git finds it:
; (NAME NAME-HOW EMAIL EMAIL-HOW WHEN), each HOW given, default, guessed
; or bogus.  The name from GIT_<ROLE>_NAME, even empty, else a
; <role>.name not empty, else git's default: user.name, else "" when any
; of user.name, author.name and committer.name is set at all, else the
; guess.  The email likewise from GIT_<ROLE>_EMAIL, <role>.email and
; user.email, the default's next step EMAIL when not empty.  The time
; from GIT_<ROLE>_DATE, else the clock.
(def %ident
  (fn (_ gitdir role)
    ; the configuration read once, not once a name
    (def read (git-config-reader gitdir))
    (def cfg (fn (_ k) (let ((vs (read k))) (if (null? vs) () (List last vs)))))
    (def lower (Str8 downcase role))
    (def set? (fn (_ part) (List any? (fn (_ who) (not (null? (cfg (Str8 append who "." part))))) (list "user" "author" "committer"))))
    (def how (fn (_ g) (pair (first g) (if (rest g) (lit bogus) (lit guessed)))))
    (def pick
      (fn (_ part guess more)
        (def env (Sys getenv (Str8 append "GIT_" role "_" (Str8 upcase part))))
        (def own (%full (cfg (Str8 append lower "." part))))
        (def user (cfg (Str8 append "user." part)))
        (match
          ((not (null? env)) (pair env (lit given)))
          ((not (null? own)) (pair own (lit given)))
          ((not (null? user)) (pair user (lit default)))
          ((set? part) (pair "" (lit default)))
          ((not (null? more)) (pair more (lit given)))
          (#t (how (guess))))))
    (def n (pick "name" %guess-name ()))
    (def m (pick "email" %guess-email (%env "EMAIL")))
    (def date (let ((d (%env (Str8 append "GIT_" role "_DATE")))) (if (null? d) () (%parse-date d))))
    (list (first n) (rest n) (Str8 trim (first m)) (rest m)
          (if (null? date) (%timestamp) date))))

(def %id-name (fn (_ id) (first id)))
(def %id-name-how (fn (_ id) (first (rest id))))
(def %id-email (fn (_ id) (first (rest (rest id)))))
(def %id-email-how (fn (_ id) (first (rest (rest (rest id))))))
(def %id-when (fn (_ id) (first (rest (rest (rest (rest id)))))))

(def %line (fn (_ name email when) (Str8 append name " <" email "> " when)))

(def %hint
  (Str8 join "\n"
    (list "" "*** Please tell me who you are." "" "Run" ""
          "  git config --global user.email \"you@example.com\""
          "  git config --global user.name \"Your Name\"" ""
          "to set your account's default identity."
          "Omit --global to set the identity only in this repository." "" "")))

; Why git will not put a role's identity in a commit, as it says it
; (the role, the hint, then the fatal line), or () when it will.
(def %refusal
  (fn (_ id role)
    (def head (Str8 append (if (str=? role "AUTHOR") "Author" "Committer") " identity unknown\n" %hint))
    (match
      ((eq? (%id-email-how id) (lit bogus))
        (Str8 append head "fatal: unable to auto-detect email address (got '" (%id-email id) "')\n"))
      ((eq? (%id-name-how id) (lit bogus))
        (Str8 append head "fatal: unable to auto-detect name (got '" (%id-name id) "')\n"))
      ((= (Str8 length (%id-name id)) 0)
        (Str8 append (if (eq? (%id-name-how id) (lit given)) "" head)
          "fatal: empty ident name (for <" (%id-email id) ">) not allowed\n"))
      (#t ()))))

; A role's `NAME <EMAIL> WHEN` for a commit: () when git would refuse it.
(def git-signature
  (fn (_ gitdir role)
    (def id (%ident gitdir role))
    (if (null? (%refusal id role)) (%line (%id-name id) (%id-email id) (%id-when id)) ())))

; A role's `NAME <EMAIL> WHEN` for the reflog, which takes the guesses,
; bogus or not, and the login name for an empty name.
(def git-signature-loose
  (fn (_ gitdir role)
    (def id (%ident gitdir role))
    (%line (if (= (Str8 length (%id-name id)) 0) (%login) (%id-name id)) (%id-email id) (%id-when id))))

; Why git will not make a commit as the identities stand -- the author's
; refusal first, then the committer's -- as its result, or ().
(def git-ident-refusal
  (fn (_ gitdir)
    (def a (%refusal (%ident gitdir "AUTHOR") "AUTHOR"))
    (def c (if (null? a) (%refusal (%ident gitdir "COMMITTER") "COMMITTER") ()))
    (match ((not (null? a)) (list (lit err) a 128)) ((not (null? c)) (list (lit err) c 128)) (#t ()))))

; What git adds to its report of a commit when the committer's email was
; guessed (a guessed name alone it lets pass): ` Committer: NAME <EMAIL>`,
; then its advice unless advice.implicitIdentity is false; the advice's
; wording turns on whether ~/.gitconfig or ~/.config/git/config exists.
; "" when the email was given.
(def git-ident-note
  (fn (_ gitdir)
    (def id (%ident gitdir "COMMITTER"))
    (def home (or (Sys getenv "HOME") ""))
    (def config? (or (File exists? (Str8 append home "/.gitconfig")) (File exists? (Str8 append home "/.config/git/config"))))
    (def v (git-config-value gitdir "advice.implicitidentity"))
    (def off? (and (not (null? v)) (List any? (fn (_ f) (str=? (Str8 downcase v) f)) (list "false" "no" "off" "0"))))
    (if (List any? (fn (_ h) (eq? (%id-email-how id) h)) (list (lit given) (lit default))) ""
      (Str8 append " Committer: " (%id-name id) " <" (%id-email id) ">\n"
        (if off? ""
          (Str8 append
            "Your name and email address were configured automatically based\n"
            "on your username and hostname. Please check that they are accurate.\n"
            (if config?
              (Str8 append
                "You can suppress this message by setting them explicitly:\n\n"
                "    git config --global user.name \"Your Name\"\n"
                "    git config --global user.email you@example.com\n\n")
              (Str8 append
                "You can suppress this message by setting them explicitly. Run the\n"
                "following command and follow the instructions in your editor to edit\n"
                "your configuration file:\n\n"
                "    git config --global --edit\n\n"))
            "After doing this, you may fix the identity used for this commit with:\n\n"
            "    git commit --amend --reset-author\n\n"))))))

(provide git/ident git-signature git-signature-loose git-ident-refusal git-ident-note)

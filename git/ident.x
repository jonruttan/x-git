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
; `NAME <EMAIL> EPOCH +HHMM`, or () when there is no name or no email.

(module git/ident)

(import x/sys/posix Sys)
(import x/sys/date Date)
(import git/config git-config-value)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %mul (prim-ref 'int '*))
(def %int-div (prim-ref (lit int) (lit /)))
(def %int-mod (prim-ref (lit int) (lit %)))

; The clock's time as a commit records it: `EPOCH +HHMM`.
(def %timestamp
  (fn (_)
    (def now (Sys now))
    (def off (Assoc get (lit offset) (Date local now)))
    (def a (if (< off 0) (%sub 0 off) off))
    (Str8 append (Str8 str now) " " (if (< off 0) "-" "+")
      (Str8 pad-left 2 #\0 (Str8 str (%int-div a 3600)))
      (Str8 pad-left 2 #\0 (Str8 str (%int-div (%int-mod a 3600) 60))))))



; Days since 1970-01-01 of a civil date (Howard Hinnant's days_from_civil).
(def %floor-div (fn (_ a b) (if (>= a 0) (%int-div a b) (%sub 0 (%int-div (%sub (%sub b 1) a) b)))))
(def %days-from-civil
  (fn (_ y m d)
    (def y2 (if (<= m 2) (%sub y 1) y))
    (def era (%floor-div y2 400))
    (def yoe (%sub y2 (%mul era 400)))
    (def doy (%add (%int-div (%add (%mul 153 (if (> m 2) (%sub m 3) (%add m 9))) 2) 5) (%sub d 1)))
    (def doe (%add (%sub (%add (%mul yoe 365) (%int-div yoe 4)) (%int-div yoe 100)) doy))
    (%sub (%add (%mul era 146097) doe) 719468)))

(def %digits (fn (_ s start n) (%str->number (Str8 sub start n s) 10)))

; A date as git takes one from GIT_AUTHOR_DATE or GIT_COMMITTER_DATE, as
; a commit records it, `EPOCH +HHMM`: the raw form `EPOCH +HHMM` (or
; `@EPOCH`), or ISO 8601, `YYYY-MM-DDTHH:MM:SS` then Z, +HH:MM or +HHMM.
; () for a form not read here.
(def %parse-date
  (fn (_ s)
    (def t (Str8 trim s))
    (def raw (if (Str8 starts? "@" t) (Str8 sub 1 (%sub (Str8 length t) 1) t) t))
    (def parts (Str8 split " " raw))
    (match
      ((and (>= (Str8 length t) 19) (str=? (Str8 sub 4 1 t) "-") (str=? (Str8 sub 10 1 t) "T"))
        (let ((zone (Str8 sub 19 (%sub (Str8 length t) 19) t)))
          (let ((sign (if (Str8 starts? "-" zone) -1 1))
                (zdigits (Str8 join "" (Str8 split ":" (if (or (= (Str8 length zone) 0) (str=? zone "Z")) "+0000" zone)))))
            (let ((zh (%digits zdigits 1 2)) (zm (%digits zdigits 3 2)))
              (let ((offset (%mul sign (%add (%mul zh 3600) (%mul zm 60))))
                    (local (%add (%mul (%days-from-civil (%digits t 0 4) (%digits t 5 2) (%digits t 8 2)) 86400)
                                 (%add (%mul (%digits t 11 2) 3600) (%add (%mul (%digits t 14 2) 60) (%digits t 17 2))))))
                (Str8 append (Str8 str (%sub local offset)) " " (if (< sign 0) "-" "+")
                  (Str8 pad-left 2 #\0 (Str8 str zh)) (Str8 pad-left 2 #\0 (Str8 str zm))))))))
      ((and (not (null? parts)) (> (Str8 length (first parts)) 0)
            (List all? (fn (_ i) (let ((c (Str8 sub i 1 (first parts)))) (and (Str8 >=? c "0") (Str8 <=? c "9"))))
              (List range 0 (Str8 length (first parts)))))
        (Str8 append (first parts) " " (if (null? (rest parts)) "+0000" (first (rest parts)))))
      (#t ()))))

(def %env (fn (_ name) (let ((v (Sys getenv name))) (if (or (null? v) (= (Str8 length v) 0)) () v))))

; A role's `NAME <EMAIL> WHEN`, role AUTHOR or COMMITTER: the name and the
; email from GIT_<ROLE>_NAME and _EMAIL, else user.name and user.email;
; the time from GIT_<ROLE>_DATE, else the clock.  () when there is no
; name or no email.
(def %signature
  (fn (_ gitdir role)
    (def name (or (%env (Str8 append "GIT_" role "_NAME")) (git-config-value gitdir "user.name")))
    (def email (or (%env (Str8 append "GIT_" role "_EMAIL")) (git-config-value gitdir "user.email")))
    (def date (let ((d (%env (Str8 append "GIT_" role "_DATE")))) (if (null? d) () (%parse-date d))))
    (if (or (null? name) (null? email)) ()
      (Str8 append name " <" email "> " (if (null? date) (%timestamp) date)))))

(def git-signature (fn (_ gitdir role) (%signature gitdir role)))

(provide git/ident git-signature)

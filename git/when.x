; # x-git -- git on x-lang
;
; ## git/when.x -- dates as a revision names them
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A date as REF@{DATE} gives one, read as git's approxidate reads it,
; to an epoch: (git-approxidate text now), or () when nothing in it is a
; date.  Read here: `@EPOCH`; dates YYYY-MM-DD, YYYY/MM/DD, MM/DD/YYYY
; and DD.MM.YYYY, a month's name with a day and a year; times HH:MM and
; HH:MM:SS, `T` between date and time, a zone +HHMM or -HHMM after the
; time; N seconds, minutes, hours, days, weeks, fortnights, months or
; years (ago, or not: back either way); yesterday, now, noon, midnight
; and tea, the last of each; Nam and Npm; last WEEKDAY.  What is not given
; is now's, in local time: a date alone is that day at this time of day.
; Words not read are passed over, as git passes them.
;
; (git-rfc2822-date epoch zone) is a date as git's warnings print it:
; `Tue, 20 Oct 2026 06:00:00 -0400`, in that zone.

(module git/when)

(import x/sys/date Date)

(def %add (prim-ref 'int '+))
(def %sub (prim-ref 'int '-))
(def %mul (prim-ref 'int '*))
(def %int-div (prim-ref (lit int) (lit /)))
(def %int-mod (prim-ref (lit int) (lit %)))

(def %month-names
  (list "january" "february" "march" "april" "may" "june" "july" "august" "september" "october" "november" "december"))
(def %day-names (list "sunday" "monday" "tuesday" "wednesday" "thursday" "friday" "saturday"))

; --- a time's fields ---

; A time is (YEAR MONTH DAY HOUR MINUTE SECOND), civil, local.
(def %fields
  (fn (_ epoch)
    (def d (Date local epoch))
    (List map (fn (_ k) (Assoc get k d)) (list (lit year) (lit month) (lit day) (lit hour) (lit minute) (lit second)))))

(def %epoch
  (fn (_ f)
    (Date local->unix
      (list (pair (lit year) (List ref 0 f)) (pair (lit month) (List ref 1 f)) (pair (lit day) (List ref 2 f))
            (pair (lit hour) (List ref 3 f)) (pair (lit minute) (List ref 4 f)) (pair (lit second) (List ref 5 f))))))

(def %with (fn (_ f i v) (List map (fn (_ k) (if (= k i) v (List ref k f))) (List range 0 6))))

; The fields moved back secs seconds.
(def %back (fn (_ f secs) (%fields (%sub (%epoch f) secs))))

; The fields moved back n months, the day left for the calendar to settle.
(def %back-months
  (fn (_ f n)
    (def m (%sub (%add (%mul (List ref 0 f) 12) (%sub (List ref 1 f) 1)) n))
    (%fields (%epoch (%with (%with f 0 (%int-div m 12)) 1 (%add (%int-mod m 12) 1))))))

; The last time it was hour o'clock: today's, or yesterday's when today's
; is still to come.
(def %last-hour
  (fn (_ f hour)
    (def g (if (< (List ref 3 f) hour) (%back f 86400) f))
    (%with (%with (%with g 3 hour) 4 0) 5 0)))

; --- words ---

(def %digit? (fn (_ c) (let ((n (Char ->int c))) (and (>= n 48) (<= n 57)))))
(def %alpha? (fn (_ c) (let ((n (Char ->int (Char downcase c)))) (and (>= n 97) (<= n 122)))))
(def %number (fn (_ s) (%str->number s 10)))

; The text in tokens: (word . TEXT) a run of letters, lower case; (num .
; TEXT) a run of digits, with any -, /, . or : between digits; (zone .
; SECONDS-EAST) a sign and four digits after a space.
(def %tokens
  (fn (_ text)
    (def n (Str8 length text))
    (def at (fn (_ i) (Str8 ref i text)))
    (def run
      (fn (self i ok?)
        (if (and (< i n) (ok? i)) (self (%add i 1) ok?) i)))
    ((fn (self i acc)
       (if (>= i n) (List reverse acc)
         (let ((c (at i)))
           (match
             ((%alpha? c)
               (let ((j (run i (fn (_ k) (%alpha? (at k))))))
                 (self j (pair (pair (lit word) (Str8 downcase (Str8 sub i (%sub j i) text))) acc))))
             ((%digit? c)
               (let ((j (run i (fn (_ k) (or (%digit? (at k))
                                             (and (< (%add k 1) n) (> k i)
                                                  (not (null? (Str8 index-of (Str8 sub k 1 text) "-/.:")))
                                                  (%digit? (at (%add k 1)))))))))
                 (self j (pair (pair (lit num) (Str8 sub i (%sub j i) text)) acc))))
             ((and (or (= (Char ->int c) 43) (= (Char ->int c) 45)) (<= (%add i 5) n)
                   (List all? (fn (_ k) (%digit? (at (%add i k)))) (list 1 2 3 4))
                   (or (= (%add i 5) n) (not (%digit? (at (%add i 5))))))
               (let ((hh (%number (Str8 sub (%add i 1) 2 text))) (mm (%number (Str8 sub (%add i 3) 2 text))))
                 (self (%add i 5)
                   (pair (pair (lit zone) (%mul (if (= (Char ->int c) 45) -1 1) (%add (%mul hh 3600) (%mul mm 60)))) acc))))
             (#t (self (%add i 1) acc))))))
     0 ())))

; Whether a word names the thing whose full name is given: at least its
; first three letters, or its full name with an s.
(def %names?
  (fn (_ word full)
    (def n (Str8 length word))
    (or (and (>= n 3) (<= n (Str8 length full)) (Str8 starts? word full))
        (str=? word (Str8 append full "s")))))

(def %units
  (list (pair "second" 1) (pair "minute" 60) (pair "hour" 3600) (pair "day" 86400)
        (pair "week" 604800) (pair "fortnight" 1209600)))

; A number with separators as a date (YEAR MONTH DAY), or ().
(def %date-of
  (fn (_ s)
    (def sep (List find (fn (_ c) (not (null? (Str8 index-of c s)))) (list "-" "/" ".")))
    (def parts (if (null? sep) () (Str8 split sep s)))
    (if (not (= (List length parts) 3)) ()
      (let ((a (List ref 0 parts)) (b (List ref 1 parts)) (c (List ref 2 parts)))
        (match
          ((= (Str8 length a) 4) (list (%number a) (%number b) (%number c)))
          ((and (= (Str8 length c) 4) (str=? sep "/")) (list (%number c) (%number a) (%number b)))
          ((= (Str8 length c) 4) (list (%number c) (%number b) (%number a)))
          (#t ()))))))

; --- approxidate ---

; The state as the words are read: (FIELDS PENDING ZONE TOUCHED LAST-MONTH?),
; PENDING the number not yet given a meaning, or ().
(def %step
  (fn (_ st tok)
    (def f (List ref 0 st))
    (def pending (List ref 1 st))
    (def zone (List ref 2 st))
    (def month? (List ref 4 st))
    (def n (if (null? pending) 0 pending))
    (def done (fn (_ g) (list g () zone #t #f)))
    (def kind (first tok))
    (def text (rest tok))
    (match
      ((eq? kind (lit zone)) (list f pending text (List ref 3 st) #f))
      ((eq? kind (lit num))
        (match
          ((not (null? (Str8 index-of ":" text)))
            (let ((p (Str8 split ":" text)))
              (done (%with (%with (%with f 3 (%number (first p))) 4 (%number (List ref 1 p)))
                      5 (if (> (List length p) 2) (%number (List ref 2 p)) 0)))))
          ((not (null? (%date-of text)))
            (let ((d (%date-of text))) (done (%with (%with (%with f 0 (first d)) 1 (List ref 1 d)) 2 (List ref 2 d)))))
          ((and month? (<= (%number text) 31)) (list (%with f 2 (%number text)) () zone #t #f))
          ((and (>= (%number text) 1900) (<= (%number text) 2100)) (list (%with f 0 (%number text)) () zone #t #f))
          (#t (list f (%number text) zone (List ref 3 st) #f))))
      ((str=? text "yesterday") (done (%back f 86400)))
      ((or (str=? text "now") (str=? text "today")) (done f))
      ((str=? text "noon") (done (%last-hour f 12)))
      ((str=? text "midnight") (done (%last-hour f 0)))
      ((str=? text "tea") (done (%last-hour f 17)))
      ((str=? text "am") (done (%with f 3 (%int-mod (if (null? pending) (List ref 3 f) pending) 12))))
      ((str=? text "pm") (done (%with f 3 (%add (%int-mod (if (null? pending) (List ref 3 f) pending) 12) 12))))
      ((str=? text "last") (list f 1 zone #t #f))
      ((not (null? (List find (fn (_ u) (%names? text (first u))) %units)))
        (done (%back f (%mul n (rest (List find (fn (_ u) (%names? text (first u))) %units))))))
      ((%names? text "month") (done (%back-months f n)))
      ((%names? text "year") (done (%with f 0 (%sub (List ref 0 f) n))))
      ((not (null? (List find (fn (_ m) (%names? text m)) %month-names)))
        (let ((m (%add 1 (List index-of (List find (fn (_ m) (%names? text m)) %month-names) %month-names))))
          (list (if (and (not (null? pending)) (<= pending 31)) (%with (%with f 1 m) 2 pending) (%with f 1 m)) () zone #t #t)))
      ; last WEEKDAY: that day the week before, or this week's when it has been
      ((and (not (null? pending)) (not (null? (List find (fn (_ d) (%names? text d)) %day-names))))
        (let ((target (List index-of (List find (fn (_ d) (%names? text d)) %day-names) %day-names))
              (today (Assoc get (lit wday) (Date local (%epoch f)))))
          (let ((diff (%sub today target)))
            (done (%back f (%mul 86400 (if (<= diff 0) (%add diff (%mul 7 pending)) (%add diff (%mul 7 (%sub pending 1))))))))))
      (#t st))))

(def git-approxidate
  (fn (_ text now)
    (def t (Str8 trim text))
    (if (and (Str8 starts? "@" t) (> (Str8 length t) 1)
             (List all? (fn (_ i) (%digit? (Str8 ref i t))) (List range 1 (Str8 length t))))
      (%number (Str8 sub 1 (%sub (Str8 length t) 1) t))
      (let ((st (List fold %step (list (%fields now) () () #f #f) (%tokens t))))
        (let ((f (List ref 0 st)) (pending (List ref 1 st)) (zone (List ref 2 st)))
          (let ((g (match
                     ((null? pending) f)
                     ((<= pending 31) (%with f 2 pending))
                     ((and (>= pending 1900) (<= pending 2100)) (%with f 0 pending))
                     (#t f))))
            (match
              ((and (not (List ref 3 st)) (or (null? pending) (> pending 2100))) ())
              ((null? zone) (%epoch g))
              (#t (%sub (Date to-unix (list (pair (lit year) (List ref 0 g)) (pair (lit month) (List ref 1 g))
                                            (pair (lit day) (List ref 2 g)) (pair (lit hour) (List ref 3 g))
                                            (pair (lit minute) (List ref 4 g)) (pair (lit second) (List ref 5 g))))
                        zone)))))))))

; --- printed ---

(def %two (fn (_ n) (Str8 pad-left 2 #\0 (Str8 str n))))

; A name's first three letters, the first a capital: Tue, Oct.
(def %short (fn (_ name) (Str8 append (Str8 upcase (Str8 sub 0 1 name)) (Str8 sub 1 2 name))))

(def git-rfc2822-date
  (fn (_ epoch zone)
    (def sign (if (Str8 starts? "-" zone) -1 1))
    (def off (%mul sign (%add (%mul (%number (Str8 sub 1 2 zone)) 3600) (%mul (%number (Str8 sub 3 2 zone)) 60))))
    (def d (Date from-unix (%add epoch off)))
    (def g (fn (_ k) (Assoc get k d)))
    (Str8 append
      (%short (List ref (g (lit wday)) %day-names)) ", "
      (Str8 str (g (lit day))) " "
      (%short (List ref (%sub (g (lit month)) 1) %month-names)) " "
      (Str8 str (g (lit year))) " "
      (%two (g (lit hour))) ":" (%two (g (lit minute))) ":" (%two (g (lit second))) " " zone)))

(provide git/when git-approxidate git-rfc2822-date)

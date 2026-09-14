;;;; lintsp — reader-only Common Lisp linter.
;;;; Front end: parse each file with the host reader, capturing source offsets.
;;;; No evaluation, no compilation, no third-party dependencies.

(in-package #:lintsp)

(defstruct diag rule severity path line col message)

(defun make-diagnostic (rule severity path line col message)
  (make-diag :rule rule :severity severity :path path :line line :col col
             :message message))

;;; A text splice for `fix`. Defined here, before the rule modules that build
;;; edits, so those modules compile without an undefined-function style warning.
;;; START/END are absolute character offsets into the file; an empty TEXT is a
;;; deletion, widened over the whitespace it leaves behind.
(defstruct edit path line rule start end text)

;;; A rewrite the fix engine REFUSED because it could not be proved safe. The
;;; fix prints these (report-only) so a refusal is visible and counted, never
;;; silent: `unix` — fail loudly, never silently default to a guess.
(defvar *fix-refusals* nil
  "Bound by `fix` to a box of (PATH LINE RULE REASON) refusals; NIL elsewhere.")

(defun record-fix-refusal (path line rule reason)
  (when *fix-refusals* (push (list path line rule reason) (car *fix-refusals*))))

;;; ------------------------------------------------------------------- positions

(defvar *line-index* (make-hash-table :test 'eq)
  "Memo of a source string's line-start offsets. LINE-COL is called for every
node, so recomputing by scanning from offset 0 makes parsing quadratic.")

(defun line-starts (src)
  (or (gethash src *line-index*)
      (setf (gethash src *line-index*)
            (let ((v (make-array 64 :adjustable t :fill-pointer 0)))
              (vector-push-extend 0 v)
              (loop for i from 0 below (length src)
                    when (char= (char src i) #\Newline)
                      do (vector-push-extend (1+ i) v))
              (coerce v 'simple-vector)))))

(defun line-col (src pos)
  "Return (values line col) 1-based for character offset POS in SRC."
  (let* ((starts (line-starts src))
         (lo 0) (hi (1- (length starts))))
    ;; rightmost line-start <= pos
    (loop while (< lo hi) do
      (let ((mid (floor (+ lo hi 1) 2)))
        (if (<= (aref starts mid) pos) (setf lo mid) (setf hi (1- mid)))))
    (values (1+ lo) (1+ (- pos (aref starts lo))))))

(defun source-line (src line)
  "1-based LINE of SRC as a string, or NIL."
  (when (and line (plusp line))
    (let ((start 0))
      (dotimes (i (1- line))

        (let ((nl (position #\Newline src :start start)))
          (if nl (setf start (1+ nl)) (return-from source-line nil))))
      (let ((end (position #\Newline src :start start)))
        (subseq src start (or end (length src)))))))

;;; ------------------------------------------------------------------------ node

(defstruct (node (:constructor %make-node))
  raw       ; source substring of the whole datum
  kind      ; :list :string :symbol :atom
  form      ; the parsed datum
  start end ; char offsets [start,end)
  line col end-line
  items     ; child nodes, aligned element-for-element when ALIGNED
  aligned)  ; T when ITEMS lines up with (elements of FORM)

(defun proper-list-p (x)
  "True only for a proper list. LISTP is true for a dotted list too, and a
DOLIST over a dotted list signals — a real hazard when walking unknown code."
  (and (listp x)
       (loop for tail = x then (cdr tail)
             while (consp tail)
             finally (return (null tail)))))

(defun node-head (n)
  "Name of the operator symbol of list NODE, else NIL."
  (when (and (eq (node-kind n) :list) (consp (node-form n))
             (symbolp (car (node-form n))))
    (symbol-name (car (node-form n)))))

(defun node-is (n name)
  (let ((h (node-head n))) (and h (string= h name))))

(defun node-child (n k)
  "The child node for element K of N's datum, or NIL."
  (when (node-aligned n) (nth k (node-items n))))

(defun node-sym-name (n) (when (eq (node-kind n) :symbol) (symbol-name (node-form n))))

(defun node-elements (n)
  (cond ((consp (node-form n)) (node-form n))
        ((vectorp (node-form n)) (coerce (node-form n) 'list))
        (t nil)))

(defun list-interior (src i end)
  "Given the first significant char of a list datum at I, return (values KIND OFFSET):
KIND is :normal (interior spans OFFSET..END-1), :quote (one datum spans OFFSET..END),
or :opaque. OFFSET is relative to I."
  (let ((c (char src i)))
    (cond
      ((char= c #\() (values :normal 1))
      ((and (char= c #\#) (< (1+ i) end) (char= (char src (1+ i)) #\()) (values :normal 2))
      ((char= c #\') (values :quote 1))
      ((char= c #\`) (values :quote 1))
      ((and (char= c #\#) (< (1+ i) end) (char= (char src (1+ i)) #\')) (values :quote 2))
      ((char= c #\,)
       (if (and (< (1+ i) end) (char= (char src (1+ i)) #\@))
           (values :quote 2) (values :quote 1)))
      (t (values :opaque 0)))))

;;; ------------------------------------------------------------------ trivia scan

(defun skip-trivia (src i &optional end)
  "Advance past whitespace, ; comments and #| |# blocks. Returns an index."
  (let ((end (or end (length src))))
    (loop
      (when (>= i end) (return i))
      (let ((c (char src i)))
        (cond
          ((member c '(#\Space #\Tab #\Newline #\Return #\Page #\Linefeed)) (incf i))
          ((char= c #\;) (let ((nl (position #\Newline src :start i :end end)))
                           (setf i (or nl end))))
          ((and (char= c #\#) (< (1+ i) end) (char= (char src (1+ i)) #\|))
           (incf i 2)
           (let ((depth 1))
             (loop while (and (< i end) (plusp depth)) do
               (cond ((and (char= (char src i) #\#) (< (1+ i) end) (char= (char src (1+ i)) #\|))
                      (incf i 2) (incf depth))
                     ((and (char= (char src i) #\|) (< (1+ i) end) (char= (char src (1+ i)) #\#))
                      (incf i 2) (decf depth))
                     (t (incf i))))))
          (t (return i)))))))

(defun scrub (src)
  "Copy of SRC with string bodies and comments blanked to spaces (newlines kept).
Used only to find package prefixes without tripping over strings/comments."
  (let* ((n (length src)) (out (make-string n :initial-element #\Space)) (i 0))
    (loop while (< i n) do
      (let ((c (char src i)))
        (cond
          ((char= c #\") (incf i)
           (loop while (< i n) do
             (cond ((char= (char src i) #\\) (incf i) (when (< i n) (incf i)))
                   ((char= (char src i) #\") (incf i) (return))
                   (t (incf i)))))
          ((char= c #\;) (loop while (and (< i n) (not (char= (char src i) #\Newline))) do (incf i)))
          ((and (char= c #\#) (< (1+ i) n) (char= (char src (1+ i)) #\|))
           (incf i 2)
           (let ((depth 1))
             (loop while (and (< i n) (plusp depth)) do
               (cond ((and (char= (char src i) #\#) (< (1+ i) n) (char= (char src (1+ i)) #\|))
                      (incf i 2) (incf depth))
                     ((and (char= (char src i) #\|) (< (1+ i) n) (char= (char src (1+ i)) #\#))
                      (incf i 2) (decf depth))
                     (t (incf i))))))
          ((and (char= c #\#) (< (1+ i) n) (char= (char src (1+ i)) #\\))
           (setf (char out i) #\#) (incf i) (setf (char out i) #\\) (incf i)
           (when (< i n)
             (if (member (char src i) '(#\( #\) #\" #\' #\` #\, #\; #\Space #\Tab #\Newline))
                 (incf i)              ; single-char literal such as #\( — not a paren
                 (loop while (and (< i n)
                                  (not (member (char src i)
                                               '(#\( #\) #\" #\; #\Space #\Tab #\Newline
                                                 #\' #\` #\,))))
                       do (incf i)))))
          (t (setf (char out i) c) (incf i)))))
    out))

;;; ------------------------------------------------------------------- the reader

(defvar *read-package* nil)

(defun ensure-package (name)
  (or (find-package name)
      (ignore-errors (make-package name :use nil))))
(defun package-name-char-p (c)
  (and (not (member c '(#\( #\) #\" #\' #\` #\, #\; #\: #\Space #\Tab #\Newline #\Return)))
       (graphic-char-p c)))

(defun register-packages (src)
  "Pre-create every package referenced as NAME: or NAME:: in SRC (strings and
comments blanked), exporting the single-colon symbols so the reader can resolve
them. Without this, reading a file that names a package this image does not know
signals a reader error and loses the whole form."
  (let ((s (scrub src)))
    (loop with n = (length s) and i = 0
          while (< i n) do
      (if (char= (char s i) #\:)
          (progn
            (let ((j i))
              (loop while (and (> j 0) (package-name-char-p (char s (1- j)))) do (decf j))
              (when (< j i)
                (let* ((name (string-upcase (subseq s j i)))
                       (double (and (< (1+ i) n) (char= (char s (1+ i)) #\:)))
                       (k (+ i (if double 2 1))))
                  (when (and (plusp (length name))
                             (not (string= name ":")))
                    (let ((pkg (ensure-package name)))
                      (when (and pkg (not double))
                        ;; single colon: the symbol must be external
                        (let ((kk k))
                          (loop while (and (< kk n) (package-name-char-p (char s kk))) do (incf kk))
                          (when (> kk k)
                            (ignore-errors
                             (export (intern (string-upcase (subseq s k kk)) pkg) pkg))))))))))
            (incf i))
          (incf i)))))

(defvar *debug-read* nil)

(defun close-paren-pos (src end)
  "Offset of the `)` that closes a list datum ending at END (exclusive). The
reader may consume one trailing delimiter past the `)`, so walk back over
whitespace; fall back to END-1."
  (let ((j (1- end)))
    (loop while (and (> j 0)
                     (member (char src j) '(#\Space #\Tab #\Newline #\Return #\Page)))
          do (decf j))
    (if (and (>= j 0) (char= (char src j) #\))) j (1- end))))

(defun make-node-from (src start end form items aligned)
  (let* ((fc (if (consp form) (skip-trivia src start end) start))
         (kind (cond ((consp form) :list) ((stringp form) :string)
                     ((symbolp form) :symbol) (t :atom))))
    (multiple-value-bind (l c) (line-col src fc)
      (multiple-value-bind (el ec) (line-col src end)
        (declare (ignore ec))
        (%make-node
         ;; RAW is kept only where a rule actually reads it. Copying the source
         ;; text of every list would duplicate each form once per nesting level,
         ;; which is what exhausts the heap on a large tree. The reader consumes
         ;; one delimiter past a symbol (a space, or a newline at end of line),
         ;; so trim it: otherwise a symbol whose definition line ends in a
         ;; newline carries that newline into a diagnostic message and splits
         ;; the message across two output lines.
         :raw (if (member kind '(:symbol :string))
                  (string-right-trim '(#\Space #\Tab #\Newline #\Return
                                       #\Page #\Linefeed)
                                     (subseq src start end))
                  nil)
         :kind kind :form form :start start :end end :line l :col c :end-line el
         :items items :aligned aligned)))))

(defun make-prefix-node (src i off form)
  "A synthetic node for the reader-macro prefix at I (e.g. the quote in 'X)."
  (multiple-value-bind (l c) (line-col src i)
    (%make-node :raw (subseq src i (+ i off)) :kind :symbol :form (car form)
                :start i :end (+ i off) :line l :col c :items nil :aligned t)))

(defun read-region (src start end count)
  "Read up to COUNT data (or all when COUNT is NIL) in region [START,END).
Returns a list of nodes, or NIL when the region cannot be re-read standalone —
which happens when the region begins inside a reader macro whose prefix lies
above it (a comma inside a backquote). The enclosing form is still kept."
  (handler-case
      (let ((items nil))
        (with-input-from-string (s2 src :start start :end end)
          (loop (let ((c (read-node s2 src start end)))
                  (unless c (return))
                  (push c items)
                  (when (and count (>= (length items) count)) (return)))))
        (nreverse items))
    (error () nil)))

(defun read-node (stream src base limit)
  "Read one datum from STREAM (a string-input-stream over SRC whose :start is
BASE and whose exclusive end is LIMIT, both absolute offsets into SRC). NIL at
end. Returns a node whose START/END are absolute offsets."
  (let* ((p (file-position stream))
         (start (+ base p)))
    (when *debug-read*
      (format t "~&read-node base=~D limit=~D fp=~D start=~D~%" base limit p start))
    (when (>= start limit) (return-from read-node nil))
    (let* ((form (read stream nil '#:lintsp-eof))
           (end (+ base (file-position stream))))
      (when (eq form '#:lintsp-eof) (return-from read-node nil))
      (let ((items nil) (aligned nil))
        (when (consp form)
          (let ((i (skip-trivia src start end)))
            (when (< i end)
              (multiple-value-bind (kind off) (list-interior src i end)
                (cond
                  ((eq kind :normal)
                   (setf items (read-region src (+ i off) (close-paren-pos src end) nil)
                         aligned t))
                  ((eq kind :quote)
                   (setf items (cons (make-prefix-node src i off form)
                                     (read-region src (+ i off) end 1))
                         aligned t)))))))
        (make-node-from src start end form items aligned)))))

(defun next-top-level-pos (src from)
  "Offset just after the next newline that begins a line with `(` — where a
top-level form plausibly resumes. Recovery, not parsing."
  (let ((i from))
    (loop
      (let ((nl (position #\Newline src :start i)))
        (when (null nl) (return nil))
        (let ((j (1+ nl)))
          (when (and (< j (length src)) (char= (char src j) #\())
            (return j))
          (setf i (1+ nl)))))))

(defun read-file (path)
  "Read PATH into (values nodes source problems). NODES are top-level datums with
spans. On a read error the nodes read before it are kept and the reader resumes
at the next plausible top-level form, so a file that breaks mid-way still yields
diagnostics for the rest."
  (let* ((src (with-open-file (in path :external-format :utf-8)
                (let ((s (make-string (file-length in))))
                  (subseq s 0 (read-sequence s in)))))
         (nodes nil) (problems nil))
    (let ((*package* (or *read-package*
                         (setf *read-package* (make-package "LINTSP.SRC" :use nil))))
          (*read-eval* nil))
      (register-packages src)
      (with-input-from-string (s src)
        (loop
          (let ((start (file-position s)))
            (when (>= start (length src)) (return))
            (handler-case
                (let ((n (read-node s src 0 (length src))))
                  (unless n (return))
                  (when (<= (node-end n) start) (return))
                  (push n nodes))
              (error (e)
                (let* ((msg (format nil "~A" e))
                       (read-eval-p (search "READ-EVAL" msg))
                       (resume (next-top-level-pos src (max 0 (or (file-position s) 0)))))
                  (push (make-diagnostic
                         "reader-error"
                         (if read-eval-p :note :error)
                         (namestring path) 0 0
                         (format nil "~A~@[ (skipped to the next top-level form)~]"
                                 (first (split-lines msg)) resume))
                        problems)
                  (if resume
                      (file-position s resume)
                      (return)))))))))
    (values (nreverse nodes) src (progn (remhash src *line-index*) (nreverse problems)))))

(defun split-lines (s)
  (let ((out nil) (start 0))
    (loop for i = (position #\Newline s :start start)
          do (push (subseq s start (or i (length s))) out)
          if i do (setf start (1+ i)) else do (return))
    (nreverse out)))

;;; ---------------------------------------------------------------------- files

(defun directory-pathname-p (p)
  (and (null (pathname-name p)) (null (pathname-type p))))

(defparameter *default-excludes*
  '(".git" "node_modules" ".qlot" "old-home" ".cache" "*.local/state/*")
  "Path components (no slash) or globs (with slash) never descended into and
never reported. Generated state trees are the big one: ~/.local/state alone
holds hundreds of generated .lisp files that duplicate live source, so linting
them reports the same finding several times in artifact copies. --exclude and
.lintspignore add patterns.")

(defun glob-match-p (pattern string)
  "* matches any run of characters (including /), ? exactly one."
  (labels ((m (p s)
             (cond ((zerop (length p)) (zerop (length s)))
                   ((char= (char p 0) #\*)
                    (or (m (subseq p 1) s)
                        (and (plusp (length s)) (m p (subseq s 1)))))
                   ((zerop (length s)) nil)
                   ((char= (char p 0) #\?) (m (subseq p 1) (subseq s 1)))
                   ((char= (char p 0) (char s 0)) (m (subseq p 1) (subseq s 1)))
                   (t nil))))
    (m pattern string)))

(defun excluded-path-p (namestring patterns)
  "True when NAMESTRING matches an exclude PATTERN. A pattern without a slash
matches one whole path component (the name, or a directory in the path); one with
a slash globs the whole path. * and ? are wildcards in either case."
  (let ((comps (remove "" (uiop:split-string namestring :separator "/") :test #'string=)))
    (some (lambda (pat)
            (if (find #\/ pat)
                ;; a slash pattern is matched at any depth, like .gitignore:
                ;; `src/foo.lisp` and `*/src/foo.lisp` both hit /a/b/src/foo.lisp
                (or (glob-match-p pat namestring)
                    (glob-match-p (concatenate 'string "*" pat) namestring))
                (some (lambda (c) (glob-match-p pat c)) comps)))
          patterns)))

(defun truename-namestring (path)
  "PATH's truename as a namestring, any trailing `/` removed so two spellings of
one directory compare equal."
  (let ((s (namestring (or (ignore-errors (truename path)) path))))
    (if (string= s "/") s (string-right-trim "/" s))))

(defun path-under-p (namestring root)
  "True when NAMESTRING is ROOT or lies under it. Both absolute, no trailing /."
  (or (string= namestring root)
      (and (> (length namestring) (length root))
           (string= root namestring :end2 (length root))
           (char= (char namestring (length root)) #\/))))

(defun collect-lisp-files (paths patterns)
  "Expand PATHS into a sorted list of .lisp/.asd pathnames. An entry an exclude
PATTERN matches is skipped; so is any entry that resolves outside every given
root. That is how a `result' symlink is walked today: DIRECTORY resolves the
link, so the entry arrives as /nix/store/...-foo-0.1.0/share/... — a read-only
build output of the very code the root already covers, which duplicates findings
against vendored copies. Returns (values FILES SKIPPED-EXCLUDED SKIPPED-OUTSIDE);
both counts are printed in the summary, because a silent exclusion is a silent
default. Signals on a missing path."
  (let ((out nil) (skipped 0) (outside 0)
        (roots (mapcar #'truename-namestring paths)))
    (labels ((add (p)
               (let* ((tp (or (ignore-errors (probe-file p))
                              (error "lintsp: no such path: ~A" p)))
                      (abs (truename-namestring tp)))
                 (cond
                   ((notany (lambda (r) (path-under-p abs r)) roots) (incf outside))
                   ((excluded-path-p abs patterns) (incf skipped))
                   ((directory-pathname-p tp)
                    (dolist (f (ignore-errors (directory (merge-pathnames "*.*" tp))))
                      (add f)))
                   ((member (pathname-type tp) '("lisp" "asd") :test #'string-equal)
                    (push tp out))))))
      (dolist (p paths) (add p)))
    (values (sort (remove-duplicates out :test #'equalp) #'string< :key #'namestring)
            skipped outside)))

(defvar *relative* nil
  "When true, printed paths are relative to *ROOT-PREFIX*. Off by default: the
output is machine-readable, and a path that is not openable as printed is
worthless to a consumer. --relative asks for the short form.")

(defvar *root-prefix* nil
  "Directory stripped from printed paths when *RELATIVE* is on. Never the
filesystem root: stripping `/` yields `home/y0usaf/...`, which no shell and no
editor can resolve.")

(defun short-name (path)
  "PATH as it is printed: absolute by default, else relative to *ROOT-PREFIX*."
  (let ((abs (namestring path)))
    (if (and *relative* *root-prefix*
             (> (length *root-prefix*) 1)
             (>= (length abs) (length *root-prefix*))
             (string= *root-prefix* abs :end2 (length *root-prefix*)))
        (subseq abs (length *root-prefix*))
        abs)))

;;; ------------------------------------------------------------------- file model

;;; ---------------------------------------------------------------- node walkers

(defun all-nodes (nodes)
  "Every node reachable from the top-level NODES, including atoms."
  (let ((acc nil))
    (labels ((walk (n)
               (push n acc)
               (dolist (c (node-items n)) (walk c))))
      (dolist (n nodes) (walk n)))
    (nreverse acc)))

(defun all-list-nodes (nodes)
  "Every list/vector node reachable from the top-level NODES, outermost first."
  (let ((acc nil))
    (labels ((walk (n)
               (when (member (node-kind n) '(:list))
                 (push n acc)
                 (dolist (c (node-items n)) (walk c)))))
      (dolist (n nodes) (walk n)))
    (nreverse acc)))

(defstruct file-model path src nodes defs refs package reader-diags list-nodes all-nodes quoted)

(defun fm-quoted-nodes (m)
  "Eq-set of nodes inside a QUOTE form, computed once per file. Rebuilding it in
a per-node rule would make the walk quadratic."
  (or (file-model-quoted m)
      (setf (file-model-quoted m) (quoted-nodes m))))

(defun node-string-atoms (node)
  "Every symbol name appearing anywhere in NODE's datum except inside quoted
data, plus symbol names inside strings are never produced (strings are atoms)."
  (let ((acc nil))
    (labels ((walk-form (f quoted)
               (cond
                 ((and (consp f) (eq (car f) 'quote)) nil)
                 ((consp f) (dolist (x f) (walk-form x quoted)))
                 ((vectorp f) (dolist (x (coerce f 'list)) (walk-form x quoted)))
                 ((symbolp f) (unless quoted (push (symbol-name f) acc))))))
      (walk-form (node-form node) nil))
    acc))

(defun fm-list-nodes (m)
  "List nodes of M, computed once: every rule walks them, and rebuilding the
list per rule per file is what makes a large tree quadratic."
  (or (file-model-list-nodes m)
      (setf (file-model-list-nodes m) (all-list-nodes (file-model-nodes m)))))

(defun fm-all-nodes (m)
  "Every node of M, computed once."
  (or (file-model-all-nodes m)
      (setf (file-model-all-nodes m) (all-nodes (file-model-nodes m)))))

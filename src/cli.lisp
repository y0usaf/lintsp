;;;; lintsp — command line, semantic model construction, output.

(in-package #:lintsp)

;;; ------------------------------------------------------------------- arg parse

(defstruct opts
  command paths enable disable format
  allow-definitions allow-symbols order-file
  long-lines deep-depth exclude fix-dry relative)

(defun usage-error (fmt &rest args)
  (format *error-output* "lintsp: ~?~%lintsp: try `lintsp --help`~%" fmt args)
  (uiop-exit 2))

(defun uiop-exit (code)
  (finish-output *standard-output*)
  (finish-output *error-output*)
  (sb-ext:exit :code code :abort nil))

(defun parse-args (argv)
  (let* ((args (coerce argv 'vector))
         (n (length args))
         (i 0)
         (o (make-opts :enable nil :disable nil :format "text"
                       :allow-definitions nil :allow-symbols nil
                       :long-lines 80 :deep-depth 10)))
    (when (zerop n) (usage-error "no command"))
    ;; SBCL passes a literal "--" through when the image is run as
    ;; `sbcl --load ... -- check ...`; ignore it.
    (when (and (>= n 2) (string= (aref args 0) "--")) (setf i 1))
    (setf (opts-command o) (aref args i))
    (incf i)
    (loop while (< i n) do
      (let ((a (aref args i)))
        (flet ((val (name)
                 (incf i)
                 (when (>= i n) (usage-error "~A needs a value" name))
                 (aref args i)))
          (cond
            ((string= a "--enable") (push (val a) (opts-enable o)))
            ((string= a "--disable") (push (val a) (opts-disable o)))
            ((string= a "--allow-definition") (push (val a) (opts-allow-definitions o)))
            ((string= a "--allow-symbol") (push (val a) (opts-allow-symbols o)))
            ((string= a "--order") (setf (opts-order-file o) (val a)))
            ((string= a "--exclude") (push (val a) (opts-exclude o)))
            ((string= a "--dry-run") (setf (opts-fix-dry o) t))
            ((string= a "--relative") (setf (opts-relative o) t))
            ((string= a "--format") (setf (opts-format o) (val a)))
            ((string= a "--long-function-lines") (setf (opts-long-lines o) (parse-integer (val a))))
            ((string= a "--deep-nesting-depth") (setf (opts-deep-depth o) (parse-integer (val a))))
            ((string= a "--help") (setf (opts-command o) "help"))
            ((and (plusp (length a)) (char= (char a 0) #\-))
             (usage-error "unknown option ~A" a))
            (t (push a (opts-paths o)))))
        (incf i)))
    (setf (opts-paths o) (nreverse (opts-paths o)))
    (setf (opts-enable o) (nreverse (opts-enable o)))
    (setf (opts-disable o) (nreverse (opts-disable o)))
    (setf (opts-exclude o) (nreverse (opts-exclude o)))
    ;; Relative paths need one root to be relative to; anything else is a
    ;; request the tool cannot honour, so fail on it rather than guess.
    (when (and (opts-relative o) (cdr (opts-paths o)))
      (usage-error "--relative needs exactly one root, got ~D" (length (opts-paths o))))
    o))

;;; ---------------------------------------------------------------- exclusions

(defun read-ignore-file (path)
  "Patterns in a .lintspignore at PATH, or NIL when there is none. A blank
line or one whose first character is # is skipped, as in .gitignore."
  (when (probe-file path)
    (with-open-file (in path :external-format :utf-8)
      (loop for line = (read-line in nil nil)
            while line
            for p = (string-trim '(#\Space #\Tab #\Return) line)
            unless (or (zerop (length p)) (char= (char p 0) #\#))
              collect p))))

(defun ignore-file-patterns (paths)
  "Patterns from .lintspignore in the current directory and beside each
analysed path."
  (let ((out nil))
    (dolist (d (cons (uiop:getcwd) paths))
      (let ((base (or (ignore-errors (probe-file d)) d)))
        (setf out (append out (read-ignore-file (merge-pathnames ".lintspignore" base))))))
    (remove-duplicates out :test #'string=)))

(defun exclude-patterns (o)
  (append *default-excludes* (opts-exclude o) (ignore-file-patterns (opts-paths o))))

;;; --------------------------------------------------------------- .lintsprc
;;; A line-oriented table, one directive per line, whitespace-separated:
;;;   enable RULE / disable RULE            select policy rules
;;;   threshold RULE N                      tune a numeric threshold
;;;   opt-out RULE GLOB [GLOB...]           a path a row skips
;;; Read from the current directory and beside each analysed path, like
;;; .lintspignore. It overrides the HOUSE-POLICY table without editing it.

(defun read-rc-file (path)
  "Token lists of a .lintsprc at PATH, or NIL. A blank line or one whose first
character is # is skipped, as in .lintspignore."
  (when (probe-file path)
    (with-open-file (in path :external-format :utf-8)
      (loop for line = (read-line in nil nil)
            while line
            for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
            unless (or (zerop (length trimmed)) (char= (char trimmed 0) #\#))
              collect (uiop:split-string trimmed :separator '(#\Space #\Tab))))))

(defun policy-rc-tables (paths)
  (let ((out nil))
    (dolist (d (cons (uiop:getcwd) paths))
      (let ((base (or (ignore-errors (probe-file d)) d)))
        (setf out (append out (read-rc-file (merge-pathnames ".lintsprc" base))))))
    out))

(defun apply-policy-rc (o)
  "Apply every .lintsprc table found for O's paths: enable/disable push into O,
threshold and opt-out land in *policy-settings*. Returns O."
  (let ((s (policy-settings-current)))
    (dolist (toks (policy-rc-tables (opts-paths o)))
      (let ((key (string-downcase (first toks))) (rest (rest toks)))
        (cond
          ((and (string= key "enable") rest) (dolist (r rest) (push r (opts-enable o))))
          ((and (string= key "disable") rest) (dolist (r rest) (push r (opts-disable o))))
          ((and (string= key "threshold") (cdr rest))
           (let ((n (parse-integer (second rest) :junk-allowed t)))
             (when n (setf (gethash (first rest) (policy-settings-limits s)) n))))
          ((and (string= key "opt-out") (cdr rest))
           (let ((name (first rest)))
             (setf (gethash name (policy-settings-optout s))
                   (append (rest rest) (gethash name (policy-settings-optout s))))))
          (t nil)))))
  o)

;;; ------------------------------------------------------------------ model build

(defun file-package (nodes)
  "The package named by a top-level (in-package ...), else NIL."
  (dolist (n (top-level-forms nodes))
    (let ((f (node-form n)))
      (when (and (consp f) (equal (form-symbol-name (car f)) "IN-PACKAGE"))
        (let ((arg (second f)))
          (return-from file-package
            (string-upcase (cond ((symbolp arg) (symbol-name arg))
                                 ((stringp arg) arg)
                                 (t nil))))))))
  nil)

(defun build-file-model (path)
  (multiple-value-bind (nodes src problems) (read-file path)
    (let ((refs (make-hash-table :test #'equal)))
      (dolist (n nodes)
        (dolist (name (node-refs n)) (incf (gethash name refs 0))))
      (let ((m (make-file-model :path (namestring path) :src src :nodes nodes
                                :defs nil :refs refs :package (file-package nodes)
                                :reader-diags nil)))
        (setf (file-model-reader-diags m)
              (mapcar (lambda (d) (setf (diag-path d) (namestring path)) d) problems))
        m))))

(defun build-ctx (o files order source)
  (let* ((models (mapcar #'build-file-model files))
         (index (make-hash-table :test #'equal))
         (defs (make-hash-table :test #'equal))
         (exports (make-hash-table :test #'equal))
         (macros (make-hash-table :test #'equal))
         (specials (make-hash-table :test #'equal)))
    (dolist (m models)
      (maphash (lambda (k v) (incf (gethash k index 0) v)) (file-model-refs m))
      (dolist (n (top-level-forms (file-model-nodes m)))
        (multiple-value-bind (kind name line) (top-level-def n)
          (when name
            (push (list kind (file-model-path m) line) (gethash name defs))
            (when (member kind '("DEFVAR" "DEFPARAMETER" "DEFCONSTANT") :test #'string=)
              (setf (gethash name specials) t))
            (when (string= kind "DEFMACRO")
              (setf (gethash name macros) t))))
        (let ((form (node-form n)))
          (when (and (consp form) (equal (form-symbol-name (car form)) "DEFPACKAGE"))
            (dolist (e (exported-names (list n))) (setf (gethash e exports) t))))))
    (make-ctx :files models :index index :defs defs :exports exports :specials specials
              :macros macros
              :fn-defs (function-def-index models)
              :order order :order-source source
              :allow-definitions (opts-allow-definitions o)
              :allow-symbols (opts-allow-symbols o)
              :long-lines (opts-long-lines o) :deep-depth (opts-deep-depth o))))

;;; ---------------------------------------------------------------- rule running

(defun enabled-rules (o)
  (let ((out nil))
    (dolist (r *rules*)
      (let ((on (rule-default r)))
        (when (member (rule-name r) (opts-enable o) :test #'string=) (setf on t))
        (when (member (rule-name r) (opts-disable o) :test #'string=) (setf on nil))
        (when on (push r out))))
    (nreverse out)))

(defun run-all-rules (ctx o)
  "Return (values diagnostics unknown-rules). A rule that signals on one file is
reported and skipped, never allowed to abort the run."
  (let ((rules (enabled-rules o))
        (box (list nil))
        (unknown nil))
    (dolist (name (append (opts-enable o) (opts-disable o)))
      (unless (find name *rules* :key #'rule-name :test #'string=)
        (push name unknown)))
    (dolist (r rules)
      (let ((fn (rule-fn r)))
        (if (eq (rule-scope r) :file)
            (dolist (m (ctx-files ctx))
              (handler-case (funcall fn m ctx box)
                (error (e)
                  (format *error-output* "lintsp: rule ~A failed on ~A: ~A~%"
                          (rule-name r) (file-model-path m) e))))
            (dolist (m (ctx-files ctx))
              (dolist (n (all-list-nodes (file-model-nodes m)))
                (handler-case (funcall fn n m ctx box)
                  (error (e)
                    (format *error-output* "lintsp: rule ~A failed on ~A:~D: ~A~%"
                            (rule-name r) (file-model-path m) (node-line n) e))))))))
    (values (sort (car box)
                  (lambda (a b)
                    (or (< (diag-line a) (diag-line b))
                        (and (= (diag-line a) (diag-line b))
                             (< (diag-col a) (diag-col b))))))
            unknown)))

(defvar *rule-fns*
  '(("optional-and-key" . rule-optional-and-key)
    ("quadratic-append" . rule-quadratic-append)
    ("ignore-then-read" . rule-ignore-then-read)
    ("unused-binding" . rule-unused-binding)
    ("unused-parameter" . rule-unused-parameter)
    ("defstruct-after-use" . rule-defstruct-after-use)
    ("internal-symbol-leak" . rule-internal-symbol-leak)
    ("unexported-external-reference" . rule-unexported-external-reference)
    ("earmuffs" . rule-earmuffs)
    ("defparameter-named-like-constant" . rule-constant-looking-parameter)
    ("dead-definition" . rule-dead-definition)
    ("long-function" . rule-long-function)
    ("deep-nesting" . rule-deep-nesting)
    ("duplicated-literal-table" . rule-duplicated-literal-table)
    ("forward-reference" . rule-forward-reference)
    ("redundant-progn" . rule-redundant-progn)
    ("when-progn" . rule-when-progn)
    ("boolean-coercion-in-test" . rule-boolean-coercion-in-test)
    ("funcall-literal-function" . rule-funcall-literal-function)
    ("quote-quote" . rule-quote-quote)
    ("eta-reduction" . rule-eta-reduction)
    ("list-star-nil" . rule-list-star-nil)))

;; The HOUSE-POLICY rules are dispatched generically through the table: one
;; closure per row, so a new convention is a table row, not a new rule function.
(dolist (row *house-policy*)
  (push (cons (getf row :name)
              (let ((name (getf row :name)))
                (lambda (model ctx out) (policy-check-rule name model ctx out))))
        *rule-fns*))

(defun rule-fn (rule)
  (cdr (assoc (rule-name rule) *rule-fns* :test #'string=)))

;;; ---------------------------------------------------------------------- output

(defun common-prefix (files)
  "Longest common directory prefix (ending in /) of FILES."
  (if (null files) ""
      (let ((s (namestring (first files))))
        (loop for f in (rest files)
              do (let ((o (namestring f)) (k 0))
                   (loop while (and (< k (length s)) (< k (length o))
                                    (char= (char s k) (char o k)))
                         do (incf k))
                   (setf s (subseq s 0 k))))
        (let ((slash (position #\/ s :from-end t)))
          (if slash (subseq s 0 (1+ slash)) "")))))

(defun print-text (diags unknown files-scanned excluded outside ordered-p order-source)
  (dolist (d diags)
    (format t "~A:~D:~D: ~A[~A]: ~A~%"
            (short-name (diag-path d)) (diag-line d) (diag-col d)
            (string-downcase (symbol-name (diag-severity d)))
            (diag-rule d) (diag-message d)))
  (dolist (u unknown)
    (format *error-output* "lintsp: warning: unknown rule ~A~%" u))
  (when diags
    (let ((nfiles (length (remove-duplicates (mapcar #'diag-path diags) :test #'equal))))
      (format t "~D finding~:P in ~D file~:P (~D scanned, ~D excluded, ~D symlink target~:P skipped; ~A)~%"
              (length diags) nfiles files-scanned excluded outside
              (if ordered-p (format nil "load order from ~A" order-source)
                  "no load order, same-file cases only")))))

(defun json-escape (s)
  (with-output-to-string (o)
    (loop for c across s do
      (case c
        (#\" (write-string "\\\"" o))
        (#\\ (write-string "\\\\" o))
        (#\Newline (write-string "\\n" o))
        (#\Return (write-string "\\r" o))
        (#\Tab (write-string "\\t" o))
        (t (if (< (char-code c) 32)
               (format o "\\u~4,'0X" (char-code c))
               (write-char c o)))))))

(defun print-json (diags files-scanned excluded outside ordered-p order-source)
  (format t "{\"findings\":[")
  (loop for d in diags for first = t then nil do
    (unless first (format t ","))
    (format t "{\"path\":\"~A\",\"line\":~D,\"col\":~D,\"severity\":\"~A\",\"rule\":\"~A\",\"message\":\"~A\"}"
            (json-escape (short-name (diag-path d))) (diag-line d) (diag-col d)
            (string-downcase (symbol-name (diag-severity d)))
            (json-escape (diag-rule d)) (json-escape (diag-message d))))
  (format t "],\"summary\":{\"findings\":~D,\"files\":~D,\"excluded\":~D,\"symlinks_skipped\":~D,\"order\":\"~A\"}}~%"
          (length diags) files-scanned excluded outside
          (if ordered-p (or order-source "discovered") "unknown")))

;;; ------------------------------------------------------------------- commands

(defun dedupe-diags (diags)
  "Collapse exact duplicates — same path, line, col, rule and message — keeping
the first. Two different rules, or two different messages, at one span are both
kept: they are different findings. Root causes this guards are the old double
run of one function behind two rule names, and a rule that emitted once per
occurrence of a name inside a single top-level form."
  (let ((seen (make-hash-table :test #'equal)) (out nil))
    (dolist (d diags)
      (let ((k (list (diag-path d) (diag-line d) (diag-col d)
                     (diag-rule d) (diag-message d))))
        (unless (gethash k seen)
          (setf (gethash k seen) t)
          (push d out))))
    (nreverse out)))

(defparameter *version* "0.1.0")

(defun cmd-list ()
  (format t "~VA ~VA  ~A~%" 32 "RULE" 9 "DEFAULT" "DESCRIPTION")
  (dolist (r (sort (copy-list *rules*) #'string< :key #'rule-name))
    (format t "~VA ~VA  ~A~%" 32 (rule-name r)
            9 (if (rule-default r) "on" "off")
            (rule-description r))))

(defun cmd-check (o)
  (unless (opts-paths o) (usage-error "check needs at least one path"))
  (let* ((*policy-settings* (make-policy-settings :limits (make-hash-table :test #'equal)
                                                  :optout (make-hash-table :test #'equal)))
         (patterns (progn (apply-policy-rc o) (exclude-patterns o))))
    (multiple-value-bind (all excluded outside)
        (handler-case (collect-lisp-files (opts-paths o) patterns)
          (error (e) (usage-error "~A" e)))
      (let* ((asd (remove-if-not (lambda (p) (equal (pathname-type p) "asd")) all))
             (lisp0 (remove-if (lambda (p) (equal (pathname-type p) "asd")) all)))
        (when (null lisp0) (usage-error "no .lisp files under the given paths (~D excluded)" excluded))
        (multiple-value-bind (order source)
            (build-order lisp0 asd (opts-order-file o) (length (opts-paths o)))
          (let* ((lisp (sort-by-order lisp0 order))
                 (*relative* (opts-relative o))
                 (*root-prefix* (and *relative* (common-prefix lisp)))
                 (ctx (build-ctx o lisp order source))
                 (ordered-p (plusp (hash-table-count order))))
            (multiple-value-bind (diags unknown) (run-all-rules ctx o)
              (dolist (m (ctx-files ctx))
                (when (file-model-reader-diags m)
                  (setf diags (append (file-model-reader-diags m) diags))))
              (setf diags (dedupe-diags diags))
              (dolist (u unknown)
                (format *error-output* "lintsp: warning: unknown rule ~A~%" u))
              (if (string= (opts-format o) "json")
                  (print-json diags (length lisp) excluded outside ordered-p source)
                  (print-text diags nil (length lisp) excluded outside ordered-p source))
              (uiop-exit (if diags 1 0)))))))))

(defun run (argv)
  ;; SBCL ignores SIGPIPE by default, so `lintsp check ... | head` dies with a
  ;; BROKEN-PIPE backtrace on stderr instead of exiting. Restore the default
  ;; action: the failed write kills the process, quietly, as a consumer expects.
  #+sbcl
  (ignore-errors (sb-sys:enable-interrupt sb-unix:sigpipe :default))
  (handler-case
      (let ((o (parse-args argv)))
        (cond
          ((string= (opts-command o) "list") (cmd-list) (uiop-exit 0))
          ((string= (opts-command o) "check") (cmd-check o))
          ((string= (opts-command o) "fix") (cmd-fix o))
          ((string= (opts-command o) "help")
           (format t "lintsp ~A — a reader-only Common Lisp linter~%~%~
usage: lintsp check [paths...] [options]~%~
       lintsp fix [paths...] [--dry-run]~%~
       lintsp list~%~%~
options:~%~
  --enable RULE / --disable RULE   toggle a rule (repeatable)~%~
  --allow-definition NAME          treat NAME as used (name-dispatched handlers)~%~
  --allow-symbol NAME              treat NAME as host-provided~%~
  --order FILE                     load order, one path per line~%~
  --exclude GLOB                   skip matching paths (repeatable; .git, ~
node_modules, .qlot, old-home, .cache and *.local/state/* are always skipped)~%~
  --relative                       print paths relative to the single root ~
rather than absolute (default: absolute, which is what a consumer can open)~%~
  --format json|text               output format (default text)~%~\
  --long-function-lines N          threshold (default 80)~%~\
  --deep-nesting-depth N           threshold (default 10)~%~%~
fix applies only rewrites it can prove safe; --dry-run prints them and writes ~
nothing~%~%~
exit: 0 no findings, 1 findings, 2 usage error~%~
~%"
                   *version*)
           (uiop-exit 0))
          (t (usage-error "unknown command ~A" (opts-command o)))))
    (storage-condition ()
      (format *error-output* "lintsp: out of memory reading that many files at ~
once; run it on a smaller set (or rebuild with a larger :dynamic-space-size)~%")
      (uiop-exit 70))))

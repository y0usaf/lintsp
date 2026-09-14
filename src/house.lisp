;;;; lintsp — HOUSE-POLICY family: the user's own written Lisp conventions,
;;;; encoded as a data table rather than an if-chain.
;;;;
;;;; The policy source is dev/sandbox/autolith/AGENTS.md and
;;;; dev/maintaining/autolith-clinedi-fix/AGENTS.md, section "Common Lisp
;;;; Style":
;;;;   - "Do not use defconstant or define-constant."
;;;;   - "Functions and methods with four or more parameters use keyword
;;;;      arguments."
;;;;   - "Prefer first and rest over car and cdr in application code."
;;;;   - "Quote keywords used as data. Whenever a keyword value directly follows
;;;;      a keyword-argument name, in a call, an evaluated plist, or a defclass
;;;;      :initform, quote the value, for example :status ':durable. Never quote
;;;;      keywords in unevaluated syntax positions: defclass :initarg names,
;;;;      case clause keys, member type specifiers, quoted configuration data,
;;;;      and macro metadata the macro quotes itself."
;;;;   - "Give functions and macros documentation strings."
;;;;
;;;; Every row is (a plist): name, matcher, severity, default, fix, opt-out,
;;;; message. The engine has one matcher per KIND (call-heads, lambda-arity,
;;;; docstring, keyword-quoting value, keyword-quoting unevaluated), and two
;;;; rows share a matcher; heads, names, severities, thresholds, messages and
;;;; the per-path opt-out live in the table. Tune a project by editing
;;;; .lintsprc, not by editing this engine.

(in-package #:lintsp)

;;; ------------------------------------------------------------- the data table

(defparameter *house-policy*
  (list
   (list :name "carcdr" :matcher :call-heads
         :heads '("CAR" "CDR")
         :rename '(("CAR" . "FIRST") ("CDR" . "REST"))
         :severity :note :default t :fix t :opt-out t
         :message "~A is the same function as ~A in Common Lisp; the project's style prefers FIRST/REST in application code"
         :description "CAR/CDR in application code; the project's style prefers FIRST/REST (fixable: they are the same functions, so the rename is a no-op; opt out per path with `opt-out carcdr GLOB`)")
   (list :name "no-defconstant" :matcher :call-heads
         :heads '("DEFCONSTANT" "DEFINE-CONSTANT")
         :severity :warning :default t :fix nil
         :message "~A is forbidden by the project's Lisp style; use DEFPARAMETER for reloadable policy or DEFVAR for state"
         :description "DEFCONSTANT/DEFINE-CONSTANT, forbidden by the project's Lisp style (not auto-fixed: DEFPARAMETER vs DEFVAR is a judgement)")
   (list :name "positional-arity-limit" :matcher :lambda-arity
         :definers '("DEFUN" "DEFMACRO" "DEFMETHOD" "LAMBDA")
         :limit 3
         :severity :note :default t :fix nil
         :message "~A ~A has ~D required positional parameters; the project's style uses keyword arguments for four or more"
         :description "a lambda list with more than 3 required positional parameters; the project's style uses keyword arguments for four or more (not auto-fixed: an API change; tune with `threshold positional-arity-limit N`)")
   (list :name "missing-docstring" :matcher :docstring
         :definers '("DEFUN" "DEFMETHOD" "DEFMACRO" "DEFCLASS")
         :severity :note :default t :fix nil :opt-out t
         :opt-out-patterns '("tests")
         :message "~A ~A has no documentation string; the project's style requires one"
         :description "a DEFUN/DEFMETHOD/DEFMACRO/DEFCLASS with no documentation string (not auto-fixed: writing it is the author's job; test trees are opted out by default, tune with `opt-out missing-docstring GLOB`)")
   (list :name "keyword-quoting" :matcher :kw-value-quote
         :severity :note :default t :fix t :opt-out t
         :message "keyword value ~A directly follows the keyword-argument name ~A; the project's style quotes it as ~A"
         :description "a bare keyword in an evaluated keyword-value position (a call argument, an evaluated plist, a defclass :initform or :default-initargs); the project's style quotes it (auto-fixed: a keyword self-evaluates, so in these evaluated positions ':X and :X are the same value and ' is inserted before the token; CL heads, macros and unevaluated positions are not suggested, and a position whose head is a macro known to the analysed set is reported without the fix, because a macro can read the raw form)")
   (list :name "keyword-quoting-in-unevaluated" :matcher :kw-unquoted
         :severity :warning :default t :fix nil
         :cases '("INITARG" "CASE") 
         :message "~A is quoted in the unevaluated ~A position; the project's style never quotes keywords there"
         :description "a keyword quoted in an unevaluated syntax position the project's style names: a defclass :initarg value, or a case clause key (not auto-fixed; member type specifiers and quoted configuration data are NOT detected because a reader cannot tell them from a legitimate MEMBER call or a quoted list)")))

;;; --------------------------------------------------------- per-run settings
;;; A .lintsprc table overrides the table without touching it: enable/disable
;;; select rows, threshold tunes a numeric row, opt-out adds a glob a row
;;; skips. Read from the current directory and beside each analysed path, the
;;; same way .lintspignore is.

(defstruct policy-settings limits optout)

(defvar *policy-settings* nil)

(defun policy-settings-current ()
  (or *policy-settings*
      (setf *policy-settings* (make-policy-settings :limits (make-hash-table :test #'equal)
                                                    :optout (make-hash-table :test #'equal)))))

;;; The .lintsprc reader and the token grammar live in cli.lisp, beside the
;;; OPTS structure they fill; see READ-RC-FILE / APPLY-POLICY-RC there.

;;; ------------------------------------------------------------------ helpers

(defun policy-row (name)
  (find name *house-policy* :key (lambda (r) (getf r :name)) :test #'string=))

(defun policy-opt-out-p (row path)
  (when (getf row :opt-out)
    (let ((pats (append (getf row :opt-out-patterns)
                        (gethash (getf row :name)
                                 (policy-settings-optout (policy-settings-current))))))
      (and pats (excluded-path-p path pats)))))

(defun policy-limit (row)
  (or (gethash (getf row :name) (policy-settings-limits (policy-settings-current)))
      (getf row :limit)))

(defun cl-name-p (name)
  "NAME names a symbol in the COMMON-LISP package (a built-in, not a project
function). Used to keep keyword-quoting away from (list :a :b) and friends."
  (and name (nth-value 1 (find-symbol name "CL"))))

(defun keyword-node (n) (and n (eq (node-kind n) :symbol) (keywordp (node-form n))))
(defun keyword-node-name (n) (and (keyword-node n) (symbol-name (node-form n))))

(defun definer-name (node)
  (or (node-atom-name (second (node-items node))) "?"))

(defun definer-lambda-list-node (node)
  (let ((items (node-items node)) (h (node-head node)))
    (cond ((string= h "LAMBDA") (second items))
          ((member h '("DEFUN" "DEFMACRO" "DEFSUBST" "DEFINE-COMPILER-MACRO") :test #'string=)
           (third items))
          ((member h '("DEFMETHOD" "DEFGENERIC") :test #'string=)
           (find-if (lambda (c) (eq (node-kind c) :list)) (cddr items)))
          (t nil))))

(defun required-positional-count (ll)
  "Count of required positional parameters: plain symbols before the first
lambda-list keyword. A (var init) pair is optional, so it is not counted."
  (let ((n 0))
    (dolist (x (node-items ll))
      (let ((nm (node-atom-name x)))
        (when nm
          (if (char= (char nm 0) #\&) (return) (incf n)))))
    n))

;;; -------------------------------------------------------------- the matchers

(defun match-call-heads (row node model ctx out)
  (declare (ignore ctx))
  (let ((h (node-head node)))
    (when (and h
               (member h (getf row :heads) :test #'string=)
               (not (gethash node (fm-quoted-nodes model))))
      (emit (make-diagnostic (getf row :name) (getf row :severity)
                             (file-model-path model) (node-line node) (node-col node)
                             (format nil (getf row :message) h
                                     (or (cdr (assoc h (getf row :rename) :test #'string=)) nil)))
            out))))

(defun match-lambda-arity (row node model ctx out)
  (declare (ignore ctx))
  (when (and (member (node-head node) (getf row :definers) :test #'string=)
             (not (gethash node (fm-quoted-nodes model))))
    (let* ((ll (definer-lambda-list-node node))
           (n (and ll (eq (node-kind ll) :list) (required-positional-count ll))))
      (when (and n (> n (policy-limit row)))
        (emit (make-diagnostic (getf row :name) (getf row :severity)
                               (file-model-path model) (node-line node) (node-col node)
                               (format nil (getf row :message)
                                       (string-downcase (node-head node)) (definer-name node) n))
              out)))))

(defun definer-docstring-p (node)
  (let* ((h (node-head node)) (items (node-items node)))
    (cond
      ((string= h "DEFCLASS")
       (let ((d (nth 4 items))) (and d (eq (node-kind d) :string))))
      (t (let ((ll (definer-lambda-list-node node)))
           (when ll
             (let* ((pos (position ll items)) (next (and pos (nth (1+ pos) items))))
               (and next (eq (node-kind next) :string)))))))))

(defun match-docstring (row node model ctx out)
  (declare (ignore ctx))
  (when (and (member (node-head node) (getf row :definers) :test #'string=)
             (not (gethash node (fm-quoted-nodes model))))
    (let ((ll (definer-lambda-list-node node)))
      (when (and ll (not (definer-docstring-p node)))
        (emit (make-diagnostic (getf row :name) (getf row :severity)
                               (file-model-path model) (node-line node) (node-col node)
                               (format nil (getf row :message)
                                       (string-downcase (node-head node)) (definer-name node)))
              out)))))

;;; A keyword in an EVALUATED keyword-value position self-evaluates, so :X and
;;; ':X are the same value there. The fix inserts one ' immediately before the
;;; keyword token, covering exactly the token span. The finding and its edit are
;;; built together (KW-PROPOSAL), so an edit can only exist where the rule
;;; reports, and never in the positions the rule excludes (CL heads, macros,
;;; unevaluated syntax). Where the form's head is a macro known to the analysed
;;; set the edit is withheld and the finding stands alone (report-only): a macro
;;; can read the raw form, so the quote is not provably value-preserving there.

(defun kw-quote-edit (model node)
  "The insertion of ' immediately before keyword NODE, covering exactly the token
span: START = END = the first character of the token."
  (when (keyword-node node)
    (multiple-value-bind (s e) (node-span (file-model-src model) node)
      (declare (ignore e))
      (make-edit :path (file-model-path model) :line (node-line node)
                 :rule "keyword-quoting" :start s :end s :text "'"))))

(defun kw-proposal (row model node message &optional (fixable t))
  "A keyword-quoting proposal: (RULE SEVERITY LINE COL MESSAGE EDITS). EDITS is
empty only when FIXABLE is false - a macro-headed position, kept report-only."
  (list (getf row :name) (getf row :severity) (node-line node) (node-col node)
        message (if fixable (list (kw-quote-edit model node)) nil)))

(defun propose-kw-value (row v key-name model)
  (when (keyword-node v)
    (list (kw-proposal row model v
                       (format nil (getf row :message) (symbol-name (node-form v))
                               key-name (concatenate 'string "'" (symbol-name (node-form v))))))))

(defun propose-keyword-run (row items model)
  "Proposals for every keyword that sits in a VALUE slot of a maximal run of
consecutive keywords in a call's argument list: the odd positions from the run's
start."
  (let ((i 1) (n (length items)) (out nil))
    (loop while (< i n) do
      (if (keyword-node (nth i items))
          (let ((start i))
            (loop while (and (< i n) (keyword-node (nth i items))) do (incf i))
            (loop for j from (1+ start) below i by 2
                  for v = (nth j items) do
                    (when (keyword-node v)
                      (push (kw-proposal row model v
                                         (format nil (getf row :message)
                                                 (symbol-name (node-form v))
                                                 (symbol-name (node-form (nth (1- j) items)))
                                                 (concatenate 'string "'" (symbol-name (node-form v)))))
                            out))))
          (incf i)))
    (nreverse out)))

(defun propose-slot-options (row node model fixable)
  "In a slot definition, a keyword that is the value of an evaluated option
(:initform or :default-initargs). FIXABLE is false when the enclosing head is a
macro known to the analysed set: the finding stands, the quote is not applied."
  (let ((items (node-items node)) (i 1) (n (length (node-items node))) (out nil))
    (loop while (< i (1- n)) do
      (let ((opt (nth i items)) (val (nth (1+ i) items)))
        (when (and (keyword-node opt) (keyword-node val)
                   (member (keyword-node-name opt) '("INITFORM" "DEFAULT-INITARGS")
                           :test #'string=))
          (dolist (p (propose-kw-value row val (concatenate 'string ":" (string-downcase (keyword-node-name opt))) model))
            (unless fixable (setf (sixth p) nil))
            (push p out))))
      (incf i 2))
    (nreverse out)))

(defparameter *unevaluated-op-heads*
  '("CASE" "ECASE" "CCASE" "TYPECASE" "ETYPECASE" "COND" "QUOTE" "FUNCTION")
  "Call-like heads whose keyword arguments are syntax, not evaluated values.")

(defparameter *slot-option-keywords*
  '("INITFORM" "INITARG" "INITARGS" "ACCESSOR" "READER" "WRITER" "TYPE" "DOCUMENTATION"
    "ALLOCATION" "DEFAULT-INITARGS")
  "The slot-option names a DEFCLASS/DEFSTRUCT slot list uses. A node whose head is a
slot NAME and whose second element is one of these is a slot definition, not a
call - (state :initform :idle :initarg :state) must not read :state as a keyword
argument value.")

(defun propose-kw-value-quote (row node model ctx)
  "Proposals for every keyword-quoting finding in NODE. The rule's own predicate:
CHECK emits these, and the fix applies their edits, so the two cannot disagree."
  (let ((h (node-head node)) (form (node-form node)))
    (when (and h (not (gethash node (fm-quoted-nodes model))))
      (let ((macros (ctx-macro-names ctx)))
        (cond
          ;; a slot definition: option names live at odd positions. Flag the
          ;; VALUE of :initform / :default-initargs only; :initarg is a name.
          ((and (symbolp (car form)) (not (keywordp (car form)))
                (keyword-node (second (node-items node)))
                (member (keyword-node-name (second (node-items node)))
                        *slot-option-keywords* :test #'string=))
           (propose-slot-options row node model (not (call-head-macro-p h macros))))
          ;; a keyword-headed option form: the value of :initform or
          ;; :default-initargs is evaluated.
          ((and (keywordp (car form)) (member h '("INITFORM" "DEFAULT-INITARGS") :test #'string=))
           (if (string= h "INITFORM")
               (loop for v in (cdr (node-items node))
                     append (propose-kw-value row v ":initform" model))
               (propose-keyword-run row (node-items node) model)))
          ;; a call: a plain operator that is not a CL builtin, a macro (whose
          ;; keyword metadata it may quote itself), or unevaluated syntax.
          ((and (symbolp (car form)) (not (keywordp (car form)))
                (not (cl-name-p h))
                (not (member h *unevaluated-op-heads* :test #'string=))
                (not (call-head-macro-p h macros)))
           (propose-keyword-run row (node-items node) model)))))))

(defun match-kw-value-quote (row node model ctx out)
  (emit-proposals (propose-kw-value-quote row node model ctx) model out))

(defun quote-keyword-node (n)
  "N is a literal (QUOTE :kw) form; return the keyword node, else NIL."
  (when (quoted-keyword-node-p n) (second (node-items n))))

(defun match-kw-unquoted (row node model ctx out)
  (declare (ignore ctx))
  (let ((h (node-head node)))
    (when h
      (cond
        ;; (:initarg ':foo) — the initarg name is unevaluated; the quote is wrong.
        ((string= h "INITARG")
         (dolist (a (cdr (node-items node)))
           (let ((k (quote-keyword-node a)))
             (when k
               (emit (make-diagnostic (getf row :name) (getf row :severity)
                                      (file-model-path model) (node-line a) (node-col a)
                                      (format nil (getf row :message) (node-text (file-model-src model) k)
                                              ":initarg"))
                     out)))))
        ;; case-family clause keys are unevaluated; ':foo as a key is wrong.
        ((member h '("CASE" "ECASE" "CCASE" "TYPECASE" "ETYPECASE") :test #'string=)
         (dolist (clause (cddr (node-items node)))
           (when (eq (node-kind clause) :list)
             (let ((key (first (node-items clause))))
               (cond
                 ((quote-keyword-node key) (flag-case-key row key model out))
                 ((and key (eq (node-kind key) :list))
                  (dolist (k (node-items key)) (flag-case-key row k model out))))))))))))

(defun flag-case-key (row key model out)
  (let ((k (quote-keyword-node key)))
    (when k
      (emit (make-diagnostic (getf row :name) (getf row :severity)
                             (file-model-path model) (node-line key) (node-col key)
                             (format nil (getf row :message)
                                     (node-text (file-model-src model) k) "case clause key"))
            out))))

;;; ------------------------------------------------------------------ engine

(defun policy-check-rule (name model ctx out)
  (let* ((row (policy-row name))
         (fn (and row (case (getf row :matcher)
                       (:call-heads #'match-call-heads)
                       (:lambda-arity #'match-lambda-arity)
                       (:docstring #'match-docstring)
                       (:kw-value-quote #'match-kw-value-quote)
                       (:kw-unquoted #'match-kw-unquoted)))))
    (when (and row fn (not (policy-opt-out-p row (file-model-path model))))
      (dolist (node (fm-list-nodes model))
        (handler-case (funcall fn row node model ctx out)
          (error () nil))))))

;;; --------------------------------------------------------------- fix (carcdr)

(defun policy-fix-edits (models)
  "The carcdr rename: replace the operator token CAR/CDR by FIRST/REST. The two
are the same function in Common Lisp, so the rename is provably a no-op."
  (let ((row (policy-row "carcdr")) (edits nil))
    (when (getf row :fix)
      (dolist (m models)
        (unless (policy-opt-out-p row (file-model-path m))
          (let ((src (file-model-src m)) (quoted (fm-quoted-nodes m)))
            (dolist (node (fm-list-nodes m))
              (let* ((h (node-head node))
                     (rename (and h (cdr (assoc h (getf row :rename) :test #'string=)))))
                (when (and rename (not (gethash node quoted))
                           (node-symbol-node (first (node-items node))))
                  (multiple-value-bind (s e) (node-span src (first (node-items node)))
                    (let ((raw (node-text src (first (node-items node)))))
                      (push (make-edit :path (file-model-path m) :line (node-line node)
                                       :rule "carcdr" :start s :end e
                                       :text (if (string= raw (string-downcase raw))
                                                 (string-downcase rename) rename))
                            edits))))))))))
    edits))

;;; ---------------------------------------------------- fix (keyword-quoting)
;;; Insert ' before a keyword in an evaluated keyword-value position. The edits
;;; come from the rule's own proposal function - the same one CHECK emits from -
;;; with the macro table built from the analysed set, exactly as the SIMPLIFICATION
;;; fixes do. A keyword self-evaluates, so the quote is value-preserving where the
;;; rule reports; a macro-headed position yields a proposal with no edit and is
;;; therefore never rewritten.

(defun policy-kw-quote-fix-edits (models)
  (let ((row (policy-row "keyword-quoting")) (edits nil))
    (when (getf row :fix)
      (let ((ctx (make-ctx :macros (defmacro-names-of models))))
        (dolist (m models)
          (unless (policy-opt-out-p row (file-model-path m))
            (dolist (node (fm-list-nodes m))
              (setf edits (append (proposal-edits (propose-kw-value-quote row node m ctx))
                                  edits)))))))
    edits))

;;; ----------------------------------------------------------- rule registry

;; defrule is a macro, so the table cannot drive it directly; the constructor is
;; called in a loop. The table is still the single source of each row's name,
;; severity, default and description.
(dolist (row *house-policy*)
  (let ((r (make-rule :name (getf row :name) :scope :file
                      :severity (getf row :severity) :default (getf row :default)
                      :description (getf row :description))))
    (setf *rules* (remove (getf row :name) *rules* :key #'rule-name :test #'string=))
    (push r *rules*)))

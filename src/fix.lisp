;;;; lintsp — `fix`: apply the rewrites that are provably safe and local.
;;;;
;;;; A fix is proposed only when it is (a) local to the analysed source, (b)
;;;; provable from what the reader sees, and (c) semantically a no-op or an
;;;; explicit two-site change. Anything the reader cannot prove — a reordering,
;;;; an API decision, a name-dispatched handler, a policy — is left alone, and
;;;; the rule says so in its own description.
;;;;
;;;; Text splices are collected, an edit that overlaps one already accepted in
;;;; the same pass is refused rather than reordered, the rest are applied, and
;;;; the whole thing re-runs to a fixpoint. --dry-run prints and writes nothing.
;;;;
;;;; Deliberately not auto-fixed, each for a reason the rule's own description
;;;; carries: quadratic-append (the rewrite reorders or needs an nreverse at the
;;;; use site), dead-definition (name-dispatched handlers), optional-and-key and
;;;; long-function / deep-nesting (API and design changes), duplicated-literal-
;;;; table (which side is right is a judgement), defstruct-after-use (structural:
;;;; reordering or an .asd edit), defparameter-named-like-constant (a project
;;;; policy). reader-error is not a rule at all — the host reader refused the
;;;; form, so there is nothing read to rewrite.

(in-package #:lintsp)

;;; EDIT is defined in core.lisp, before the rule modules that build edits.

(defparameter *fix-max-passes* 10)

;;; ------------------------------------------------------------ edit rendering

(defun one-line (s)
  (substitute #\Space #\Newline
              (substitute #\Space #\Return (or s ""))))

(defun snippet (src a b)
  (one-line (subseq src a (min b (length src)))))

(defun trim-back (src e)
  "E of [_,E) with trailing whitespace removed. The reader consumes one
delimiter past a datum, so a node's END can sit past the token on the next line."
  (let ((e (min e (length src))))
    (loop while (and (> e 0)
                     (member (char src (1- e)) '(#\Space #\Tab #\Newline #\Return #\Page)))
          do (decf e))
    e))

;;; ------------------------------------------------------------------ fix (a)
;;; Delete a (declare (ignore X)) whose X the body then READS as a variable.
;;; The declaration is a lie; dropping it changes nothing a compiler would do
;;; with correct code. The rule's own predicate is reused, so the fix and the
;;; finding can never disagree.

(defun false-ignore-edits (model)
  (let ((edits nil))
    (dolist (node (fm-list-nodes model))
      (when (node-is node "DECLARE")
        (let ((refs (sibling-body-refs node (fm-list-nodes model)))
              (bad nil))
          (dolist (spec (cdr (node-items node)))
            (when (and (node-is spec "IGNORE") (node-aligned spec))
              (let ((names (remove nil (mapcar #'node-sym-name (cdr (node-items spec))))))
                (when (and names (every (lambda (n) (member n refs :test #'string=)) names))
                  (push (make-edit :path (file-model-path model) :line (node-line spec)
                                   :rule "ignore-then-read"
                                   :start (node-start spec) :end (node-end spec)
                                   :text "")
                        bad)))))
          (let ((specs (cdr (node-items node))))
            (cond
              ;; every clause of the declaration is false: drop the DECLARE
              ((and bad specs (= (length bad) (length specs)))
               (setf edits
                     (cons (make-edit :path (file-model-path model) :line (node-line node)
                                      :rule "ignore-then-read"
                                      :start (node-start node) :end (node-end node)
                                      :text "")
                           edits)))
              (bad (setf edits (append bad edits))))))))
    edits))

;;; ------------------------------------------------------------------ fix (b)
;;; internal-symbol-leak: narrow PKG::SYM to PKG:SYM. The rewrite is sound only
;;; when SYM really is external in PKG, and the fix can prove that ONLY from a
;;; DEFPACKAGE in the analysed set whose :export clause ALREADY names SYM. The
;;; original two-site version also appended the export; that is what broke slope:
;;; the DEFPACKAGE it edited was a generated copy (src/ash.lisp, installed by the
;;; project's flake), so the rewrite manufactured an external the real ASH
;;; package never declared, and the build read `ash:*builtins*` as a package
;;; error. An export the fix itself adds is not proof, so the fix never adds one.
;;; A reference whose package is absent from the set, or whose symbol is not
;;; already exported, is REFUSED (recorded, report-only).
;;;
;;; RESOLVE CHECK: every surviving narrowing is re-read from the defining file's
;;; source and the symbol confirmed external there; if it cannot be confirmed the
;;; edit is dropped and the refusal recorded.

(defvar *leak-skip-packages*
  '("CL" "COMMON-LISP" "CL-USER" "KEYWORD" "LINTSP"))

(defun leak-package-paths (models)
  "Hash of package name -> paths that declare or extend it, from MODELS: a
DEFPACKAGE form, or a top-level (EXPORT ...) call naming the package."
  (let ((h (make-hash-table :test #'equal)))
    (flet ((note (pname path)
             (unless (or (null pname) (zerop (length pname)))
               (pushnew path (gethash pname h) :test #'string=))))
      (dolist (m models)
        (let ((own (file-model-package m)) (path (file-model-path m)))
          (dolist (n (top-level-forms (file-model-nodes m)))
            (let ((f (node-form n)))
              (cond
                ((and (consp f) (equal (form-symbol-name (car f)) "DEFPACKAGE"))
                 (note (string-upcase (or (form-symbol-name (second f)) "")) path))
                ((and (consp f) (equal (form-symbol-name (car f)) "EXPORT") (cdr f))
                 (note (or (and (cddr f) (quoted-export-package (third f))) own) path))))))))
    h))

(defun resolve-leak-narrow (pkg sym paths)
  "T when SYM is external in PKG per a FRESH read of PATHS' source text. The
re-read is the proof; a remembered export set, or an export the fix proposed to
add, is not."
  (and paths
       (let ((fresh (package-export-table
                     (mapcar #'build-file-model (remove-duplicates paths :test #'string=)))))
         (gethash sym (gethash pkg fresh)))))

(defun leak-narrow-edit (m node pos raw)
  "The splice that drops one colon. The splice covers exactly the token: a
node's START/END can include surrounding trivia the reader consumed."
  (let ((off (search raw (file-model-src m) :start2 (node-start node)
                     :end2 (min (node-end node) (length (file-model-src m))))))
    (when off
      (make-edit :path (file-model-path m) :line (node-line node)
                 :rule "internal-symbol-leak"
                 :start off :end (+ off (length raw))
                 :text (concatenate 'string (subseq raw 0 pos) ":"
                                    (subseq raw (+ pos 2)))))))

(defun leak-edits (models)
  "Narrowing edits for the internal-symbol-leak findings whose symbol the analysed
set proves is external. Records a refusal for every one it will not rewrite. Two
gates, both required: the package's DEFPACKAGE is in the analysed set and already
exports the symbol, and a re-read of the defining source confirms it."
  (let ((sets (package-export-table models))
        (paths (leak-package-paths models))
        (cands nil))
    (dolist (m models)
      (let ((own (file-model-package m)) (path (file-model-path m)))
        (dolist (node (fm-all-nodes m))
          (when (eq (node-kind node) :symbol)
            (let ((raw (node-raw node)))
              (when (and (stringp raw) (search "::" raw))
                (let* ((pos (search "::" raw))
                       (pkg (string-upcase (subseq raw 0 pos)))
                       (sym (string-upcase (subseq raw (+ pos 2))))
                       (set (gethash pkg sets)))
                  (cond
                    ((or (string= pkg (or own ""))
                         (member pkg *leak-skip-packages* :test #'string=)
                         (and (>= (length pkg) 3) (string= (subseq pkg 0 3) "SB-")))
                     nil)                     ; not a cross-project leak
                    ((null set)
                     (record-fix-refusal path (node-line node) "internal-symbol-leak"
                       (format nil "no DEFPACKAGE for ~A in the analysed set, so ~A cannot be proved external"
                               pkg sym)))
                    ((not (gethash sym set))
                     (record-fix-refusal path (node-line node) "internal-symbol-leak"
                       (format nil "the analysed DEFPACKAGE for ~A does not export ~A; narrowing would create an external it never declared"
                               pkg sym)))
                    (t
                     (let ((e (leak-narrow-edit m node pos raw)))
                       (when e (push (list e pkg sym) cands))))))))))))
    ;; RESOLVE CHECK: re-read the defining source and confirm, or refuse.
    (let ((kept nil))
      (dolist (c (nreverse cands))
        (destructuring-bind (e pkg sym) c
          (if (resolve-leak-narrow pkg sym (gethash pkg paths))
              (push e kept)
              (record-fix-refusal (edit-path e) (edit-line e) "internal-symbol-leak"
                (format nil "resolve check failed: a fresh read of the DEFPACKAGE source does not show ~A exported from ~A"
                        sym pkg)))))
      (nreverse kept))))
;;; ------------------------------------------------------------------ fix (c)
;;; Delete an unused LET/LET* binding, but only when dropping the binding cannot
;;; drop an effect. Two guards: the init form must be a literal, a quoted form,
;;; or a plain symbol (no call, no side effect), and the NAME must be a plain
;;; unqualified lexical name that nothing in the analysed set declares special —
;;; a special variable's binding IS the effect a caller's dynamic read depends
;;; on, so (let ((yason:true t)) (yason:parse ...)) must never be touched. A
;;; lone binding is left alone too: deleting it would leave an empty (let ()).
;;; Everything refused here is still reported by unused-binding.

(defun side-effect-free-p (form)
  (cond ((consp form) (equal (form-symbol-name (car form)) "QUOTE"))
        ((symbolp form) (not (keywordp form)))
        ((or (numberp form) (stringp form) (characterp form)) t)
        (t nil)))

(defun specials-of (models)
  "Hash of every special variable name a DEFVAR/DEFPARAMETER/DEFCONSTANT in
MODELS declares."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (m models)
      (dolist (n (top-level-forms (file-model-nodes m)))
        (multiple-value-bind (kind name line) (top-level-def n)
          (declare (ignore line))
          (when (and name
                     (member kind '("DEFVAR" "DEFPARAMETER" "DEFCONSTANT") :test #'string=))
            (setf (gethash name h) t)))))
    h))

(defun unused-let-edits (model specials)
  (let ((edits nil))
    (dolist (node (fm-list-nodes model))
      (let ((h (node-head node)))
        (when (member h '("LET" "LET*") :test #'string=)
          (let* ((binds (second (node-form node)))
                 (bind-node (node-child node 1))
                 (body (cddr (node-form node))))
            (when (and bind-node (proper-list-p binds) (> (length binds) 1))
              (let ((refs (make-hash-table :test #'equal)))
                (dolist (b body) (dolist (n (refs-of b)) (incf (gethash n refs 0))))
                (when (string= h "LET*")
                  (dolist (b binds)
                    (when (consp b)
                      (dolist (init (cdr b))
                        (dolist (n (refs-of init)) (incf (gethash n refs 0)))))))
                (let ((declared-ignore (list nil)))
                  (dolist (b body) (collect-ignores b declared-ignore))
                  (loop for b in binds
                        for bn in (node-items bind-node)
                        when (and bn (consp b) (symbolp (first b)))
                          do (let* ((name (symbol-name (first b)))
                                    (name-node (if (eq (node-kind bn) :symbol)
                                                   bn (first (node-items bn))))
                                    ;; a package-qualified binding (yason:true) is
                                    ;; not a lexical name we can reason about
                                    (qualified (and name-node
                                                    (search ":" (or (node-raw name-node) ""))))
                                    (init (second b)))
                               (when (and (not (gethash name refs))
                                          (not (member name (car declared-ignore) :test #'string=))
                                          (not (char= (char name 0) #\_))
                                          (not (and (char= (char name 0) #\*)
                                                    (char= (char name (1- (length name))) #\*)))
                                          (not qualified)
                                          (not (gethash name specials))
                                          (side-effect-free-p init))
                                 (push (make-edit :path (file-model-path model)
                                                  :line (node-line bn)
                                                  :rule "unused-binding"
                                                  :start (node-start bn) :end (node-end bn)
                                                  :text "")
                                       edits)))))))))))
    edits))

;;; ------------------------------------------------------------------ the pass

(defun collect-fix-edits (models &optional order)
  (let ((edits (leak-edits models))
        (specials (specials-of models)))
    (dolist (m models)
      (setf edits (append edits (false-ignore-edits m)
                          (unused-let-edits m specials))))
    (append edits (simplification-fix-edits models order) (policy-fix-edits models)
            (policy-kw-quote-fix-edits models))))

(defun expand-deletion (src start end)
  "Widen a deletion [START,END) over the whitespace it leaves behind. The span is
first trimmed to the form's own text (a node's START/END include trivia the reader
consumed), then the form's line indentation is taken, and the newline too when the
form stood alone on its line. Never crosses into another line's text.
Returns (values START END)."
  (let ((s start) (e (min end (length src))))
    (loop while (and (< s e) (member (char src s) '(#\Space #\Tab #\Newline #\Return #\Page)))
          do (incf s))
    (setf e (trim-back src e))
    (loop while (and (> s 0) (member (char src (1- s)) '(#\Space #\Tab))) do (decf s))
    (let ((n (length src)))
      (loop while (and (< e n) (member (char src e) '(#\Space #\Tab))) do (incf e))
      (when (and (< e n) (char= (char src e) #\Newline)
                 (or (zerop s) (char= (char src (1- s)) #\Newline)))
        (incf e)))
    (values s e)))

(defun fix-file (src edits)
  "Apply EDITS to SRC. Returns (values NEW-SRC APPLIED REFUSED), APPLIED in
ascending position. An edit that overlaps one already accepted in this pass is
refused, never reordered; splices are applied from the highest offset down, so an
accepted edit never moves a lower one."
  (let* ((sorted (sort (copy-list edits) #'< :key #'edit-start))
         (accepted nil) (refused nil) (limit nil))
    (dolist (e (reverse sorted))
      (if (and limit (> (edit-end e) limit))
          (push e refused)
          (progn (push e accepted) (setf limit (edit-start e)))))
    ;; ACCEPTED came out of a descending walk, so it is already ascending.
    (let ((out src))
      (dolist (e (reverse accepted))
        (let ((s (edit-start e)) (en (edit-end e)))
          (when (zerop (length (edit-text e)))
            (multiple-value-setq (s en) (expand-deletion out s en)))
          (setf out (concatenate 'string
                                 (subseq out 0 s) (edit-text e) (subseq out en)))))
      (values out accepted (nreverse refused)))))

(defun write-source (path text)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :external-format :utf-8)
    (write-string text out)))

(defun report-edit (path src e)
  (format t "~A:~D: ~A: ~A~@[ -> ~A~]~%"
          (short-name path) (edit-line e) (edit-rule e)
          (one-line (snippet src (edit-start e) (edit-end e)))
          (if (zerop (length (edit-text e))) nil (edit-text e))))

(defun print-fix-refusals ()
  "Print the guard refusals collected in *fix-refusals*, once each, and return the
count. A refusal is a rewrite the fix declined because it is not provably safe;
it is reported, never silently dropped."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (r (reverse (car *fix-refusals*)))
      (destructuring-bind (path line rule reason) r
        (let ((k (list path line rule reason)))
          (unless (gethash k seen)
            (setf (gethash k seen) t)
            (format t "~A:~D: ~A: REFUSED (not proven safe: ~A)~%"
                    (short-name path) line rule reason)))))
    (hash-table-count seen)))

(defun cmd-fix (o)
  (unless (opts-paths o) (usage-error "fix needs at least one path"))
  (let* ((*policy-settings* (make-policy-settings :limits (make-hash-table :test #'equal)
                                                  :optout (make-hash-table :test #'equal)))
         (*fix-refusals* (list nil))
         (patterns (progn (apply-policy-rc o) (exclude-patterns o)))
         (dry (opts-fix-dry o))
         (files (handler-case
                    (multiple-value-bind (f n o2) (collect-lisp-files (opts-paths o) patterns)
                      (declare (ignore n o2))
                      f)
                  (error (e) (usage-error "~A" e))))
         (order (multiple-value-bind (ord src)
                    (build-order (remove-if-not (lambda (p) (string-equal (pathname-type p) "lisp")) files)
                                 (remove-if-not (lambda (p) (string-equal (pathname-type p) "asd")) files)
                                 (opts-order-file o) (length (opts-paths o)))
                  (declare (ignore src))
                  ord))
         (*relative* (opts-relative o))
         (*root-prefix* (and *relative* (common-prefix files)))
         (total 0) (refused-total 0) (changed-files 0))
    (when (null files) (usage-error "no .lisp files under the given paths"))
    (labels ((run-once ()
               (let* ((models (mapcar #'build-file-model files))
                      (edits (collect-fix-edits models order))
                      (by-path (make-hash-table :test #'equal)))
                 (dolist (e edits) (push e (gethash (edit-path e) by-path)))
                 (let ((applied-any nil))
                   (loop for m in models
                         for path = (file-model-path m)
                         for es = (gethash path by-path) do
                     (when es
                       (let ((src (file-model-src m)))
                         (multiple-value-bind (new applied refused) (fix-file src es)
                           (dolist (e (sort (copy-list applied) #'< :key #'edit-line))
                             (report-edit path src e)
                             (incf total)
                             (setf applied-any t))
                           (dolist (e refused)
                             (incf refused-total)
                             (format t "~A:~D: ~A: REFUSED (overlaps an accepted edit): ~A~%"
                                     (short-name path) (edit-line e) (edit-rule e)
                                     (one-line (snippet src (edit-start e) (edit-end e)))))
                           (unless (or dry (null applied) (string= new src))
                             (write-source path new)
                             (incf changed-files))))))
                   applied-any))))
      (if dry
          (run-once)
          (loop repeat *fix-max-passes* while (run-once)))
      (let ((guard-refused (print-fix-refusals)))
        (if dry
            (format t "~D proposed edit~:P~@[, ~D refused (not proven safe)~] (dry run; nothing written)~%"
                    total guard-refused)
            (when (or (plusp total) (plusp refused-total) (plusp guard-refused))
              (format t "~D edit~:P applied in ~D file~:P~@[ (~D refused)~]~@[ (~D refused, not proven safe)~]~%"
                      total changed-files refused-total refused-total guard-refused)))
        (uiop-exit (if (or (plusp total) (plusp refused-total) (plusp guard-refused)) 1 0))))))

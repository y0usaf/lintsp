;;;; selfcheck.lisp — read lintsp's own sources with its own reader and report
;;;; any top-level form that looks wrong: a file that does not read cleanly, or a
;;;; form whose span is implausibly long (the signature of a missing close paren
;;;; swallowing the forms that follow it).
;;;;
;;;;   sbcl --non-interactive --load src/package.lisp --load src/core.lisp \
;;;;        --load tools/selfcheck.lisp
;;;;
;;;; Exits 1 when it finds something, 0 when clean.

(load "src/package.lisp")
(load "src/core.lisp")

(defun paren-depth (node src)
  "Net paren depth of NODE's source text with strings and comments blanked."
  (let ((s (lintsp::scrub (subseq src (lintsp::node-start node) (lintsp::node-end node)))))
    (let ((d 0))
      (loop for c across s do
        (case c (#\( (incf d)) (#\) (decf d))))
      d)))

(let ((bad 0)
      (limit 100))
  (dolist (path (lintsp::collect-lisp-files (list ".")))
    (multiple-value-bind (nodes src err) (lintsp::read-file path)
      (declare (ignore src))
      (dolist (d err)
        (incf bad)
        (format t "~&READ-ERROR  ~A  ~A~%" path (diag-message d)))
      (dolist (n nodes)
        (unless (zerop (paren-depth n))
          (incf bad)
          (format t "~&UNBALANCED  ~A:~D  ~A net depth ~D~%"
                  path (lintsp::node-line n) (lintsp::node-head n) (paren-depth n)))
        (let ((span (- (or (lintsp::node-end-line n) (lintsp::node-line n))
                        (lintsp::node-line n))))
          (when (> span limit)
            (incf bad)
            (format t "~&SUSPECT     ~A:~D  ~A spans ~D lines (check the parens before it)~%"
                    path (lintsp::node-line n) (lintsp::node-head n) span))))))
  (if (zerop bad)
      (progn (format t "~&selfcheck: clean~%") (sb-ext:exit :code 0))
      (progn (format t "~&selfcheck: ~D problem~:P~%" bad) (sb-ext:exit :code 1))))

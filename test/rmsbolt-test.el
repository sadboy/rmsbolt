;;; rmsbolt-test.el --- Tests for rmsbolt  -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for rmsbolt

;;; Code:

(require 'el-mock nil t)
(require 'rmsbolt)
(require 'rust-ts-mode nil t)

(ert-deftest sanity-check-ert ()
  "Check if ERT is working. :)"
  (should t))

(defun test-asm-preprocessor (pre post)
  "Tests the asm preprocessor on the current buffer."
  (insert-file-contents pre)
  (setq-local buffer-file-name (expand-file-name default-directory))
  (let
      ((source
        (string-trim
         (string-join
          (rmsbolt--process-asm-lines (current-buffer)
                                      (split-string (buffer-string) "\n" t))
          "\n")))
       (target
        (with-temp-buffer
          (insert-file-contents post)
          (string-trim
           (buffer-string)))))
    (should (string= source target))))

;;;; Filtration tests

(ert-deftest filter-tests-all-c ()
  "Test if assembly filteration in c is working."
  (with-temp-buffer
    (setq-local rmsbolt-disassemble nil)
    (setq-local rmsbolt-filter-comment-only t)
    (setq-local rmsbolt-filter-directives t)
    (setq-local rmsbolt-filter-labels t)
    (test-asm-preprocessor "test/rmsbolt-c-pre1.s" "test/rmsbolt-c-post1.s")))
(ert-deftest filter-tests-none-c ()
  "Test if assembly filteration in c is working."
  (with-temp-buffer
    (setq-local rmsbolt-disassemble nil)
    (setq-local rmsbolt-filter-comment-only nil)
    (setq-local rmsbolt-filter-directives nil)
    (setq-local rmsbolt-filter-labels nil)
    (test-asm-preprocessor "test/rmsbolt-c-pre1.s" "test/rmsbolt-c-post2.s")))
(ert-deftest filter-tests-dir-c ()
  "Test if assembly filteration in c is working."
  (with-temp-buffer
    (setq-local rmsbolt-disassemble nil)
    (setq-local rmsbolt-filter-comment-only nil)
    (setq-local rmsbolt-filter-directives t)
    (setq-local rmsbolt-filter-labels nil)
    (test-asm-preprocessor "test/rmsbolt-c-pre1.s" "test/rmsbolt-c-post3.s")))
(ert-deftest filter-tests-weak-ref-c ()
  "Test if assembly filteration in c is working."
  (with-temp-buffer
    (setq-local rmsbolt-disassemble nil)
    (setq-local rmsbolt-filter-comment-only nil)
    (setq-local rmsbolt-filter-directives t)
    (setq-local rmsbolt-filter-labels t)
    (test-asm-preprocessor "test/rmsbolt-c-pre2.s" "test/rmsbolt-c-post4.s")))

;;;; Demangler tests

(ert-deftest demangler-test-disabled ()
  (with-temp-buffer
    (setq-local rmsbolt-demangle nil)
    (should
     (string-empty-p
      (rmsbolt--demangle-command
       ""
       (make-rmsbolt-lang :demangler nil)
       (current-buffer))))))

(ert-deftest demangler-test-invalid-demangler ()
  (with-temp-buffer
    (setq-local rmsbolt-demangle t)
    (should
     (string-empty-p
      (rmsbolt--demangle-command
       ""
       (make-rmsbolt-lang :demangler nil)
       (current-buffer))))))

(ert-deftest demangler-test-not-path ()
  (with-temp-buffer
    (setq-local rmsbolt-demangle t)
    (should
     (string-empty-p
      (rmsbolt--demangle-command
       ""
       (make-rmsbolt-lang :demangler "nonsense-binary-name-not-on-path")
       (current-buffer))))))

(ert-deftest demangler-test-valid-demangler ()
  ;; Assumes test is on the path!
  (with-temp-buffer
    (setq-local rmsbolt-demangle t)
    (should
     (string-match-p
      (regexp-opt '("test"))
      (rmsbolt--demangle-command
       ""
       (make-rmsbolt-lang :demangler "test")
       (current-buffer))))))

;;;; Output chunk navigation tests

(defmacro rmsbolt-test--with-chunk-buffers (&rest body)
  "Run BODY with a fake rmsbolt output buffer and its source buffer.
The output buffer has eight lines.  Source line 5 maps to the chunks on
lines 1-2 and 6-7, and source line 6 maps to line 4.  The mapping is
stored out of order to exercise sorting."
  (declare (indent 0) (debug (body)))
  `(let ((src-buffer (generate-new-buffer " *rmsbolt-test-src*"))
         (output-buffer (get-buffer-create rmsbolt-output-buffer)))
     (unwind-protect
         (progn
           (with-current-buffer src-buffer
             (setq rmsbolt-line-mapping (make-hash-table :test #'eq))
             (puthash 5 '((6 . 7) (1 . 2)) rmsbolt-line-mapping)
             (puthash 6 '((4 . 4)) rmsbolt-line-mapping)
             (setq-local rmsbolt-mode t)
             (insert "one\ntwo\nthree\nfour\nfive\nsix\n"))
           (with-current-buffer output-buffer
             (erase-buffer)
             (insert "a\nb\nc\nd\ne\nf\ng\nh\n")
             (setq rmsbolt-src-buffer src-buffer)
             (dolist (chunk '((1 2 5) (4 4 6) (6 7 5)))
               (goto-char (point-min))
               (forward-line (1- (nth 0 chunk)))
               (dotimes (_ (1+ (- (nth 1 chunk) (nth 0 chunk))))
                 (add-text-properties (line-beginning-position)
                                      (line-end-position)
                                      `(rmsbolt-src-line ,(nth 2 chunk)))
                 (forward-line 1)))
             (goto-char (point-min)))
           ,@body)
       (kill-buffer src-buffer)
       (kill-buffer output-buffer))))

(defun rmsbolt-test--output-line ()
  "Return the line number at point in the fake rmsbolt output buffer."
  (with-current-buffer rmsbolt-output-buffer
    (line-number-at-pos)))

(ert-deftest output-chunks-sorted-test ()
  (rmsbolt-test--with-chunk-buffers
    (with-current-buffer rmsbolt-output-buffer
      (should (equal (rmsbolt--output-chunks src-buffer 5) '((1 . 2) (6 . 7))))
      (should (equal (rmsbolt--output-chunks src-buffer 6) '((4 . 4))))
      (should-not (rmsbolt--output-chunks src-buffer 42)))
    ;; Sorting must not change the stored mapping.
    (with-current-buffer src-buffer
      (should (equal (gethash 5 rmsbolt-line-mapping) '((6 . 7) (1 . 2)))))))

(ert-deftest output-chunk-forward-and-backward-test ()
  (rmsbolt-test--with-chunk-buffers
    (with-current-buffer rmsbolt-output-buffer
      (goto-char (point-min))
      (rmsbolt-output-forward-chunk)
      (should (= (line-number-at-pos) 6))
      (rmsbolt-output-forward-chunk)
      (should (= (line-number-at-pos) 1))
      (rmsbolt-output-backward-chunk)
      (should (= (line-number-at-pos) 6))
      (rmsbolt-output-backward-chunk)
      (should (= (line-number-at-pos) 1)))))

(ert-deftest output-chunk-single-chunk-test ()
  (rmsbolt-test--with-chunk-buffers
    (with-current-buffer rmsbolt-output-buffer
      (goto-char (point-min))
      (forward-line 3)
      (rmsbolt-output-forward-chunk)
      (should (= (line-number-at-pos) 4))
      (rmsbolt-output-backward-chunk)
      (should (= (line-number-at-pos) 4)))))

(ert-deftest output-chunk-source-buffer-test ()
  (rmsbolt-test--with-chunk-buffers
    (with-current-buffer src-buffer
      ;; Source line 5 has two chunks.  The output starts focused on line 1.
      (goto-char (point-min))
      (forward-line 4)
      (rmsbolt-output-forward-chunk)
      (should (= (rmsbolt-test--output-line) 6))
      (rmsbolt-output-forward-chunk)
      (should (= (rmsbolt-test--output-line) 1))
      (rmsbolt-output-backward-chunk)
      (should (= (rmsbolt-test--output-line) 6))
      ;; A focus outside the chunks starts at the first chunk.
      (with-current-buffer rmsbolt-output-buffer
        (goto-char (point-min))
        (forward-line 2))
      (rmsbolt-output-forward-chunk)
      (should (= (rmsbolt-test--output-line) 1))
      ;; A single-chunk source line does not move the focus.
      (with-current-buffer rmsbolt-output-buffer
        (goto-char (point-min))
        (forward-line 2))
      (goto-char (point-min))
      (forward-line 5)
      (rmsbolt-output-forward-chunk)
      (should (= (rmsbolt-test--output-line) 3))
      ;; Unmapped source lines signal an error.
      (goto-char (point-min))
      (should-error (rmsbolt-output-forward-chunk) :type 'user-error)
      (should-error (rmsbolt-output-backward-chunk) :type 'user-error))))

(ert-deftest output-chunk-keybindings-test ()
  (should (eq (lookup-key rmsbolt-mode-map (kbd "C-c C-n"))
              #'rmsbolt-output-forward-chunk))
  (should (eq (lookup-key rmsbolt-mode-map (kbd "C-c C-p"))
              #'rmsbolt-output-backward-chunk)))

(ert-deftest output-chunk-end-of-line-test ()
  (rmsbolt-test--with-chunk-buffers
    (with-current-buffer rmsbolt-output-buffer
      (goto-char (point-min))
      (goto-char (line-end-position))
      (rmsbolt-output-forward-chunk)
      (should (= (line-number-at-pos) 6)))))

(ert-deftest output-chunk-no-live-source-test ()
  (rmsbolt-test--with-chunk-buffers
    (should-not (rmsbolt--output-chunks nil 5))
    (with-current-buffer rmsbolt-output-buffer
      (setq rmsbolt-src-buffer nil)
      (goto-char (point-min))
      (should-error (rmsbolt-output-forward-chunk) :type 'user-error)
      (should-error (rmsbolt-output-backward-chunk) :type 'user-error))
    (let ((dead-src (generate-new-buffer " *rmsbolt-test-dead-src*")))
      (with-current-buffer rmsbolt-output-buffer
        (setq rmsbolt-src-buffer dead-src))
      (kill-buffer dead-src)
      (should-not (rmsbolt--output-chunks dead-src 5))
      (with-current-buffer rmsbolt-output-buffer
        (goto-char (point-min))
        (should-error (rmsbolt-output-forward-chunk) :type 'user-error)
        (should-error (rmsbolt-output-backward-chunk) :type 'user-error)))))

(ert-deftest output-chunk-displayed-output-test ()
  (rmsbolt-test--with-chunk-buffers
    (save-window-excursion
      (display-buffer rmsbolt-output-buffer '(nil (inhibit-same-window . t)))
      (let ((output-window (get-buffer-window rmsbolt-output-buffer 'visible)))
        (should output-window)
        (with-current-buffer src-buffer
          (goto-char (point-min))
          (forward-line 4)
          (set-window-point output-window (point-min))
          (set-window-start output-window (point-min))
          (rmsbolt-output-forward-chunk)
          (should (= (with-current-buffer rmsbolt-output-buffer
                       (line-number-at-pos (window-point output-window)))
                     6))
          (rmsbolt-output-forward-chunk)
          (should (= (with-current-buffer rmsbolt-output-buffer
                       (line-number-at-pos (window-point output-window)))
                     1)))))))

(ert-deftest output-chunk-unmapped-position-test ()
  (rmsbolt-test--with-chunk-buffers
    (with-current-buffer rmsbolt-output-buffer
      (goto-char (point-min))
      (forward-line 2)
      (should-error (rmsbolt-output-forward-chunk) :type 'user-error)
      (should-error (rmsbolt-output-backward-chunk) :type 'user-error))))

(ert-deftest output-chunk-outside-output-buffer-test ()
  (rmsbolt-test--with-chunk-buffers
    (with-temp-buffer
      (should-error (rmsbolt-output-forward-chunk) :type 'user-error)
      (should-error (rmsbolt-output-backward-chunk) :type 'user-error))
    ;; `rmsbolt-mode' in a buffer that is not linked to the output buffer.
    (with-temp-buffer
      (setq-local rmsbolt-mode t)
      (should-error (rmsbolt-output-forward-chunk) :type 'user-error)
      (should-error (rmsbolt-output-backward-chunk) :type 'user-error))))

;;;; Output header tests

(ert-deftest output-header-compiler-name-test ()
  (should (equal (rmsbolt--header-compiler-name "gcc -O2") "gcc"))
  (should (equal (rmsbolt--header-compiler-name "/usr/bin/clang++ -O3") "clang++"))
  (should (equal (rmsbolt--header-compiler-name "ccache gcc -O2") "gcc"))
  (should (equal (rmsbolt--header-compiler-name
                  "env CARGO=/usr/bin/cargo rustc --crate-name foo src/lib.rs")
                 "rustc"))
  (should-not (rmsbolt--header-compiler-name ""))
  (should-not (rmsbolt--header-compiler-name nil)))

(defconst rmsbolt-test--header-specs
  '(("^-O" . nil)
    ("^-march$" . "^[^-]")
    ("^-march" . nil)
    ("^-mtune" . nil)
    ("^-std=" . nil)
    ("^-flto" . nil)
    ("^-target$" . "^[^-]")
    ("^-target" . nil)
    ("^-C$" . "^\\(opt-level\\|target-cpu\\|target-feature\\|lto\\)")
    ("^-C\\(opt-level\\|target-cpu\\|target-feature\\|lto\\)" . nil))
  "Argument specs shared by the output header tests.")

(ert-deftest output-header-args-test ()
  (should (equal (rmsbolt--header-args
                  "gcc -O2 -march=native -Wall -I/usr/include -o out.s src.c"
                  rmsbolt-test--header-specs)
                 "-O2 -march=native"))
  (should (equal (rmsbolt--header-args
                  "clang++ -O3 -march native -std=c++20"
                  rmsbolt-test--header-specs)
                 "-O3 -march native -std=c++20"))
  (should (equal (rmsbolt--header-args
                  (concat "rustc --crate-name foo src/lib.rs"
                          " -C opt-level=3 -C target-cpu=native"
                          " -C embed-bitcode=no -C debuginfo=2")
                  rmsbolt-test--header-specs)
                 "-C opt-level=3 -C target-cpu=native"))
  (should (equal (rmsbolt--header-args
                  "rustc -Copt-level=2 -Cdebuginfo=0"
                  rmsbolt-test--header-specs)
                 "-Copt-level=2"))
  (should (equal (rmsbolt--header-args
                  "gcc -flto=thin -flto -target x86_64-linux"
                  rmsbolt-test--header-specs)
                 "-flto=thin -flto -target x86_64-linux"))
  (should (equal (rmsbolt--header-args
                  "gcc -march native -march=x86-64"
                  rmsbolt-test--header-specs)
                 "-march native -march=x86-64"))
  ;; A value flag without a matching value must not swallow the next flag.
  (should (equal (rmsbolt--header-args
                  "gcc -march -O2"
                  rmsbolt-test--header-specs)
                 "-march -O2"))
  (should (equal (rmsbolt--header-args
                  "gcc -Wall -Wextra -o out.s"
                  rmsbolt-test--header-specs)
                 ""))
  (should (equal (rmsbolt--header-args "" rmsbolt-test--header-specs) "")))

(ert-deftest output-header-args-regexp-pairs-test ()
  "Cover the LEADING and FOLLOW regexp pair semantics."
  (let ((specs '(("^-C$" . "^opt-level=.*")
                 ("^-flto$" . nil)
                 ("^-std=.*$" . nil))))
    ;; A matching follow argument is kept as the value.
    (should (equal (rmsbolt--header-args "rustc -C opt-level=1 src.rs" specs)
                   "-C opt-level=1"))
    ;; A non-matching follow argument drops both arguments.
    (should (equal (rmsbolt--header-args
                    "rustc -C embed-bitcode=no src.rs" specs)
                   ""))
    ;; An anchored leading regexp matches the exact argument only.
    (should (equal (rmsbolt--header-args "gcc -flto" specs) "-flto"))
    (should (equal (rmsbolt--header-args "gcc -flto=thin" specs) ""))
    ;; An argument with an attached value matches its own regexp.
    (should (equal (rmsbolt--header-args "gcc -std=c++17" specs)
                   "-std=c++17"))))

(ert-deftest output-header-arg-specs-test ()
  (with-temp-buffer
    (setq major-mode 'c-mode)
    (should (equal (rmsbolt--header-arg-specs (current-buffer))
                   (cdr (assq t rmsbolt-output-header-arg-alist))))
    (setq major-mode 'rust-mode)
    (should (equal (rmsbolt--header-arg-specs (current-buffer))
                   (cdr (assq 'rust-mode rmsbolt-output-header-arg-alist))))
    (should (equal (rmsbolt--header-args
                    "rustc -C opt-level=2 -C debuginfo=2 src.rs"
                    (rmsbolt--header-arg-specs (current-buffer)))
                   "-C opt-level=2"))
    ;; Tree-sitter modes fall back to their non-tree-sitter entry.
    (setq major-mode 'rust-ts-mode)
    (should (equal (rmsbolt--header-arg-specs (current-buffer))
                   (cdr (assq 'rust-mode rmsbolt-output-header-arg-alist))))
    (setq major-mode 'zig-mode)
    (should (equal (rmsbolt--header-args
                    "zig build-obj -O ReleaseFast -mcpu=baseline"
                    (rmsbolt--header-arg-specs (current-buffer)))
                   "-O ReleaseFast -mcpu=baseline"))
    (setq major-mode 'some-unknown-mode)
    (should (equal (rmsbolt--header-arg-specs (current-buffer))
                   (cdr (assq t rmsbolt-output-header-arg-alist)))))
  (let ((rmsbolt-output-header-arg-alist
         '((t ("^-O" . nil)) (c-mode ("^-f" . nil)))))
    (with-temp-buffer
      (setq major-mode 'c-mode)
      (should (equal (rmsbolt--header-arg-specs (current-buffer))
                     '(("^-f" . nil)))))))

(ert-deftest output-header-line-test ()
  (should (equal (rmsbolt--output-header-line
                  "gcc -O2 -march=native -o out.s src.c"
                  rmsbolt-test--header-specs)
                 ";; compiled with: gcc -O2 -march=native"))
  (should (equal (rmsbolt--output-header-line
                  "rustc -C opt-level=3"
                  rmsbolt-test--header-specs)
                 ";; compiled with: rustc -C opt-level=3"))
  (should-not (rmsbolt--output-header-line nil rmsbolt-test--header-specs))
  (should-not (rmsbolt--output-header-line "" rmsbolt-test--header-specs)))

(ert-deftest output-header-custom-args-test ()
  (let ((rmsbolt-output-header-arg-alist '((t ("^-f" . nil)))))
    (with-temp-buffer
      (should (equal (rmsbolt--output-header-line
                      "gcc -O2 -fno-exceptions"
                      (rmsbolt--header-arg-specs (current-buffer)))
                     ";; compiled with: gcc -fno-exceptions")))))

(ert-deftest output-header-insert-shifts-mapping-test ()
  (let ((src-buffer (generate-new-buffer " *rmsbolt-test-header-src*"))
        (output-buffer (generate-new-buffer " *rmsbolt-test-header-output*")))
    (unwind-protect
        (progn
          (with-current-buffer src-buffer
            (setq-local rmsbolt-command "clang -O3 -march=x86-64-v3")
            (setq rmsbolt-line-mapping (make-hash-table :test #'eq))
            (puthash 5 '((1 . 2) (6 . 7)) rmsbolt-line-mapping))
          (with-current-buffer output-buffer
            (asm-mode)
            (insert "a\nb\nc\nd\ne\nf\ng\nh\n")
            (rmsbolt--finalize-output-buffer src-buffer)
            (should (equal (buffer-substring-no-properties
                            (point-min) (point-max))
                           (concat ";; compiled with: clang -O3 -march=x86-64-v3\n"
                                   "a\nb\nc\nd\ne\nf\ng\nh\n")))
            (should buffer-read-only)
            (should view-mode))
          (with-current-buffer src-buffer
            (should (equal (gethash 5 rmsbolt-line-mapping)
                           '((2 . 3) (7 . 8))))))
      (kill-buffer src-buffer)
      (kill-buffer output-buffer))))

(ert-deftest output-header-disabled-test ()
  (let ((src-buffer (generate-new-buffer " *rmsbolt-test-header-src*"))
        (output-buffer (generate-new-buffer " *rmsbolt-test-header-output*"))
        (rmsbolt-output-header nil))
    (unwind-protect
        (progn
          (with-current-buffer src-buffer
            (setq-local rmsbolt-command "gcc -O2")
            (setq rmsbolt-line-mapping (make-hash-table :test #'eq))
            (puthash 5 '((1 . 2)) rmsbolt-line-mapping))
          (with-current-buffer output-buffer
            (asm-mode)
            (insert "a\nb\n")
            (rmsbolt--finalize-output-buffer src-buffer)
            (should (equal (buffer-string) "a\nb\n"))
            (should buffer-read-only)
            (should view-mode))
          (with-current-buffer src-buffer
            (should (equal (gethash 5 rmsbolt-line-mapping) '((1 . 2))))))
      (kill-buffer src-buffer)
      (kill-buffer output-buffer))))

(ert-deftest output-header-end-to-end-test ()
  (let* ((temp-dir (make-temp-file "rmsbolt-header-test-" t))
         (rmsbolt--temp-dir temp-dir)
         (rmsbolt-output-buffer "*rmsbolt-test-header-output*")
         (src-buffer (generate-new-buffer " *rmsbolt-test-header-src*"))
         (compilation-buffer (generate-new-buffer " *rmsbolt-test-header-compile*")))
    (unwind-protect
        (progn
          (with-current-buffer src-buffer
            (setq default-directory temp-dir)
            (insert "int main(void) { return 0; }\n")
            (setq-local rmsbolt-command "gcc -O2 -march=native")
            (setq-local rmsbolt-language-descriptor
                        (make-rmsbolt-lang :supports-asm t :supports-disass nil))
            (setq-local rmsbolt-disassemble nil)
            (setq-local rmsbolt-filter-directives nil)
            (setq-local rmsbolt-filter-labels nil)
            (setq-local rmsbolt-filter-comment-only nil))
          (with-temp-file (expand-file-name "rmsbolt.s" temp-dir)
            (insert "\t.text\n\t.globl\tmain\nmain:\n.LFB0:\n"
                    "\t.loc 1 2 0\n\tpush\trbp\n"
                    "\t.loc 1 3 0\n\tmov\teax, 1\n\tret\n"))
          (with-current-buffer compilation-buffer
            (setq default-directory temp-dir)
            (setq rmsbolt-src-buffer src-buffer))
          (cl-letf (((symbol-function 'rmsbolt-mode) #'ignore)
                    ((symbol-function 'display-buffer) #'ignore)
                    ((symbol-function 'run-at-time) #'ignore))
            (rmsbolt--handle-finish-compile compilation-buffer nil))
          (let ((output-buffer (get-buffer rmsbolt-output-buffer)))
            (should output-buffer)
            (with-current-buffer output-buffer
              (should (equal (buffer-substring-no-properties
                              (point-min) (line-end-position))
                             ";; compiled with: gcc -O2 -march=native"))
              (should buffer-read-only)
              (should view-mode))
            ;; Each mapping chunk must still start on a line that carries its
            ;; source line, which fails when the header is not accounted for.
            (with-current-buffer src-buffer
              (maphash
               (lambda (src-line chunks)
                 (dolist (chunk chunks)
                   (with-current-buffer output-buffer
                     (goto-char (point-min))
                     (forward-line (1- (car chunk)))
                     (should (= (get-text-property
                                 (line-beginning-position) 'rmsbolt-src-line)
                                src-line)))))
               rmsbolt-line-mapping)
              (should (equal (gethash 2 rmsbolt-line-mapping) '((7 . 7))))
              (should (equal (gethash 3 rmsbolt-line-mapping) '((9 . 10)))))))
      (kill-buffer src-buffer)
      (when (get-buffer rmsbolt-output-buffer)
        (kill-buffer (get-buffer rmsbolt-output-buffer)))
      (kill-buffer compilation-buffer)
      (delete-directory temp-dir t))))


;;;; Compile arg override tests

(defmacro rmsbolt-test--with-read-string (input &rest body)
  "Evaluate BODY with `read-string' returning INPUT."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'read-string) (lambda (&rest _) ,input)))
     ,@body))

(ert-deftest compile-arg-overrides-read-test ()
  (with-temp-buffer
    (setq major-mode 'c-mode)
    (rmsbolt-test--with-read-string "-O3 -march native"
      (should (equal (rmsbolt--read-compile-arg-overrides)
                     "-O3 -march native")))
    (rmsbolt-test--with-read-string "-std=c++17 -mtune=generic"
      (should (equal (rmsbolt--read-compile-arg-overrides)
                     "-std=c++17 -mtune=generic")))
    (rmsbolt-test--with-read-string ""
      (should (equal (rmsbolt--read-compile-arg-overrides) "")))
    ;; Uninteresting arguments are rejected.
    (rmsbolt-test--with-read-string "-O3 -Wall -I/usr/include"
      (should-error (rmsbolt--read-compile-arg-overrides) :type 'user-error)))
  (with-temp-buffer
    (setq major-mode 'rust-mode)
    (rmsbolt-test--with-read-string "-C opt-level=3 -C target-cpu=native"
      (should (equal (rmsbolt--read-compile-arg-overrides)
                     "-C opt-level=3 -C target-cpu=native")))
    (rmsbolt-test--with-read-string "-C opt-level=3 -C debuginfo=2"
      (should-error (rmsbolt--read-compile-arg-overrides)
                    :type 'user-error)))
  ;; A user supplied alist decides what is interesting.
  (let ((rmsbolt-output-header-arg-alist '((t ("^-f" . nil)))))
    (with-temp-buffer
      (setq major-mode 'c-mode)
      (rmsbolt-test--with-read-string "-fno-exceptions"
        (should (equal (rmsbolt--read-compile-arg-overrides)
                       "-fno-exceptions")))
      (rmsbolt-test--with-read-string "-O2"
        (should-error (rmsbolt--read-compile-arg-overrides)
                      :type 'user-error)))))

(ert-deftest compile-arg-overrides-apply-test ()
  (should (equal (rmsbolt--apply-arg-overrides
                  "gcc -g1 -S src.c -o out.s" "-O3 -march=native")
                 "gcc -g1 -S src.c -o out.s -O3 -march=native"))
  ;; Commands chained after the compiler invocation must not receive them.
  (should (equal (rmsbolt--apply-arg-overrides
                  "gcc -g1 -c src.c -o out && objdump -d out > out.s" "-O3")
                 "gcc -g1 -c src.c -o out -O3 && objdump -d out > out.s"))
  (should (equal (rmsbolt--apply-arg-overrides "gcc -O2" nil) "gcc -O2"))
  (should (equal (rmsbolt--apply-arg-overrides "gcc -O2" "") "gcc -O2")))

(ert-deftest output-header-args-overrides-test ()
  (should (equal (rmsbolt--header-args
                  "gcc -O2 -march=native -Wall" rmsbolt-test--header-specs
                  "-O3 -mtune=generic")
                 "-O2 -march=native -O3 -mtune=generic"))
  ;; Overrides pass through the same filtering as the command.
  (should (equal (rmsbolt--header-args
                  "gcc -O2" rmsbolt-test--header-specs "-Wall -O3")
                 "-O2 -O3"))
  ;; Without overrides the header is unchanged.
  (should (equal (rmsbolt--header-args
                  "gcc -O2" rmsbolt-test--header-specs)
                 "-O2"))
  (should (equal (rmsbolt--output-header-line
                  "gcc -O2" rmsbolt-test--header-specs "-O3 -march=native")
                 ";; compiled with: gcc -O2 -O3 -march=native")))

(ert-deftest compile-arg-overrides-end-to-end-test ()
  (let* ((temp-dir (make-temp-file "rmsbolt-override-test-" t))
         (rmsbolt--temp-dir temp-dir)
         (rmsbolt-output-buffer "*rmsbolt-test-override-output*")
         (src-buffer (generate-new-buffer " *rmsbolt-test-override-src*"))
         (compilation-buffer (generate-new-buffer
                              " *rmsbolt-test-override-compile*")))
    (unwind-protect
        (progn
          (with-current-buffer src-buffer
            (setq default-directory temp-dir)
            (insert "int main(void) { return 0; }\n")
            (setq-local rmsbolt-command "gcc -O2")
            (setq-local rmsbolt-compile-arg-overrides "-O3 -march=native")
            (setq-local rmsbolt-language-descriptor
                        (make-rmsbolt-lang :supports-asm t :supports-disass nil))
            (setq-local rmsbolt-disassemble nil)
            (setq-local rmsbolt-filter-directives nil)
            (setq-local rmsbolt-filter-labels nil)
            (setq-local rmsbolt-filter-comment-only nil))
          (with-temp-file (expand-file-name "rmsbolt.s" temp-dir)
            (insert "\t.text\nmain:\n\t.loc 1 2 0\n\tpush\trbp\n\tret\n"))
          (with-current-buffer compilation-buffer
            (setq default-directory temp-dir)
            (setq rmsbolt-src-buffer src-buffer))
          (cl-letf (((symbol-function 'rmsbolt-mode) #'ignore)
                    ((symbol-function 'display-buffer) #'ignore)
                    ((symbol-function 'run-at-time) #'ignore))
            (rmsbolt--handle-finish-compile compilation-buffer nil))
          (let ((output-buffer (get-buffer rmsbolt-output-buffer)))
            (should output-buffer)
            (with-current-buffer output-buffer
              (should (equal (buffer-substring-no-properties
                              (point-min) (line-end-position))
                             ";; compiled with: gcc -O2 -O3 -march=native"))))
          ;; The overrides stay in effect for the buffer.
          (with-current-buffer src-buffer
            (should (equal rmsbolt-compile-arg-overrides
                           "-O3 -march=native"))))
      (kill-buffer src-buffer)
      (when (get-buffer rmsbolt-output-buffer)
        (kill-buffer (get-buffer rmsbolt-output-buffer)))
      (kill-buffer compilation-buffer)
      (delete-directory temp-dir t))))

(ert-deftest compile-arg-overrides-in-compile-command-test ()
  (let* ((temp-dir (make-temp-file "rmsbolt-override-cmd-test-" t))
         (rmsbolt--temp-dir temp-dir)
         (src-file (expand-file-name "rmsbolt.c" temp-dir))
         (src-buffer (generate-new-buffer " *rmsbolt-test-override-cmd-src*"))
         (cmd nil))
    (unwind-protect
        (progn
          (with-temp-file src-file
            (insert "int main(void) { return 0; }\n"))
          (with-current-buffer src-buffer
            (setq default-directory temp-dir)
            (setq buffer-file-name src-file)
            (insert-file-contents src-file)
            (set-buffer-modified-p nil)
            (setq-local rmsbolt-command "gcc -O2")
            (setq-local rmsbolt-language-descriptor
                        (make-rmsbolt-lang
                         :supports-asm t :supports-disass nil
                         :compile-cmd-function
                         (lambda (&key _src-buffer)
                           (concat (buffer-local-value 'rmsbolt-command
                                                       (current-buffer))
                                   " -S rmsbolt.c -o rmsbolt.s"))))
            (cl-letf (((symbol-function 'rmsbolt--gen-temp) #'ignore)
                      ((symbol-function 'compilation-start)
                       (lambda (command &rest _)
                         (setq cmd command)
                         (current-buffer)))
                      ((symbol-function 'display-buffer) #'ignore))
              (rmsbolt-compile "-O3 -march=native")
              (should (equal cmd "gcc -O2 -S rmsbolt.c -o rmsbolt.s -O3 -march=native"))
              (should (equal rmsbolt-compile-arg-overrides "-O3 -march=native"))
              ;; A later compilation keeps the overrides.
              (rmsbolt-compile)
              (should (equal cmd
                             "gcc -O2 -S rmsbolt.c -o rmsbolt.s -O3 -march=native"))
              ;; A prefix argument prompts for and replaces the overrides.
              (let ((current-prefix-arg '(4)))
                (rmsbolt-test--with-read-string "-Os"
                  (call-interactively #'rmsbolt-compile)))
              (should (equal cmd "gcc -O2 -S rmsbolt.c -o rmsbolt.s -Os"))
              (should (equal rmsbolt-compile-arg-overrides "-Os"))
              ;; An empty answer removes the overrides.
              (let ((current-prefix-arg '(4)))
                (rmsbolt-test--with-read-string ""
                  (call-interactively #'rmsbolt-compile)))
              (should (equal cmd "gcc -O2 -S rmsbolt.c -o rmsbolt.s"))
              (should-not rmsbolt-compile-arg-overrides))))
      (kill-buffer src-buffer)
      (delete-directory temp-dir t))))
;;;; Cargo integration tests

(ert-deftest cargo-extract-and-clean-cmd-test ()
  (let* ((sample-output
          (concat
           "   Compiling foo v0.1.0 (/tmp/ws/crates/foo)\n"
           "     Running `CARGO=/usr/bin/cargo "
           "rustc --crate-name build_script_build --edition=2024 build.rs "
           "--crate-type bin --emit=dep-info,link -C extra-filename=-111 "
           "--out-dir /tmp/ws/target/debug/build/foo-111`\n"
           "     Running `/tmp/ws/target/debug/build/foo-111/build-script-build`\n"
           "     Running `CARGO=/usr/bin/cargo CARGO_BIN_EXE_my-bin=/tmp/ws/target/debug/my-bin "
           "CARGO_PKG_DESCRIPTION='A `quoted` description\nwith newline' "
           "OUT_DIR=/tmp/ws/target/debug/build/foo-123/out "
           "rustc --crate-name foo_lib --edition=2024 src/lib.rs "
           "--error-format=json --json=diagnostic-rendered-ansi,artifacts "
           "--crate-type lib --emit=dep-info,metadata,link "
           "-C embed-bitcode=no -C debuginfo=2 "
           "--check-cfg 'cfg(feature, values(\"default\", \"loader\"))' "
           "-C metadata=abc -C extra-filename=-def "
           "--out-dir /tmp/ws/target/debug/deps "
           "-C incremental=/tmp/ws/target/debug/incremental "
           "-L dependency=/tmp/ws/target/debug/deps "
           "--print crate-name -C lto=thin`\n"
           "foo_lib\n"))
         (extracted (rmsbolt--extract-cargo-rustc-cmd sample-output "foo-lib"))
         (cleaned (rmsbolt--clean-cargo-rustc-cmd extracted))
         (build-extracted (rmsbolt--extract-cargo-rustc-cmd sample-output t))
         (build-cleaned (rmsbolt--clean-cargo-rustc-cmd build-extracted)))
    (should (equal (rmsbolt-split--tokenize cleaned)
                   '("env"
                     "CARGO=/usr/bin/cargo"
                     "CARGO_BIN_EXE_my-bin=/tmp/ws/target/debug/my-bin"
                     "CARGO_PKG_DESCRIPTION='A `quoted` description\nwith newline'"
                     "OUT_DIR=/tmp/ws/target/debug/build/foo-123/out"
                     "rustc"
                     "--crate-name" "foo_lib"
                     "--edition=2024"
                     "src/lib.rs"
                     "--crate-type" "lib"
                     "-C" "embed-bitcode=no"
                     "--check-cfg" "'cfg(feature, values(\"default\", \"loader\"))'"
                     "-C" "metadata=abc"
                     "-L" "dependency=/tmp/ws/target/debug/deps")))
    (should (equal (rmsbolt-split--tokenize build-cleaned)
                   '("env"
                     "CARGO=/usr/bin/cargo"
                     "rustc"
                     "--crate-name" "build_script_build"
                     "--edition=2024"
                     "build.rs"
                     "--crate-type" "bin")))))

(ert-deftest cargo-find-target-test ()
  (let* ((tmp-root (make-temp-file "rmsbolt-cargo-test-" t))
         (src-dir (expand-file-name "src" tmp-root))
         (tests-dir (expand-file-name "tests" tmp-root))
         (sub-crate-dir (expand-file-name "crates/sub" tmp-root))
         (sub-src-dir (expand-file-name "src" sub-crate-dir))
         (target-dir (expand-file-name "target" tmp-root))
         (deps-dir (expand-file-name "debug/deps" target-dir))
         (manifest (expand-file-name "Cargo.toml" tmp-root))
         (sub-manifest (expand-file-name "Cargo.toml" sub-crate-dir))
         (lib-rs (expand-file-name "lib.rs" src-dir))
         (main-rs (expand-file-name "main.rs" src-dir))
         (sub-rs (expand-file-name "asdl.rs" src-dir))
         (cli-rs (expand-file-name "cli.rs" src-dir))
         (dep-only-rs (expand-file-name "dep_only.rs" src-dir))
         (test-rs (expand-file-name "mini_sql.rs" tests-dir))
         (build-rs (expand-file-name "build.rs" tmp-root))
         (member-lib-rs (expand-file-name "lib.rs" sub-src-dir))
         (member-mod-rs (expand-file-name "helper.rs" sub-src-dir)))
    (unwind-protect
        (progn
          (make-directory src-dir t)
          (make-directory tests-dir t)
          (make-directory sub-src-dir t)
          (make-directory deps-dir t)
          (with-temp-file manifest (insert "[package]\nname = \"demo\"\n"))
          (with-temp-file sub-manifest (insert "[package]\nname = \"sub\"\n"))
          (with-temp-file lib-rs
            (insert "// mod cli;\nlet _ = \"mod cli;\";\npub mod asdl;\n"))
          (with-temp-file main-rs (insert "mod cli;\nfn main() {}\n"))
          (with-temp-file sub-rs (insert "pub fn f() {}\n"))
          (with-temp-file cli-rs (insert "pub fn g() {}\n"))
          (with-temp-file dep-only-rs (insert "pub fn d() {}\n"))
          (with-temp-file test-rs (insert "#[test] fn t() {}\n"))
          (with-temp-file build-rs (insert "#[path = \"src/asdl.rs\"]\nmod asdl;\nfn main() {}\n"))
          (with-temp-file member-lib-rs (insert "pub mod helper;\n"))
          (with-temp-file member-mod-rs (insert "pub fn h() {}\n"))
          (with-temp-file (expand-file-name "demo_bin-1234abcd.d" deps-dir)
            (insert "target/debug/deps/demo_bin-1234abcd.d: src/main.rs src/cli.rs src/dep_only.rs\n"))
          (let ((metadata
                 `((workspace_root . ,tmp-root)
                   (target_directory . ,target-dir)
                   (packages
                    . [((name . "demo")
                        (manifest_path . ,manifest)
                        (targets
                         . [((name . "demo")
                             (kind . ["lib"])
                             (src_path . ,lib-rs))
                            ((name . "demo-bin")
                             (kind . ["bin"])
                             (src_path . ,main-rs))
                            ((name . "mini_sql")
                             (kind . ["test"])
                             (required-features . ["feat-a" "feat-b"])
                             (src_path . ,test-rs))
                            ((name . "build-script-build")
                             (kind . ["custom-build"])
                             (src_path . ,build-rs))]))
                       ((name . "sub")
                        (manifest_path . ,sub-manifest)
                        (targets
                         . [((name . "sub")
                             (kind . ["rlib"])
                             (src_path . ,member-lib-rs))]))]))))
            (should (equal (rmsbolt--cargo-target-args
                            (cdr (rmsbolt--cargo-find-target metadata lib-rs)))
                           '("--lib")))
            (should (equal (rmsbolt--cargo-target-args
                            (cdr (rmsbolt--cargo-find-target metadata sub-rs)))
                           '("--lib")))
            (should (equal (rmsbolt--cargo-target-args
                            (cdr (rmsbolt--cargo-find-target metadata main-rs)))
                           '("--bin" "demo-bin")))
            (should (equal (rmsbolt--cargo-target-args
                            (cdr (rmsbolt--cargo-find-target metadata cli-rs)))
                           '("--bin" "demo-bin")))
            (should (equal (rmsbolt--cargo-target-args
                            (cdr (rmsbolt--cargo-find-target metadata dep-only-rs)))
                           '("--bin" "demo-bin")))
            (should (equal (rmsbolt--cargo-target-args
                            (cdr (rmsbolt--cargo-find-target metadata test-rs)))
                           '("--test" "mini_sql" "--features" "feat-a,feat-b")))
            (should (rmsbolt--cargo-build-script-p
                     (cdr (rmsbolt--cargo-find-target metadata build-rs))))
            (should-not (rmsbolt--cargo-target-args
                         (cdr (rmsbolt--cargo-find-target metadata build-rs))))
            (should (equal (alist-get 'name (car (rmsbolt--cargo-find-target metadata member-lib-rs)))
                           "sub"))
            (should (equal (alist-get 'name (car (rmsbolt--cargo-find-target metadata member-mod-rs)))
                           "sub"))))
      (delete-directory tmp-root t))))

(ert-deftest cargo-handle-rust-compile-cmd-gating-test ()
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/nonexistent/src/lib.rs")
    (setq-local rmsbolt-command "rustc-custom")
    (setq-local rmsbolt-default-directory nil)
    (setq-local rmsbolt--default-variables '(rmsbolt-default-directory))
    (should-not (rmsbolt--handle-rust-compile-cmd (current-buffer)))
    (should (equal rmsbolt-command "rustc-custom"))
    (setq-local rmsbolt-command nil)
    (setq-local rmsbolt-default-directory "/tmp/custom-dir/")
    (setq-local rmsbolt--default-variables '(rmsbolt-command))
    (should-not (rmsbolt--handle-rust-compile-cmd (current-buffer)))
    (should (equal rmsbolt-default-directory "/tmp/custom-dir/"))))

(ert-deftest cargo-parse-compile-cmd-end-to-end-test ()
  (skip-unless (executable-find "cargo"))
  (let* ((tmp-root (make-temp-file "rmsbolt-cargo-e2e-" t))
         (src-dir (expand-file-name "src" tmp-root))
         (manifest (expand-file-name "Cargo.toml" tmp-root))
         (lib-rs (expand-file-name "lib.rs" src-dir)))
    (unwind-protect
        (progn
          (make-directory src-dir t)
          (with-temp-file manifest
            (insert "[package]\nname = \"e2e_demo\"\nversion = \"0.1.0\"\nedition = \"2021\"\n"))
          (with-temp-file lib-rs
            (insert "pub fn add(a: i32, b: i32) -> i32 { a + b }\n"))
          (let ((res1 (rmsbolt--parse-cargo-compile-cmd tmp-root lib-rs))
                (res2 (rmsbolt--parse-cargo-compile-cmd tmp-root lib-rs)))
            (should res1)
            (should (equal res1 res2))
            (should (equal (car res1) (file-name-as-directory (file-truename tmp-root))))
            (should (member "e2e_demo" (rmsbolt-split--tokenize (cadr res1))))
            (should (member "src/lib.rs" (rmsbolt-split--tokenize (cadr res1))))))
      (delete-directory tmp-root t))))


;;;; C/C++ compile_commands.json and compile_flags.txt tests

(ert-deftest c-compile-cmd-flags-and-commands-test ()
  (let* ((tmp-root (make-temp-file "rmsbolt-c-test-" t))
         (src-dir (expand-file-name "src" tmp-root))
         (build-dir (expand-file-name "build" tmp-root))
         (ccj-file (expand-file-name "compile_commands.json" tmp-root))
         (cft-file (expand-file-name "compile_flags.txt" tmp-root))
         (file-a (expand-file-name "a.c" src-dir))
         (file-b (expand-file-name "b.c" src-dir)))
    (unwind-protect
        (progn
          (make-directory src-dir t)
          (make-directory build-dir t)
          (with-temp-file file-a (insert "int a(void) { return 1; }\n"))
          (with-temp-file file-b (insert "int b(void) { return 2; }\n"))
          (with-temp-file cft-file
            (insert "  -I\n  include/  \n\n-O2\n-c\n-flto=thin\n-o\nignored.o\n"))
          (with-temp-buffer
            (setq-local buffer-file-name file-b)
            (setq-local rmsbolt-command "gcc")
            (setq-local rmsbolt-default-directory nil)
            (setq-local rmsbolt--default-variables
                        '(rmsbolt-default-directory rmsbolt-command))
            (should (rmsbolt--handle-c-compile-cmd (current-buffer)))
            (should (equal rmsbolt-default-directory
                           (file-name-as-directory tmp-root)))
            (should (equal rmsbolt-command
                           (format "gcc -I include/ -O2 %s" file-b))))
          (with-temp-file ccj-file
            (insert (format "[{\"directory\": %S, \"command\": %S, \"file\": %S}]"
                            build-dir
                            (format "clang -Wall -O3 -c -o a.o -flto %s" file-a)
                            file-a)))
          (with-temp-buffer
            (setq-local buffer-file-name file-a)
            (setq-local rmsbolt-command "gcc")
            (setq-local rmsbolt-default-directory nil)
            (setq-local rmsbolt--default-variables
                        '(rmsbolt-default-directory rmsbolt-command))
            (should (rmsbolt--handle-c-compile-cmd (current-buffer)))
            (should (equal rmsbolt-default-directory
                           (file-name-as-directory build-dir)))
            (should (equal rmsbolt-command
                           (format "clang -Wall -O3 %s" file-a))))
          (with-temp-buffer
            (setq-local buffer-file-name file-b)
            (setq-local rmsbolt-command "gcc")
            (setq-local rmsbolt-default-directory nil)
            (setq-local rmsbolt--default-variables
                        '(rmsbolt-default-directory rmsbolt-command))
            (should (rmsbolt--handle-c-compile-cmd (current-buffer)))
            (should (equal rmsbolt-default-directory
                           (file-name-as-directory tmp-root)))
            (should (equal rmsbolt-command
                           (format "gcc -I include/ -O2 %s" file-b)))))
      (delete-directory tmp-root t))))

(ert-deftest c-handle-compile-cmd-gating-test ()
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/nonexistent/src/main.c")
    (setq-local rmsbolt-command "gcc-custom")
    (setq-local rmsbolt-default-directory nil)
    (setq-local rmsbolt--default-variables '(rmsbolt-default-directory))
    (should-not (rmsbolt--handle-c-compile-cmd (current-buffer)))
    (should (equal rmsbolt-command "gcc-custom"))
    (setq-local rmsbolt-command nil)
    (setq-local rmsbolt-default-directory "/tmp/custom-dir/")
    (setq-local rmsbolt--default-variables '(rmsbolt-command))
    (should-not (rmsbolt--handle-c-compile-cmd (current-buffer)))
    (should (equal rmsbolt-default-directory "/tmp/custom-dir/"))))

;;;; Cargo ASM tests

(defun rmsbolt-test--rust-tree-sitter-available-p ()
  "Return non-nil if Rust tree-sitter support is available."
  (and (fboundp 'treesit-available-p)
       (treesit-available-p)
       (fboundp 'treesit-language-available-p)
       (treesit-language-available-p 'rust)))

(defun rmsbolt-test--rust-buffer (source &optional file)
  "Return a temporary Rust SOURCE buffer with optional FILE."
  (let ((buffer (generate-new-buffer " *rmsbolt-test-rust*")))
    (with-current-buffer buffer
      (insert source)
      (when file
        (setq buffer-file-name file))
      (rust-ts-mode)
      (rmsbolt--cargo-asm-ensure-parser))
    buffer))

(defmacro rmsbolt-test--with-rust-buffer (source &optional file &rest body)
  "Run BODY in a Rust SOURCE buffer with optional FILE."
  (declare (indent 2) (debug (form form &rest body)))
  `(let ((buffer (rmsbolt-test--rust-buffer ,source ,file)))
     (unwind-protect
         (with-current-buffer buffer
           ,@body)
       (kill-buffer buffer))))

(defun rmsbolt-test--rust-function-at (source marker &optional file)
  "Return the parsed Rust function at MARKER in SOURCE with optional FILE."
  (let ((buffer (rmsbolt-test--rust-buffer source file)))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (search-forward marker)
          (goto-char (match-beginning 0))
          (rmsbolt--cargo-asm-function-at-point))
      (kill-buffer buffer))))

(defun rmsbolt-test--function-by-display (display functions)
  "Return the function in FUNCTIONS with DISPLAY name."
  (cl-find display functions
           :key #'rmsbolt--cargo-asm-function-display-name
           :test #'equal))

(defconst rmsbolt-test--cargo-asm-rust-source
  (concat
   "pub mod sub {\n"
   "    pub fn bar() {}\n"
   "}\n"
   "\n"
   "struct Foo;\n"
   "impl Foo {\n"
   "    pub fn bar(&self) {}\n"
   "}\n"
   "\n"
   "struct Wrapper<T>(T);\n"
   "impl<T> Wrapper<T> {\n"
   "    pub fn unwrap_val(&self) {}\n"
   "}\n"
   "impl Wrapper<i32> {\n"
   "    pub fn concrete(&self) {}\n"
   "}\n"
   "\n"
   "trait MyTrait { fn trait_fn(&self); }\n"
   "impl MyTrait for Foo {\n"
   "    fn trait_fn(&self) {}\n"
   "}\n"
   "\n"
   "pub fn foo() {}\n"
   "pub fn outer() {\n"
   "    struct Local;\n"
   "    enum E { A }\n"
   "    fn inner() {}\n"
   "    let _ = Local;\n"
   "    let _ = E::A;\n"
   "}\n")
  "Rust source for cargo-asm function extraction tests.")

(defconst rmsbolt-test--cargo-asm-items
  '(((id . 0) (name . "demo::add"))
    ((id . 1) (name . "demo::add_one"))
    ((id . 2) (name . "demo::generic_add::<i32>"))
    ((id . 3) (name . "demo::generic_add::<u8>"))
    ((id . 4) (name . "demo::sub::bar"))
    ((id . 5) (name . "<demo::Foo>::bar"))
    ((id . 6) (name . "<demo::Wrapper<i32>>::unwrap_val"))
    ((id . 7) (name . "<demo::Wrapper<u8>>::unwrap_val"))
    ((id . 8) (name . "<demo::Wrapper<i32>>::concrete"))
    ((id . 9) (name . "<demo::Foo as demo::MyTrait>::trait_fn")))
  "Fake cargo-asm JSON items for matching tests.")

(ert-deftest cargo-asm-keybinding-test ()
  (should (eq (lookup-key rmsbolt-mode-map (kbd "C-c C-a"))
              #'rmsbolt-cargo-asm)))

(ert-deftest cargo-asm-function-extraction-test ()
  (skip-unless (rmsbolt-test--rust-tree-sitter-available-p))
  (rmsbolt-test--with-rust-buffer rmsbolt-test--cargo-asm-rust-source nil
    (let ((functions (rmsbolt--cargo-asm-functions)))
      (should (= (length functions) 8))
      (should (rmsbolt-test--function-by-display "sub::bar" functions))
      (should (rmsbolt-test--function-by-display "Foo::bar" functions))
      (should (rmsbolt-test--function-by-display "Wrapper<T>::unwrap_val" functions))
      (should (rmsbolt-test--function-by-display "Wrapper<i32>::concrete" functions))
      (should (rmsbolt-test--function-by-display "<Foo as MyTrait>::trait_fn" functions))
      (should (rmsbolt-test--function-by-display "foo" functions))
      (should (rmsbolt-test--function-by-display "outer" functions))
      (should (rmsbolt-test--function-by-display "outer::inner" functions))
      (should-not (rmsbolt-test--function-by-display "Local" functions))
      (should-not (rmsbolt-test--function-by-display "E" functions))
      (should (equal (rmsbolt--cargo-asm-function-qualifiers
                      (rmsbolt-test--function-by-display "Foo::bar" functions))
                     '("Foo")))
      (should (equal (rmsbolt--cargo-asm-function-qualifiers
                      (rmsbolt-test--function-by-display
                       "Wrapper<T>::unwrap_val" functions))
                     '("Wrapper")))
      (should (equal (rmsbolt--cargo-asm-function-qualifiers
                      (rmsbolt-test--function-by-display
                       "Wrapper<i32>::concrete" functions))
                     '("Wrapper<i32>")))
      (should (equal (rmsbolt--cargo-asm-function-qualifiers
                      (rmsbolt-test--function-by-display
                       "<Foo as MyTrait>::trait_fn" functions))
                     '("Foo" "MyTrait")))
      (goto-char (point-min))
      (search-forward "struct Local")
      (goto-char (match-beginning 0))
      (should (equal (rmsbolt--cargo-asm-function-name
                      (rmsbolt--cargo-asm-function-at-point))
                     "outer"))
      (goto-char (point-min))
      (search-forward "fn inner")
      (goto-char (match-beginning 0))
      (should (equal (rmsbolt--cargo-asm-function-name
                      (rmsbolt--cargo-asm-function-at-point))
                     "inner")))))

(ert-deftest cargo-asm-prompt-selection-test ()
  (skip-unless (rmsbolt-test--rust-tree-sitter-available-p))
  (rmsbolt-test--with-rust-buffer "pub fn foo() {}\npub fn bar() {}\n" nil
    (let* ((functions (rmsbolt--cargo-asm-functions))
           (selected (rmsbolt--cargo-asm--prompt
                      (lambda (_prompt collection _predicate _require-match
                               _initial _history default)
                        (should (equal default "foo"))
                        (should (member "bar" collection))
                        "bar")
                      functions (car functions))))
      (should (equal (rmsbolt--cargo-asm-function-name selected) "bar")))))

(ert-deftest cargo-asm-file-module-stem-test ()
  (skip-unless (rmsbolt-test--rust-tree-sitter-available-p))
  (rmsbolt-test--with-rust-buffer "pub fn bar() {}\n"
      "/tmp/rmsbolt-cargo-asm-test/src/sub.rs"
    (let* ((function (car (rmsbolt--cargo-asm-functions))))
      (should (equal (rmsbolt--cargo-asm-function-display-name function)
                     "sub::bar"))
      (should (equal (rmsbolt--cargo-asm-function-modules function)
                     '("sub"))))))

(ert-deftest cargo-asm-nested-module-paths-test ()
  (skip-unless (rmsbolt-test--rust-tree-sitter-available-p))
  (rmsbolt-test--with-rust-buffer "pub fn bar() {}\n"
      "/tmp/rmsbolt-cargo-asm-test/src/foo/mod.rs"
    (let ((function (car (rmsbolt--cargo-asm-functions))))
      (should (equal (rmsbolt--cargo-asm-function-display-name function)
                     "foo::bar"))
      (should (equal (rmsbolt--cargo-asm-function-modules function)
                     '("foo")))))
  (rmsbolt-test--with-rust-buffer "pub fn bar() {}\n"
      "/tmp/rmsbolt-cargo-asm-test/src/foo/bar.rs"
    (let ((function (car (rmsbolt--cargo-asm-functions))))
      (should (equal (rmsbolt--cargo-asm-function-display-name function)
                     "foo::bar::bar"))
      (should (equal (rmsbolt--cargo-asm-function-modules function)
                     '("foo" "bar")))))
  (let ((my-bin "/tmp/rmsbolt-cargo-asm-test/src/bin/my_bin.rs"))
    (rmsbolt-test--with-rust-buffer "pub fn bar() {}\n" my-bin
      (let ((function (car (rmsbolt--cargo-asm-functions my-bin))))
        (should (equal (rmsbolt--cargo-asm-function-display-name function)
                       "bar"))
        (should-not (rmsbolt--cargo-asm-function-modules function)))))
  (let ((tool "/tmp/rmsbolt-cargo-asm-test/src/bin/tool.rs")
        (helper "/tmp/rmsbolt-cargo-asm-test/src/bin/tool/helper.rs"))
    (rmsbolt-test--with-rust-buffer "pub fn helper() {}\n" helper
      (let ((function (car (rmsbolt--cargo-asm-functions tool))))
        (should (equal (rmsbolt--cargo-asm-function-display-name function)
                       "helper::helper"))
        (should (equal (rmsbolt--cargo-asm-function-modules function)
                       '("helper")))))))

(ert-deftest cargo-asm-item-matching-test ()
  (skip-unless (rmsbolt-test--rust-tree-sitter-available-p))
  (let* ((items rmsbolt-test--cargo-asm-items)
         (add (rmsbolt-test--rust-function-at
               "pub fn add(a: i32, b: i32) -> i32 { a + b }\n" "fn add"))
         (add-one (rmsbolt-test--rust-function-at
                   "pub fn add_one(a: i32) -> i32 { a + 1 }\n" "fn add_one"))
         (generic-add (rmsbolt-test--rust-function-at
                       "pub fn generic_add<T>(a: T) -> T { a }\n" "fn generic_add"))
         (foo-bar (rmsbolt-test--rust-function-at
                   rmsbolt-test--cargo-asm-rust-source "pub fn bar(&self)"))
         (sub-bar (rmsbolt-test--rust-function-at
                   "pub fn bar() {}\n" "fn bar"
                   "/tmp/rmsbolt-cargo-asm-test/src/sub.rs"))
         (generic-method (rmsbolt-test--rust-function-at
                          rmsbolt-test--cargo-asm-rust-source "pub fn unwrap_val"))
         (concrete-method (rmsbolt-test--rust-function-at
                           rmsbolt-test--cargo-asm-rust-source "pub fn concrete"))
         (trait-method (rmsbolt-test--rust-function-at
                        rmsbolt-test--cargo-asm-rust-source
                        "fn trait_fn(&self) {}")))
    (should (equal (rmsbolt--cargo-asm-matching-ids (list add) items)
                   '(0)))
    (should (equal (rmsbolt--cargo-asm-matching-ids (list add-one) items)
                   '(1)))
    (should (equal (rmsbolt--cargo-asm-matching-ids (list generic-add) items)
                   '(2 3)))
    (should (equal (rmsbolt--cargo-asm-matching-ids (list foo-bar) items)
                   '(5)))
    (should (equal (rmsbolt--cargo-asm-matching-ids (list sub-bar) items)
                   '(4)))
    (should (equal (rmsbolt--cargo-asm-matching-ids (list generic-method) items)
                   '(6 7)))
    (should (equal (rmsbolt--cargo-asm-matching-ids (list concrete-method) items)
                   '(8)))
    (should (equal (rmsbolt--cargo-asm-matching-ids (list trait-method) items)
                   '(9)))
    ;; A free function name must not match a method or a longer name.
    (should-not (rmsbolt--cargo-asm-item-matches-p add "demo::add_one"))
    (should-not (rmsbolt--cargo-asm-item-matches-p add "demo::generic_add::<i32>"))
    (should-not (rmsbolt--cargo-asm-item-matches-p add "demo::sub::bar"))))

(ert-deftest cargo-asm-process-lines-test ()
  (let ((src-file "/tmp/rmsbolt-cargo-asm-process/src/lib.rs")
        (workspace "/tmp/rmsbolt-cargo-asm-process/")
        (asm (string-join
              '("\t.intel_syntax noprefix"
                ".section .text.first,\"ax\",@progbits"
                "first:"
                "\t\t// src/lib.rs:2"
                "\t\tpub fn first() {"
                "\t.cfi_startproc"
                "\tpush rax"
                "\t\t// src/lib.rs:3"
                "\t\tlet x = 1;"
                "\tmov eax, 1"
                "\tret"
                "\t.cfi_endproc"
                ".section .text.second,\"ax\",@progbits"
                "second:"
                "\t\t// src/lib.rs:10"
                "\t\tpub fn second() {"
                "\t.cfi_startproc"
                "\tpush rbx"
                "\t\t// src/lib.rs:11"
                "\t\tlet y = 2;"
                "\tmov ebx, 2"
                "\tret"
                "\t.cfi_endproc"
                "\t\t// src/other.rs:5"
                "\t\tlet z = 3;"
                "\tmov ecx, 3")
              "\n")))
    (with-temp-buffer
      (setq buffer-file-name src-file)
      (setq-local rmsbolt--cargo-asm-workspace-dir workspace)
      (insert asm)
      (rmsbolt--process-cargo-asm-lines (current-buffer))
      (should (equal
               (split-string (buffer-string) "\n" t)
               '("\t.intel_syntax noprefix"
                 ".section .text.first,\"ax\",@progbits"
                 "first:"
                 "\t.cfi_startproc"
                 "\tpush rax"
                 "\tmov eax, 1"
                 "\tret"
                 "\t.cfi_endproc"
                 ".section .text.second,\"ax\",@progbits"
                 "second:"
                 "\t.cfi_startproc"
                 "\tpush rbx"
                 "\tmov ebx, 2"
                 "\tret"
                 "\t.cfi_endproc"
                 "\tmov ecx, 3")))
      (should-not (string-match-p "^\t\t" (buffer-string)))
      (should (equal (gethash 3 rmsbolt-line-mapping) '((6 . 7))))
      (should (equal (gethash 11 rmsbolt-line-mapping) '((13 . 14))))
      (should-not (gethash 2 rmsbolt-line-mapping))
      (should-not (gethash 10 rmsbolt-line-mapping))
      (cl-labels ((line-property (needle)
                    (goto-char (point-min))
                    (search-forward needle)
                    (get-text-property (line-beginning-position)
                                       'rmsbolt-src-line)))
        (should (= (line-property "\tmov eax, 1") 3))
        (should-not (line-property "\tpush rbx"))
        (should (= (line-property "\tmov ebx, 2") 11))
        (should-not (line-property "\tmov ecx, 3"))))))

(ert-deftest cargo-asm-end-to-end-test ()
  (skip-unless (executable-find "cargo-asm"))
  (skip-unless (rmsbolt-test--rust-tree-sitter-available-p))
  (let* ((root (make-temp-file "rmsbolt-cargo-asm-e2e-" t))
         (src-dir (expand-file-name "src" root))
         (manifest (expand-file-name "Cargo.toml" root))
         (lib-rs (expand-file-name "lib.rs" src-dir))
         (src-buffer nil))
    (unwind-protect
        (progn
          (make-directory src-dir t)
          (with-temp-file manifest
            (insert "[package]\n"
                    "name = \"rmsbolt_cargo_asm_e2e\"\n"
                    "version = \"0.1.0\"\n"
                    "edition = \"2021\"\n"))
          (with-temp-file lib-rs
            (insert "#[inline(never)]\n"
                    "pub fn generic_add<T: std::ops::Add<Output = T>>(a: T, b: T) -> T { a + b }\n"
                    "\n"
                    "#[inline(never)]\n"
                    "pub fn use_i32() -> i32 { generic_add::<i32>(1, 2) }\n"
                    "\n"
                    "#[inline(never)]\n"
                    "pub fn use_u8() -> u8 { generic_add::<u8>(1, 2) }\n"))
          (setq src-buffer (find-file-noselect lib-rs))
          (with-current-buffer src-buffer
            (rust-ts-mode)
            (goto-char (point-min))
            (search-forward "fn generic_add")
            (goto-char (match-beginning 0))
            (setq-local rmsbolt-compile-arg-overrides "--release")
            (rmsbolt-cargo-asm)
            (let ((limit (+ (float-time) 120)))
              (while (and (< (float-time) limit)
                          (or (not (get-buffer "*rmsbolt-compilation*"))
                              (get-buffer-process
                               (get-buffer "*rmsbolt-compilation*"))
                              rmsbolt--cargo-asm-active))
                (accept-process-output nil 0.1))))
          (let ((output (get-buffer rmsbolt-output-buffer)))
            (should output)
            (with-current-buffer output
              (let ((text (buffer-string)))
                (should (string-match-p
                         ";; compiled with: cargo-asm --release" text))
                (should (string-match-p "generic_add::<i32>" text))
                (should (string-match-p "generic_add::<u8>" text))))
            (with-current-buffer src-buffer
              (should rmsbolt-line-mapping)
              (let (mapped)
                (maphash
                 (lambda (src-line chunks)
                   (dolist (chunk chunks)
                     (with-current-buffer output
                       (goto-char (point-min))
                       (forward-line (1- (car chunk)))
                       (should (= (get-text-property
                                   (line-beginning-position)
                                   'rmsbolt-src-line)
                                  src-line)))
                     (setq mapped t)))
                 rmsbolt-line-mapping)
                (should mapped)))))
      (when (buffer-live-p src-buffer)
        (kill-buffer src-buffer))
      (when (get-buffer rmsbolt-output-buffer)
        (kill-buffer (get-buffer rmsbolt-output-buffer)))
      (delete-directory root t))))

;;; rmsbolt-test.el ends here
(provide 'rmsbolt-test)

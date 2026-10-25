;;; rmsbolt-test.el --- Tests for rmsbolt  -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for rmsbolt

;;; Code:

(require 'el-mock nil t)
(require 'rmsbolt)

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


;;;; Cargo integration tests

(ert-deftest cargo-extract-and-clean-cmd-test ()
  (let* ((sample-output
          (concat
           "   Compiling foo v0.1.0 (/tmp/ws/crates/foo)\n"
           "     Running `CARGO=/usr/bin/cargo CARGO_BIN_EXE_my-bin=/tmp/ws/target/debug/my-bin "
           "CARGO_PKG_DESCRIPTION='A `quoted` description\nwith newline' "
           "OUT_DIR=/tmp/ws/target/debug/build/foo-123/out "
           "rustc --crate-name foo --edition=2024 src/lib.rs "
           "--error-format=json --json=diagnostic-rendered-ansi,artifacts "
           "--crate-type lib --emit=dep-info,metadata,link "
           "-C embed-bitcode=no -C debuginfo=2 "
           "--check-cfg 'cfg(feature, values(\"default\", \"loader\"))' "
           "-C metadata=abc -C extra-filename=-def "
           "--out-dir /tmp/ws/target/debug/deps "
           "-C incremental=/tmp/ws/target/debug/incremental "
           "-L dependency=/tmp/ws/target/debug/deps "
           "--print crate-name -C lto=thin`\n"
           "foo\n"))
         (extracted (rmsbolt--extract-cargo-rustc-cmd sample-output))
         (cleaned (rmsbolt--clean-cargo-rustc-cmd extracted)))
    (should extracted)
    (should (string-prefix-p "env CARGO=/usr/bin/cargo CARGO_BIN_EXE_my-bin=" cleaned))
    (should (string-match-p "CARGO_PKG_DESCRIPTION='A `quoted` description\nwith newline'" cleaned))
    (should (string-match-p "--check-cfg 'cfg(feature, values(\"default\", \"loader\"))'" cleaned))
    (should (string-match-p "-C embed-bitcode=no" cleaned))
    (should (string-match-p "-C metadata=abc" cleaned))
    (should-not (string-match-p "--print" cleaned))
    (should-not (string-match-p "--emit" cleaned))
    (should-not (string-match-p "--out-dir" cleaned))
    (should-not (string-match-p "--error-format" cleaned))
    (should-not (string-match-p "--json" cleaned))
    (should-not (string-match-p "extra-filename=" cleaned))
    (should-not (string-match-p "incremental=" cleaned))
    (should-not (string-match-p "debuginfo=" cleaned))
    (should-not (string-match-p "lto" cleaned))))

(ert-deftest cargo-find-target-test ()
  (let* ((tmp-root (make-temp-file "rmsbolt-cargo-test-" t))
         (src-dir (expand-file-name "src" tmp-root))
         (tests-dir (expand-file-name "tests" tmp-root))
         (manifest (expand-file-name "Cargo.toml" tmp-root))
         (lib-rs (expand-file-name "lib.rs" src-dir))
         (main-rs (expand-file-name "main.rs" src-dir))
         (sub-rs (expand-file-name "asdl.rs" src-dir))
         (cli-rs (expand-file-name "cli.rs" src-dir))
         (test-rs (expand-file-name "mini_sql.rs" tests-dir))
         (build-rs (expand-file-name "build.rs" tmp-root)))
    (unwind-protect
        (progn
          (make-directory src-dir t)
          (make-directory tests-dir t)
          (with-temp-file manifest (insert "[package]\nname = \"demo\"\n"))
          (with-temp-file lib-rs (insert "pub mod asdl;\n"))
          (with-temp-file main-rs (insert "mod cli;\nfn main() {}\n"))
          (with-temp-file sub-rs (insert "pub fn f() {}\n"))
          (with-temp-file cli-rs (insert "pub fn g() {}\n"))
          (with-temp-file test-rs (insert "#[test] fn t() {}\n"))
          (with-temp-file build-rs (insert "#[path = \"src/asdl.rs\"]\nmod asdl;\nfn main() {}\n"))
          (let ((metadata
                 `((workspace_root . ,tmp-root)
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
                             (src_path . ,test-rs))
                            ((name . "build-script-build")
                             (kind . ["custom-build"])
                             (src_path . ,build-rs))]))]))))
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
                            (cdr (rmsbolt--cargo-find-target metadata test-rs)))
                           '("--test" "mini_sql")))
            (should (rmsbolt--cargo-build-script-p
                     (cdr (rmsbolt--cargo-find-target metadata build-rs))))
            (should-not (rmsbolt--cargo-target-args
                         (cdr (rmsbolt--cargo-find-target metadata build-rs))))))
      (delete-directory tmp-root t))))


;;; rmsbolt-test.el ends here
(provide 'rmsbolt-test)

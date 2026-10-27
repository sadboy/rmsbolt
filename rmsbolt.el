;;; rmsbolt.el --- A compiler output viewer -*- lexical-binding: t; -*-

;; Copyright (C) 2018-2023 Jay Kamat

;; Author: Jay Kamat <jaygkamat@gmail.com>
;; Version: 0.1.2
;; Keywords: compilation, tools
;; URL: http://gitlab.com/jgkamat/rmsbolt
;; Package-Requires: ((emacs "25.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; RMSBolt is a package to provide assembly or bytecode output for a source
;; code input file.
;;
;; It currently supports: C/C++, Fortran, OCaml, Haskell, Python, Java, Go, PHP, D,
;; Pony, Zig, Swift, Emacs Lisp, and (limited) Common Lisp.
;;
;; Adding support for more languages, if they have an easy manual compilation
;; path from source->assembly/bytecode with debug information, should be much
;; easier than in other alternatives.
;;
;; It's able to do this by:
;; 1. Compiling changes automatically, adding options which cause the compiler
;; to output assembly/bytecode with debug information (or by using objdump)
;; 2. Parse assembly/bytecode to create a map from it to the original source
;; 3. Strip out unneeded information from bytecode to only show useful code
;; 4. Provide an interface for highlighting the matched assembly/bytecode line
;; to the source and vice versa
;;

;;;; Tweakables:

;; RMSBolt is primarily configured with Emacs local variables.  This lets you
;; change compiler and rmsbolt options simply by editing a local variable block.
;;
;; Notable options:
;; `rmsbolt-command': determines the prefix of the compilation command to use.
;; `rmsbolt-default-directory': determines the default-drectory to compile from.
;; `rmsbolt-disassemble': disassemble from a compiled binary with objdump, if supported.
;; `rmsbolt-filter-*': Tweak filtering of binary output.
;; `rmsbolt-asm-format': Choose between intel att, and other syntax if supported.
;; `rmsbolt-demangle': Demangle the output, if supported.
;; `rmsbolt-output-header': Show the compiler and its interesting arguments
;; at the top of the output buffer.
;;
;; For more advanced configuration (to the point where you can override almost
;; all of RMSbolt yourself), you can set `rmsbolt-language-descriptor' with a
;; replacement language spec.
;;
;; Please see the readme at https://gitlab.com/jgkamat/rmsbolt for
;; more information!
;;
;; Tramp support notes:
;; - Compilation occurs on a remote system, via Tramp, when default-directory is
;;   a remote path.  default-directory will be remote when rmsbolt is invoked on
;;   a buffer backed by a remote path.
;; - Paths used in externally-run command lines must use the local component of a
;;   path so they can run on a remote system.  `rmsbolt--with-local-files` takes
;;   care of commonly used paths that typically need to be local (`src-filename` and
;;   `output-filename`), though `file-local-name` should be used in other cases.
;; - One temporary directory exists per remote so that intermediate files are
;;   created on the system performing the compilation.
;;
;; Thanks:
;; Inspiration and some assembly parsing logic was adapted from Matt Godbolt's
;; compiler-explorer: https://github.com/mattgodbolt/compiler-explorer and
;; Jonas Konrad's javap: https://github.com/yawkat/javap.

;;; Requires:

(require 'cl-lib)
(eval-when-compile (require 'subr-x))
(require 'map)
(require 'cc-defs)
(require 'compile)
(require 'disass)
(require 'json)
(require 'view)

(require 'rmsbolt-java)
(require 'rmsbolt-split)
(require 'treesit nil t)

;;; Code:
;;;; Customize:
(defgroup rmsbolt nil
  "Customization for rmsbolt."
  :group 'applications)

(defcustom rmsbolt-use-overlays t
  "Whether we should use overlays to show matching code."
  :type 'boolean
  :group 'rmsbolt)
(defcustom rmsbolt-goto-match t
  "Whether we should goto the match in the other buffer if it is non visible."
  :type 'boolean
  :group 'rmsbolt)

(defcustom rmsbolt-output-header t
  "Whether to insert a compiler header into the output buffer.
The header is a single comment line with the compiler that produced the
assembly and its interesting arguments, such as optimization levels."
  :type 'boolean
  :safe 'booleanp
  :group 'rmsbolt)

(defcustom rmsbolt-output-header-arg-alist
  '((t
     ("^-O" . nil)
     ("^-march$" . "^[^-]")
     ("^-march" . nil)
     ("^-mtune$" . "^[^-]")
     ("^-mtune" . nil)
     ("^-mcpu$" . "^[^-]")
     ("^-mcpu" . nil)
     ("^-mcmodel$" . "^[^-]")
     ("^-mcmodel" . nil)
     ("^-m.+$" . nil)
     ("^-std=" . nil)
     ("^-f.+$" . nil)
     ("^-target$" . "^[^-]")
     ("^-target" . nil)
     ("^--target=" . nil))
    (rust-mode
     ("^-O" . nil)
     ("^--release$" . nil)
     ("^--dev$" . nil)
     ("^--profile$" . "^[^-]")
     ("^--profile=" . nil)
     ("^--target-cpu$" . "^[^-]")
     ("^--target-cpu=" . nil)
     ("^--native$" . nil)
     ("^-C$" . "^\\(opt-level\\|target-cpu\\|target-feature\\|lto\\|llvm-args\\)")
     ("^-C\\(opt-level\\|target-cpu\\|target-feature\\|lto\\|llvm-args\\)" . nil))
    (rustic-mode
     ("^-O" . nil)
     ("^--release$" . nil)
     ("^--dev$" . nil)
     ("^--profile$" . "^[^-]")
     ("^--profile=" . nil)
     ("^--target-cpu$" . "^[^-]")
     ("^--target-cpu=" . nil)
     ("^--native$" . nil)
     ("^-C$" . "^\\(opt-level\\|target-cpu\\|target-feature\\|lto\\|llvm-args\\)")
     ("^-C\\(opt-level\\|target-cpu\\|target-feature\\|lto\\|llvm-args\\)" . nil))
    (zig-mode
     ("^-O$" . "^\\(Debug\\|ReleaseSafe\\|ReleaseFast\\|ReleaseSmall\\)$")
     ("^-O" . nil)
     ("^-mcpu$" . "^[^-]")
     ("^-mcpu" . nil)
     ("^-target$" . "^[^-]")
     ("^-target" . nil)))
  "Compiler arguments to show in the output buffer header.
Keys are major mode symbols and `t' is the default for modes without an
entry.  Each value is a list of (LEADING . FOLLOW) regexp pairs.  LEADING
is matched against an argument and FOLLOW, when non-nil, is matched
against the argument after it, which is then shown as its value.  For
example:

  (\"^-C$\" . \"^opt-level=.*\") ; -C opt-level=2, not -C debuginfo=2
  (\"^-flto$\" . nil)            ; -flto, not -flto=thin
  (\"^-std=.*$\" . nil)          ; -std=c++17

The first pair whose LEADING matches wins.  When FOLLOW does not match,
the remaining pairs are tried for the same argument."
  :type '(alist :key-type symbol
                :value-type (repeat (cons regexp
                                          (choice (const :tag "None" nil)
                                                  regexp))))
  :group 'rmsbolt)

(defcustom rmsbolt-mode-lighter " RMSB"
  "Lighter displayed in mode line when function `rmsbolt-mode' is active."
  :type 'string
  :group 'rmsbolt)

(defcustom rmsbolt-large-buffer-size 500
  "Number of lines past which a buffer is considred large."
  :type 'natnum
  :group 'rmsbolt)

(defcustom rmsbolt-automatic-recompile t
  "Whether to automatically save and recompile the source buffer.
This setting is automatically disabled on large buffers, set to
`force' to force-enable it.  To only recompile when the buffer is
manually saved, set to `on-save'."
  :group 'rmsbolt
  :type '(choice (const :tag "Off" nil)
                 (const :tag "On save" on-save)
                 (const :tag "On" t)
                 (const :tag "Always" force)))


(defcustom rmsbolt-cargo-force-build-script nil
  "Whether to update the timestamp of a Cargo build script before compilation.
When non-nil, RMSBolt updates the modification time of `build.rs' so
Cargo prints the `rustc' command even when the build script is already
built.  This invalidates the build-script fingerprint and causes Cargo
to rebuild downstream targets."
  :group 'rmsbolt
  :type 'boolean
  :safe 'booleanp)
;;;;; Buffer Local Tweakables
(defcustom rmsbolt-disassemble nil
  "Whether we should disassemble an output binary."
  :group 'rmsbolt
  :type 'boolean
  :safe 'booleanp)

(defcustom rmsbolt-command nil
  "The base command to run rmsbolt from."
  :type 'string
  :group 'rmsbolt
  ;; nil means use default command
  :safe (lambda (v) (or (booleanp v) (stringp v))))

(defcustom rmsbolt-default-directory nil
  "The default directory to compile from.
This must be an absolute path if set.
Some exporters (such as pony) may not work with this set."
  :type 'string
  ;; nil means use default command
  :safe (lambda (v) (or (booleanp v) (stringp v))))

(define-obsolete-variable-alias 'rmsbolt-intel-x86
  'rmsbolt-asm-format "RMSBolt-0.2"
  "Sorry about not providing a proper migration for this variable.
Unfortunately the new options aren't a straightforward mapping.
Most likely what you want:

t -> \"intel\"
nil -> \"att\"
tool defaults -> nil

This means that if you had rmsbolt-intel-x86 set manually, you
are now getting tool defaults.")

(defcustom rmsbolt-asm-format "intel"
  "Which output assembly format to use.

The supported values depend highly on the exporter, but typical
values are: intel, att, <nil/t> (for using tool defaults).
Invalid values will be passed onto the disassembly tools, which
may throw errors.

If you are not on x86, you most likely want to set this to nil.

Since this defaults to \"intel\", implementers must support this
being set (at worst falling back to nil if passed \"intel\")."
  :type 'string
  :safe (lambda (v) (or (booleanp v) (stringp v)))
  :group 'rmsbolt)
(defcustom rmsbolt-filter-directives t
  "Whether to filter assembly directives."
  :type 'boolean
  :safe 'booleanp
  :group 'rmsbolt)
(defcustom rmsbolt-filter-labels t
  "Whether to filter unused labels."
  :type 'boolean
  :safe 'booleanp
  :group 'rmsbolt)
(defcustom rmsbolt-filter-comment-only t
  "Whether to filter comment-only lines."
  :type 'boolean
  :safe 'booleanp
  :group 'rmsbolt)
(defcustom rmsbolt-ignore-binary-limit nil
  "Whether to ignore the binary limit. Could hang emacs..."
  :type 'boolean
  :safe 'booleanp
  :group 'rmsbolt)
(defcustom rmsbolt-demangle t
  "Whether to attempt to demangle the resulting assembly."
  :type 'boolean
  :safe 'booleanp
  :group 'rmsbolt)
(defcustom rmsbolt-flag-quirks t
  "Whether to tweak flags to enable as many features as possible.

In most cases, we will try to honor flags in rmsbolt-command as
much as possible.  However, some features may be disabled with
some odd combinations of flags.  This variable controls
removing/adding flags to handle those cases.

Note that basic flags to ensure basic usage are always modified."
  :type 'boolean
  :safe 'booleanp
  :group 'rmsbolt)

(defcustom rmsbolt-after-parse-hook nil
  "Hook after all parsing is done, but before compile command is run.

Exercise caution when setting variables in this hook - doing so
can disrupt rmsbolt state and cause issues. Variables set here
may not be cleared to default as variables are usually."
  :group 'rmsbolt
  :type 'hook)

;;;; Faces

(defface rmsbolt-current-line-face
  '((t (:weight bold :inherit highlight)))
  "Face to fontify the current line for showing matches."
  :group 'rmsbolt)

;;;; Variables:
(defvar rmsbolt-output-buffer "*rmsbolt-output*")
;; whether rmsbolt-mode is enabled.
(defvar rmsbolt-mode)

(defvar rmsbolt-hide-compile t)
(defvar rmsbolt-binary-asm-limit 10000)
(defvar-local rmsbolt-line-mapping nil
  "Line mapping hashtable from source lines -> asm lines.")
(defvar-local rmsbolt-current-line nil
  "Current line for fontifier.")
(defvar-local rmsbolt--last-point nil
  "Used to detect when the point has moved.")

(defvar rmsbolt-overlays nil
  "List of overlays to use.")
(defvar rmsbolt-compile-delay 0.4
  "Time in seconds to delay before recompiling if there is a change.")
(defvar rmsbolt--automated-compile nil
  "Whether this compile was automated or not.")

(defvar-local rmsbolt-compile-arg-overrides nil
  "Compiler arguments that override the ones in `rmsbolt-command'.
`rmsbolt-compile' sets this when it is given argument overrides, and the
value stays in effect for the buffer until it is set again.")
(defvar rmsbolt--shell "bash"
  "Which shell to prefer if available.
Used to work around inconsistencies in alternative shells.")

(defvar rmsbolt--temp-dir nil
  "Temporary directory to use for compilation and other reasons.

Please DO NOT modify this blindly, as this directory will get
deleted on Emacs exit.")

(defvar rmsbolt-dir (and load-file-name (file-name-directory load-file-name))
  "The directory which rmsbolt is installed to.")

(defvar-local rmsbolt-src-buffer nil)

(defvar-local rmsbolt--cargo-asm-active nil
  "Non-nil when the output buffer comes from `rmsbolt-cargo-asm'.")

(defvar-local rmsbolt--cargo-asm-workspace-dir nil
  "Cargo workspace directory for the active `rmsbolt-cargo-asm' output.")

(defvar-local rmsbolt--cargo-asm-function nil
  "Function descriptor for the active `rmsbolt-cargo-asm' invocation.")

(defvar-local rmsbolt--cargo-asm-command nil
  "Base cargo-asm command for the active `rmsbolt-cargo-asm' invocation.")

(defvar-local rmsbolt--real-src-file nil
  "The real filename that we compiled from.
If this is set, it is probably due to a copy from this file.")
;; FIXME should we be unbinding the list here, or is setting nil good enough.
(defvar-local rmsbolt--default-variables nil
  "A list of the buffer-local variables we filled in with defaults.
Useful for determining if the user overrode things like `rmsbolt-command'.

This list of variables will automatically be restored to nil.")

(defvar-local rmsbolt-objdump-binary "objdump"
  "A binary to use for objdumping when using `rmsbolt-disassemble'.
Useful if you have multiple objdumpers and want to select between them")

(defvar rmsbolt--temp-dirs-hash (make-hash-table :test #'equal)
  "Hash table mapping file path remote components to a 'local' temporary directory.")

;;;; Variable-like funcs
(defun rmsbolt-output-filename (src-buffer &optional asm)
  "Function for generating an output filename for SRC-BUFFER.

Outputs assembly file if ASM.
This function does NOT quote the return value for use in inferior shells."
  (if (and (not asm)
           (buffer-local-value 'rmsbolt-disassemble src-buffer))
      (expand-file-name "rmsbolt.o" rmsbolt--temp-dir)
    (expand-file-name "rmsbolt.s" rmsbolt--temp-dir)))

;;;; Regexes

(defvar rmsbolt-label-def  (rx bol (group (any ".a-zA-Z_$@")
                                          (0+ (any "a-zA-Z0-9$_@.")))
                               ":"))
(defvar rmsbolt-defines-global (rx bol (0+ space) ".glob"
                                   (opt "a") "l" (0+ space)
                                   (group (any ".a-zA-Z_")
                                          (0+ (any "a-zA-Z0-9$_.")))))
(defvar rmsbolt-label-find (rx (any ".a-zA-Z_")
                               (0+
                                (any "a-zA-Z0-9$_."))))
(defvar rmsbolt-assignment-def (rx bol (0+ space)
                                   (group (any ".a-zA-Z_$")
                                          (1+ (any "a-zA-Z0-9$_.")))
                                   (0+ space) "="))
(defvar rmsbolt-has-opcode (rx bol (0+ space)
                               (any "a-zA-Z")))

(defvar rmsbolt-defines-function (rx bol (0+ space) ".type"
                                     (0+ any) "," (0+ space) (any "@%")
                                     "function" eol))
(defvar rmsbolt-data-defn (rx bol (0+ space) "."
                              (group (or "string" "asciz" "ascii"
                                         (and
                                          (optional (any "1248")) "byte")
                                         "short" "word" "long" "quad" "value" "zero"))))

(defvar rmsbolt-directive (rx bol (0+ space) "." (0+ any) eol))
(defvar rmsbolt-endblock (rx "." (or "cfi_endproc" "data" "text" "section")))
(defvar rmsbolt-comment-only (rx bol (0+ space) (or (and (or (any "#@;") "//"))
                                                    (and "/*" (0+ any) "*/"))
                                 (0+ any) eol))
(defvar rmsbolt-disass-line (rx bol
                                (group "/" (1+ (not (any ":")))) ":"
                                (group (1+ num))
                                (0+ any)))
(defvar rmsbolt-disass-label (rx bol (group (1+ (any digit "a-f")))
                                 (1+ space) "<"
                                 (group (1+ (not (any ">")))) ">:" eol))
(defvar rmsbolt-disass-dest (rx (0+ any) (group (1+ (any digit "a-f")))
                                (1+ space) "<" (group (1+ (not (any ">")))) ">" eol))

(defvar rmsbolt-disass-opcode (rx bol (0+ space) (group (1+ (any digit "a-f")))
                                  ":" (0+ space)
                                  (group (1+
                                          (repeat 2
                                                  (any digit "a-f"))
                                          (opt " ")))
                                  (0+ space)
                                  (group (0+ any))))
(defvar rmsbolt-source-file (rx bol (0+ space) ".file" (1+ space)
                                (group (1+ digit)) (1+ space) ?\"
                                (group (1+ (not (any ?\")))) ?\"
                                (opt (1+ space) ?\"
                                     (group (1+ (not (any ?\")))) ?\")
                                (0+ any)))
(defvar rmsbolt-source-tag (rx bol (0+ space) ".loc" (1+ space)
                               (group (1+ digit)) (1+ space)
                               (group (1+ digit))
                               (0+ any)))
(defvar rmsbolt-source-stab (rx bol (0+ any) ".stabn" (1+ space)
                                (group (1+ digit)) ",0,"
                                (group (1+ digit)) "," (0+ any)))

;;;; Classes

(cl-defstruct (rmsbolt-lang
               (:conc-name rmsbolt-l-))
  (supports-disass
   nil
   :type 'bool
   :documentation "If we support assembly directly. If nil, we must use other methods.")
  (supports-asm
   nil
   :type 'bool
   :documentation "If we support disassembling from binaries. If nil, we must use other methods.")
  (objdumper
   'objdump
   :type 'symbol
   :documentation "The object dumper to use if disassembling binary.")
  (demangling-style
   nil
   :type 'string
   :documentation "The demangling style as interpreted by the objdumper, if applicable.")
  (demangler
   nil
   :type 'string
   :documentation "The command of the demangler to use for this source code.
If nil, don't demangle.")
  (disass-hidden-funcs
   nil
   :type 'string
   :documentation "Functions that are hidden when disassembling.")
  (compile-cmd
   nil
   :type 'string
   :documentation "Default compilation command to use if none is provided.
If provided a function, call that function with the source buffer to determine
the compile command.")
  (default-directory
    nil
    :type 'string
    :documentation "Default directory to run compilation in. By default, use rmsbolt--temp-dir.
If provided a function, call that function with the source buffer to determine
the default directory.")
  (compile-cmd-function
   nil
   :type 'function
   :documentation "A function which takes in a compile command
(could be the default) and adds needed args to it.")
  (process-asm-custom-fn
   nil
   :type 'function
   :documentation "A custom function used for parsing asm lines
   instead of the default assembly one." )
  (elisp-compile-override
   nil
   :type 'function
   :documentation "A custom function to run instead of running any compilation command.
Generally not useful with the sole exception of the emacs lisp disassembler.
This function is responsible for calling `rmsbolt--handle-finish-compile'
Please be careful when setting this, as it bypasses most logic and is
generally not useful."))

;;;; Helper Functions
(defun rmsbolt--convert-file-name-to-system-type (file-name) ;perhaps use `convert-standard-filename'?
  "Convert FILE-NAME to windows format if `system-type' is equal to `cygwin'.

Additional escaping with double quotes included to avoid
backslashes loss in cygwin environment. If not `cygwin' then
bypass the FILE-NAME."
  (if (eq system-type 'cygwin)
      (concat "\"" (cygwin-convert-file-name-to-windows file-name) "\"")
    file-name))

(defmacro rmsbolt--with-local-files (src-buffer &rest body)
  "Execute BODY with `src-filename' and `output-filename' defined as the local
components of the args taken from SRC-BUFFER.
Return value is quoted for passing to the shell."
  ;; Both src-filename and output-filename are local components so
  ;; they can be used in commands on a remote system.
  `(let ((src-filename
          (rmsbolt--convert-file-name-to-system-type
           (shell-quote-argument
            (file-local-name
             (buffer-file-name)))))
         (output-filename
          (rmsbolt--convert-file-name-to-system-type
           (shell-quote-argument
            (file-local-name
             (rmsbolt-output-filename ,src-buffer))))))
     ,@body))

(defmacro rmsbolt--set-local (var val)
  "Set unquoted variable VAR to value VAL in current buffer."
  (declare (debug (symbolp form)))
  `(set (make-local-variable ,var) ,val))

(defun rmsbolt--file-equal-p (src-path target-path)
  "Return non-nil if SRC-PATH and TARGET-PATH refer to the same file."
  (let ((default-directory (and default-directory
                                (file-local-name default-directory))))
    (equal (expand-file-name (file-local-name src-path))
           (expand-file-name (file-local-name target-path)))))

;;;; Language Functions
;;;;; Compile Commands

(defun rmsbolt--c-quirks (cmd &key src-buffer)
  "Handle quirks in CMD, and return unchanged or modified CMD.

Use SRC-BUFFER as buffer for local variables."
  (if (and (buffer-local-value 'rmsbolt-flag-quirks src-buffer)
           (string-match-p (rx "-save-temps") cmd)
           (string-match-p (rx "-P") cmd))
      (rmsbolt-split-rm-single cmd "-save-temps")
    cmd))

(cl-defun rmsbolt--c-compile-cmd (&key src-buffer)
  "Process a compile command for gcc/clang.

Use SRC-BUFFER as buffer containing local variables."

  (rmsbolt--with-local-files
   src-buffer
   (let* ( ;; Turn off passing the source file if we find compile_commands
          (no-src-filename (rmsbolt--handle-c-compile-cmd src-buffer))
          (asm-format (buffer-local-value 'rmsbolt-asm-format src-buffer))
          (disass (buffer-local-value 'rmsbolt-disassemble src-buffer))
          (cmd (buffer-local-value 'rmsbolt-command src-buffer))
          (cmd (string-join
                (list cmd
                      "-g1"
                      (if disass
                          "-c"
                        "-S")
                      (if no-src-filename
                          ""
                        src-filename)
                      "-o" output-filename
                      (when (and (not (booleanp asm-format))
                                 (not disass))
                        (concat "-masm=" asm-format)))
                " "))
          (cmd (rmsbolt--c-quirks cmd :src-buffer src-buffer)))
     cmd)))

(cl-defun rmsbolt--c-dwarf-compile-cmd (&key src-buffer)
  "Process a compile command for c dwarf.

Use SRC-BUFFER as buffer for local variables.

We use a hack where we overwrite the asm setting to trick the
rest of the code into doing what we want. In this case, setting
this value dosen't make sense anyway, so it should be fine to do
this."
  (with-current-buffer src-buffer

    (setq rmsbolt-disassemble t)
    (let* ((old-cmd (rmsbolt--c-compile-cmd :src-buffer src-buffer))
           (binary-out (file-local-name (rmsbolt-output-filename src-buffer)))
           (asm-out (progn
                      (setq rmsbolt-disassemble nil)
                      (file-local-name (rmsbolt-output-filename src-buffer))))
           (full-cmd (string-join
                      (list old-cmd
                            "&&" "eu-readelf" "--debug-dump=info" binary-out ">" asm-out)
                      " ")))
      full-cmd)))

(cl-defun rmsbolt--ocaml-compile-cmd (&key src-buffer)
  "Process a compile command for ocaml.

Use SRC-BUFFER as buffer for local variables.

Needed as ocaml cannot output asm to a non-hardcoded file"
  (rmsbolt--with-local-files
   src-buffer
   (let* ((diss (buffer-local-value 'rmsbolt-disassemble src-buffer))
          (predicted-asm-filename (shell-quote-argument
                                   (concat (file-name-sans-extension src-filename) ".s")))
          (cmd (buffer-local-value 'rmsbolt-command src-buffer))
          (cmd (string-join
                (list cmd
                      "-g"
                      (if (buffer-local-value 'rmsbolt-disassemble src-buffer)
                          ""
                        "-S")
                      src-filename
                      (string-join
                       (cond
                        (diss
                         (list "-o" output-filename))
                        ((equal predicted-asm-filename output-filename)
                         nil)
                        (t
                         (list "&&" "mv"
                               predicted-asm-filename
                               output-filename)))
                       " "))
                " ")))
     cmd)))

(cl-defun rmsbolt--lisp-compile-cmd (&key src-buffer)
  "Process a compile command for common LISP.

Use SRC-BUFFER as buffer for local variables.

Assumes function name to disassemble is \\='main\\='."
  (rmsbolt--with-local-files
   src-buffer
   (let* ((cmd (buffer-local-value 'rmsbolt-command src-buffer))
          (interpreter (cl-first (split-string cmd nil t)))
          (disass-eval "\"(disassemble 'main)\"")
          (disass-eval-unquoted "(disassemble 'main)"))
     (pcase interpreter
       ("sbcl"
        (string-join
         (list cmd "--noinform" "--load"
               src-filename
               "--eval" disass-eval "--non-interactive"
               ;; Remove leading comments
               "|" "sed" "'s/^;\s//'" ">"
               output-filename)
         " "))
       ("clisp"
        (string-join
         (list cmd "-q" "-x"
               (concat
                "\"(load \\\"" src-filename "\\\") " disass-eval-unquoted "\"")
               ">" output-filename)
         " "))
       (_
        (error "This Common Lisp interpreter is not supported"))))))

(cl-defun rmsbolt--mlir-compile-cmd (&key src-buffer)
  "Process a compile command for mlir.

Use SRC-BUFFER as buffer containing local variables."

  (rmsbolt--with-local-files
   src-buffer
   (let* ( ;; Turn off passing the source file if we find compile_commands
          (cmd (buffer-local-value 'rmsbolt-command src-buffer))
          (cmd (string-join
                (list cmd
                      src-filename
                      "-o" output-filename)
                " ")))
     cmd)))

(cl-defun rmsbolt--rust-compile-cmd (&key src-buffer)
  "Process a compile command for rustc.

Use SRC-BUFFER as buffer for local variables."
  (rmsbolt--with-local-files
   src-buffer
   (let* ((omit-src-filename (rmsbolt--handle-rust-compile-cmd src-buffer))
          (asm-format (buffer-local-value 'rmsbolt-asm-format src-buffer))
          (disass (buffer-local-value 'rmsbolt-disassemble src-buffer))
          (cmd (buffer-local-value 'rmsbolt-command src-buffer))
          (cmd (string-join
                (delq nil
                      (list cmd
                            "-C" "debuginfo=1"
                            "--emit"
                            (if disass
                                "link"
                              "asm")
                            (unless omit-src-filename
                              src-filename)
                            "-o" output-filename
                            (when (and (not (booleanp asm-format))
                                       (not disass))
                              (concat "-Cllvm-args=--x86-asm-syntax=" asm-format))))
                " ")))
     cmd)))

(cl-defun rmsbolt--go-compile-cmd (&key src-buffer)
  "Process a compile command for go.

Use SRC-BUFFER as buffer for local variables."
  (rmsbolt--with-local-files
   src-buffer
   (let* ((cmd (buffer-local-value 'rmsbolt-command src-buffer))
          (cmd (string-join
                (list cmd
                      "tool" "compile"
                      "-S"
                      "-o" output-filename
                      src-filename)
                " ")))
     cmd)))

(cl-defun rmsbolt--d-compile-cmd (&key src-buffer)
  "Process a compile command for d.

Use SRC-BUFFER as buffer for local variables."
  (rmsbolt--with-local-files
   src-buffer
   (let* ((compiler (buffer-local-value 'rmsbolt-command src-buffer))
          (cmd (string-join
                (list compiler "-g" "-output-s" src-filename "-of" output-filename)
                " ")))
     cmd)))

(cl-defun rmsbolt--pony-compile-cmd (&key src-buffer)
  "Process a compile command for ponyc.

Use SRC-BUFFER as buffer for local variables."
  (let* ((cmd (buffer-local-value 'rmsbolt-command src-buffer))
         (dir (expand-file-name "pony/" rmsbolt--temp-dir))
         (local-dir (file-local-name dir))
         (_ (make-directory dir t))
         ;; (base-filename (file-name-sans-extension
         ;;                 (file-name-nondirectory
         ;;                  (buffer-file-name))))
         (base-filename "pony")
         (base-filename (expand-file-name base-filename dir))
         (asm-filename (shell-quote-argument (file-local-name (concat base-filename ".s"))))
         (object-filename (shell-quote-argument (file-local-name (concat base-filename ".o"))))
         ;; TODO should we copy this in lisp here, or pass this to the compilation command?
         (_ (copy-file (buffer-file-name)
                       (expand-file-name dir) t))
         (dis (buffer-local-value 'rmsbolt-disassemble src-buffer))
         (cmd (string-join
               (list
                cmd
                "-g"
                ;; FIXME: test this properly and use rmsbolt-asm-format to expose it.
                (if dis
                    "-r=obj"
                  "-r=asm")
                local-dir
                "-o" local-dir
                "&&" "mv"
                (if dis object-filename asm-filename)
                (shell-quote-argument
                 (file-local-name (rmsbolt-output-filename src-buffer))))
               " ")))
    (with-current-buffer src-buffer
      (setq rmsbolt--real-src-file
            (expand-file-name (file-name-nondirectory
                               (buffer-file-name))
                              dir)))
    cmd))

(cl-defun rmsbolt--py-compile-cmd (&key src-buffer)
  "Process a compile command for python3.

Use SRC-BUFFER as buffer for local variables."
  (rmsbolt--with-local-files
   src-buffer
   (let* ((cmd (buffer-local-value 'rmsbolt-command src-buffer)))
     (string-join
      (list cmd "-m" "dis" src-filename
            ">" output-filename)
      " "))))

(defun rmsbolt--hack-p (src-buffer)
  "Return non-nil if SRC-BUFFER should should use hhvm instead of php."
  (with-current-buffer src-buffer
    (save-excursion
      (goto-char (point-min))
      (re-search-forward (rx "<?hh") nil t))))

(defun rmsbolt--php-default-compile-cmd (src-buffer)
  "Return the default php compile command for SRC-BUFFER."
  (if (rmsbolt--hack-p src-buffer)
      "hh_single_compile"
    "php"))

(cl-defun rmsbolt--php-compile-cmd (&key src-buffer)
  "Process a compile command for PHP.

Use SRC-BUFFER as buffer for local variables.

In order to disassemble opcdoes, we need to have the vld.so
extension to php on.
https://github.com/derickr/vld"
  (rmsbolt--with-local-files
   src-buffer
   (if (rmsbolt--hack-p src-buffer)
       (concat (buffer-local-value 'rmsbolt-command src-buffer)
               " " src-filename " > " output-filename)
     (concat (buffer-local-value 'rmsbolt-command src-buffer)
             " -dvld.active=1 -dvld.execute=0 -dvld.verbosity=1 "
             src-filename " 2> " output-filename " > /dev/null"))))

(cl-defun rmsbolt--hs-compile-cmd (&key src-buffer)
  "Process a compile command for ghc.

Use SRC-BUFFER as buffer for local variables."
  (rmsbolt--with-local-files
   src-buffer
   (let* ((cmd (buffer-local-value 'rmsbolt-command src-buffer))
          (cmd (string-join
                (list cmd
                      "-g"
                      (if (buffer-local-value 'rmsbolt-disassemble src-buffer)
                          ""
                        "-S")
                      src-filename
                      "-o" output-filename)
                " ")))
     cmd)))

(cl-defun rmsbolt--java-compile-cmd (&key src-buffer)
  "Process a compile command for ocaml.

Use SRC-BUFFER as buffer for local variables.

Needed as ocaml cannot output asm to a non-hardcoded file"
  (rmsbolt--with-local-files
   src-buffer
   (let* ((class-filename (shell-quote-argument
                           (concat (file-name-sans-extension src-filename) ".class")))
          (cmd (buffer-local-value 'rmsbolt-command src-buffer))
          (cmd (string-join
                (list cmd
                      "-g"
                      src-filename
                      "&&"
                      "javap"
                      "-c" "-l"
                      class-filename
                      ">"
                      output-filename)
                " ")))
     cmd)))

(cl-defun rmsbolt--elisp-compile-override (&key src-buffer)
  "Handle elisp overrides - this is a special case.

Use SRC-BUFFER as buffer for local variables."
  ;; We don't need the local path since Emacs lisp support handles remote paths
  ;; natively.
  (let ((file-name buffer-file-name))
    (with-temp-buffer
      (rmsbolt--disassemble-file file-name (current-buffer))
      (rmsbolt--handle-finish-compile src-buffer nil :override-buffer (current-buffer)))))

(cl-defun rmsbolt--nim-compile-cmd (&key src-buffer)
  "Process a compile command for nim.

Use SRC-BUFFER as buffer for local variables."
  (rmsbolt--with-local-files
   src-buffer
   (let* ((cmd (buffer-local-value 'rmsbolt-command src-buffer))
          (cmd
           (let* ((outdir (file-local-name (expand-file-name "nim-cache" rmsbolt--temp-dir))))
             (string-join
              (list cmd
                    "--debugger:native"
                    "--noLinking"
                    "--colors:off"
                    (concat "--nimcache:" outdir)
                    src-filename
                    (concat
                     "&& cp "
                     (expand-file-name
                      (concat "@m"
                              (file-name-nondirectory src-filename)
                              (if (string-match (rx "nim cpp") cmd) ".cpp.o" ".c.o"))
                      outdir)
                     " " output-filename))
              " "))))
     cmd)))

(cl-defun rmsbolt--zig-compile-cmd (&key src-buffer)
  "Process a compile command for zig.

Use SRC-BUFFER as buffer for local variables."
  (rmsbolt--with-local-files
   src-buffer
   (let* ((disass (buffer-local-value 'rmsbolt-disassemble src-buffer))
          (cmd (buffer-local-value 'rmsbolt-command src-buffer))
          (cmd (string-join
                (list cmd
                      src-filename
                      "--cache-dir" (expand-file-name "zig-cache" rmsbolt--temp-dir)
                      (concat (if disass
                                  "-femit-bin="
                                "-fno-emit-bin -femit-asm=")
                              output-filename))
                " ")))
     cmd)))

(cl-defun rmsbolt--swift-compile-cmd (&key src-buffer)
  "Process a compile command for swiftc.

Use SRC-BUFFER as buffer for local variables."
  (rmsbolt--with-local-files
   src-buffer
   (let* ((asm-format (buffer-local-value 'rmsbolt-asm-format src-buffer))
          (cmd (buffer-local-value 'rmsbolt-command src-buffer))
          (cmd (string-join
                (list cmd
                      "-g"
                      "-emit-assembly"
                      src-filename
                      "-o" output-filename
                      (when (not (booleanp asm-format))
                        (concat "-Xllvm --x86-asm-syntax=" asm-format)))
                " ")))
     cmd)))

;;;;; Hidden Function Definitions

(defvar rmsbolt--hidden-func-c
  (rx bol (or (and "__" (0+ any))
              (and "_" (or "init" "start" "fini"))
              (and (opt "de") "register_tm_clones")
              "call_gmon_start"
              "frame_dummy"
              (and ".plt" (0+ any)))
      eol))

(defvar rmsbolt--hidden-func-ocaml
  (rx bol
      (or (and "__" (0+ any))
          (and "_" (or "init" "start" "fini"))
          (and (opt "de") "register_tm_clones")
          (and ".plt" (0+ any))
          (and "camlCamlinternalFormat" (0+ any))
          (and (1+ (not (any "@"))) "@plt")
          (and (or "caml_" "camlStd_") (0+ any))
          (and "caml" (or "Pervasives" "List" "Bytes"
                          "String" "Buffer" "Printf"
                          "Char" "Sys")
               "__" (0+ any))
          ;; Ocaml likes to make labels following camlModule__,
          ;; filter out any lowercase
          (and (1+ (1+ lower) (opt (or "64" "32" "8" "16")) (opt "_"))))
      eol))

(defvar rmsbolt--hidden-func-zig
  (rx bol (or (and "_" (0+ any))
              (and (opt "de") "register_tm_clones")
              "call_gmon_start"
              "frame_dummy"
              (and (0+ any) "@plt" (0+ any)))
      eol))

;;;;; Demangling Functions

(defun rmsbolt--path-to-swift-demangler ()
  "Return the path to the configured Swift demangler.

Depends on the active toolchain."
  (rmsbolt--path-to-swift-tool "swift-demangle"))

;;;;; Language Integrations

(defun rmsbolt--path-to-swift-compiler ()
  "Return the path to the configured Swift compiler.

Depends on the active toolchain."
  (rmsbolt--path-to-swift-tool "swiftc"))

(defun rmsbolt--path-to-swift-tool (swift-tool)
  "Return the path to SWIFT-TOOL, depending on the active toolchain."
  (let* ((swift-tool-binary swift-tool)
         (swift-tool-toolchain-path (shell-command-to-string (format "echo -n `xcrun --find %s`" swift-tool-binary))))
    ;; If we have the Swift tool in PATH, just return it (this is the
    ;; typical case in Linux systems). If it's not in PATH, look for a
    ;; toolchain-specific path.
    (cond
     ((executable-find swift-tool-binary t)
      swift-tool-binary)
     ((executable-find swift-tool-toolchain-path t)
      swift-tool-toolchain-path))))

(defun rmsbolt--parse-compile-commands (comp-cmds file)
  "Parse COMP-CMDS and extract a compilation dir and command for FILE."
  (when-let ((json-object-type 'alist)
             (json-array-type 'vector)
             (cmds (json-read-file comp-cmds))
             (entry (cl-find-if
                     (lambda (elt)
                       (rmsbolt--file-equal-p
                        file
                        (expand-file-name
                         (alist-get 'file elt "")
                         (alist-get 'directory elt ""))))
                     cmds))
             (dir (alist-get 'directory entry))
             (cmd (or (alist-get 'command entry)
                      (string-join (alist-get 'arguments entry) " "))))
    (list dir cmd)))

(defun rmsbolt--parse-compile-flags (comp-flags file &optional cmd)
  "Parse COMP-FLAGS and build a compilation dir and command for FILE with CMD."
  (when (file-readable-p comp-flags)
    (let* ((dir (file-name-directory comp-flags))
           (flags (with-temp-buffer
                    (insert-file-contents comp-flags)
                    (split-string (buffer-string) "\n" t "[ \t\r]+")))
           (file-arg (rmsbolt--convert-file-name-to-system-type
                      (shell-quote-argument file))))
      (list dir
            (string-join
             (delq nil (append (list cmd) flags (list file-arg)))
             " ")))))

(defun rmsbolt--handle-c-compile-cmd (src-buffer)
  "Handle compile_commands.json or compile_flags.txt for c/c++ for SRC-BUFFER.
Return t if successful."
  (when-let* ((defaults (buffer-local-value 'rmsbolt--default-variables src-buffer))
              (default-dir (cl-find 'rmsbolt-default-directory defaults))
              (default-cmd (cl-find 'rmsbolt-command defaults))
              ;; We need a remote path to the compilation JSON so that it is
              ;; properly parsed, but a local source file path to match the
              ;; JSON's contents.
              (src-file (buffer-file-name src-buffer))
              (local-src-file (file-local-name src-file))
              (to-ret
               (or (when-let* ((ccj "compile_commands.json")
                               (dir (locate-dominating-file src-file ccj)))
                     (rmsbolt--parse-compile-commands
                      (expand-file-name ccj dir) local-src-file))
                   (when-let* ((cft "compile_flags.txt")
                               (dir (locate-dominating-file src-file cft)))
                     (rmsbolt--parse-compile-flags
                      (expand-file-name cft dir)
                      local-src-file
                      (with-current-buffer src-buffer
                        (or rmsbolt-command
                            (when-let* ((lang (rmsbolt--get-lang)))
                              (rmsbolt-l-compile-cmd lang))
                            "gcc")))))))
    (with-current-buffer src-buffer
      (setq-local rmsbolt-default-directory
                  (concat (file-remote-p src-file)
                          (file-name-as-directory (file-local-name (cl-first to-ret)))))
      (setq-local rmsbolt-command
                  ;; Remove -c, -S, and -o <arg> if present,
                  ;; as we will add them back
                  ;; Remove args starting with -flto, as -flto breaks asm output.
                  (thread-first (cl-second to-ret)
                                (rmsbolt-split-rm-single "-c")
                                (rmsbolt-split-rm-single "-S")
                                (rmsbolt-split-rm-single "-flto" #'string-prefix-p)
                                (rmsbolt-split-rm-double "-o")))
      t)))

(defconst rmsbolt--cargo-target-kinds
  '((("lib" "rlib" "dylib" "cdylib" "staticlib" "proc-macro") . "--lib")
    (("bin") . "--bin")
    (("test") . "--test")
    (("example") . "--example")
    (("bench") . "--bench")
    (("custom-build") . nil))
  "Cargo target kind groups, most to least preferred, with their `cargo rustc' flag.")

(defun rmsbolt--cargo-target-kind-entry (kinds)
  "Return `(INDEX . ENTRY)' in `rmsbolt--cargo-target-kinds' matching KINDS."
  (cl-loop for entry in rmsbolt--cargo-target-kinds
           for idx from 0
           when (cl-some (lambda (k) (member k (car entry))) kinds)
           return (cons idx entry)))

(defun rmsbolt--cargo-target-kind-priority (kinds)
  "Return the selection priority for Cargo target KINDS."
  (if-let* ((match (rmsbolt--cargo-target-kind-entry kinds)))
      (- (length rmsbolt--cargo-target-kinds) (car match))
    0))

(defun rmsbolt--cargo-build-script-p (target)
  "Return non-nil if TARGET is a Cargo `custom-build' target."
  (when-let* ((match (rmsbolt--cargo-target-kind-entry (alist-get 'kind target))))
    (null (cddr match))))

(defun rmsbolt--cargo-target-args (target)
  "Return `cargo rustc' target flags for TARGET, or nil for a build script."
  (when-let* ((match (rmsbolt--cargo-target-kind-entry (alist-get 'kind target)))
              (flag (cddr match)))
    (let* ((name (alist-get 'name target))
           (req-features (alist-get 'required-features target))
           (base-args (if (string= flag "--lib")
                          (list flag)
                        (list flag name))))
      (if (> (length req-features) 0)
          (append base-args (list "--features" (mapconcat #'identity req-features ",")))
        base-args))))

(defun rmsbolt--cargo-score-less-p (a b)
  "Return non-nil if score list A is lexicographically less than B."
  (cl-assert (= (length a) (length b)))
  (cl-loop for x in a
           for y in b
           unless (eql x y)
           return (< x y)))

(defun rmsbolt--cargo-sanitize-rust-source (source)
  "Return `(NO-COMMENTS . NO-STRINGS)' for Rust SOURCE."
  (let* ((no-comments
          (replace-regexp-in-string
           (rx (or (seq "//" (0+ nonl))
                   (seq "/*" (minimal-match (0+ anything)) "*/")))
           " "
           source))
         (no-strings
          (replace-regexp-in-string
           (rx "\"" (0+ (or (seq "\\" anything) (not (any "\"\\")))) "\"")
           "\"\""
           no-comments)))
    (cons no-comments no-strings)))

(defun rmsbolt--cargo-root-declares-mod-p (root-file mod-name rel-path &optional root-cache)
  "Return non-nil if ROOT-FILE declares module MOD-NAME or path attribute REL-PATH.
Optional hash table ROOT-CACHE caches sanitized file contents by ROOT-FILE."
  (when root-file
    (let ((entry
           (if (and root-cache (gethash root-file root-cache))
               (gethash root-file root-cache)
             (let ((val (if (file-readable-p root-file)
                            (with-temp-buffer
                              (insert-file-contents root-file)
                              (rmsbolt--cargo-sanitize-rust-source (buffer-string)))
                          'unreadable)))
               (when root-cache
                 (puthash root-file val root-cache))
               val))))
      (when (consp entry)
        (or (string-match-p
             (concat "\\_<mod[[:space:]]+\\(?:r#\\)?" (regexp-quote mod-name) "\\_>")
             (cdr entry))
            (string-match-p
             (rx "#[" (0+ space) "path" (0+ space) "=" (0+ space)
                 "\"" (literal rel-path) "\"")
             (car entry)))))))

(defun rmsbolt--cargo-dep-info-member-p (deps-dir workspace-root target target-src local-file dep-cache)
  "Return non-nil if Cargo dep-info in DEPS-DIR lists LOCAL-FILE under TARGET."
  (when (and deps-dir workspace-root)
    (let ((dir-ok (gethash :dir-exists dep-cache 'unset)))
      (when (eq dir-ok 'unset)
        (setq dir-ok (file-directory-p deps-dir))
        (puthash :dir-exists dir-ok dep-cache))
      (when dir-ok
        (let* ((crate-name (replace-regexp-in-string "-" "_" (alist-get 'name target)))
               (entries (gethash crate-name dep-cache 'unset)))
          (when (eq entries 'unset)
            (setq entries nil)
            (dolist (d-file (directory-files
                             deps-dir t
                             (concat "\\`" (regexp-quote crate-name) "-[0-9a-f]+\\.d\\'")))
              (when (file-readable-p d-file)
                (with-temp-buffer
                  (insert-file-contents d-file nil 0 8192)
                  (goto-char (point-min))
                  (let ((line (buffer-substring-no-properties
                               (point-min) (line-end-position))))
                    (when (string-match ":[[:space:]]+\\(.+\\)\\'" line)
                      (let ((files
                             (mapcar (lambda (p)
                                       (file-local-name
                                        (expand-file-name p workspace-root)))
                                     (split-string (match-string 1 line) "[ \t\r\n]+" t))))
                        (when files
                          (push files entries))))))))
            (puthash crate-name entries dep-cache))
          (cl-some (lambda (files)
                     (and (equal (car files) target-src)
                          (member local-file files)))
                   entries))))))

(defun rmsbolt--cargo-find-target (metadata file &optional remote-prefix)
  "Find the best `(PKG . TARGET)' in Cargo METADATA for local FILE."
  (let* ((remote (or remote-prefix ""))
         (local-file (file-local-name (expand-file-name file)))
         (workspace-root (alist-get 'workspace_root metadata))
         (target-directory (alist-get 'target_directory metadata))
         (deps-dir (and target-directory
                        (expand-file-name "debug/deps" (concat remote target-directory))))
         (packages (alist-get 'packages metadata))
         (root-cache (make-hash-table :test #'equal))
         (dep-cache (make-hash-table :test #'equal))
         exact-match
         exact-prio
         best-match
         best-score)
    (cl-loop for pkg across packages do
             (cl-loop for target across (alist-get 'targets pkg) do
                      (let ((target-src (file-local-name
                                         (expand-file-name (alist-get 'src_path target)))))
                        (when (equal local-file target-src)
                          (let ((prio (rmsbolt--cargo-target-kind-priority
                                       (alist-get 'kind target))))
                            (when (or (not exact-prio) (> prio exact-prio))
                              (setq exact-match (cons pkg target)
                                    exact-prio prio)))))))
    (or exact-match
        (progn
          (cl-loop for pkg across packages do
                   (let ((pkg-dir (file-name-directory
                                   (file-local-name
                                    (expand-file-name (alist-get 'manifest_path pkg))))))
                     (cl-loop for target across (alist-get 'targets pkg) do
                              (let* ((target-src (file-local-name
                                                  (expand-file-name (alist-get 'src_path target))))
                                     (prio (rmsbolt--cargo-target-kind-priority
                                            (alist-get 'kind target)))
                                     (target-dir (file-name-directory target-src))
                                     (target-nondir (file-name-nondirectory target-src))
                                     (target-stem-dir (file-name-as-directory
                                                       (file-name-sans-extension target-src)))
                                     (dir-score
                                      (cond
                                       ((and (not (member target-nondir '("lib.rs" "main.rs" "mod.rs")))
                                             (string-prefix-p target-stem-dir local-file))
                                        (1+ (length target-stem-dir)))
                                       ((string-prefix-p target-dir local-file)
                                        (length target-dir))
                                       ((string-prefix-p pkg-dir local-file)
                                        (length pkg-dir))
                                       (t 0))))
                                (when (and (> dir-score 0)
                                           (or (not best-score)
                                               (rmsbolt--cargo-score-less-p
                                                best-score
                                                (list (length pkg-dir) 1 dir-score 1 prio))))
                                  (let* ((dep-match
                                          (if (rmsbolt--cargo-dep-info-member-p
                                               deps-dir workspace-root target
                                               target-src local-file dep-cache)
                                              1
                                            0))
                                         (rel (and (string-prefix-p target-dir local-file)
                                                   (file-relative-name local-file target-dir)))
                                         (top-mod (and rel
                                                       (car (split-string
                                                             (file-name-sans-extension rel) "/"))))
                                         (mod-match
                                          (if (and (= dep-match 0)
                                                   top-mod
                                                   (rmsbolt--cargo-root-declares-mod-p
                                                    (concat remote target-src)
                                                    top-mod rel root-cache))
                                              1
                                            0))
                                         (score (list (length pkg-dir) dep-match dir-score mod-match prio)))
                                    (when (or (not best-score)
                                              (rmsbolt--cargo-score-less-p best-score score))
                                      (setq best-match (cons pkg target)
                                            best-score score))))))))
          (when (and best-match
                     (= (nth 1 best-score) 0)
                     (= (nth 3 best-score) 0))
            (message "RMSBolt: guessing Cargo target `%s' for %s"
                     (alist-get 'name (cdr best-match))
                     (file-name-nondirectory local-file)))
          best-match))))

(defun rmsbolt--extract-cargo-rustc-cmd (output &optional crate-name)
  "Extract the `rustc' command for CRATE-NAME from `cargo -vv' OUTPUT.
CRATE-NAME may be a target name string, t for `build_script_build', or
nil to match the last `rustc' invocation."
  ;; Cargo prints `Running `<env> rustc --crate-name <name> ...`' on stderr.
  ;; Environment variables can contain line breaks, so search backward for the
  ;; last line of the target command (which ends with a backtick).
  ;; Then search backward for the opening `Running `' prefix.
  (with-temp-buffer
    (insert output)
    (goto-char (point-max))
    (let* ((expected (cond
                      ((eq crate-name t) "build_script_build")
                      ((stringp crate-name)
                       (replace-regexp-in-string "-" "_" crate-name))
                      (t nil)))
           (pattern (if expected
                        (rx "--crate-name" (1+ space) (literal expected)
                            symbol-end (0+ nonl) "`" line-end)
                      (rx "--crate-name" (1+ space) (1+ (or alnum "_"))
                          (0+ nonl) "`" line-end))))
      (when (re-search-backward pattern nil t)
        (let ((cmd-end (1- (match-end 0))))
          (when (re-search-backward (rx line-start (0+ blank) "Running `") nil t)
            (buffer-substring-no-properties (match-end 0) cmd-end)))))))

(defun rmsbolt--clean-cargo-rustc-cmd (cmd)
  "Remove Cargo flags from CMD that conflict with RMSBolt output.
Flags such as `-C strip=...' are kept because linker stripping does not
remove `.loc' directives from `--emit asm' output."
  (let ((cleaned
         (thread-first cmd
                       (rmsbolt-split-rm-double "--print")
                       (rmsbolt-split-rm-single "--print=" #'string-prefix-p)
                       (rmsbolt-split-rm-double "--emit")
                       (rmsbolt-split-rm-single "--emit=" #'string-prefix-p)
                       (rmsbolt-split-rm-double "--out-dir")
                       (rmsbolt-split-rm-single "--out-dir=" #'string-prefix-p)
                       (rmsbolt-split-rm-double "-o")
                       (rmsbolt-split-rm-double "--error-format")
                       (rmsbolt-split-rm-single "--error-format=" #'string-prefix-p)
                       (rmsbolt-split-rm-double "--json")
                       (rmsbolt-split-rm-single "--json=" #'string-prefix-p)
                       (rmsbolt-split-rm-double "-C" "extra-filename=" #'string-prefix-p)
                       (rmsbolt-split-rm-single "-Cextra-filename=" #'string-prefix-p)
                       (rmsbolt-split-rm-double "-C" "incremental=" #'string-prefix-p)
                       (rmsbolt-split-rm-single "-Cincremental=" #'string-prefix-p)
                       (rmsbolt-split-rm-double "-C" "debuginfo=" #'string-prefix-p)
                       (rmsbolt-split-rm-single "-Cdebuginfo=" #'string-prefix-p)
                       (rmsbolt-split-rm-double "-C" "lto" #'string-prefix-p)
                       (rmsbolt-split-rm-single "-Clto" #'string-prefix-p))))
    (if (string-match-p (rx bos (1+ (any "A-Za-z0-9_-")) "=") cleaned)
        (concat "env " cleaned)
      cleaned)))

(defun rmsbolt--cargo-format-error (output)
  "Format Cargo error OUTPUT as a single truncated line."
  (let* ((trimmed (string-trim (or output "")))
         (summary
          (if (string-match
               (rx line-start (0+ blank) "error" (opt "[" (1+ alnum) "]") ":" (0+ nonl))
               trimmed)
              (string-trim (match-string 0 trimmed))
            (replace-regexp-in-string "[ \t\n\r]+" " " trimmed))))
    (truncate-string-to-width
     (if (string-empty-p summary) "unknown cargo error" summary)
     200 nil nil "...")))

(defvar rmsbolt--cargo-cmd-cache (make-hash-table :test #'equal)
  "Cache of Cargo metadata and compile commands.")

(defun rmsbolt--cargo-cache-stamp (manifest-dir &optional workspace-dir)
  "Return a modification-time stamp for MANIFEST-DIR and WORKSPACE-DIR."
  (let ((dirs (delete-dups
               (list (file-name-as-directory manifest-dir)
                     (file-name-as-directory (or workspace-dir manifest-dir)))))
        stamp)
    (dolist (dir dirs (nreverse stamp))
      (dolist (name '("Cargo.toml" "Cargo.lock"))
        (let ((path (expand-file-name name dir)))
          (push (cons path
                      (file-attribute-modification-time
                       (file-attributes path)))
                stamp))))))

(defun rmsbolt--cargo-cache-get (key manifest-dir)
  "Return the cached value for KEY in MANIFEST-DIR if its stamp is valid."
  (when-let* ((entry (gethash key rmsbolt--cargo-cmd-cache))
              (workspace-dir (plist-get entry :workspace-dir))
              ((equal (plist-get entry :stamp)
                      (rmsbolt--cargo-cache-stamp manifest-dir workspace-dir))))
    (plist-get entry :value)))

(defun rmsbolt--cargo-cache-put (key manifest-dir workspace-dir value)
  "Store VALUE for KEY under MANIFEST-DIR and WORKSPACE-DIR."
  (puthash key
           (list :workspace-dir workspace-dir
                 :stamp (rmsbolt--cargo-cache-stamp manifest-dir workspace-dir)
                 :value value)
           rmsbolt--cargo-cmd-cache)
  value)

(defun rmsbolt--parse-cargo-compile-cmd (manifest-dir file)
  "Invoke Cargo in MANIFEST-DIR and extract the compile dir and command for FILE."
  (let ((file-key (cons manifest-dir file)))
    (or (rmsbolt--cargo-cache-get file-key manifest-dir)
        (let* ((default-directory manifest-dir)
               (remote (file-remote-p manifest-dir))
               (json-object-type 'alist)
               (json-array-type 'vector)
               err-msg
               result)
          (with-temp-message "RMSBolt: querying cargo..."
            (let* (meta-err
                   (metadata
                    (or (rmsbolt--cargo-cache-get manifest-dir manifest-dir)
                        (with-temp-buffer
                          (if (zerop (condition-case err
                                         (process-file "cargo" nil t nil
                                                       "metadata" "--no-deps" "--format-version" "1")
                                       (error
                                        (insert (error-message-string err))
                                        1)))
                              (progn
                                (goto-char (point-min))
                                (when (re-search-forward "^[[:space:]]*{" nil t)
                                  (goto-char (match-beginning 0)))
                                (condition-case err
                                    (json-read)
                                  (error
                                   (setq meta-err (error-message-string err))
                                   nil)))
                            (setq meta-err (buffer-string))
                            nil)))))
              (if (not metadata)
                  (setq err-msg (rmsbolt--cargo-format-error meta-err))
                (let* ((workspace-root (alist-get 'workspace_root metadata))
                       (workspace-dir (and workspace-root
                                           (concat remote (file-name-as-directory workspace-root))))
                       (match (and workspace-dir
                                   (rmsbolt--cargo-find-target metadata file remote)))
                       (pkg (car-safe match))
                       (target (cdr-safe match))
                       (pkg-name (alist-get 'name pkg))
                       (build-script-p (and target (rmsbolt--cargo-build-script-p target)))
                       (target-args (and target (rmsbolt--cargo-target-args target))))
                  (when workspace-dir
                    (rmsbolt--cargo-cache-put manifest-dir manifest-dir workspace-dir metadata))
                  (if (not (and workspace-dir pkg-name (or build-script-p target-args)))
                      (setq err-msg (format "no target found for %s" file))
                    (let ((target-key (list workspace-dir pkg-name
                                            (if build-script-p 'custom-build target-args))))
                      (if-let* ((cached-target (rmsbolt--cargo-cache-get target-key manifest-dir)))
                          (setq result (rmsbolt--cargo-cache-put
                                        file-key manifest-dir workspace-dir cached-target))
                        (let* ((default-directory workspace-dir)
                               (cargo-args
                                (if build-script-p
                                    (let ((other-args
                                           (cl-loop for tgt across (alist-get 'targets pkg)
                                                    for args = (rmsbolt--cargo-target-args tgt)
                                                    when args
                                                    return args)))
                                      (if other-args
                                          (append (list "rustc" "-p" pkg-name)
                                                  other-args
                                                  '("-vv" "--" "--print" "crate-name"))
                                        (list "check" "-p" pkg-name "-vv")))
                                  (append (list "rustc" "-p" pkg-name)
                                          target-args
                                          '("-vv" "--" "--print" "crate-name"))))
                               cmd-err
                               (output
                                (with-temp-buffer
                                  (when (and build-script-p rmsbolt-cargo-force-build-script)
                                    (condition-case err
                                        (set-file-times (concat remote file))
                                      (error
                                       (message "RMSBolt: could not update timestamp of %s: %s"
                                                file (error-message-string err)))))
                                  (if (zerop (condition-case err
                                                 (apply #'process-file "cargo" nil t nil cargo-args)
                                               (error
                                                (insert (error-message-string err))
                                                1)))
                                      (buffer-string)
                                    (setq cmd-err (buffer-string))
                                    nil)))
                               (raw-cmd (and output
                                             (rmsbolt--extract-cargo-rustc-cmd
                                              output
                                              (if build-script-p
                                                  "build_script_build"
                                                (alist-get 'name target))))))
                          (cond
                           (raw-cmd
                            (let ((res (list workspace-dir (rmsbolt--clean-cargo-rustc-cmd raw-cmd))))
                              (rmsbolt--cargo-cache-put target-key manifest-dir workspace-dir res)
                              (setq result (rmsbolt--cargo-cache-put
                                            file-key manifest-dir workspace-dir res))))
                           (cmd-err
                            (setq err-msg (rmsbolt--cargo-format-error cmd-err)))
                           ((and build-script-p (not rmsbolt-cargo-force-build-script))
                            (setq err-msg
                                  (format "build script for %s is already fresh (customize `rmsbolt-cargo-force-build-script' to force)"
                                          pkg-name)))
                           (t
                            (setq err-msg
                                  (format "could not extract rustc command for %s"
                                          pkg-name))))))))))))
          (when err-msg
            (message "RMSBolt: Cargo integration failed: %s" err-msg))
          result))))

(defun rmsbolt--handle-rust-compile-cmd (src-buffer)
  "Handle Cargo integration for Rust for a given SRC-BUFFER.
Return t if successful."
  (when-let* ((defaults (buffer-local-value 'rmsbolt--default-variables src-buffer))
             (default-dir (cl-find 'rmsbolt-default-directory defaults))
             (default-cmd (cl-find 'rmsbolt-command defaults))
             (src-file (buffer-file-name src-buffer))
             (manifest-dir (locate-dominating-file src-file "Cargo.toml"))
             (to-ret (rmsbolt--parse-cargo-compile-cmd
                      manifest-dir (file-local-name src-file))))
    (with-current-buffer src-buffer
      (setq-local rmsbolt-default-directory (cl-first to-ret))
      (setq-local rmsbolt-command (cl-second to-ret))
      t)))

;;;; Cargo ASM

(cl-defstruct (rmsbolt--cargo-asm-function
               (:conc-name rmsbolt--cargo-asm-function-))
  node name display-name modules qualifiers type type-base trait trait-base
  generic-type-p)

(defun rmsbolt--cargo-asm--strip-raw-identifier (name)
  "Return NAME without a Rust raw identifier prefix."
  (if (string-prefix-p "r#" name)
      (substring name 2)
    name))

(defun rmsbolt--cargo-asm--trim-type (text)
  "Return TYPE TEXT with its whitespace runs collapsed."
  (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text)))

(defun rmsbolt--cargo-asm--strip-angle-groups (text)
  "Return TEXT without text inside angle brackets."
  (let ((depth 0)
        (result nil))
    (dolist (char (string-to-list text))
      (cond
       ((= char ?<) (setq depth (1+ depth)))
       ((= char ?>)
        (when (> depth 0)
          (setq depth (1- depth))))
       ((= depth 0) (push char result))))
    (apply #'string (nreverse result))))

(defun rmsbolt--cargo-asm--base-identifier (type)
  "Return the base identifier of Rust type TYPE."
  (let* ((flat (rmsbolt--cargo-asm--strip-angle-groups type))
         (flat (replace-regexp-in-string "[ \t\n\r]+" "" flat))
         (flat (replace-regexp-in-string
                "\\`\\(?:(?:crate\\|self\\|super)::\\)+" "" flat))
         (base (car (last (split-string flat "::" t)))))
    (rmsbolt--cargo-asm--strip-raw-identifier
     (replace-regexp-in-string "\\`[&*]+" "" (or base "")))))

(defun rmsbolt--cargo-asm--node-name (node)
  "Return the bare name of Rust NODE."
  (when-let* ((name-node (treesit-node-child-by-field-name node "name")))
    (rmsbolt--cargo-asm--strip-raw-identifier
     (treesit-node-text name-node t))))

(defun rmsbolt--cargo-asm--file-module-path (src-file &optional target-src)
  "Return the module path of SRC-FILE relative to TARGET-SRC.
A nil result means that SRC-FILE is a crate root."
  (when src-file
    (let* ((src-file (file-local-name (expand-file-name src-file)))
           (target-src (and target-src
                            (file-local-name (expand-file-name target-src))))
           (base
            (cond
             (target-src
              (if (member (file-name-nondirectory target-src)
                          '("lib.rs" "main.rs" "mod.rs"))
                  (file-name-directory target-src)
                (file-name-as-directory
                 (file-name-sans-extension target-src))))
             ((string-match "\\(?:\\`\\|/\\)src/" src-file)
              (substring src-file 0 (match-end 0)))))
           (root-p (or (and target-src (equal src-file target-src))
                       (member (file-name-nondirectory src-file)
                               '("lib.rs" "main.rs")))))
      (when (and (not root-p)
                 base
                 (string-prefix-p base src-file))
        (let* ((relative (file-relative-name src-file base))
               (parts (split-string
                       (file-name-sans-extension relative) "/" t)))
          (if (equal (car (last parts)) "mod")
              (butlast parts)
            parts))))))

(defun rmsbolt--cargo-asm--make-function (node &optional target-src)
  "Return a function descriptor for Rust function NODE.
TARGET-SRC is the root source file of the Cargo target."
  (when (equal (treesit-node-type node) "function_item")
    (when-let* ((name (rmsbolt--cargo-asm--node-name node)))
      (let ((parent (treesit-node-parent node))
            mods
            function-parents
            impl)
        (while parent
          (pcase (treesit-node-type parent)
            ("mod_item"
             (when-let* ((mod-name (rmsbolt--cargo-asm--node-name parent)))
               (push mod-name mods)))
            ("function_item"
             (when-let* ((function-name (rmsbolt--cargo-asm--node-name parent)))
               (push function-name function-parents)))
            ("impl_item"
             (unless impl
               (setq impl parent))))
          (setq parent (treesit-node-parent parent)))
        (let* ((modules
                (append (rmsbolt--cargo-asm--file-module-path
                         (buffer-file-name) target-src)
                        (nreverse mods)
                        (nreverse function-parents)))
               (type-node (and impl (treesit-node-child-by-field-name impl "type")))
               (trait-node (and impl (treesit-node-child-by-field-name impl "trait")))
               (type-parameters
                (and impl (treesit-node-child-by-field-name impl "type_parameters")))
               (type (and type-node
                          (rmsbolt--cargo-asm--trim-type
                           (treesit-node-text type-node t))))
               (trait (and trait-node
                           (rmsbolt--cargo-asm--trim-type
                            (treesit-node-text trait-node t))))
               (type-base (and type (rmsbolt--cargo-asm--base-identifier type)))
               (trait-base (and trait (rmsbolt--cargo-asm--base-identifier trait)))
               (display-name
                (cond
                 ((and type trait)
                  (concat (if modules
                              (concat (string-join modules "::") "::")
                            "")
                          (format "<%s as %s>::%s" type trait name)))
                 (type
                  (string-join (append modules (list type name)) "::"))
                 (t
                  (string-join (append modules (list name)) "::"))))
               (type-qualifier (and type
                                    (if type-parameters
                                        (or type-base type)
                                      type)))
               (qualifiers (append modules
                                   (when type-qualifier (list type-qualifier))
                                   (when trait-base (list trait-base)))))
          (make-rmsbolt--cargo-asm-function
           :node node
           :name name
           :display-name display-name
           :modules modules
           :qualifiers qualifiers
           :type type
           :type-base type-base
           :trait trait
           :trait-base trait-base
           :generic-type-p (not (null type-parameters))))))))

(defun rmsbolt--cargo-asm-ensure-parser ()
  "Make sure that the current buffer has a Rust tree-sitter parser."
  (when (and (fboundp 'treesit-available-p)
             (treesit-available-p)
             (fboundp 'treesit-language-available-p)
             (treesit-language-available-p 'rust))
    (or (car (treesit-parser-list nil 'rust))
        (treesit-parser-create 'rust))))

(defun rmsbolt--cargo-asm-functions (&optional target-src)
  "Return all Rust functions in the current buffer.
TARGET-SRC is the root source file of the Cargo target."
  (let (functions)
    (when (rmsbolt--cargo-asm-ensure-parser)
      (dolist (capture
               (treesit-query-capture (treesit-buffer-root-node)
                                      "(function_item) @function"))
        (when (eq (car capture) 'function)
          (when-let* ((function (rmsbolt--cargo-asm--make-function
                                 (cdr capture) target-src)))
            (push function functions)))))
    (nreverse functions)))

(defun rmsbolt--cargo-asm-function-at-point (&optional target-src)
  "Return the Rust function at point, or nil.
TARGET-SRC is the root source file of the Cargo target."
  (when (and (rmsbolt--cargo-asm-ensure-parser)
             (fboundp 'treesit-defun-at-point))
    (let ((treesit-defun-type-regexp "\\`function_item\\'")
          (treesit-thing-settings nil))
      (when-let* ((node (treesit-defun-at-point)))
        (rmsbolt--cargo-asm--make-function node target-src)))))

(defun rmsbolt--cargo-asm--strip-trailing-generics (name)
  "Remove generic arguments from the end of item NAME."
  (if (not (string-suffix-p ">" name))
      name
    (let ((depth 0)
          (index (1- (length name)))
          start)
      (while (>= index 0)
        (let ((char (aref name index)))
          (cond
           ((= char ?>) (setq depth (1+ depth)))
           ((= char ?<)
            (setq depth (1- depth))
            (when (= depth 0)
              (setq start index
                    index -1)))))
        (setq index (1- index)))
      (if (and start
               (> start 1)
               (string= (substring name (- start 2) start) "::"))
          (substring name 0 (- start 2))
        name))))

(defun rmsbolt--cargo-asm--normalize-item-name (name)
  "Return item NAME in a form that is independent of the crate root."
  (let ((name (replace-regexp-in-string (rx "[" (1+ (any "0-9a-f")) "]") "" name)))
    (setq name
          (replace-regexp-in-string
           (rx (group (or bol "<" " as "))
               (0+ (any "&*' "))
               (1+ (or alnum "_")) "::")
           "\\1" name))
    (rmsbolt--cargo-asm--strip-trailing-generics name)))

(defun rmsbolt--cargo-asm--matching-angle-end (string start)
  "Return the index of the angle that closes the one at START in STRING."
  (let ((depth 0)
        (index start)
        end)
    (while (and (< index (length string)) (not end))
      (let ((char (aref string index)))
        (cond
         ((= char ?<) (setq depth (1+ depth)))
         ((= char ?>)
          (setq depth (1- depth))
          (when (= depth 0)
            (setq end index)))))
      (setq index (1+ index)))
    end))

(defun rmsbolt--cargo-asm--item-parts (name)
  "Return the method and qualifiers of cargo-asm item NAME."
  (let ((name (rmsbolt--cargo-asm--normalize-item-name name)))
    (if (not (string-prefix-p "<" name))
        (let* ((parts (split-string name "::" t))
               (method (car (last parts)))
               (path (butlast parts)))
          (list :angle nil :path path :method method))
      (let* ((end (rmsbolt--cargo-asm--matching-angle-end name 0))
             (body (and end (substring name 1 end)))
             (rest (and end (substring name (1+ end))))
             (method (and rest
                          (if (string-prefix-p "::" rest)
                              (substring rest 2)
                            rest)))
             (as-index (and body (string-match " as " body))))
        (list :angle t
              :type (and body (if as-index (substring body 0 as-index) body))
              :trait (and as-index (substring body (+ as-index 4)))
              :method method)))))

(defun rmsbolt--cargo-asm--normalize-type-string (type)
  "Return TYPE without whitespace or a leading crate path."
  (let ((type (replace-regexp-in-string "[ \t\n\r]+" "" type)))
    (replace-regexp-in-string
     "\\`\\(?:(?:crate\\|self\\|super)::\\)+" "" type)))

(defun rmsbolt--cargo-asm--type-path-parts (type)
  "Return the module parts and base identifier of TYPE."
  (let* ((flat (rmsbolt--cargo-asm--strip-angle-groups type))
         (flat (rmsbolt--cargo-asm--normalize-type-string flat))
         (parts (split-string flat "::" t)))
    (cons (butlast parts) (car (last parts)))))

(defun rmsbolt--cargo-asm--descriptor-type-path (function)
  "Return the expected module parts and base identifier for FUNCTION."
  (let* ((type (rmsbolt--cargo-asm--normalize-type-string
                (rmsbolt--cargo-asm-function-type function)))
         (flat (rmsbolt--cargo-asm--strip-angle-groups type))
         (parts (split-string flat "::" t))
         (type-modules (and (cdr parts) (butlast parts))))
    (cons (or type-modules
              (rmsbolt--cargo-asm-function-modules function))
          (or (rmsbolt--cargo-asm-function-type-base function)
              (car (last parts))))))

(defun rmsbolt--cargo-asm--type-matches-p (function type)
  "Return non-nil if TYPE matches the impl type of FUNCTION."
  (when-let* ((desired (rmsbolt--cargo-asm-function-type function)))
    (let* ((actual (rmsbolt--cargo-asm--normalize-type-string type))
           (actual-parts (rmsbolt--cargo-asm--type-path-parts type))
           (actual-modules (car actual-parts))
           (actual-base (rmsbolt--cargo-asm--base-identifier type))
           (expected-parts (rmsbolt--cargo-asm--descriptor-type-path function))
           (expected-modules (car expected-parts))
           (expected-base (cdr expected-parts)))
      (if (rmsbolt--cargo-asm-function-generic-type-p function)
          (and (equal actual-base expected-base)
               (equal actual-modules expected-modules))
        (let* ((desired (rmsbolt--cargo-asm--normalize-type-string desired))
               (flat (rmsbolt--cargo-asm--strip-angle-groups desired))
               (has-path (string-match-p "::" flat))
               (modules (rmsbolt--cargo-asm-function-modules function))
               (expected (cond
                          (has-path desired)
                          (modules (concat (string-join modules "::") "::" desired))
                          (t desired))))
          (equal actual expected))))))

(defun rmsbolt--cargo-asm--trait-matches-p (function trait)
  "Return non-nil if TRAIT matches the impl trait of FUNCTION."
  (let ((desired (rmsbolt--cargo-asm-function-trait-base function)))
    (if desired
        (and trait
             (equal (rmsbolt--cargo-asm--base-identifier trait) desired))
      (null trait))))

(defun rmsbolt--cargo-asm-item-matches-p (function item-name)
  "Return non-nil if cargo-asm ITEM-NAME matches FUNCTION."
  (let* ((parts (rmsbolt--cargo-asm--item-parts item-name))
         (method (plist-get parts :method)))
    (when (equal method (rmsbolt--cargo-asm-function-name function))
      (if (plist-get parts :angle)
          (and (rmsbolt--cargo-asm--type-matches-p function (plist-get parts :type))
               (rmsbolt--cargo-asm--trait-matches-p function (plist-get parts :trait)))
        (and (not (rmsbolt--cargo-asm-function-trait function))
             (if (rmsbolt--cargo-asm-function-type function)
                 (rmsbolt--cargo-asm--type-matches-p
                  function (string-join (plist-get parts :path) "::"))
               (equal (plist-get parts :path)
                      (rmsbolt--cargo-asm-function-modules function))))))))

(defun rmsbolt--cargo-asm-matching-ids (functions items)
  "Return the cargo-asm item ids in ITEMS that match FUNCTIONS."
  (sort (delete-dups
         (cl-loop for item in items
                  for name = (or (alist-get 'name item)
                                 (alist-get 'full_name item))
                  when (and name
                            (cl-some (lambda (function)
                                       (rmsbolt--cargo-asm-item-matches-p
                                        function name))
                                     functions))
                  collect (alist-get 'id item)))
        #'<))

(defun rmsbolt--cargo-asm--metadata (manifest-dir)
  "Return Cargo metadata for MANIFEST-DIR."
  (or (rmsbolt--cargo-cache-get manifest-dir manifest-dir)
      (let ((default-directory manifest-dir)
            (json-object-type 'alist)
            (json-array-type 'vector)
            metadata)
        (with-temp-buffer
          (unless (zerop (condition-case err
                             (process-file "cargo" nil t nil
                                           "metadata" "--no-deps" "--format-version" "1")
                           (error
                            (insert (error-message-string err))
                            1)))
            (user-error "Cargo metadata failed: %s"
                        (string-trim (buffer-string))))
          (goto-char (point-min))
          (when (re-search-forward "^[[:space:]]*{" nil t)
            (goto-char (match-beginning 0)))
          (condition-case err
              (setq metadata (json-read))
            (error
             (user-error "Could not parse Cargo metadata: %s"
                         (error-message-string err)))))
        (let* ((remote (file-remote-p manifest-dir))
               (workspace-root (alist-get 'workspace_root metadata))
               (workspace-dir (and workspace-root
                                   (concat remote
                                           (file-name-as-directory
                                            workspace-root)))))
          (rmsbolt--cargo-cache-put manifest-dir manifest-dir
                                    (or workspace-dir manifest-dir)
                                    metadata)))))

(defun rmsbolt--cargo-asm--target (src-buffer)
  "Return workspace directory, package name, and target args for SRC-BUFFER."
  (let* ((src-file (buffer-file-name src-buffer))
         (manifest-dir (and src-file
                            (locate-dominating-file src-file "Cargo.toml"))))
    (unless manifest-dir
      (user-error "Buffer is not in a Cargo project"))
    (let* ((manifest-dir (file-name-as-directory (expand-file-name manifest-dir)))
           (remote (file-remote-p manifest-dir))
           (metadata (rmsbolt--cargo-asm--metadata manifest-dir))
           (workspace-root (alist-get 'workspace_root metadata))
           (workspace-dir (and workspace-root
                               (concat remote
                                       (file-name-as-directory workspace-root))))
           (match (and workspace-dir
                       (rmsbolt--cargo-find-target
                        metadata (file-local-name (expand-file-name src-file)) remote)))
           (package (car-safe match))
           (target (cdr-safe match))
           (package-name (alist-get 'name package))
           (target-args (and target (rmsbolt--cargo-target-args target)))
           (target-src (alist-get 'src_path target)))
      (unless workspace-dir
        (user-error "Could not find the Cargo workspace root"))
      (when (or (not package-name)
                (not target)
                (rmsbolt--cargo-build-script-p target))
        (user-error "cargo-asm is not available for build scripts"))
      (unless target-args
        (user-error "Could not find a Cargo target for %s" src-file))
      (list workspace-dir package-name target-args
            (and target-src
                 (file-local-name (expand-file-name target-src)))))))

(defun rmsbolt--cargo-asm--base-command (src-buffer package-name target-args)
  "Return the cargo-asm command for SRC-BUFFER."
  (let ((parts
         (append
          (list "cargo-asm" "-p" package-name)
          target-args
          (list (if (equal (buffer-local-value 'rmsbolt-asm-format src-buffer)
                           "att")
                    "--att"
                  "--intel"))
          (list "--asm")
          (when (buffer-local-value 'rmsbolt-filter-directives src-buffer)
            (list "--simplify"))
          (list (if (buffer-local-value 'rmsbolt-filter-labels src-buffer)
                    "-R"
                  "-K"))
          (list (if (buffer-local-value 'rmsbolt-demangle src-buffer)
                    "--short-name"
                  "--keep-mangled")))))
    (mapconcat #'shell-quote-argument parts " ")))

(defun rmsbolt--cargo-asm--json-items (file)
  "Return the cargo-asm JSON items in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (unless (search-forward "[" nil t)
      (error "cargo-asm did not return JSON"))
    (goto-char (1- (point)))
    (let ((json-object-type 'alist)
          (json-array-type 'list)
          (json-key-type 'symbol))
      (json-read))))

(defun rmsbolt--reset-default-variables (src-buffer)
  "Clean up the default variables in SRC-BUFFER."
  (with-current-buffer src-buffer
    (dolist (var rmsbolt--default-variables)
      (rmsbolt--set-local var nil))
    (setq rmsbolt--default-variables nil)))

(defun rmsbolt--handle-finish-cargo-asm (buffer str &optional stopped)
  "Finish hook for cargo-asm compilations.
Argument BUFFER compilation buffer.
Argument STR compilation finish status.
Argument STOPPED non-nil if the compilation was stopped."
  (let ((src-buffer (buffer-local-value 'rmsbolt-src-buffer buffer))
        (failed (and str (not (string-match "^finished" str)))))
    (if (or stopped failed)
        (rmsbolt--handle-finish-compile buffer str :stopped stopped)
      (let* ((json-file (expand-file-name "rmsbolt-cargo-asm.json"
                                          rmsbolt--temp-dir))
             (function (buffer-local-value 'rmsbolt--cargo-asm-function
                                           src-buffer))
             (command (buffer-local-value 'rmsbolt--cargo-asm-command
                                          src-buffer))
             (workspace-dir (buffer-local-value
                             'rmsbolt--cargo-asm-workspace-dir src-buffer))
             (ids (condition-case err
                      (rmsbolt--cargo-asm-matching-ids
                       (list function)
                       (rmsbolt--cargo-asm--json-items json-file))
                    (error
                     (rmsbolt--reset-default-variables src-buffer)
                     (message "RMSBolt: could not parse cargo-asm JSON: %s"
                              (error-message-string err))
                     'error))))
        (cond
         ((eq ids 'error))
         ((not ids)
          (rmsbolt--reset-default-variables src-buffer)
          (message "RMSBolt: cargo-asm found no matching function for %s"
                   (rmsbolt--cargo-asm-function-display-name function)))
         (t
          (let* ((output (shell-quote-argument
                          (file-local-name
                           (rmsbolt-output-filename src-buffer t))))
                 (asm-command
                  (concat command " -q --no-color --rust --this-workspace"))
                 (shell-command
                  (concat "status=0; for id in "
                          (mapconcat (lambda (id) (number-to-string id))
                                     ids " ")
                          "; do " asm-command
                          " \"$id\" || { status=$?; break; }; done > "
                          output "; exit $status"))
                 (default-directory workspace-dir)
                 (shell-file-name (or (executable-find rmsbolt--shell)
                                      shell-file-name)))
            (process-file shell-file-name nil nil nil "-c" shell-command)
            (rmsbolt--handle-finish-compile buffer str))))))))

(defun rmsbolt--cargo-asm--prompt (prompt-function functions at-point)
  "Read a function from FUNCTIONS with PROMPT-FUNCTION."
  (let* ((names (mapcar #'rmsbolt--cargo-asm-function-display-name functions))
         (default (and at-point
                       (rmsbolt--cargo-asm-function-display-name at-point)))
         (choice (funcall (if (functionp prompt-function)
                              prompt-function
                            #'completing-read)
                          "Rust function: " names nil t nil nil default)))
    (cond
     ((rmsbolt--cargo-asm-function-p choice) choice)
     ((stringp choice)
      (or (cl-find choice functions
                   :key #'rmsbolt--cargo-asm-function-display-name
                   :test #'equal)
          (cl-find choice functions
                   :key #'rmsbolt--cargo-asm-function-name
                   :test #'equal)
          (user-error "No such function: %s" choice)))
     (t (user-error "No function selected")))))

(defun rmsbolt--cargo-asm--run (src-buffer function &optional target)
  "Run cargo-asm for FUNCTION in SRC-BUFFER.
TARGET is the Cargo target information from `rmsbolt--cargo-asm--target'."
  (rmsbolt--stop-running-compilation)
  (let* ((target (or target (rmsbolt--cargo-asm--target src-buffer)))
         (workspace-dir (nth 0 target))
         (package-name (nth 1 target))
         (target-args (nth 2 target))
         (base-command (rmsbolt--cargo-asm--base-command
                        src-buffer package-name target-args))
         (command (rmsbolt--apply-arg-overrides
                   base-command
                   (buffer-local-value 'rmsbolt-compile-arg-overrides src-buffer))))
    (rmsbolt--gen-temp)
    (let ((json-file (expand-file-name "rmsbolt-cargo-asm.json"
                                       rmsbolt--temp-dir)))
      (with-current-buffer src-buffer
        (dolist (var '(rmsbolt-command
                       rmsbolt--cargo-asm-active
                       rmsbolt--cargo-asm-workspace-dir
                       rmsbolt--cargo-asm-function
                       rmsbolt--cargo-asm-command))
          (add-to-list 'rmsbolt--default-variables var))
        (setq-local rmsbolt-command base-command)
        (setq-local rmsbolt--cargo-asm-active t)
        (setq-local rmsbolt--cargo-asm-workspace-dir workspace-dir)
        (setq-local rmsbolt--cargo-asm-function function)
        (setq-local rmsbolt--cargo-asm-command command)
        (setq rmsbolt-src-buffer src-buffer))
      (let ((shell-command
             (concat command " --no-color --json > "
                     (shell-quote-argument (file-local-name json-file)))))
        (with-current-buffer
            (let ((default-directory workspace-dir)
                  (shell-file-name (or (executable-find rmsbolt--shell)
                                       shell-file-name))
                  (compilation-auto-jump-to-first-error t))
              (rmsbolt-with-display-buffer-no-window
               (compilation-start shell-command nil
                                  (lambda (&rest _) "*rmsbolt-compilation*"))))
          (setq default-directory workspace-dir)
          (setq-local compilation-skip-threshold 2)
          (add-hook 'compilation-finish-functions
                    #'rmsbolt--handle-finish-cargo-asm nil t)
          (setq rmsbolt-src-buffer src-buffer))))))

;;;###autoload
(defun rmsbolt-cargo-asm (&optional prompt-function)
  "Show cargo-asm output for a Rust function at point.
With PROMPT-FUNCTION, select a function from the current buffer instead.
Interactively, use a prefix argument to select a function."
  (interactive (list (when current-prefix-arg #'completing-read)))
  (when (eq prompt-function t)
    (setq prompt-function #'completing-read))
  (let ((src-buffer (or (buffer-base-buffer) (current-buffer))))
    (with-current-buffer src-buffer
      (unless rmsbolt-mode
        (rmsbolt-mode 1))
      (when (and (buffer-modified-p)
                 (yes-or-no-p (format "Save buffer %s? " (buffer-name))))
        (save-buffer))
      (hack-local-variables)
      (let* ((target (rmsbolt--cargo-asm--target src-buffer))
             (target-src (nth 3 target))
             (at-point (rmsbolt--cargo-asm-function-at-point target-src))
             (function (if prompt-function
                           (rmsbolt--cargo-asm--prompt
                            prompt-function
                            (rmsbolt--cargo-asm-functions target-src)
                            at-point)
                         at-point)))
        (unless function
          (user-error "No Rust function at point"))
        (rmsbolt--cargo-asm--run src-buffer function target)))))


;;;; Language Definitions
(defvar rmsbolt-languages)
(setq
 rmsbolt-languages
 `((c-mode
    . ,(make-rmsbolt-lang :compile-cmd "gcc"
                          :supports-asm t
                          :supports-disass t
                          :demangler "c++filt"
                          :compile-cmd-function #'rmsbolt--c-compile-cmd
                          :disass-hidden-funcs rmsbolt--hidden-func-c))
   (c++-mode
    . ,(make-rmsbolt-lang :compile-cmd "g++"
                          :supports-asm t
                          :supports-disass t
                          :demangler "c++filt"
                          :compile-cmd-function #'rmsbolt--c-compile-cmd
                          :disass-hidden-funcs rmsbolt--hidden-func-c))
   (d-mode
    . ,(make-rmsbolt-lang :compile-cmd "ldc2"
                          :supports-asm t
                          :supports-disass nil
                          :demangler "ddemangle"
                          :compile-cmd-function #'rmsbolt--d-compile-cmd))
   (fortran-mode
    . ,(make-rmsbolt-lang :compile-cmd "gfortran"
                          :supports-asm t
                          :supports-disass t
                          :demangler "c++filt"
                          :compile-cmd-function #'rmsbolt--c-compile-cmd
                          :disass-hidden-funcs rmsbolt--hidden-func-c))
   (f90-mode
    . ,(make-rmsbolt-lang :compile-cmd "gfortran"
                          :supports-asm t
                          :supports-disass t
                          :demangler "c++filt"
                          :compile-cmd-function #'rmsbolt--c-compile-cmd
                          :disass-hidden-funcs rmsbolt--hidden-func-c))
   (ada-mode
    . ,(make-rmsbolt-lang :compile-cmd "gcc"
                          :supports-asm t
                          :supports-disass t
                          :demangling-style "gnat"
                          :compile-cmd-function #'rmsbolt--c-compile-cmd
                          :disass-hidden-funcs rmsbolt--hidden-func-c))
   ;; In order to parse ocaml files, you need the emacs ocaml mode, tuareg
   (tuareg-mode
    . ,(make-rmsbolt-lang :compile-cmd "ocamlopt"
                          :supports-asm t
                          :supports-disass t
                          :compile-cmd-function #'rmsbolt--ocaml-compile-cmd
                          :disass-hidden-funcs rmsbolt--hidden-func-ocaml))
   (lisp-mode
    . ,(make-rmsbolt-lang :compile-cmd "sbcl"
                          :supports-asm t
                          :supports-disass nil
                          :objdumper 'cat
                          :compile-cmd-function #'rmsbolt--lisp-compile-cmd))
   (rust-mode
    . ,(make-rmsbolt-lang :compile-cmd "rustc"
                          :supports-asm t
                          :supports-disass nil
                          :objdumper 'objdump
                          :demangler "rustfilt"
                          :compile-cmd-function #'rmsbolt--rust-compile-cmd))
   ;; Copy of above
   (rustic-mode
    . ,(make-rmsbolt-lang :compile-cmd "rustc"
                          :supports-asm t
                          :supports-disass nil
                          :objdumper 'objdump
                          :demangler "rustfilt"
                          :compile-cmd-function #'rmsbolt--rust-compile-cmd))
   (ponylang-mode
    . ,(make-rmsbolt-lang :compile-cmd "ponyc"
                          :supports-asm t
                          :supports-disass t
                          :objdumper 'objdump
                          :compile-cmd-function #'rmsbolt--pony-compile-cmd))
   (php-mode
    . ,(make-rmsbolt-lang :compile-cmd #'rmsbolt--php-default-compile-cmd
                          :supports-asm t
                          :supports-disass nil
                          :compile-cmd-function #'rmsbolt--php-compile-cmd
                          :process-asm-custom-fn #'rmsbolt--process-php-bytecode))
   ;; ONLY SUPPORTS PYTHON 3
   (python-mode
    . ,(make-rmsbolt-lang :compile-cmd "python3"
                          :supports-asm t
                          :supports-disass nil
                          :compile-cmd-function #'rmsbolt--py-compile-cmd
                          :process-asm-custom-fn #'rmsbolt--process-python-bytecode))
   (haskell-mode
    . ,(make-rmsbolt-lang :compile-cmd "ghc"
                          :supports-asm t
                          :supports-disass nil
                          :demangler "haskell-demangler"
                          :compile-cmd-function #'rmsbolt--hs-compile-cmd))
   (java-mode
    . ,(make-rmsbolt-lang :compile-cmd "javac"
                          :supports-asm t
                          :supports-disass nil
                          :objdumper 'cat
                          :compile-cmd-function #'rmsbolt--java-compile-cmd
                          :process-asm-custom-fn #'rmsbolt--process-java-bytecode))
   (emacs-lisp-mode
    . ,(make-rmsbolt-lang :supports-asm t
                          :supports-disass nil
                          ;; Nop
                          :process-asm-custom-fn (lambda (_src-buffer lines)
                                                   lines)
                          :elisp-compile-override #'rmsbolt--elisp-compile-override))
   (nim-mode
    . ,(make-rmsbolt-lang :compile-cmd "nim c"
                          :supports-disass t
                          :objdumper 'objdump
                          :demangler "c++filt"
                          :compile-cmd-function #'rmsbolt--nim-compile-cmd
                          :disass-hidden-funcs rmsbolt--hidden-func-c))
   (zig-mode
    . ,(make-rmsbolt-lang :compile-cmd "zig build-obj -O ReleaseFast"
                          :supports-asm t
                          :supports-disass t
                          :objdumper 'objdump
                          :compile-cmd-function #'rmsbolt--zig-compile-cmd
                          :disass-hidden-funcs rmsbolt--hidden-func-zig))
   (go-mode
    . ,(make-rmsbolt-lang :compile-cmd "go"
                          :supports-asm nil
                          :supports-disass t
                          :objdumper 'go-objdump
                          :compile-cmd-function #'rmsbolt--go-compile-cmd
                          :process-asm-custom-fn #'rmsbolt--process-go-asm-lines))
   (mlir-mode
    . ,(make-rmsbolt-lang :compile-cmd "mlir-opt"
                          :supports-asm t
                          :supports-disass nil
                          :compile-cmd-function #'rmsbolt--mlir-compile-cmd))
   (swift-mode
    . ,(make-rmsbolt-lang :compile-cmd (rmsbolt--path-to-swift-compiler)
                          :supports-asm t
                          :supports-disass nil
                          :objdumper 'objdump
                          :demangler (rmsbolt--path-to-swift-demangler)
                          :compile-cmd-function #'rmsbolt--swift-compile-cmd))
   ))

(defvar rmsbolt-c-dwarf-language
  (make-rmsbolt-lang :compile-cmd "gcc"
                     :supports-asm t
                     :supports-disass t
                     :demangler "c++filt"
                     :compile-cmd-function #'rmsbolt--c-dwarf-compile-cmd
                     :process-asm-custom-fn #'rmsbolt--process-dwarf-readelf))
(make-obsolete-variable 'rmsbolt-languages
                        'rmsbolt-language-descriptor "RMSBolt-0.2")

(defvar-local rmsbolt-language-descriptor nil
  ;; FIXME: Major modes can't set this without calling `make-rmsbolt-lang',
  ;; so it forces them to require `rmsbolt', which is a bummer.
  "Description of the language tools of current buffer for use by RMSBolt.
This should be an object of type `rmsbolt-lang', normally set by the major mode")

;;;; Macros

(defmacro rmsbolt-with-display-buffer-no-window (&rest body)
  "Run BODY without displaying any window."
  ;; See http://debbugs.gnu.org/13594
  `(let ((display-buffer-overriding-action
          (if rmsbolt-hide-compile
              (list #'display-buffer-no-window)
            display-buffer-overriding-action)))
     ,@body))

;;;; Functions
;; Functions to parse and lint assembly were lifted almost directly from the compiler-explorer

(defun rmsbolt-re-seq (regexp string)
  "Get list of all REGEXP match in STRING."
  (save-match-data
    (let ((pos 0)
          matches)
      (while (string-match regexp string pos)
        (push (match-string 0 string) matches)
        (setq pos (match-end 0)))
      matches)))

;; Prevent byte-compilation warnings for cl-print-compiled, which is imported
;; from cl-print
(defvar cl-print-compiled)
(defun rmsbolt--disassemble-file (filename out-buffer)
  "Disassemble an elisp FILENAME into elisp bytecode in OUT-BUFFER.
Lifted from https://emacs.stackexchange.com/questions/35936/disassembly-of-a-bytecode-file"
  (if (not (require 'cl-print nil 'noerror))
      (error "Package cl-print or Emacs 26+ are required for the Emacs disassembler")
    (byte-compile-file filename)
    ;; .el -> .elc
    (setq filename (concat filename "c"))
    (with-temp-buffer
      (insert-file-contents filename)
      (let ((inbuf (current-buffer)))
        (goto-char (point-min))
        (with-current-buffer out-buffer
          (erase-buffer)
          (setq-local cl-print-compiled 'disassemble)
          (condition-case ()
              (cl-loop for expr = (read inbuf)
                       do
                       (pcase expr
                         (`(byte-code ,(pred stringp) ,(pred vectorp) ,(pred natnump))
                          (princ "TOP-LEVEL byte code:\n" (current-buffer))
                          (disassemble-1 expr 0))
                         (_ (cl-prin1 expr (current-buffer))))
                       do (terpri (current-buffer)))
            (end-of-file nil)))))))

;;;;; Filter Functions

;; Filtering functions were more or less lifted from the godbolt compiler explorer to maintain compatiblity.
;; https://github.com/mattgodbolt/compiler-explorer/blob/master/lib/asm.js

(defmacro rmsbolt--sweeping (src-buffer &rest forms)
  "Sweep the current buffer for SRC-BUFFER and evaluate FORMS on each line."
  (declare (indent 1)
           (debug (form &rest (form &rest form))))
  (let ((lbp (gensym "lbp-"))
        (lep (gensym "lep-"))
        (preserve-directives (gensym "preserve-directives-"))
        (linum (gensym "linum-"))
        (ht (gensym "ht-"))
        (prev-property (gensym "prev-property-"))
        (property (gensym "property-"))
        (regions (gensym "regions-")))
    `(let ((,preserve-directives
            (not (buffer-local-value 'rmsbolt-filter-directives ,src-buffer)))
           (,linum 1)
           (,ht (make-hash-table :test #'eq))
           (,prev-property nil))
       (goto-char (point-min))
       (while (not (eobp))
         (let ((,lbp (line-beginning-position))
               (,lep (line-end-position)))
           (cl-macrolet ((match (&rest res)
                           `(cl-loop for re in ,(cons 'list res)
                                     thereis (re-search-forward re ,',lep t)))
                         (asm-linum () ',linum)
                         (kill-line ()
                           `(delete-region ,',lbp (min (point-max) (1+ ,',lep))))
                         (preserve ()
                           `(let ((,',property (get-text-property ,',lbp 'rmsbolt-src-line)))
                              (when ,',property
                                (let ((,',regions (gethash ,',property ,',ht)))
                                  (if (and (eq ,',property ,',prev-property)
                                           ,',regions
                                           (= ,',linum (1+ (cdar ,',regions))))
                                      (setcdr (car ,',regions) ,',linum)
                                    (puthash ,',property
                                             (cons (cons ,',linum ,',linum) ,',regions)
                                             ,',ht))))
                              (setq ,',prev-property ,',property
                                    ,',linum (1+ ,',linum))
                              (forward-line 1))))
             (pcase (cond ,@forms)
               (:preserve (preserve))
               (:kill (kill-line))
               (_
                (if ,preserve-directives (preserve)
                  (kill-line)))))))
       (with-current-buffer ,src-buffer
         (setq rmsbolt-line-mapping ,ht)))))

(defun rmsbolt--has-opcode-p (&optional line)
  "Return non-nil if the current line or LINE has opcodes."
  (save-excursion
    (save-match-data
      (if line
          (let* ((match (string-match rmsbolt-label-def line))
                 (line (if match
                           (substring line (match-end 0))
                         line))
                 (line (cl-first (split-string line (rx (1+ (any ";#")))))))
            (if (string-match-p rmsbolt-assignment-def line)
                nil
              (string-match-p rmsbolt-has-opcode line)))
        (let ((lbp (line-beginning-position))
              (lep (line-end-position)))
          (goto-char lbp)
          (when (looking-at rmsbolt-label-def)
            (goto-char (match-end 0)))
          (let ((end (save-excursion
                       (skip-chars-forward "^;#\n" lep)
                       (point))))
            (skip-chars-forward " \t" end)
            (let ((c (char-after)))
              (and (< (point) end)
                   (or (<= ?a c ?z) (<= ?A c ?Z))
                   (not (looking-at-p "[a-zA-Z0-9$_.]+[ \t]*="))))))))))

(defun rmsbolt--find-used-labels (src-buffer &optional asm-lines)
  "Find used labels in the current buffer or ASM-LINES from SRC-BUFFER."
  (if asm-lines
      (with-temp-buffer
        (insert (string-join asm-lines "\n"))
        (rmsbolt--find-used-labels src-buffer))
    (let ((labels-used (make-hash-table :test #'equal))
          (filter-directives (buffer-local-value 'rmsbolt-filter-directives src-buffer)))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((lbp (line-beginning-position))
                (lep (line-end-position)))
            (skip-chars-forward " \t" lep)
            (when (< (point) lep)
              (if (eq (char-after) ?.)
                  (when (progn (goto-char lbp)
                               (looking-at rmsbolt-defines-global))
                    (puthash (match-string-no-properties 1) t labels-used))
                (when (or (not filter-directives)
                          (rmsbolt--has-opcode-p))
                  (while (re-search-forward rmsbolt-label-find lep t)
                    (puthash (match-string-no-properties 0) t labels-used))))))
          (forward-line 1)))
      labels-used)))

(defun rmsbolt--user-func-p (src-buffer func)
  "Return t if FUNC is a user function.
Argument SRC-BUFFER source buffer."
  (let* ((lang (with-current-buffer src-buffer
                 (rmsbolt--get-lang)))
         (regexp (rmsbolt-l-disass-hidden-funcs lang)))
    (if regexp
        (not (string-match-p regexp func))
      t)))

(cl-defun rmsbolt--process-disassembled-lines (src-buffer &optional asm-lines)
  "Filter disassembled lines in current buffer or ASM-LINES from SRC-BUFFER."
  (if asm-lines
      (with-temp-buffer
        (insert (string-join asm-lines "\n"))
        (rmsbolt--process-disassembled-lines src-buffer)
        (split-string (buffer-string) "\n" t))
    (let* ((src-file-name (or (buffer-local-value 'rmsbolt--real-src-file src-buffer)
                              (buffer-file-name src-buffer)))
           (local-src-file-name (and src-file-name (file-local-name src-file-name)))
           (func nil)
           (user-func-p nil)
           (source-linum nil)
           (ignore-limit (buffer-local-value 'rmsbolt-ignore-binary-limit src-buffer))
           (def-dir (or (buffer-local-value 'rmsbolt-default-directory src-buffer)
                        (and src-file-name
                             (file-name-directory src-file-name)))))
      (rmsbolt--sweeping src-buffer
        ((and (not ignore-limit)
              (> (asm-linum) rmsbolt-binary-asm-limit))
         (erase-buffer)
         (insert "Aborting processing due to exceeding the binary limit.")
         (cl-return-from rmsbolt--process-disassembled-lines
           '("Aborting processing due to exceeding the binary limit.")))
        ((looking-at rmsbolt-disass-line)
         (let ((default-directory def-dir))
           (if (rmsbolt--file-equal-p local-src-file-name
                                      (match-string-no-properties 1))
               (setq source-linum (string-to-number (match-string-no-properties 2)))
             (setq source-linum nil)))
         :kill)
        ((looking-at rmsbolt-disass-label)
         (setq func (match-string-no-properties 2)
               user-func-p (rmsbolt--user-func-p src-buffer func))
         (if user-func-p
             (progn
               (replace-match (concat func ":") t t)
               :preserve)
           :kill))
        ((not (and func user-func-p))
         :kill)
        ((looking-at rmsbolt-disass-opcode)
         (replace-match (concat (match-string-no-properties 1)
                                "\t" (match-string-no-properties 3))
                        t t)
         (when source-linum
           (put-text-property (line-beginning-position) (line-end-position)
                              'rmsbolt-src-line source-linum))
         :preserve)
        (t :kill)))))

(cl-defun rmsbolt--process-src-asm-lines (src-buffer &optional asm-lines)
  "Process and filter assembly in the current buffer or ASM-LINES from SRC-BUFFER."
  (if asm-lines
      (with-temp-buffer
        (insert (string-join asm-lines "\n"))
        (rmsbolt--process-src-asm-lines src-buffer)
        (split-string (buffer-string) "\n" t))
    (let* ((used-labels (rmsbolt--find-used-labels src-buffer))
           (src-file-name (or (buffer-local-value 'rmsbolt--real-src-file src-buffer)
                              (buffer-file-name src-buffer)))
           (local-src-file-name (and src-file-name (file-local-name src-file-name)))
           (prev-label nil)
           (source-linum nil)
           (source-file-map (make-hash-table :test #'eq))
           (def-dir (or (buffer-local-value 'rmsbolt-default-directory src-buffer)
                        (and src-file-name
                             (file-name-directory src-file-name))))
           (filter-comment-only (buffer-local-value 'rmsbolt-filter-comment-only src-buffer))
           (filter-labels (buffer-local-value 'rmsbolt-filter-labels src-buffer))
           (filter-directives (buffer-local-value 'rmsbolt-filter-directives src-buffer)))
      (rmsbolt--sweeping src-buffer
        (t
         (let* ((lbp (line-beginning-position))
                (lep (line-end-position))
                (raw-match (or (looking-at rmsbolt-label-def)
                               (looking-at rmsbolt-assignment-def)))
                (match (when raw-match
                         (match-string-no-properties 1)))
                (used-label-p (and match (gethash match used-labels))))
           (skip-chars-forward " \t" lep)
           (let ((first-char (char-after)))
             (when (eq first-char ?.)
               (goto-char lbp)
               (cond
                ((looking-at rmsbolt-source-file)
                 (let* ((file (if (match-string 3)
                                  (expand-file-name (match-string-no-properties 3)
                                                    (match-string-no-properties 2))
                                (match-string-no-properties 2)))
                        (match-p (or (not src-file-name)
                                     (let ((default-directory def-dir))
                                       (rmsbolt--file-equal-p local-src-file-name file)))))
                   (puthash (string-to-number (match-string-no-properties 1))
                            match-p
                            source-file-map)))
                ((looking-at rmsbolt-source-tag)
                 (if (or (not src-file-name)
                         (gethash (string-to-number (match-string-no-properties 1))
                                  source-file-map))
                     (setq source-linum (string-to-number
                                         (match-string-no-properties 2)))
                   (setq source-linum nil)))
                ((match rmsbolt-source-stab)
                 (pcase (string-to-number (match-string-no-properties 1))
                   (68
                    (setq source-linum (string-to-number (match-string-no-properties 2))))
                   ((or 100 132)
                    (setq source-linum nil)))))
               (goto-char lbp)
               (when (match rmsbolt-endblock)
                 (setq prev-label nil)))
             (goto-char lbp)
             (cond
              ((and filter-comment-only
                    (not (eq first-char ?.))
                    (looking-at-p rmsbolt-comment-only))
               :kill)
              ((and match (not used-label-p) filter-labels)
               :kill)
              (t
               (when (and match used-label-p)
                 (setq prev-label raw-match))
               (if (and filter-directives
                        (not match)
                        (eq first-char ?.)
                        (not (and prev-label
                                  (looking-at-p rmsbolt-data-defn))))
                   :kill
                 (when (and source-linum
                            (not (and (not match) (eq first-char ?.)))
                            (rmsbolt--has-opcode-p))
                   (put-text-property lbp lep 'rmsbolt-src-line source-linum))
                 :preserve))))))))))

(cl-defun rmsbolt--process-cargo-asm-lines (src-buffer &optional asm-lines)
  "Process cargo-asm output from SRC-BUFFER or ASM-LINES."
  (if asm-lines
      (with-temp-buffer
        (insert (string-join asm-lines "\n"))
        (rmsbolt--process-cargo-asm-lines src-buffer)
        (split-string (buffer-string) "\n" t))
    (let* ((src-file-name (or (buffer-local-value 'rmsbolt--real-src-file src-buffer)
                              (buffer-file-name src-buffer)))
           (local-src-file-name (and src-file-name (file-local-name src-file-name)))
           (workspace-dir (or (buffer-local-value 'rmsbolt--cargo-asm-workspace-dir src-buffer)
                              (buffer-local-value 'rmsbolt-default-directory src-buffer)
                              (buffer-local-value 'default-directory src-buffer)
                              default-directory))
           (source-dir (or (and src-file-name (file-name-directory src-file-name))
                           (buffer-local-value 'default-directory src-buffer)
                           default-directory))
           (source-linum nil))
      (rmsbolt--sweeping src-buffer
        ((looking-at "^\t\t// \\(.+\\):\\([0-9]+\\)$")
         (let ((filename (match-string-no-properties 1))
               (linum (string-to-number (match-string-no-properties 2))))
           (setq source-linum
                 (when (or (not local-src-file-name)
                           (cl-some (lambda (dir)
                                      (rmsbolt--file-equal-p
                                       local-src-file-name
                                       (expand-file-name filename dir)))
                                    (list workspace-dir source-dir)))
                   linum)))
         :kill)
        ((looking-at-p "^\t\t") :kill)
        ((or (looking-at-p "^[ \t]*\\.\\(?:section\\|cfi_startproc\\|cfi_endproc\\)\\(?:[ \t]\\|$\\)")
             (looking-at-p "^[^.\t ][^\n]*:$"))
         (setq source-linum nil)
         :preserve)
        ((and source-linum (looking-at-p "^\t[^\t.]"))
         (put-text-property (line-beginning-position) (line-end-position)
                            'rmsbolt-src-line source-linum)
         :preserve)
        (t :preserve)))))

(cl-defun rmsbolt--process-php-bytecode (src-buffer asm-lines)
  "Process and filter php ASM-LINES from SRC-BUFFER."
  (if (rmsbolt--hack-p src-buffer)
      asm-lines
    (let ((state 'useless)
          (current-line nil)
          (result nil))
      (dolist (line asm-lines)
        (cl-case state
          ((text)
           (push line result)
           (when (string-match "^-+$" line)
             (setq state 'asm)))
          ((asm)
           (cond
            ((string-empty-p line) (setq state 'useless))
            ((string-match "^ *\\([0-9]+\\) +[0-9]+" line)
             (setq current-line (string-to-number (match-string 1 line)))
             (add-text-properties 0 (length line) `(rmsbolt-src-line ,current-line) line))
            (t
             (add-text-properties 0 (length line) `(rmsbolt-src-line ,current-line) line)))
           (push line result))
          (otherwise
           (when (string-match "^filename:" line)
             (setq state 'text)))))
      (nreverse result))))

(cl-defun rmsbolt--process-python-bytecode (_src-buffer asm-lines)
  "Process and filter python ASM-LINES from SRC-BUFFER."
  (let ((source-linum nil)
        (result nil))
    (dolist (line asm-lines)
      (if (not (string-match (rx bol (repeat 3 (opt space))
                                 (group (opt (1+ digit))) (0+ space)
                                 (group (opt "-->")) (0+ space)
                                 (group (opt ">>")) (0+ space)
                                 (group (1+ digit)) (0+ space)
                                 (group (1+ (or letter "_"))) (0+ space)
                                 (group (opt (1+ digit))) (0+ space)
                                 (group (opt (0+ any))))
                             line))
          ;; just push the var with no linum
          (push line result)
        ;; Grab line numbers
        (unless (string-empty-p (match-string 1 line))
          (setq source-linum
                (string-to-number (match-string 1 line))))
        ;; Reformat line to be more like assembly
        (setq line (string-join
                    (list
                     ;; Register
                     (match-string 4 line)
                     ;; Command
                     (match-string 5 line)
                     (match-string 6 line)
                     (match-string 7 line))
                    "\t"))
        (when source-linum
          (add-text-properties 0 (length line)
                               `(rmsbolt-src-line ,source-linum) line))
        ;; Add line
        (push line result)))
    (nreverse result)))

(defun rmsbolt--process-java-bytecode (src-buffer asm-lines)
  "Wrapper for easy integration into rmsbolt.
Argument SRC-BUFFER source buffer.
Argument ASM-LINES input lines."
  (rmsbolt-java-process-bytecode
   asm-lines
   (buffer-local-value 'rmsbolt-filter-directives src-buffer)))

(cl-defun rmsbolt--process-asm-lines (src-buffer &optional asm-lines)
  "Process and filter assembly in the current buffer or ASM-LINES from SRC-BUFFER."
  (let* ((lang (with-current-buffer src-buffer
                 (rmsbolt--get-lang)))
         (process-asm-fn (when lang
                           (rmsbolt-l-process-asm-custom-fn lang))))
    (cond
     ((buffer-local-value 'rmsbolt--cargo-asm-active src-buffer)
      (rmsbolt--process-cargo-asm-lines src-buffer asm-lines))
     (process-asm-fn
      (if asm-lines
          (funcall process-asm-fn src-buffer asm-lines)
        (let ((lines (funcall process-asm-fn
                              src-buffer
                              (split-string (buffer-string) "\n" nil)))
              (ht (make-hash-table :test #'eq))
              (linum 1)
              (prev-property nil))
          (dolist (line lines)
            (let ((property (get-text-property 0 'rmsbolt-src-line line)))
              (when property
                (let ((regions (gethash property ht)))
                  (if (and (eq property prev-property)
                           regions
                           (= linum (1+ (cdar regions))))
                      (setcdr (car regions) linum)
                    (puthash property (cons (cons linum linum) regions) ht))))
              (setq prev-property property
                    linum (1+ linum))))
          (with-current-buffer src-buffer
            (setq rmsbolt-line-mapping ht))
          (erase-buffer)
          (insert (string-join lines "\n")))))
     ((buffer-local-value 'rmsbolt-disassemble src-buffer)
      (rmsbolt--process-disassembled-lines src-buffer asm-lines))
     (t
      (rmsbolt--process-src-asm-lines src-buffer asm-lines)))))
(cl-defun rmsbolt--process-go-asm-lines (_src-buffer asm-lines)
  "Process and filter go ASM-LINES from SRC-BUFFER."
  (let ((source-linum nil)
        (result nil))
    (dolist (line asm-lines)
      (if (not
           (string-match (rx bol (repeat 2 space)
                             (group (opt (0+ any))) ":"
                             (group (opt (1+ digit)) (1+ "\t"))
                             (group (opt "0x" (0+ hex)) (1+ "\t"))
                             (group (1+ xdigit) (1+ "\t"))
                             (group (opt (0+ any)) (1+ "\t")))
                         line))
          ;; just push the var with no linum
          (push line result)
        ;; Grab line numbers
        (unless (string-empty-p (match-string 2 line))
          (setq source-linum
                (string-to-number (match-string 2 line))))
        ;; Reformat line to be more like assembly
        (setq line (string-join
                    (list (match-string 3 line)
                          (match-string 4 line)
                          (match-string 5 line))
                    "\t"))
        (when source-linum
          (add-text-properties 0 (length line)
                               `(rmsbolt-src-line ,source-linum) line))
        ;; Add line
        (push line result)))
    (nreverse result)))

(cl-defun rmsbolt--process-dwarf-readelf (src-buffer asm-lines)
  "Process and filter DWARF ASM-LINES from SRC-BUFFER.

Tuned to Elfutils's implementation of readelf"
  (let ((result nil)
        (die nil)
        (filename nil)
        (linum nil)
        (comp-dir nil)
        (src-file-name (file-local-name (or (buffer-local-value 'rmsbolt--real-src-file src-buffer)
                                            (buffer-file-name src-buffer)))))
    (dolist (line asm-lines)
      (if (string-match (rx bol space
                            (group "[" (0+ space) (1+ hex) "]"))
                        line)
          ;; We have seen the next die - let's commit the previous one
          (progn
            (when (and linum filename (rmsbolt--file-equal-p src-file-name (expand-file-name filename comp-dir)))
              (dolist (dieline die)
                (add-text-properties 0 (length dieline)
                                     `(rmsbolt-src-line ,linum) dieline)))
            (setq
             result (nconc die result)
             die nil
             linum nil
             filename nil))
        ;; Collect information on an entire die before committing it.
        (when-let* ((match-result
                     (string-match (rx bol (1+ space)
                                       (group (or "decl_file" "decl_line" "comp_dir")) (1+ space)
                                       (group "(" (1+ alnum) ")") (1+ space)
                                       (group (1+ (or alnum "."))))
                                   line))
                    (indicator (match-string 1 line))
                    (payload (match-string 3 line)))
          (message payload)
          (pcase indicator
            ("decl_file" (setq filename payload))
            ("decl_line" (setq linum (string-to-number payload)))
            ("comp_dir" (setq comp-dir payload)))))
      (push line die))

    ;; Final iteration of the die
    (when (and linum (rmsbolt--file-equal-p src-file-name (expand-file-name filename comp-dir)))
      (dolist (dieline die)
        (add-text-properties 0 (length dieline)
                             `(rmsbolt-src-line ,linum) dieline)))
    (setq result (nconc die result))
    (nreverse result)))

(defconst rmsbolt--header-wrappers '("env" "ccache" "sccache" "distcc")
  "Command prefixes that hide the compiler in a compile command.")

(defun rmsbolt--header-compiler-name (command)
  "Return the compiler executable name from COMMAND, or nil."
  (let ((tokens (and command (rmsbolt-split--tokenize command))))
    ;; Skip wrappers and environment assignments, such as those Cargo adds.
    (while (and tokens
                (or (member (car tokens) rmsbolt--header-wrappers)
                    (string-match-p (rx bos (1+ (any "A-Za-z0-9_")) "=")
                                    (car tokens))))
      (setq tokens (cdr tokens)))
    (when tokens
      (string-trim (file-name-nondirectory (car tokens)) "[\"']" "[\"']"))))

(defun rmsbolt--header-arg-specs (src-buffer)
  "Return the header argument specs for SRC-BUFFER.
Look up the major mode of SRC-BUFFER in
`rmsbolt-output-header-arg-alist', then its tree-sitter equivalent, then
the default entry."
  (let* ((mode (buffer-local-value 'major-mode src-buffer))
         (base-mode (intern (replace-regexp-in-string
                             "ts-mode$" "mode" (symbol-name mode)))))
    (or (cdr (assq mode rmsbolt-output-header-arg-alist))
        (cdr (assq base-mode rmsbolt-output-header-arg-alist))
        (cdr (assq t rmsbolt-output-header-arg-alist)))))

(defun rmsbolt--header-arg-match-p (regexp token)
  "Return non-nil if REGEXP matches TOKEN, ignoring case folding."
  (let ((case-fold-search nil))
    (string-match-p regexp token)))

(defun rmsbolt--header-arg-scan (command specs)
  "Classify the arguments of COMMAND against SPECS.
SPECS is a list of (LEADING . FOLLOW) regexp pairs, as in
`rmsbolt-output-header-arg-alist'.  Return a list of two elements, the
arguments of COMMAND that match SPECS and the arguments that match no
spec.  A matching argument is a string with its value appended when
FOLLOW matched the argument after it."
  (let ((tokens (and command (rmsbolt-split--tokenize command)))
        args ignored)
    (while tokens
      (let ((token (pop tokens))
            (remaining specs)
            match)
        (while (and remaining (not match))
          (let ((leading (caar remaining))
                (follow (cdar remaining)))
            (when (rmsbolt--header-arg-match-p leading token)
              (cond
               ((null follow)
                (setq match token))
               ((and tokens
                     (rmsbolt--header-arg-match-p follow (car tokens)))
                (setq match (concat token " " (pop tokens)))))))
          (setq remaining (cdr remaining)))
        (if match
            (push match args)
          (push token ignored))))
    (list (nreverse args) (nreverse ignored))))

(defun rmsbolt--header-args (command specs &optional overrides)
  "Return the interesting arguments from COMMAND as a string.
SPECS is a list of (LEADING . FOLLOW) regexp pairs, as in
`rmsbolt-output-header-arg-alist'.  OVERRIDES, when non-nil, is a
string of arguments that are appended to the arguments of COMMAND."
  (mapconcat #'identity
             (append (car (rmsbolt--header-arg-scan command specs))
                     (car (rmsbolt--header-arg-scan overrides specs)))
             " "))

(defun rmsbolt--output-header-line (command specs &optional overrides)
  "Return the header comment line for COMMAND using SPECS.
SPECS is a list of (LEADING . FOLLOW) regexp pairs.  OVERRIDES, when
non-nil, is a string of arguments that take precedence over the ones in
COMMAND.  Return nil if COMMAND has no compiler."
  (let ((compiler (and command (rmsbolt--header-compiler-name command))))
    (when compiler
      (string-trim-right
       (string-join
        (list ";; compiled with:" compiler
              (rmsbolt--header-args command specs overrides))
        " ")))))
(defun rmsbolt--shift-line-mapping (src-buffer lines)
  "Move the assembly line numbers in SRC-BUFFER's mapping down by LINES."
  (with-current-buffer src-buffer
    (when rmsbolt-line-mapping
      (let (entries)
        (maphash (lambda (src-line chunks)
                   (push (cons src-line chunks) entries))
                 rmsbolt-line-mapping)
        (dolist (entry entries)
          (puthash (car entry)
                   (mapcar (lambda (chunk)
                             (cons (+ (car chunk) lines)
                                   (+ (cdr chunk) lines)))
                           (cdr entry))
                   rmsbolt-line-mapping))))))

(defun rmsbolt--insert-output-header (src-buffer)
  "Insert a compiler header into the current output buffer.
Shift `rmsbolt-line-mapping' in SRC-BUFFER by the number of inserted
lines.  Do nothing if `rmsbolt-output-header' is nil."
  (let ((header (and rmsbolt-output-header
                     (rmsbolt--output-header-line
                      (buffer-local-value 'rmsbolt-command src-buffer)
                      (rmsbolt--header-arg-specs src-buffer)
                      (buffer-local-value 'rmsbolt-compile-arg-overrides
                                          src-buffer)))))
    (when header
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t))
        (save-excursion
          (goto-char (point-min))
          (insert header "\n")))
      (rmsbolt--shift-line-mapping src-buffer 1))))

(defun rmsbolt--finalize-output-buffer (src-buffer)
  "Finish populating the output buffer for SRC-BUFFER.
Insert the compiler header, then make the buffer read-only and enable
`view-mode'."
  (rmsbolt--insert-output-header src-buffer)
  (read-only-mode 1)
  (view-mode 1))

;;;;; HANDLERS
(cl-defun rmsbolt--handle-finish-compile (buffer str &key override-buffer stopped)
  "Finish hook for compilations.
Argument BUFFER compilation buffer.
Argument STR compilation finish status.
Argument OVERRIDE-BUFFER asm src buffer to use instead of reading
   `rmsbolt-output-filename'.
Argument STOPPED The compilation was stopped to start another compilation."
  (when (not (buffer-live-p buffer))
    (error "Dead buffer passed to compilation-finish-function! RMSBolt cannot continue"))
  (let ((compilation-fail
         (and str
              (not (string-match "^finished" str))))
        (src-default-directory (buffer-local-value 'default-directory buffer))
        (src-buffer (buffer-local-value 'rmsbolt-src-buffer buffer)))

    (with-current-buffer (get-buffer-create rmsbolt-output-buffer)
      (setq default-directory src-default-directory)
      ;; Store src buffer value for later linking
      (cond (stopped) ; Do nothing
            ((not compilation-fail)
             (if (and (not override-buffer)
                      (not (file-exists-p (rmsbolt-output-filename src-buffer t))))
                 (message "Error reading from output file.")
               (let* ((output-buffer (current-buffer))
                      (window (get-buffer-window output-buffer))
                      (old-point (and window (window-point window)))
                      (old-window-start (and window (window-start window))))
                 (asm-mode)
                 (rmsbolt-mode 1)
                 (buffer-disable-undo)
                 (setq default-directory src-default-directory
                       rmsbolt-src-buffer src-buffer)
                 (let ((inhibit-modification-hooks t)
                       (inhibit-read-only t))
                   (erase-buffer)
                   (if override-buffer
                       (insert-buffer-substring override-buffer)
                     (insert-file-contents (rmsbolt-output-filename src-buffer t)))
                   (save-excursion
                     (rmsbolt--process-asm-lines src-buffer)))
                   (rmsbolt--finalize-output-buffer src-buffer)
                 (when window
                   (set-window-start window old-window-start)
                   (set-window-point window old-point))
                 (display-buffer (current-buffer) '(nil (inhibit-same-window . t)))
                 (run-at-time 0 nil #'rmsbolt-update-overlays))))
            (t ; Compilation failed
             ;; Display compilation buffer
             (if rmsbolt--automated-compile
                 (display-buffer buffer '(nil (inhibit-same-window . t)))
               ;; If the compilation was directly started by the user,
               ;; select the compilation buffer.
               (pop-to-buffer buffer))
             ;; TODO find a cleaner way to disable overlays.
             (with-current-buffer src-buffer
               (setq rmsbolt-line-mapping nil))
             (rmsbolt--remove-overlays)))
      ;; Reset automated recompile
      (setq rmsbolt--automated-compile nil))
    ;; Clear out default-set variables
    (rmsbolt--reset-default-variables src-buffer)))

;;;;; Parsing Options
(defun rmsbolt--get-lang ()
  "Helper function to get lang def for LANGUAGE."
  (or (if (symbolp rmsbolt-language-descriptor)
          (symbol-value rmsbolt-language-descriptor)
        rmsbolt-language-descriptor)
      (cdr-safe (or
                 (assoc major-mode rmsbolt-languages)
                 ;; If the normal major mode cannot be found, try converting
                 ;; from a tree-sitter to a non-tree-sitter mode name
                 ;; https://github.com/renzmann/treesit-auto/blob/d32617b5edb660b8a046053af3b92cf14f9b978e/treesit-auto.el#L89
                 (assoc (thread-last
                          (symbol-name major-mode)
                          (replace-regexp-in-string "ts-mode$" "mode")
                          (intern))
                        rmsbolt-languages)))))

(defun rmsbolt--parse-options ()
  "Parse RMS options from file."
  (hack-local-variables)
  (let* ((lang (rmsbolt--get-lang))
         (src-buffer (current-buffer))
         (cmd rmsbolt-command)
         (dir rmsbolt-default-directory)
         (force-disass (not (rmsbolt-l-supports-asm lang)))
         (force-asm (not (rmsbolt-l-supports-disass lang))))
    ;; If this is non-nil, most likely we are running two compiles at once.
    ;; This is not exactly ideal, as it causes a race condition.
    (when rmsbolt--default-variables
      (message "It looks like RMSbolt state wasn't cleaned up properly.
Are you running two compilations at the same time?"))
    (when (and force-disass force-asm)
      (error "No disassemble method found for this langauge, please double check spec"))
    (when force-disass
      (setq-local rmsbolt-disassemble t))
    (when force-asm
      (setq-local rmsbolt-disassemble nil))
    (when (not dir)
      (add-to-list 'rmsbolt--default-variables 'rmsbolt-default-directory)
      (setq-local rmsbolt-default-directory
                  (let ((new-dir (rmsbolt-l-default-directory lang)))
                    (pcase new-dir
                      ((pred functionp) (funcall new-dir src-buffer))
                      (_ new-dir)))))
    (when (not cmd)
      (add-to-list 'rmsbolt--default-variables 'rmsbolt-command)
      (setq-local rmsbolt-command
                  (let ((new-cmd (rmsbolt-l-compile-cmd lang)))
                    (pcase new-cmd
                      ((pred functionp) (funcall new-cmd src-buffer))
                      (_ new-cmd)))))
    src-buffer))

(defun rmsbolt--demangle-command (existing-cmd lang src-buffer)
  "Add a demangler routine to EXISTING-CMD with LANG and SRC-BUFFER and return."
  (if-let ((to-demangle (buffer-local-value 'rmsbolt-demangle src-buffer))
           (demangler (rmsbolt-l-demangler lang))
           (demangler-exists (executable-find demangler))
           (output-filename (rmsbolt--convert-file-name-to-system-type
                             (file-local-name (rmsbolt-output-filename src-buffer t))))
           (assembly-filename (rmsbolt--convert-file-name-to-system-type
                               (file-local-name (expand-file-name "tmp.s" rmsbolt--temp-dir)))))
      (concat existing-cmd " "
              (string-join
               (list "&&" demangler
                     "<" output-filename
                     ">" assembly-filename
                     "&&" "mv"
                     assembly-filename
                     output-filename)
               " "))
    existing-cmd))

;;;;; UI Functions
(defun rmsbolt--read-compile-arg-overrides ()
  "Read compiler argument overrides for `rmsbolt-compile'.
Only arguments that match `rmsbolt-output-header-arg-alist' for the
mode of the current buffer are accepted."
  (let* ((scan (rmsbolt--header-arg-scan
                (read-string "Compile args (this compilation only): ")
                (rmsbolt--header-arg-specs (current-buffer))))
         (ignored (cadr scan)))
    (when ignored
      (user-error "Only interesting compile args are allowed, not: %s"
                  (string-join ignored " ")))
    (mapconcat #'identity (car scan) " ")))

(defun rmsbolt--apply-arg-overrides (command overrides)
  "Return COMMAND with OVERRIDES added to the compiler invocation.
OVERRIDES are inserted before any command that is chained to the
compiler invocation with `&&', so that chained commands do not receive
them.  Compilers give later arguments precedence, so the appended
arguments override the ones already in COMMAND."
  (if (or (null overrides) (string-empty-p overrides))
      command
    (let ((chained (string-match (rx " && ") command)))
      (if chained
          (concat (substring command 0 chained) " " overrides
                  (substring command chained))
        (concat command " " overrides)))))

(defun rmsbolt-compile (&optional arg-overrides)
  "Compile the current rmsbolt buffer.

When ARG-OVERRIDES is non-nil, it is a string of space separated
compiler arguments that override the ones in `rmsbolt-command'.  They
stay in effect for the buffer until they are set again, and an empty
string removes them.  Only arguments that match
`rmsbolt-output-header-arg-alist' for the language of the current buffer
are accepted, and they are shown in the output buffer header.
Interactively, use a prefix argument to be prompted for the arguments."
  (interactive
   (list (when current-prefix-arg
           (rmsbolt--read-compile-arg-overrides))))
  ;; perhaps use `save-some-buffers'?
  (when (and (buffer-modified-p)
             (yes-or-no-p (format "Save buffer %s? " (buffer-name))))
    (save-buffer))
  (rmsbolt--gen-temp)
  ;; Current buffer = src-buffer at this point
  (setq rmsbolt-src-buffer (current-buffer))
  (when arg-overrides
    (setq-local rmsbolt-compile-arg-overrides
                (unless (string-empty-p arg-overrides) arg-overrides)))
  (cond
   ((derived-mode-p 'asm-mode)
    ;; We cannot compile asm-mode files
    (message "Cannot compile assembly files. Are you sure you are not in the output buffer?"))
   ((rmsbolt-l-elisp-compile-override (rmsbolt--get-lang))
    (with-current-buffer (or (buffer-base-buffer) (current-buffer))
      (funcall
       (rmsbolt-l-elisp-compile-override (rmsbolt--get-lang))
       :src-buffer (current-buffer))))
   (t
    (rmsbolt--stop-running-compilation)
    (rmsbolt--parse-options)
    (let* ((src-buffer (current-buffer))
           (lang (rmsbolt--get-lang))
           (func (rmsbolt-l-compile-cmd-function lang))
           ;; Generate command
           (cmd
            ;; Compilation commands assume the current buffer is a real file
            ;; currently - this works around that.
            (with-current-buffer (or (buffer-base-buffer) (current-buffer))
              (funcall func :src-buffer src-buffer)))
           (cmd (rmsbolt--apply-arg-overrides
                 cmd rmsbolt-compile-arg-overrides))
           (asm-format
            (buffer-local-value 'rmsbolt-asm-format src-buffer))
           ;; Directory where we generate files, while respecting a buffer's
           ;; remoteness.  We keep this as a separate variable since
           ;; default-directory is local for each buffer.
           (src-default-directory (or rmsbolt-default-directory
                                  rmsbolt--temp-dir))
           (default-directory src-default-directory))
      (run-hooks 'rmsbolt-after-parse-hook)
      (when (buffer-local-value 'rmsbolt-disassemble src-buffer)
        (pcase
            (rmsbolt-l-objdumper lang)
          ('objdump
           (setq cmd
                 (string-join
                  (list cmd
                        "&&"
                        rmsbolt-objdump-binary "-d" (file-local-name (rmsbolt-output-filename src-buffer))
                        (concat "--demangle"
                                (when-let (style (rmsbolt-l-demangling-style lang))
                                  (concat "=" style)))
                        "--insn-width=16" "-l"
                        (when (not (booleanp asm-format))
                          (concat "-M " asm-format))
                        ">" (file-local-name (rmsbolt-output-filename src-buffer t)))
                  " ")))
          ('go-objdump
           (setq cmd
                 (string-join
                  (list cmd
                        "&&"
                        "go" "tool"
                        "objdump" (file-local-name (rmsbolt-output-filename src-buffer))
                        ">" (file-local-name (rmsbolt-output-filename src-buffer t)))
                  " ")))
          ('cat
           (setq cmd
                 (string-join
                  (list cmd
                        "&&" "mv"
                        (file-local-name (rmsbolt-output-filename src-buffer))
                        (file-local-name (rmsbolt-output-filename src-buffer t)))
                  " ")))
          (_
           (error "Objdumper not recognized"))))
      ;; Convert to demangle if we need to
      (setq cmd (rmsbolt--demangle-command cmd lang src-buffer))
      (with-current-buffer ; With compilation buffer
          (let ((shell-file-name (or (executable-find rmsbolt--shell)
                                     shell-file-name))
                (compilation-auto-jump-to-first-error t))
            ;; TODO should this be configurable?
            (rmsbolt-with-display-buffer-no-window
             (compilation-start cmd nil (lambda (&rest _) "*rmsbolt-compilation*"))))
        ;; Make sure the compilation hooks use the same temporary directory as
        ;; the buffer being compiled.
        (setq default-directory src-default-directory)
        ;; Only jump to errors, skip over warnings
        (setq-local compilation-skip-threshold 2)
        (add-hook 'compilation-finish-functions
                  #'rmsbolt--handle-finish-compile nil t)
        (setq rmsbolt-src-buffer src-buffer))))))

(defun rmsbolt--stop-running-compilation ()
  "Cancel a compilation."
  (when-let* ((compilation-buffer (get-buffer "*rmsbolt-compilation*"))
              (proc (get-buffer-process compilation-buffer)))
    (when (eq (process-status proc) 'run)
      (set-process-sentinel proc nil)
      (interrupt-process proc)
      (let ((src-buffer (buffer-local-value 'rmsbolt-src-buffer
                                            compilation-buffer)))
        (if (and src-buffer
                 (buffer-local-value 'rmsbolt--cargo-asm-active src-buffer))
            (rmsbolt--handle-finish-cargo-asm compilation-buffer nil t)
          (rmsbolt--handle-finish-compile compilation-buffer nil :stopped t)))
      ;; Wait a short while for the process to exit cleanly
      (sit-for 0.2)
      (delete-process proc))))

;;;; Keymap
(defvar rmsbolt-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'rmsbolt-compile)
    (define-key map (kbd "C-c C-a") #'rmsbolt-cargo-asm)
    (define-key map (kbd "C-c C-n") #'rmsbolt-output-forward-chunk)
    (define-key map (kbd "C-c C-p") #'rmsbolt-output-backward-chunk)
    map)
  "Keymap for function `rmsbolt-mode'.")

;;;; Init commands

(defun rmsbolt--gen-temp ()
  "Get a temporary directory close to the current buffer.  A new directory is
created if needed.  Only one temporary directory exists per host so as to support
compilation of remote files."
  ;; Get this buffer's temporary directory.  Use the buffer's default directory
  ;; if the current buffer isn't backed by a file.
  (let* ((remote-components (file-remote-p (or (buffer-file-name)
                                               default-directory)))
        (temp-directory (gethash remote-components rmsbolt--temp-dirs-hash)))
    ;; Create a temporary directory if we haven't already for this remote.
    (unless temp-directory
      (puthash remote-components (make-nearby-temp-file "rmsbolt-" t) rmsbolt--temp-dirs-hash)
      (setq temp-directory (gethash remote-components rmsbolt--temp-dirs-hash))
      ;; Make sure this directory is removed when we exit.
      (add-hook 'kill-emacs-hook
                (lambda ()
                  (when (and temp-directory
                             (file-directory-p temp-directory)
                             (string-match "rmsbolt" (file-name-nondirectory temp-directory)))
                    (delete-directory temp-directory t)))))
    (setq rmsbolt--temp-dir temp-directory)))

;;;;; Starter Definitions

;; IIUC, this "starter" business is not a necessary part of RMSBolt, but is
;; a way to provide sample files with which users can try out RMSBolt.

(defvar rmsbolt-starter-files
  '(("c" . "rmsbolt.c")
    ("c++" . "rmsbolt.cpp")
    ("ada" . "rmsbolt.adb")
    ("ocaml" . "rmsbolt.ml")
    ("cl" . "rmsbolt.lisp")
    ("rust " . "rmsbolt.rs")
    ("python" . "rmsbolt.py")
    ("fortran" . "rmsbolt.f")
    ("fortran90" . "rmsbolt.f90")
    ("haskell" . "rmsbolt.hs")
    ("mlir" . "rmsbolt.mlir")
    ("php" . "rmsbolt.php")
    ("pony" . "rmsbolt.pony")
    ("emacs-lisp" . "rmsbolt-starter.el")
    ("d" . "rmsbolt.d")
    ("zig" . "rmsbolt.zig")
    ("go" . "rmsbolt.go")
    ("swift" . "rmsbolt.swift")
    ;; Rmsbolt is capitalized here because of Java convention of Capitalized
    ;; class names.
    ("java" . "Rmsbolt.java")
    ("nim" . "rmsbolt.nim")))

;;;###autoload
(defun rmsbolt-starter (lang-name)
  "Setup new file based on the sample for the language provided.

Uses LANG-NAME to determine the language."
  (interactive
   (list (completing-read "Language: " rmsbolt-starter-files nil t)))
  (rmsbolt--gen-temp)
  (let* ((starter-file-name (cdr (assoc lang-name rmsbolt-starter-files)))
         (file-name
          (expand-file-name starter-file-name rmsbolt--temp-dir))
         (exists (file-exists-p file-name))
         (src-file-name
          (when rmsbolt-dir
            (expand-file-name starter-file-name
                              (expand-file-name "starters/" rmsbolt-dir))))
         (src-file-exists (when src-file-name
                            (file-exists-p src-file-name))))
    (if (not src-file-exists)
        (error "Could not find starter files! Are you sure the starters/ folder is available? If you want to overide, set `rmsbolt-dir' to your install path")
      (unless exists
        (copy-file src-file-name file-name)
        (set-file-modes file-name #o644))
      (find-file file-name)
      (unless rmsbolt-mode
        (rmsbolt-mode 1)))))

;;;; Output Chunk Navigation

(defun rmsbolt--output-chunks (src-buffer src-line)
  "Return the assembly chunks mapped to SRC-LINE in SRC-BUFFER.
The chunks are ordered by their start line.  Each chunk is a cons of its
first and last line number in the rmsbolt output buffer."
  (let ((mapping (and (buffer-live-p src-buffer)
                      (buffer-local-value 'rmsbolt-line-mapping src-buffer))))
    (when mapping
      (sort (copy-sequence (gethash src-line mapping))
            (lambda (a b) (< (car a) (car b)))))))

(defun rmsbolt--output-chunk-at-line (line chunks)
  "Return the chunk from CHUNKS that contains LINE, or nil."
  (cl-find-if (lambda (chunk) (<= (car chunk) line (cdr chunk))) chunks))

(defun rmsbolt--output-focus-line (output-buffer)
  "Return the line in OUTPUT-BUFFER that currently has focus."
  (with-current-buffer output-buffer
    (line-number-at-pos
     (if-let* ((window (get-buffer-window output-buffer 'visible)))
         (window-point window)
       (point)))))

(defun rmsbolt--output-focus-chunk (chunk output-buffer)
  "Move the focus in OUTPUT-BUFFER to the start of CHUNK."
  (if-let* ((window (get-buffer-window output-buffer 'visible)))
      (with-selected-window window
        (goto-char (point-min))
        (forward-line (1- (car chunk)))
        (recenter))
    (with-current-buffer output-buffer
      (goto-char (point-min))
      (forward-line (1- (car chunk))))))

(defun rmsbolt--output-cycle-chunk (step)
  "Cycle the rmsbolt output focus through the chunks of the current line.
The current line is the source line at point in the rmsbolt output
buffer, or the line at point in its source buffer.  STEP is 1 to move to
the next chunk and -1 to move to the previous one.  Cycling wraps around
at either end."
  (let* ((output-buffer (get-buffer rmsbolt-output-buffer))
         (src-buffer (and output-buffer
                          (buffer-local-value 'rmsbolt-src-buffer output-buffer)))
         (in-output (eq (current-buffer) output-buffer))
         (in-source (and rmsbolt-mode
                         src-buffer
                         (eq (current-buffer) src-buffer))))
    (unless (or in-output in-source)
      (user-error "This buffer is not linked to the rmsbolt output buffer"))
    (unless (buffer-live-p src-buffer)
      (user-error "The rmsbolt output buffer has no live source buffer"))
    (let* ((src-line (if in-output
                         (or (get-text-property (point) 'rmsbolt-src-line)
                             (get-text-property (line-beginning-position)
                                                'rmsbolt-src-line))
                       (line-number-at-pos)))
           (chunks (and src-line (rmsbolt--output-chunks src-buffer src-line))))
      (unless chunks
        (user-error "No assembly mapped to the current line"))
      (let ((count (length chunks)))
        (if (= count 1)
            (message "Source line %d maps to a single assembly chunk" src-line)
          (let* ((current (rmsbolt--output-chunk-at-line
                           (if in-output
                               (line-number-at-pos)
                             (rmsbolt--output-focus-line output-buffer))
                           chunks))
                 (index (if current
                            (cl-position current chunks :test #'eq)
                          (if (< step 0) count -1)))
                 (next-index (mod (+ index step) count))
                 (chunk (nth next-index chunks)))
            (rmsbolt--output-focus-chunk chunk output-buffer)
            (message "Assembly chunk %d/%d for source line %d"
                     (1+ next-index) count src-line)))))))

;;;###autoload
(defun rmsbolt-output-forward-chunk ()
  "Move to the next assembly chunk of the current source line.
A source line can compile to several disjoint chunks of assembly.  This
command cycles the rmsbolt output focus through them and wraps around
after the last chunk.  It works in the output buffer and in the source
buffer under `rmsbolt-mode'."
  (interactive)
  (rmsbolt--output-cycle-chunk 1))

;;;###autoload
(defun rmsbolt-output-backward-chunk ()
  "Move to the previous assembly chunk of the current source line.
A source line can compile to several disjoint chunks of assembly.  This
command cycles the rmsbolt output focus through them and wraps around
before the first chunk.  It works in the output buffer and in the source
buffer under `rmsbolt-mode'."
  (interactive)
  (rmsbolt--output-cycle-chunk -1))

;;;; Overlay Commands
(defun rmsbolt--goto-line (line)
  "Goto a certain LINE."
  (when line
    (let ((cur (line-number-at-pos)))
      (forward-line (- line cur)))))

(defun rmsbolt--setup-overlay (start end buf)
  "Setup overlay with START and END in BUF."
  (let ((o (make-overlay start end buf)))
    (overlay-put o 'face 'rmsbolt-current-line-face)
    o))

(cl-defun rmsbolt--point-visible (point)
  "Check if the current POINT is visible in a window in the current buffer."
  (cl-find-if (lambda (w)
                (<= (window-start w) point (window-end w)))
              (get-buffer-window-list)))

(cl-defun rmsbolt-update-overlays (&key (force nil))
  "Update overlays to highlight the currently selected source and asm lines.
If FORCE, always scroll overlay, even when one is visible.  FORCE also
scrolls to the first line, instead of the first line of the last block."
  (when rmsbolt-mode
    (if-let ((should-run rmsbolt-use-overlays)
             (output-buffer (get-buffer rmsbolt-output-buffer))
             (src-buffer (buffer-local-value 'rmsbolt-src-buffer output-buffer))
             (should-run (and (or (eq (current-buffer) src-buffer)
                                  (eq (current-buffer) output-buffer))
                              ;; Don't run on unsaved buffers
                              (not (buffer-modified-p src-buffer))
                              (buffer-local-value 'rmsbolt-mode src-buffer)))
             (current-line (line-number-at-pos))
             (src-current-line
              (if (eq (current-buffer) src-buffer)
                  current-line
                (get-text-property (point) 'rmsbolt-src-line)))
             (line-mappings (buffer-local-value 'rmsbolt-line-mapping src-buffer))
             (asm-regions (gethash src-current-line line-mappings))
             ;; TODO also consider asm
             (src-pts
              (with-current-buffer src-buffer
                (save-excursion
                  (rmsbolt--goto-line src-current-line)
                  (cl-values (c-point 'bol) (c-point 'bonl))))))
        (let*
            ;; If nil, output-buffer is scrolled instead
            ((scroll-src-buffer-p (not (eq (current-buffer) src-buffer)))
             (line-visible (or (not rmsbolt-goto-match)
                               (when scroll-src-buffer-p
                                 (with-current-buffer src-buffer
                                   (rmsbolt--point-visible (cl-first src-pts)))))))
          ;; Remove existing overlays
          (rmsbolt--remove-overlays)
          (push (rmsbolt--setup-overlay (cl-first src-pts) (cl-second src-pts) src-buffer)
                rmsbolt-overlays)
          (with-current-buffer output-buffer
            (let ((saved-pt (point)))
              (save-excursion
                (cl-loop for (start . end) in asm-regions
                         do (let ((start-pt (progn (rmsbolt--goto-line start)
                                                   (c-point 'bol)))
                                  (end-pt (progn (rmsbolt--goto-line end)
                                                 (c-point 'bonl))))
                              (when (and (not line-visible)
                                         (not scroll-src-buffer-p))
                                (setq line-visible (or (rmsbolt--point-visible start-pt)
                                                       (rmsbolt--point-visible end-pt)
                                                       (< start-pt saved-pt end-pt))))
                              (push (rmsbolt--setup-overlay start-pt end-pt output-buffer)
                                    rmsbolt-overlays)))))
            (when (or (not line-visible) force)
              ;; Scroll buffer to first line
              (when-let ((scroll-buffer (if scroll-src-buffer-p
                                            src-buffer
                                          output-buffer))
                         (window (get-buffer-window scroll-buffer))
                         (line-scroll (if scroll-src-buffer-p
                                          src-current-line
                                        (progn
                                          (car-safe
                                           ;; If forcing, pick the last region instead
                                           (if force
                                               (car-safe (last asm-regions))
                                             (cl-first asm-regions)))))))
                (with-selected-window window
                  (rmsbolt--goto-line line-scroll)
                  ;; If we scrolled, recenter
                  (recenter))))))
      (rmsbolt--remove-overlays))
    ;; If not in rmsbolt-mode, don't do anything
    ))

(defun rmsbolt--remove-overlays ()
  "Clean up overlays, assuming they are no longer needed."
  (mapc #'delete-overlay rmsbolt-overlays)
  (setq rmsbolt-overlays nil))

(defun rmsbolt--post-command-hook ()
  "Update overlays and perform book-keeping post-compile."
  ;; Use (point) instead of (line-number-at-pos) to track movements because
  ;; the former is faster (constant runtime)
  (unless (eq (point) rmsbolt--last-point)
    (setq rmsbolt--last-point (point))
    (rmsbolt-update-overlays)))

(defun rmsbolt--on-kill-buffer ()
  "Perform cleanup if the user deletes the buffer."
  (when-let (output-buffer (get-buffer rmsbolt-output-buffer))
    (when (or (eq (current-buffer) output-buffer)
              (eq (current-buffer) (buffer-local-value 'rmsbolt-src-buffer output-buffer)))
      (rmsbolt--remove-overlays))))

(defun rmsbolt--is-active-src-buffer ()
  "Helper to see if our src buffer is active."
  (when-let (output-buffer (get-buffer rmsbolt-output-buffer))
    (eq (current-buffer) (buffer-local-value 'rmsbolt-src-buffer output-buffer))))

(defun rmsbolt--after-save ()
  "Handle automated compile and other after-safe functions."
  (when (and (rmsbolt--is-active-src-buffer)
             rmsbolt-automatic-recompile)
    (setq rmsbolt--automated-compile t)
    (rmsbolt-compile)))

;; Auto-save the src buffer after it has been unchanged for `rmsbolt-compile-delay' seconds.
;; The buffer is then automatically recompiled via `rmsbolt--after-save'.
(defvar rmsbolt--change-timer nil)
(defvar rmsbolt--buffer-to-auto-save nil)

(defun rmsbolt--after-change (&rest _)
  "Handle automatic recompile and other functions after edit."
  (when (and (rmsbolt--is-active-src-buffer)
             rmsbolt-automatic-recompile
             (not (eq rmsbolt-automatic-recompile 'on-save)))
    (when rmsbolt--change-timer
      (cancel-timer rmsbolt--change-timer))
    (setq rmsbolt--buffer-to-auto-save (current-buffer)
          rmsbolt--change-timer (run-with-timer rmsbolt-compile-delay nil #'rmsbolt--on-change-timer))))

(defun rmsbolt--on-change-timer ()
  "Hook to run on automatic recompile timer."
  (setq rmsbolt--change-timer nil)
  (when (buffer-live-p rmsbolt--buffer-to-auto-save)
    (with-current-buffer rmsbolt--buffer-to-auto-save
      (setq rmsbolt--buffer-to-auto-save nil)
      (when (or (< (line-number-at-pos (point-max)) rmsbolt-large-buffer-size)
                (eq rmsbolt-automatic-recompile 'force))
        ;; Clear `before-save-hook' to prevent things like whitespace cleanup
        ;; (e.g., set by spacemacs in `spacemacs-whitespace-cleanup.el`)
        ;; and aggressive indenting from running (this is a hot recompile).
        ;; TODO does anyone want before-save-hook to run on a hot recompile?
        (let ((before-save-hook nil))
          (save-buffer))))))

;;;; Mode Definition:

;;;###autoload
;; TODO handle more modes than c-mode
(define-minor-mode rmsbolt-mode
  "Toggle `rmsbolt-mode'.

This mode is enabled in both src and assembly output buffers."
  :global nil
  :lighter rmsbolt-mode-lighter
  :keymap rmsbolt-mode-map
  ;; Init
  (cond
   (rmsbolt-mode
    (setq rmsbolt--last-point (point))
    (add-hook 'post-command-hook #'rmsbolt--post-command-hook nil t)
    (add-hook 'kill-buffer-hook #'rmsbolt--on-kill-buffer nil t)

    (when (and rmsbolt-automatic-recompile
               ;; Only turn on auto-save in src buffers
               (not (eq (current-buffer) (get-buffer rmsbolt-output-buffer))))
      (add-hook 'after-save-hook #'rmsbolt--after-save nil t)
      (when (eq rmsbolt-automatic-recompile t)
        (add-hook 'after-change-functions #'rmsbolt--after-change nil t)))

    (rmsbolt--gen-temp))
   (t ;; Cleanup
    (rmsbolt--remove-overlays)
    (remove-hook 'after-change-functions #'rmsbolt--after-change t)
    (remove-hook 'after-save-hook #'rmsbolt--after-save t)
    (remove-hook 'kill-buffer-hook #'rmsbolt--on-kill-buffer t)
    (remove-hook 'post-command-hook #'rmsbolt--post-command-hook t))))

;;;###autoload
(defun rmsbolt ()
  "Start a rmsbolt compilation and enable `rmsbolt-mode'.

Provides code region highlighting and automatic recompilation."
  (interactive)
  (unless rmsbolt-mode
    (rmsbolt-mode))
  (rmsbolt-compile))

(provide 'rmsbolt)

;;; rmsbolt.el ends here

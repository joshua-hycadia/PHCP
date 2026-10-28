;;;============================================================================
;;; phcp_export.lsp -- mark up a 2D AutoCAD drawing and export it to PHCP.
;;;
;;; Copyright (c) 2026 Hycadia Pty Ltd
;;; SPDX-License-Identifier: MIT -- see LICENSE.
;;;
;;; For AutoCAD 2026 (Visual LISP).  Load with APPLOAD, or add to the Startup
;;; Suite, then type the commands below at the command line.
;;;
;;; ---------------------------------------------------------------------------
;;; WHAT IT DOES
;;; ---------------------------------------------------------------------------
;;; Turns a 2D pipework layout into a PHCP model file (.phc) that PHCP solves
;;; and reports on, so the network is never typed in by hand.
;;;
;;;   PHCPSETUP     create the PHCP layers and symbol blocks, set symbol size
;;;   PHCPPROJECT   enter the project details that appear on the cover sheet
;;;   PHCPSUPPLY    place the water supply, with its pressure or curve
;;;   PHCPPIPE      give selected lines their size, type and fittings
;;;   PHCPELEV      mark node elevations
;;;   PHCPHEAD      nominate discharging heads -- place new, or tag existing
;;;   PHCPCHECK     check the drawing without exporting; faults are selected
;;;   PHCPEXPORT    check, then write the .phc file
;;;   PHCPSOLVE     export beside the drawing, run phcp.exe --json on it, and
;;;                 show the result: the governing outlet, any that fail
;;;   PHCPINFO      list the PHCP data on an object you pick
;;;
;;; ---------------------------------------------------------------------------
;;; HOW THE DRAWING BECOMES A MODEL
;;; ---------------------------------------------------------------------------
;;; PIPES are LINEs or open LWPOLYLINEs that carry PHCP data.  A pipe runs from
;;; its start point to its end point; a polyline with bends is ONE pipe, and
;;; its bends must be included in its fitting string.
;;;
;;; NODES are made at pipe ends.  Two ends within the tolerance of each other
;;; are the same node.  A node's elevation comes from an elevation marker
;;; placed on it, or from the head placed on it, or from the default elevation
;;; asked for at export.
;;;
;;; HEADS and the SUPPLY attach to the node at their insertion point.
;;;
;;; LENGTH is the true length: the plan length along the line or polyline,
;;; combined with the change in elevation between its two ends.  A pipe that
;;; is vertical in reality -- a riser -- can be given its actual length with
;;; the length override in PHCPPIPE.
;;;
;;; DROPS to sprinklers are vertical and cannot be drawn in plan.  Give the
;;; head its own elevation and a drop size in PHCPHEAD; the export adds the
;;; drop as a pipe from the branch-line node down (or up) to the head.
;;;
;;; ---------------------------------------------------------------------------
;;; WHERE THE DATA IS KEPT
;;; ---------------------------------------------------------------------------
;;; On the drawing objects themselves, as extended data (XDATA) under the
;;; application name "PHCP", as KEY=value strings.  A line keeps its pipe size
;;; wherever it is moved, copied or stretched, and the drawing IS the model --
;;; there is no second file to keep in step.  Blocks are only the visible
;;; symbols; the data on them is XDATA too, so a tagged existing sprinkler
;;; block works exactly like a PHCP head block.
;;;
;;; Project details are kept in the drawing's own dictionary ("PHCP") and
;;; travel with the DWG.
;;;
;;; ---------------------------------------------------------------------------
;;; WHAT IT REFUSES TO DO
;;; ---------------------------------------------------------------------------
;;; Guess.  A drawing with errors is not exported: the faults are listed, and
;;; the objects responsible are selected on screen so they can be fixed.  The
;;; most common one in 2D work is a branch line drawn to the MIDDLE of a main
;;; that was never broken there -- on screen it looks connected, in the model
;;; it is not.  That is checked for.
;;;
;;; Units: PHCP models are written in metres, millimetres, kPa and L/min.  The
;;; drawing may be in millimetres or metres; the export converts.
;;;============================================================================

(vl-load-com)

;;;----------------------------------------------------------------------------
;;; Settings.  Kept in global variables named *phcp-...* so they survive
;;; between commands in one session; the symbol size is also stored in the
;;; drawing so it survives closing and reopening.
;;;----------------------------------------------------------------------------
(setq *phcp-app*  "PHCP")          ; XDATA application name
(setq *phcp-dict* "PHCP")          ; drawing dictionary for project data

;; Pipe types in PHCP's pipe database (data/pipes.dat).  Offered as the
;; choices in PHCPPIPE so a type cannot be mistyped.
(setq *phcp-types* '("ASAM" "ASAH" "S20" "S40" "CPVC" "PE11" "PE9" "PVCM16"))

;;;============================================================================
;;; SMALL HELPERS
;;;============================================================================

;; The drawing's length unit as a factor to metres.  INSUNITS 4 is
;; millimetres, 6 is metres; anything else is asked for, because a wrong
;; factor makes every length a thousand times out.
(defun phcp:unit-factor ( / u k)
  (setq u (getvar "INSUNITS"))
  (cond ((= u 4) 0.001)
        ((= u 6) 1.0)
        ;; asked ONCE per session: this is called on every symbol placed, and
        ;; the question must not come back each time
        (*phcp-uf* *phcp-uf*)
        (t
         (initget "Millimetres Metres")
         (setq k (getkword "\nDrawing units are not set. Drawing is in [Millimetres/Metres] <Millimetres>: "))
         (setq *phcp-uf* (if (= k "Metres") 1.0 0.001)))))

;; A real number with a default taken on Enter.
(defun phcp:get-real (msg def / v)
  (setq v (getreal (strcat msg (if def (strcat " <" (rtos def 2 3) ">") "") ": ")))
  (if v v def))

;; A string with a default taken on Enter.  Spaces are allowed.
(defun phcp:get-str (msg def / v)
  (setq v (getstring T (strcat msg (if (and def (/= def "")) (strcat " <" def ">") "") ": ")))
  (if (= v "") def v))

;; "KEY=value" -> ("KEY" . "value").  Keys are upper-cased; values kept.
(defun phcp:split-kv (s / i)
  (if (setq i (vl-string-search "=" s))
    (cons (strcase (substr s 1 i)) (substr s (+ i 2)))
    (cons (strcase s) "")))

;; The value for KEY in an association list of strings, or nil.
(defun phcp:val (key alist)
  (cdr (assoc (strcase key) alist)))

;; A value as a number, or nil when it is absent or not a number.
(defun phcp:num (key alist / v)
  (setq v (phcp:val key alist))
  (if (and v (/= v "") (distof v 2)) (distof v 2) nil))

;; Plan distance between two points, ignoring Z: the drawing is 2D and a
;; stray Z on one end must not change a length.
(defun phcp:dist2d (a b)
  (distance (list (car a) (cadr a)) (list (car b) (cadr b))))

;; A number as text for the model file.  Three decimals is 1 mm in metres.
(defun phcp:fmt (x) (rtos x 2 3))

;;;============================================================================
;;; XDATA -- the PHCP data on a drawing object
;;;============================================================================

;; Read an object's PHCP data as an association list of strings.
;; entget with an application list returns the XDATA as
;;   (-3 ("PHCP" (1000 . "KIND=PIPE") (1000 . "DN=50") ...))
(defun phcp:xd-get (e / xd)
  (setq xd (cdr (assoc -3 (entget e (list *phcp-app*)))))
  (if xd
    (mapcar '(lambda (g) (phcp:split-kv (cdr g)))
            (vl-remove-if-not '(lambda (g) (= (car g) 1000)) (cdr (car xd))))))

;; Replace an object's PHCP data with an association list of strings.
;; entmod with a -3 group replaces this application's XDATA and leaves any
;; other application's XDATA on the object alone.  Empty values are dropped,
;; so clearing a field removes it rather than storing "KEY=".
(defun phcp:xd-set (e alist / ed)
  (if (not (tblsearch "APPID" *phcp-app*)) (regapp *phcp-app*))
  (setq ed (entget e))
  (entmod
    (append ed
      (list (list -3
                  (cons *phcp-app*
                        (mapcar '(lambda (p) (cons 1000 (strcat (car p) "=" (cdr p))))
                                (vl-remove-if '(lambda (p) (or (null (cdr p)) (= (cdr p) "")))
                                              alist)))))))
  (entupd e))

;; Set one field, keeping the rest.
(defun phcp:xd-put (e key value / al)
  (setq al (vl-remove-if '(lambda (p) (= (car p) (strcase key))) (phcp:xd-get e)))
  (phcp:xd-set e (append al (list (cons (strcase key) value)))))

;; Every object in the drawing carrying PHCP data of a given KIND.
(defun phcp:all-of-kind (kind / ss i e out)
  (setq ss (ssget "_X" (list (list -3 (list *phcp-app*)))) i 0)
  (if ss
    (repeat (sslength ss)
      (setq e (ssname ss i) i (1+ i))
      (if (= (phcp:val "KIND" (phcp:xd-get e)) kind) (setq out (cons e out)))))
  (reverse out))

;;;============================================================================
;;; PROJECT DATA -- kept in the drawing's dictionary, travels with the DWG
;;;============================================================================

(setq *phcp-project-fields*
  '(("TITLE" "Job name") ("PROJECT" "Project") ("JOB" "Job number")
    ("COMPANY" "Company") ("ADDRESS" "Company address") ("LICENCE" "Licence")
    ("DESIGNER" "Designer") ("CHECKER" "Checker") ("REVISION" "Revision")
    ("DATE" "Date") ("LOCATION" "Site location") ("STANDARD" "Standard")
    ("HAZARD" "Hazard class") ("DENSITY" "Design density, mm/min")
    ("AREA_PER_SPRINKLER" "Area per sprinkler, m2")
    ("AREA_OF_OPERATION" "Area of operation, m2 (optional)")
    ("AUTHORITY" "Authority having jurisdiction") ("AUTHORITY_PHONE" "Authority phone")))

(defun phcp:proj-get (key) (vlax-ldata-get *phcp-dict* key))
(defun phcp:proj-put (key v) (vlax-ldata-put *phcp-dict* key v))

;;;============================================================================
;;; LAYERS AND SYMBOL BLOCKS
;;;============================================================================

(defun phcp:layer (name color / lays lay)
  (setq lays (vla-get-Layers (vla-get-ActiveDocument (vlax-get-acad-object))))
  (setq lay (vla-Add lays name))
  (vla-put-Color lay color)
  name)

;; An attribute definition for entmake.  The subclass markers are required
;; in this order for entmake to accept an ATTDEF.
(defun phcp:attdef (tag prompt y h)
  (list '(0 . "ATTDEF") '(100 . "AcDbEntity") '(8 . "0") '(100 . "AcDbText")
        (list 10 1.3 y 0.0) (cons 40 h) '(1 . "") '(100 . "AcDbAttributeDefinition")
        (cons 3 prompt) (cons 2 tag) '(70 . 0)))

;; A closed polyline for use inside a block definition.
(defun phcp:poly (pts)
  (append (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(8 . "0")
                '(100 . "AcDbPolyline") (cons 90 (length pts)) '(70 . 1))
          (mapcar '(lambda (p) (cons 10 p)) pts)))

;; Define a block once.  Geometry is drawn at unit size about the insertion
;; point and scaled at insertion, so the same definition works in a
;; millimetre drawing and a metre drawing.
(defun phcp:define-block (name ents)
  (if (not (tblsearch "BLOCK" name))
    (progn
      (entmake (list '(0 . "BLOCK") (cons 2 name) '(70 . 2) '(10 0.0 0.0 0.0)))
      (foreach g ents (entmake g))
      (entmake '((0 . "ENDBLK") (8 . "0"))))))

;; Everything a command needs before it can place a symbol.  Called by every
;; command rather than relying on PHCPSETUP having been run first: a symbol
;; inserted on a layer that does not exist fails with an error that tells the
;; user nothing useful.
(defun phcp:ensure ()
  (phcp:layer "PHCP-SUPPLY" 1)          ; red
  (phcp:layer "PHCP-HEAD"   5)          ; blue
  (phcp:layer "PHCP-ELEV"   3)          ; green
  (phcp:layer "PHCP-LABEL"  8)          ; grey
  (phcp:layer "PHCP-TAGS"   6)          ; magenta
  (phcp:define-blocks)
  (if (not (tblsearch "APPID" *phcp-app*)) (regapp *phcp-app*)))

(defun phcp:define-blocks ()
  ;; water supply: a square with a cross, and its ID and pressure beside it
  (phcp:define-block "PHCP_SUPPLY"
    (list (phcp:poly '((-1.0 -1.0) (1.0 -1.0) (1.0 1.0) (-1.0 1.0)))
          '((0 . "LINE") (8 . "0") (10 -1.0 -1.0 0.0) (11 1.0 1.0 0.0))
          '((0 . "LINE") (8 . "0") (10 -1.0 1.0 0.0) (11 1.0 -1.0 0.0))
          (phcp:attdef "ID" "Supply ID" 0.5 0.6)
          (phcp:attdef "INFO" "Supply" -0.5 0.5)))
  ;; head: a circle, and its ID and K beside it
  (phcp:define-block "PHCP_HEAD"
    (list '((0 . "CIRCLE") (8 . "0") (10 0.0 0.0 0.0) (40 . 1.0))
          (phcp:attdef "ID" "Head ID" 0.5 0.6)
          (phcp:attdef "INFO" "Head" -0.5 0.5)))
  ;; elevation marker: a diamond, and the elevation beside it
  (phcp:define-block "PHCP_ELEV"
    (list (phcp:poly '((0.0 -0.7) (0.7 0.0) (0.0 0.7) (-0.7 0.0)))
          (phcp:attdef "ELEV" "Elevation" 0.0 0.6))))

;; Insert a PHCP symbol with its attribute text filled in, and return it.
(defun phcp:insert (name pt attvals / ms blk v)
  (setq ms (vla-get-ModelSpace (vla-get-ActiveDocument (vlax-get-acad-object))))
  (setq blk (vla-InsertBlock ms (vlax-3d-point pt) name
                             (phcp:symbol-size) (phcp:symbol-size) (phcp:symbol-size) 0.0))
  (vla-put-Layer blk (cdr (assoc name '(("PHCP_SUPPLY" . "PHCP-SUPPLY")
                                        ("PHCP_HEAD" . "PHCP-HEAD")
                                        ("PHCP_ELEV" . "PHCP-ELEV")))))
  (foreach att (vlax-invoke blk 'GetAttributes)
    (if (setq v (cdr (assoc (strcase (vla-get-TagString att)) attvals)))
      (vla-put-TextString att v)))
  (vlax-vla-object->ename blk))

;; Symbol size in drawing units: 150 mm, whatever the drawing unit.
(defun phcp:symbol-size ( / s)
  (setq s (phcp:proj-get "SYMBOL_SIZE"))
  (if s s (/ 0.15 (phcp:unit-factor))))

;;;============================================================================
;;; COMMANDS -- MARKING UP THE DRAWING
;;;============================================================================

(defun c:PHCPSETUP ( / s)
  (phcp:ensure)
  (setq s (phcp:get-real "\nSymbol size in drawing units" (phcp:symbol-size)))
  (phcp:proj-put "SYMBOL_SIZE" s)
  (princ "\nPHCP layers and symbols ready.  Next: PHCPPROJECT, PHCPSUPPLY, PHCPPIPE.")
  (princ))

(defun c:PHCPPROJECT ( / f v)
  (princ "\nProject details for the PHCP cover sheet.  Enter keeps the value shown.")
  (foreach f *phcp-project-fields*
    (setq v (phcp:get-str (strcat "\n" (cadr f)) (phcp:proj-get (car f))))
    (if v (phcp:proj-put (car f) v)))
  (princ "\nProject details saved in the drawing.")
  (princ))

;;; PHCPSUPPLY -- the water supply, as a static pressure or a flow/pressure
;;; curve (for example from a hydrant flow test or a water authority
;;; statement).  Pressures in kPa, flows in L/min.
(defun c:PHCPSUPPLY ( / pt id kind p q pts e info)
  (phcp:ensure)
  (setq pt (getpoint "\nPick the supply connection point (snap to a pipe end): "))
  (if pt
    (progn
      (setq id (phcp:get-str "\nSupply ID" "SUP1"))
      (initget "Static Curve")
      (setq kind (getkword "\nSupply type [Static/Curve] <Static>: "))
      (if (= kind "Curve")
        (progn
          ;; The static pressure is the curve's point at zero flow, and the
          ;; model's WATER line needs it; then the flow-test points.
          (setq p (phcp:get-real "\nStatic pressure (at zero flow), kPa" nil))
          (if (not p) (progn (princ "\n*** No static pressure given; supply not placed.") (exit)))
          (setq pts (list 0.0 p))
          (princ "\nNow the flow-test points, flow first.  At least one; Enter on a flow to finish.")
          (while (setq q (getreal (strcat "\n  Point " (itoa (/ (length pts) 2)) " flow L/min <done>: ")))
            (setq p (getreal "\n  pressure kPa: "))
            (if p (setq pts (append pts (list q p)))))
          (if (< (length pts) 4)
            (progn (princ "\n*** A curve needs at least one flow-test point; supply not placed.") (exit)))
          (setq p nil)
          (setq info (strcat "CURVE " (itoa (/ (length pts) 2)) " points")))
        (progn
          (setq p (phcp:get-real "\nStatic pressure, kPa" nil))
          (if (not p) (progn (princ "\n*** No pressure given; supply not placed.") (exit)))
          (setq info (strcat (rtos p 2 0) " kPa"))))
      (setq e (phcp:insert "PHCP_SUPPLY" pt (list (cons "ID" id) (cons "INFO" info))))
      (phcp:xd-set e (list (cons "KIND" "SUPPLY") (cons "ID" id)
                           (cons "TYPE" (if (= kind "Curve") "CURVE" "STATIC"))
                           (cons "P" (if p (rtos p 2 3) ""))
                           (cons "CURVE" (if pts (vl-string-right-trim " "
                                              (apply 'strcat (mapcar '(lambda (x) (strcat (rtos x 2 3) " ")) pts)))
                                           ""))))
      (princ (strcat "\nSupply " id " placed."))))
  (princ))

;;; PHCPPIPE -- pipe data on selected lines.  Everything asked for has a
;;; default taken from the last pipe entered, so a run of the same size is
;;; one selection and a few presses of Enter.
(defun c:PHCPPIPE ( / ss i e ty dn c fit len kw lbl mid ang)
  (phcp:ensure)
  (princ "\nSelect the lines or polylines that are pipes (all will get the same data):")
  (setq ss (ssget '((0 . "LINE,LWPOLYLINE"))))
  (if ss
    (progn
      (initget (apply 'strcat (mapcar '(lambda (x) (strcat x " ")) *phcp-types*)))
      (setq ty (getkword (strcat "\nPipe type [ASAM/ASAH/S20/S40/CPVC/PE11/PE9/PVCM16] <"
                                 (if *phcp-last-type* *phcp-last-type* "ASAM") ">: ")))
      (if (not ty) (setq ty (if *phcp-last-type* *phcp-last-type* "ASAM")))
      (setq dn (getint (strcat "\nNominal size DN" (if *phcp-last-dn* (strcat " <" (itoa *phcp-last-dn*) ">") "") ": ")))
      (if (not dn) (setq dn *phcp-last-dn*))
      (if (not dn) (progn (princ "\n*** A nominal size is required.") (exit)))
      (setq c   (phcp:get-str "\nC factor (Enter = the pipe type's own)" ""))
      (setq fit (phcp:get-str "\nFittings, e.g. 2E,1T or 1E1T (Enter = none)" ""))
      (setq len (phcp:get-str "\nLength override in metres, for a riser (Enter = measured)" ""))
      (initget "Yes No")
      (setq kw (getkword "\nLabel the pipes on layer PHCP-LABEL? [Yes/No] <Yes>: "))
      (setq *phcp-last-type* ty *phcp-last-dn* dn i 0)
      (repeat (sslength ss)
        (setq e (ssname ss i) i (1+ i))
        ;; keep an existing pipe ID, so re-marking a pipe does not renumber it
        (phcp:xd-set e (list (cons "KIND" "PIPE") (cons "ID" (phcp:val "ID" (phcp:xd-get e)))
                             (cons "TYPE" ty) (cons "DN" (itoa dn)) (cons "C" c)
                             (cons "FIT" fit) (cons "LEN" len)))
        (if (/= kw "No")
          (progn
            (setq mid (vlax-curve-getPointAtDist e (/ (vlax-curve-getDistAtParam e (vlax-curve-getEndParam e)) 2.0)))
            (setq ang (angle (vlax-curve-getStartPoint e) (vlax-curve-getEndPoint e)))
            ;; keep label text upright
            (if (and (> ang (/ pi 2)) (<= ang (* 1.5 pi))) (setq ang (+ ang pi)))
            (setq lbl (strcat "DN" (itoa dn) " " ty (if (/= fit "") (strcat " " fit) "")))
            (entmake (list '(0 . "TEXT") '(8 . "PHCP-LABEL") (cons 10 mid) (cons 11 mid)
                           (cons 40 (* 0.5 (phcp:symbol-size))) (cons 1 lbl)
                           (cons 50 ang) '(72 . 1) '(73 . 1))))))
      (princ (strcat "\n" (itoa (sslength ss)) " pipe(s) set to DN" (itoa dn) " " ty "."))))
  (princ))

;;; PHCPELEV -- elevation markers.  Pick as many points as needed at one
;;; elevation, then Enter.
(defun c:PHCPELEV ( / z pt e n)
  (phcp:ensure)
  (setq z (phcp:get-real "\nElevation, metres above the site datum" *phcp-last-z*))
  (if z
    (progn
      (setq *phcp-last-z* z n 0)
      (while (setq pt (getpoint (strcat "\nPick a node at RL " (rtos z 2 3) " m (snap to a pipe end) <done>: ")))
        (setq e (phcp:insert "PHCP_ELEV" pt (list (cons "ELEV" (strcat "RL " (rtos z 2 3))))))
        (phcp:xd-set e (list (cons "KIND" "ELEV") (cons "Z" (rtos z 2 3))))
        (setq n (1+ n)))
      (princ (strcat "\n" (itoa n) " elevation marker(s) placed."))))
  (princ))

;;; PHCPHEAD -- discharging heads.  Either place PHCP head symbols, or select
;;; the sprinkler / hydrant blocks already in the drawing and tag them: the
;;; data is attached to the existing blocks, and nothing is redrawn.
(defun c:PHCPHEAD ( / mode ty k p q z ddn dty dfit ss i e pt n al)
  (phcp:ensure)
  (initget "Place Tag")
  (setq mode (getkword "\nHeads: [Place new symbols/Tag existing blocks] <Tag>: "))
  (if (not mode) (setq mode "Tag"))
  (initget "Sprinkler Hydrant Hosereel")
  (setq ty (getkword "\nType [Sprinkler/Hydrant/Hosereel] <Sprinkler>: "))
  (setq ty (strcase (if ty ty "Sprinkler")))
  (princ "\nAny TWO of K, minimum pressure and minimum flow define the head.")
  (setq k (phcp:get-real "\nK-factor, L/min/kPa^0.5 (Enter = none)" *phcp-last-k*))
  (setq p (phcp:get-real "\nMinimum pressure, kPa (Enter = none)" *phcp-last-p*))
  (setq q (phcp:get-real "\nMinimum flow, L/min (Enter = none)" nil))
  (if (< (length (vl-remove nil (list k p q))) 2)
    (progn (princ "\n*** Two of K, pressure and flow are needed; nothing tagged.") (exit)))
  (setq z (phcp:get-real "\nHead elevation, m (Enter = same as its pipe)" nil))
  (if z
    (progn
      (setq ddn (getint "\nDrop size DN <25>: "))
      (if (not ddn) (setq ddn 25))
      (setq dty (phcp:get-str "\nDrop pipe type" (if *phcp-last-type* *phcp-last-type* "ASAM")))
      (setq dfit (phcp:get-str "\nDrop fittings (Enter = none)" ""))))
  (setq *phcp-last-k* k *phcp-last-p* p n 0)
  (setq al (list (cons "KIND" "HEAD") (cons "TYPE" ty)
                 (cons "K" (if k (rtos k 2 3) "")) (cons "P" (if p (rtos p 2 3) ""))
                 (cons "Q" (if q (rtos q 2 3) "")) (cons "Z" (if z (rtos z 2 3) ""))
                 (cons "DROP_DN" (if ddn (itoa ddn) "")) (cons "DROP_TYPE" (if dty dty ""))
                 (cons "DROP_FIT" (if dfit dfit ""))))
  (if (= mode "Tag")
    (progn
      (princ "\nSelect the existing head blocks:")
      (setq ss (ssget '((0 . "INSERT"))) i 0)
      (if ss
        (repeat (sslength ss)
          (setq e (ssname ss i) i (1+ i) n (1+ n))
          ;; keep an existing head ID across re-tagging
          (phcp:xd-set e (cons (cons "ID" (phcp:val "ID" (phcp:xd-get e))) al)))))
    (while (setq pt (getpoint "\nPick a head location (snap to a pipe end) <done>: "))
      (setq e (phcp:insert "PHCP_HEAD" pt
                           (list (cons "INFO" (strcat ty (if k (strcat " K" (rtos k 2 1)) ""))))))
      (phcp:xd-set e al)
      (setq n (1+ n))))
  (princ (strcat "\n" (itoa n) " head(s) set as " ty "."))
  (princ))

;;; PHCPINFO -- what PHCP data is on this object?
(defun c:PHCPINFO ( / es al)
  (if (setq es (entsel "\nPick an object: "))
    (if (setq al (phcp:xd-get (car es)))
      (foreach p al (princ (strcat "\n  " (car p) " = " (cdr p))))
      (princ "\nNo PHCP data on that object.")))
  (princ))

;;;============================================================================
;;; ANALYSIS -- from drawing objects to a checked network
;;;
;;; Builds nodes from pipe ends, attaches heads, supplies and elevations, and
;;; collects every problem found as (severity message entity).  Nothing is
;;; written here; PHCPCHECK reports the result and PHCPEXPORT writes it.
;;;============================================================================

;; The node index nearest a point, if one is within tolerance, else nil.
(defun phcp:find-node (pt nodes tol / best bd d i)
  (setq i 0 bd tol)
  (foreach n nodes
    (setq d (phcp:dist2d pt (cadr n)))
    (if (<= d bd) (setq best i bd d))
    (setq i (1+ i)))
  best)

;; Next free number for an ID prefix, so new IDs never reuse one in the drawing.
(defun phcp:next-id (prefix used / n)
  (setq n 0)
  (foreach u used
    (if (and u (wcmatch u (strcat prefix "#*")) (distof (substr u (1+ (strlen prefix))) 2))
      (setq n (max n (fix (distof (substr u (1+ (strlen prefix))) 2))))))
  (1+ n))

(defun phcp:analyse (tol zdef uf / pipes heads sups elevs nodes probs pe al a b ia ib
                      n pid used np nh hid z dz plan len ids e best)
  (setq pipes (phcp:all-of-kind "PIPE") heads (phcp:all-of-kind "HEAD")
        sups (phcp:all-of-kind "SUPPLY") elevs (phcp:all-of-kind "ELEV"))
  (if (null pipes) (setq probs (cons (list "ERROR" "no pipes carry PHCP data - use PHCPPIPE" nil) probs)))
  (if (null sups)  (setq probs (cons (list "ERROR" "no water supply - use PHCPSUPPLY" nil) probs)))
  (if (null heads) (setq probs (cons (list "ERROR" "no discharging heads - use PHCPHEAD" nil) probs)))

  ;; -- nodes at pipe ends.  A node is (id point elevation-or-nil).
  (foreach e pipes
    (foreach pt (list (vlax-curve-getStartPoint e) (vlax-curve-getEndPoint e))
      (if (not (phcp:find-node pt nodes tol))
        (setq nodes (append nodes (list (list (strcat "N" (itoa (1+ (length nodes)))) pt nil)))))))

  ;; -- a pipe end touching the MIDDLE of another pipe is not a junction until
  ;;    that pipe is broken there.  On screen it looks connected; in the model
  ;;    it is not, and the branch would be fed from nowhere.
  (foreach n nodes
    (foreach e pipes
      (setq pe (vlax-curve-getClosestPointTo e (cadr n)))
      (if (and (< (phcp:dist2d pe (cadr n)) tol)
               (> (phcp:dist2d (cadr n) (vlax-curve-getStartPoint e)) tol)
               (> (phcp:dist2d (cadr n) (vlax-curve-getEndPoint e)) tol))
        (setq probs (cons (list "ERROR" (strcat "a pipe end meets another pipe mid-length at node "
                                                (car n) " - BREAK that pipe at the junction") e)
                          probs)))))

  ;; -- elevations from markers
  (foreach e elevs
    (setq ia (phcp:find-node (cdr (assoc 10 (entget e))) nodes tol))
    (if ia
      (setq nodes (subst (list (car (nth ia nodes)) (cadr (nth ia nodes))
                               (phcp:num "Z" (phcp:xd-get e)))
                         (nth ia nodes) nodes))
      (setq probs (cons (list "ERROR" "elevation marker is not on a pipe end" e) probs))))

  ;; -- heads: attach to a node; a head with its own elevation gets a drop
  (setq used (mapcar '(lambda (h) (phcp:val "ID" (phcp:xd-get h))) heads) nh (phcp:next-id "S" used))
  (foreach e heads
    (setq al (phcp:xd-get e) ia (phcp:find-node (cdr (assoc 10 (entget e))) nodes tol))
    (if (not ia)
      (setq probs (cons (list "ERROR" "head is not on a pipe end - snap it to one, or break the pipe there" e) probs))
      (progn
        (if (not (phcp:val "ID" al))
          (progn (phcp:xd-put e "ID" (strcat "S" (itoa nh))) (setq nh (1+ nh) al (phcp:xd-get e))))
        (if (< (length (vl-remove nil (list (phcp:num "K" al) (phcp:num "P" al) (phcp:num "Q" al)))) 2)
          (setq probs (cons (list "ERROR" (strcat "head " (phcp:val "ID" al) " needs two of K, pressure and flow") e) probs))))))

  ;; -- supplies: on a pipe end, and with a static pressure (the WATER line
  ;;    of the model needs it; a curve entered before PHCPSUPPLY asked for it
  ;;    may not start at zero flow)
  (foreach e sups
    (if (not (phcp:find-node (cdr (assoc 10 (entget e))) nodes tol))
      (setq probs (cons (list "ERROR" "supply is not on a pipe end - snap it to one" e) probs)))
    (if (not (phcp:supply-curve (phcp:xd-get e)))
      (setq probs (cons (list "ERROR" (strcat "supply " (phcp:val "ID" (phcp:xd-get e))
                                              " has no static pressure - place it again with PHCPSUPPLY") e) probs))))

  ;; -- a supply or a head names the node it sits on, so a node can carry
  ;;    only one of them; a head with its own elevation (a drop) has its own
  ;;    node and does not count
  (setq ids nil)
  (foreach e (append sups (vl-remove-if '(lambda (h) (phcp:num "Z" (phcp:xd-get h))) heads))
    (setq ia (phcp:find-node (cdr (assoc 10 (entget e))) nodes tol))
    (if ia
      (if (assoc ia ids)
        (setq probs (cons (list "ERROR" (strcat (phcp:val "ID" (phcp:xd-get e)) " and "
                                                (cdr (assoc ia ids)) " are on the same pipe end - "
                                                "give the head its own elevation, or move one") e) probs))
        (setq ids (cons (cons ia (phcp:val "ID" (phcp:xd-get e))) ids)))))

  ;; -- pipe IDs: keep existing ones, number new ones after the highest in use
  (setq used (mapcar '(lambda (p) (phcp:val "ID" (phcp:xd-get p))) pipes) np (phcp:next-id "P" used))
  (foreach e pipes
    (if (not (phcp:val "ID" (phcp:xd-get e)))
      (progn (phcp:xd-put e "ID" (strcat "P" (itoa np))) (setq np (1+ np)))))
  (setq ids nil)
  (foreach e pipes
    (setq pid (phcp:val "ID" (phcp:xd-get e)))
    (if (member pid ids)
      (setq probs (cons (list "ERROR" (strcat "two pipes share ID " pid " - copied lines keep their ID; clear it with PHCPPIPE") e) probs))
      (setq ids (cons pid ids))))
  ;; -- every name in the model is used once: a supply's or head's ID must not
  ;;    be a pipe's, another head's, or a plain node's (N1, N2 ...)
  (foreach e (append sups heads)
    (setq pid (phcp:name (phcp:val "ID" (phcp:xd-get e))))
    (if (or (member pid ids) (assoc pid nodes))
      (setq probs (cons (list "ERROR" (strcat "the ID " pid " is used twice - give this one another ID") e) probs))
      (setq ids (cons pid ids))))

  ;; -- per-pipe checks
  (foreach e pipes
    (setq al (phcp:xd-get e)
          ia (phcp:find-node (vlax-curve-getStartPoint e) nodes tol)
          ib (phcp:find-node (vlax-curve-getEndPoint e) nodes tol))
    (if (= ia ib)
      (setq probs (cons (list "ERROR" (strcat "pipe " (phcp:val "ID" al) " starts and ends at the same node") e) probs)))
    (if (not (phcp:num "DN" al))
      (setq probs (cons (list "ERROR" (strcat "pipe " (phcp:val "ID" al) " has no nominal size") e) probs)))
    (if (and (= (phcp:val "LEN" al) nil)
             (< (* uf (vlax-curve-getDistAtParam e (vlax-curve-getEndParam e))) 0.001))
      (setq probs (cons (list "ERROR" (strcat "pipe " (phcp:val "ID" al) " has no length - give a length override") e) probs))))

  ;; -- nodes with no elevation take the default, and are reported
  (setq n 0)
  (setq nodes (mapcar '(lambda (nd) (if (caddr nd) nd (progn (setq n (1+ n)) (list (car nd) (cadr nd) zdef)))) nodes))
  (if (> n 0)
    (setq probs (cons (list "WARN" (strcat (itoa n) " node(s) had no elevation marker and were set to RL "
                                           (rtos zdef 2 3) " m") nil) probs)))
  (list nodes pipes heads sups (reverse probs)))

;;;============================================================================
;;; REPORTING PROBLEMS
;;;============================================================================

;; List the problems, and select the objects responsible so they can be seen.
;; Returns T if there is at least one ERROR.
(defun phcp:report (probs / ss nerr nwarn)
  (setq ss (ssadd) nerr 0 nwarn 0)
  (foreach p probs
    (if (= (car p) "ERROR") (setq nerr (1+ nerr)) (setq nwarn (1+ nwarn)))
    (princ (strcat "\n  " (car p) "  " (cadr p)))
    (if (caddr p) (ssadd (caddr p) ss)))
  (princ (strcat "\n\n" (itoa nerr) " error(s), " (itoa nwarn) " warning(s)."))
  (if (> (sslength ss) 0)
    (progn (sssetfirst nil ss)
           (princ "  The objects concerned are selected on screen.")))
  (> nerr 0))

;;;============================================================================
;;; WRITING THE MODEL
;;;
;;; The model is written in PHCP's command language (.phc): one command per
;;; line, fields by position, comments after //, everything in capitals.  The
;;; file reads top to bottom as
;;;
;;;   // where it came from
;;;   TITLE, PROJECT    the cover sheet, as entered with PHCPPROJECT
;;;   UNITS, METHOD     metres, millimetres, kPa, L/min; Hazen-Williams
;;;   WATER             the supply: its node, elevation, static pressure and
;;;                     any flow-test points
;;;   NODE              every other pipe junction, with its elevation
;;;   SPRINKLER etc.    every head: its node, elevation, minimum and K
;;;   USE, PIPE         every pipe, with a USE line wherever the pipe type or
;;;                     C factor changes; then the drops to heads
;;;
;;; A supply or head NAMES its node: the node a head sits on is called by the
;;; head's ID (S12), the supply's node by the supply's ID (SUP1), and only a
;;; plain junction is N1, N2 ...  So the calculation's results read against
;;; the drawing's own IDs.  A head given its own elevation sits on its own
;;; node, named by its ID; the drop to it is the pipe <ID>_D from the
;;; branch-line node.
;;;============================================================================

;; A command word padded to the column the fields start in.
(defun phcp:cmd (c / s)
  (setq s c)
  (while (< (strlen s) 10) (setq s (strcat s " ")))
  s)

;; Text for the model: capitals, and none of the characters the .phc reader
;; refuses ("!" "#") or reads as a comment ("//").
(defun phcp:clean (s / i)
  (setq s (strcase s))
  (while (setq i (vl-string-search "//" s)) (setq s (strcat (substr s 1 (1+ i)) (substr s (+ i 3)))))
  (vl-string-translate "!#" "  " s))

;; An ID as a .phc name: capitals, spaces as underscores.
(defun phcp:name (s) (vl-string-translate " " "_" (strcase s)))

;; Numbers from a space-separated string, e.g. a supply curve.
(defun phcp:numbers (s / out w i)
  (setq s (strcat (vl-string-trim " " s) " "))
  (while (setq i (vl-string-search " " s))
    (setq w (substr s 1 i) s (vl-string-left-trim " " (substr s (+ i 2))))
    (if (distof w 2) (setq out (append out (list (distof w 2))))))
  out)

;; A supply's static pressure and its flow-test points, as
;; (static (q1 p1 q2 p2 ...)).  A curve entered from zero flow carries its
;; static pressure as its first point.  nil if the static pressure is unknown.
(defun phcp:supply-curve (al / pts)
  (setq pts (if (= (phcp:val "TYPE" al) "CURVE") (phcp:numbers (phcp:val "CURVE" al)) nil))
  (cond ((and pts (= (car pts) 0.0)) (list (cadr pts) (cddr pts)))
        ((phcp:num "P" al) (list (phcp:num "P" al) pts))
        (t nil)))

;; A head's line: TYPE NAME ELEVATION MINFLOW K.  MINFLOW is the minimum flow,
;; or the minimum pressure as a negative number.  Of K, minimum pressure and
;; minimum flow any two are entered; K is worked out from the other two when
;; it is not given, and when all three are, the larger demand governs.
(defun phcp:head-line (al name z / k p q mf ty)
  (setq k (phcp:num "K" al) p (phcp:num "P" al) q (phcp:num "Q" al))
  (if (and (not k) p q (> p 0)) (setq k (/ q (sqrt p))))
  (setq mf (cond ((and q p k (> q (* k (sqrt p)))) (phcp:fmt q))
                 (p (strcat "-" (phcp:fmt p)))
                 (t (phcp:fmt q))))
  (setq ty (phcp:val "TYPE" al))
  (strcat (phcp:cmd (cond ((= ty "HYDRANT") "HYDRANT") ((= ty "HOSEREEL") "HREEL") (t "SPRINKLER")))
          name " " (phcp:fmt z) " " mf " " (phcp:fmt k)))

;; The name of each node, by index: the supply's ID, the ID of a head sitting
;; on it without a drop, or its own N1, N2 ...
(defun phcp:node-names (res tol / nodes names i al)
  (setq nodes (nth 0 res) names (mapcar 'car nodes))
  (foreach e (nth 3 res)
    (setq i (phcp:find-node (cdr (assoc 10 (entget e))) nodes tol))
    (if i (setq names (phcp:set-nth names i (phcp:name (phcp:val "ID" (phcp:xd-get e)))))))
  (foreach e (nth 2 res)
    (setq al (phcp:xd-get e) i (phcp:find-node (cdr (assoc 10 (entget e))) nodes tol))
    (if (and i (not (phcp:num "Z" al)))
      (setq names (phcp:set-nth names i (phcp:name (phcp:val "ID" al))))))
  names)

;; A list with its element at index i replaced.
(defun phcp:set-nth (lst i v / j out)
  (setq j 0)
  (foreach x lst (setq out (cons (if (= j i) v x) out) j (1+ j)))
  (reverse out))

;; A pipe's USE line: its type, and its C factor when one was given.
(defun phcp:use-line (ty c)
  (strcat (phcp:cmd "USE") ty (if (and c (/= c "")) (strcat " " c) "")))

;; Fittings as .phc fields: "2E,1T" becomes "2E 1T".
(defun phcp:fits (f)
  (if (and f (/= f "")) (strcat " " (vl-string-translate "," " " (strcase f))) ""))

(defun phcp:write (fname res uf tol / f nodes pipes heads sups names al nd ia ib za zb plan len
                    hz dn v sc use u n i supnodes headnodes)
  (setq nodes (nth 0 res) pipes (nth 1 res) heads (nth 2 res) sups (nth 3 res)
        names (phcp:node-names res tol))
  (setq f (open fname "w"))
  (write-line "// PHCP MODEL EXPORTED FROM AUTOCAD BY PHCP_EXPORT.LSP" f)
  (write-line (strcat "// DRAWING: " (phcp:clean (strcat (getvar "DWGPREFIX") (getvar "DWGNAME")))) f)
  (write-line (strcat "// EXPORTED: " (menucmd "M=$(edtime,$(getvar,date),YYYY-MO-DD HH:MM)")) f)
  (write-line "// NODE NAMES FOLLOW PIPE ORDER AND MAY CHANGE BETWEEN EXPORTS." f)
  (write-line "// PIPE AND HEAD IDS ARE STORED IN THE DRAWING AND STAY THE SAME." f)
  (write-line "" f)

  ;; The cover sheet: only the fields that have been filled in.
  (foreach p *phcp-project-fields*
    (if (and (setq v (phcp:proj-get (car p))) (/= v ""))
      (write-line (if (= (car p) "TITLE")
                    (strcat (phcp:cmd "TITLE") (phcp:clean v))
                    (strcat (phcp:cmd "PROJECT") (car p) " " (phcp:clean v)))
                  f)))
  (foreach u '("LENGTH M" "ELEVATION M" "SIZE MM" "PRESSURE KPA" "FLOW LPM" "KFACTOR LPM/KPA")
    (write-line (strcat (phcp:cmd "UNITS") u) f))
  (write-line (strcat (phcp:cmd "METHOD") "HW") f)
  (write-line "" f)

  ;; The supply, then every other node, then the heads.  A node that is a
  ;; supply's or a head's is written once, as that.
  (foreach e sups
    (setq al (phcp:xd-get e)
          i (phcp:find-node (cdr (assoc 10 (entget e))) nodes tol)
          sc (phcp:supply-curve al)
          supnodes (cons i supnodes))
    (write-line (strcat (phcp:cmd "WATER") (nth i names) " " (phcp:fmt (caddr (nth i nodes)))
                        " " (phcp:fmt (car sc))
                        (apply 'strcat (mapcar '(lambda (x) (strcat " " (phcp:fmt x))) (cadr sc))))
                f))
  (foreach e heads
    (setq al (phcp:xd-get e) i (phcp:find-node (cdr (assoc 10 (entget e))) nodes tol))
    (if (not (phcp:num "Z" al)) (setq headnodes (cons i headnodes))))
  (setq i 0)
  (foreach nd nodes
    (if (not (or (member i supnodes) (member i headnodes)))
      (write-line (strcat (phcp:cmd "NODE") (nth i names) " " (phcp:fmt (caddr nd))) f))
    (setq i (1+ i)))
  (foreach e heads
    (setq al (phcp:xd-get e) i (phcp:find-node (cdr (assoc 10 (entget e))) nodes tol))
    (write-line (phcp:head-line al (phcp:name (phcp:val "ID" al))
                                (if (phcp:num "Z" al) (phcp:num "Z" al) (caddr (nth i nodes))))
                f))
  (write-line "" f)

  ;; Pipes -- true length from the plan length and the change in elevation,
  ;; unless an override was given.  A USE line wherever the type or C changes.
  (foreach e pipes
    (setq al (phcp:xd-get e)
          ia (phcp:find-node (vlax-curve-getStartPoint e) nodes tol)
          ib (phcp:find-node (vlax-curve-getEndPoint e) nodes tol)
          za (caddr (nth ia nodes)) zb (caddr (nth ib nodes))
          plan (* uf (vlax-curve-getDistAtParam e (vlax-curve-getEndParam e)))
          len (if (phcp:num "LEN" al) (phcp:num "LEN" al) (sqrt (+ (* plan plan) (* (- zb za) (- zb za))))))
    (setq u (phcp:use-line (phcp:val "TYPE" al) (phcp:val "C" al)))
    (if (/= u use) (progn (write-line u f) (setq use u)))
    (write-line (strcat (phcp:cmd "PIPE") (phcp:name (phcp:val "ID" al)) " " (nth ia names) " " (nth ib names)
                        " " (phcp:fmt len) " " (phcp:val "DN" al) (phcp:fits (phcp:val "FIT" al)))
                f))
  ;; Drops: from the branch-line node to the head's own node.
  (foreach e heads
    (setq al (phcp:xd-get e))
    (if (setq hz (phcp:num "Z" al))
      (progn
        (setq i (phcp:find-node (cdr (assoc 10 (entget e))) nodes tol)
              nd (nth i nodes)
              dn (if (phcp:num "DROP_DN" al) (phcp:val "DROP_DN" al) "25"))
        (setq u (phcp:use-line (if (phcp:val "DROP_TYPE" al) (phcp:val "DROP_TYPE" al) "ASAM") nil))
        (if (/= u use) (progn (write-line u f) (setq use u)))
        (write-line (strcat (phcp:cmd "PIPE") (phcp:name (phcp:val "ID" al)) "_D " (nth i names) " "
                            (phcp:name (phcp:val "ID" al)) " " (phcp:fmt (max 0.001 (abs (- hz (caddr nd)))))
                            " " dn (phcp:fits (phcp:val "DROP_FIT" al)))
                    f))))
  (close f))

;; Node and pipe tags on layer PHCP-TAGS, so the calculation can be read
;; against the drawing.  Old tags are removed first; node names can change
;; between exports.
(defun phcp:tag (res / ss i h)
  (if (setq ss (ssget "_X" '((8 . "PHCP-TAGS"))))
    (progn (setq i 0) (repeat (sslength ss) (entdel (ssname ss i)) (setq i (1+ i)))))
  (setq h (* 0.4 (phcp:symbol-size)))
  (foreach n (nth 0 res)
    (entmake (list '(0 . "TEXT") '(8 . "PHCP-TAGS") (cons 10 (cadr n)) (cons 40 h) (cons 1 (car n)))))
  (foreach e (nth 1 res)
    (entmake (list '(0 . "TEXT") '(8 . "PHCP-TAGS")
                   (cons 10 (vlax-curve-getPointAtDist e (* 0.3 (vlax-curve-getDistAtParam e (vlax-curve-getEndParam e)))))
                   (cons 40 h) (cons 1 (phcp:val "ID" (phcp:xd-get e)))))))

;;;============================================================================
;;; COMMANDS -- CHECKING AND EXPORTING
;;;============================================================================

;; The tolerance and default elevation, asked once per session.
(defun phcp:settings ( / uf)
  (setq uf (phcp:unit-factor))
  (if (not *phcp-tol*) (setq *phcp-tol* (/ 0.005 uf)))          ; 5 mm
  (setq *phcp-tol* (phcp:get-real "\nTolerance for joining pipe ends, drawing units" *phcp-tol*))
  (if (not *phcp-zdef*) (setq *phcp-zdef* 0.0))
  (setq *phcp-zdef* (phcp:get-real "\nElevation for nodes with no marker, m" *phcp-zdef*))
  uf)

(defun c:PHCPCHECK ( / uf res)
  (setq uf (phcp:settings))
  (setq res (phcp:analyse *phcp-tol* *phcp-zdef* uf))
  (princ (strcat "\nPHCP check: " (itoa (length (nth 0 res))) " nodes, "
                 (itoa (length (nth 1 res))) " pipes, " (itoa (length (nth 2 res))) " heads, "
                 (itoa (length (nth 3 res))) " supply."))
  (if (nth 4 res) (phcp:report (nth 4 res)) (princ "\nNo problems found."))
  (princ))

(defun c:PHCPEXPORT ( / uf res fname kw)
  (phcp:ensure)
  (setq uf (phcp:settings))
  (setq res (phcp:analyse *phcp-tol* *phcp-zdef* uf))
  (if (and (nth 4 res) (phcp:report (nth 4 res)))
    (princ "\n*** Not exported: fix the errors above, then run PHCPEXPORT again.")
    (progn
      (setq fname (getfiled "Save PHCP model"
                            (strcat (getvar "DWGPREFIX") (vl-filename-base (getvar "DWGNAME")) ".phc")
                            "phc" 1))
      (if fname
        (progn
          (phcp:write fname res uf *phcp-tol*)
          (initget "Yes No")
          (setq kw (getkword "\nTag nodes and pipe IDs on layer PHCP-TAGS? [Yes/No] <Yes>: "))
          (if (/= kw "No") (phcp:tag res))
          (princ (strcat "\nExported " (itoa (length (nth 1 res))) " pipes, "
                         (itoa (length (nth 2 res))) " heads to " fname))
          (princ "\nOpen it in PHCP to solve and report.")))))
  (princ))

;;;============================================================================
;;; SOLVING FROM AUTOCAD
;;;
;;; PHCPSOLVE exports the drawing to a .phc beside it, runs
;;;   phcp.exe --json model.phc
;;; and shows the result.  phcp.exe prints its results as JSON, one value to a
;;; line, and always includes a "summary": a few lines in capitals saying
;;; whether it converged, which outlet governs and with what margin, which
;;; outlets fail, and whether the supply meets the demand.  Those lines are
;;; all this command needs, so it reads them line by line and needs no JSON
;;; reader.  The full report is the PHCP editor's or phcp.exe's job.
;;;
;;; Where phcp.exe is, is asked for once and remembered (setenv PHCP_EXE).
;;;============================================================================

;; The path of phcp.exe: remembered, or asked for.
(defun phcp:exe ( / p)
  (setq p (getenv "PHCP_EXE"))
  (if (not (and p (findfile p)))
    (progn
      (setq p (getfiled "Where is phcp.exe?" "phcp.exe" "exe" 0))
      (if p (setenv "PHCP_EXE" p))))
  p)

;; The "summary" lines of phcp.exe's JSON output, read from a file.
(defun phcp:summary (fname / f l in out)
  (if (setq f (open fname "r"))
    (progn
      (while (setq l (read-line f))
        (setq l (vl-string-trim " \t" l))
        ;; In a wcmatch pattern [ is special, so it is escaped with a backquote.
        (cond ((wcmatch l "\"summary\"*`[") (setq in T))
              ((and in (= (substr l 1 1) "]")) (setq in nil))
              (in (setq out (append out (list (vl-string-trim "\"" (vl-string-right-trim "," l))))))))
      (close f)))
  out)

(defun c:PHCPSOLVE ( / exe uf res phc out ws code lines)
  (phcp:ensure)
  (if (not (setq exe (phcp:exe)))
    (progn (princ "\n*** phcp.exe was not found; nothing solved.") (exit)))
  (setq uf (phcp:settings))
  (setq res (phcp:analyse *phcp-tol* *phcp-zdef* uf))
  (if (and (nth 4 res) (phcp:report (nth 4 res)))
    (princ "\n*** Not solved: fix the errors above, then run PHCPSOLVE again.")
    (progn
      (setq phc (strcat (getvar "DWGPREFIX") (vl-filename-base (getvar "DWGNAME")) ".phc")
            out (vl-filename-mktemp "phcp" nil ".json"))
      (phcp:write phc res uf *phcp-tol*)
      ;; Run hidden (window style 0) and wait for it to finish (true).
      (setq ws (vlax-create-object "WScript.Shell"))
      (setq code (vlax-invoke ws 'Run
                   (strcat "cmd /c \"\"" exe "\" --json \"" phc "\" > \"" out "\"\"") 0 :vlax-true))
      (vlax-release-object ws)
      (setq lines (phcp:summary out))
      (vl-file-delete out)
      (if (null lines)
        (princ (strcat "\n*** phcp.exe gave no result (exit " (itoa code) ")."))
        (progn
          (princ (strcat "\nPHCP: " phc))
          (foreach l lines (princ (strcat "\n  " l)))
          (alert (apply 'strcat (mapcar '(lambda (l) (strcat l "\n")) lines)))))))
  (princ))

(princ "\nPHCP export loaded.  Commands: PHCPSETUP PHCPPROJECT PHCPSUPPLY PHCPPIPE PHCPELEV PHCPHEAD PHCPCHECK PHCPEXPORT PHCPSOLVE PHCPINFO")
(princ)

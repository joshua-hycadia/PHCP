# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Dialogs for the ribbon.  Revit is Windows, so these are ordinary Windows
# forms rather than a pyRevit helper, which is not the same in every
# pyRevit release.  Nothing here imports the Revit API, so the module loads
# in the tests; the forms themselves only exist when a button is pressed.

def _forms():
    import clr
    clr.AddReference("System.Windows.Forms")
    clr.AddReference("System.Drawing")
    import System.Windows.Forms as forms
    import System.Drawing as drawing
    return forms, drawing


def tell(message, title="PHCP", echo=True):
    """A message the designer has to see.  Printed as well, so a long list
    is in the pyRevit output and not only in a box that cannot be copied.
    """
    text = str(message or "")
    if echo:
        print(text)
    try:
        forms, _drawing = _forms()
        forms.MessageBox.Show(text, title)
    except Exception:
        pass


def ask_choice(title, prompt, choices):
    """One of `choices`, or None if the designer cancels."""
    forms, drawing = _forms()
    form = forms.Form()
    form.Text = title
    form.FormBorderStyle = forms.FormBorderStyle.FixedDialog
    form.StartPosition = forms.FormStartPosition.CenterScreen
    form.MinimizeBox = False
    form.MaximizeBox = False
    form.ClientSize = drawing.Size(420, 80 + 28 * len(choices))
    label = forms.Label()
    label.Text = prompt
    label.Location = drawing.Point(12, 12)
    label.Size = drawing.Size(396, 32)
    form.Controls.Add(label)
    picked = {"value": None}

    def choose(text):
        def handler(_s, _e):
            picked["value"] = text
            form.Close()
        return handler

    for i, text in enumerate(choices):
        button = forms.Button()
        button.Text = text
        button.Location = drawing.Point(12, 48 + 28 * i)
        button.Size = drawing.Size(396, 26)
        button.Click += choose(text)
        form.Controls.Add(button)
    form.ShowDialog()
    return picked["value"]


def ask_form(title, rows):
    """rows are (key, label, default, multiline).  A dict, or None if cancelled.

    A blank answer is returned as "".  The caller decides whether blank means
    "leave this alone" or "clear it".
    """
    forms, drawing = _forms()
    form = forms.Form()
    form.Text = title
    form.FormBorderStyle = forms.FormBorderStyle.FixedDialog
    form.StartPosition = forms.FormStartPosition.CenterScreen
    form.MinimizeBox = False
    form.MaximizeBox = False
    y = 12
    boxes = []
    for key, label, default, multiline in rows:
        lab = forms.Label()
        lab.Text = label
        # A long label is two lines.  One line clips the figures a device needs.
        tall = len(label) > 78
        lab.Location = drawing.Point(12, y)
        lab.Size = drawing.Size(460, 32 if tall else 16)
        form.Controls.Add(lab)
        y += 34 if tall else 18
        box = forms.TextBox()
        box.Location = drawing.Point(12, y)
        box.Size = drawing.Size(460, 90 if multiline else 22)
        if multiline:
            box.Multiline = True
            box.ScrollBars = forms.ScrollBars.Vertical
        box.Text = "" if default is None else str(default)
        form.Controls.Add(box)
        boxes.append((key, box))
        y += (96 if multiline else 28)
    ok = forms.Button()
    ok.Text = "OK"
    ok.DialogResult = forms.DialogResult.OK
    ok.Location = drawing.Point(292, y)
    ok.Size = drawing.Size(84, 26)
    cancel = forms.Button()
    cancel.Text = "CANCEL"
    cancel.DialogResult = forms.DialogResult.Cancel
    cancel.Location = drawing.Point(384, y)
    cancel.Size = drawing.Size(88, 26)
    form.Controls.Add(ok)
    form.Controls.Add(cancel)
    form.AcceptButton = ok
    form.CancelButton = cancel
    form.ClientSize = drawing.Size(484, y + 40)
    if form.ShowDialog() != forms.DialogResult.OK:
        return None
    return {key: box.Text.strip() for key, box in boxes}


def save_phc(default_name):
    """A path ending in .phc, or None."""
    forms, _drawing = _forms()
    dlg = forms.SaveFileDialog()
    dlg.Filter = "PHCP model (*.phc)|*.phc"
    dlg.DefaultExt = "phc"
    dlg.AddExtension = True
    dlg.FileName = default_name if str(default_name).lower().endswith(".phc") else (str(default_name) + ".phc")
    dlg.Title = "Export PHCP model"
    if dlg.ShowDialog() != forms.DialogResult.OK:
        return None
    path = dlg.FileName
    if not path.lower().endswith(".phc"):
        path += ".phc"
    return path


def open_exe():
    """The engine the designer pointed at, or None."""
    forms, _drawing = _forms()
    dlg = forms.OpenFileDialog()
    dlg.Filter = "PHCP (phcp.exe)|phcp.exe|Programs (*.exe)|*.exe"
    dlg.Title = "Where is phcp.exe?"
    if dlg.ShowDialog() != forms.DialogResult.OK:
        return None
    return dlg.FileName

# Explicit save (Cmd+S) instead of autosave

Files in the Vault change only when the user presses Cmd+S, deliberately deviating from macOS autosave. The Vault is shared with git, other editors and the Agent, so the user wants every on-disk change to be intentional. Consequences: tabs show an unsaved-changes marker, closing or quitting with unsaved changes asks "Save changes?", and an external change to a file with unsaved edits shows a "Reload / Keep mine" bar.

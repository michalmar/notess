# Markdown files in the Vault are the source of truth; the Agent owns `_brain/`

All notes are plain `.md` files in a user-chosen Vault so they stay readable and editable without the app. Any database (search index, later embeddings) is a disposable cache rebuilt from files. The Agent writes only inside `_brain/` and never modifies the user's Daily Entries or Free Notes; the app shows `_brain/` read-only. This keeps user writing and machine output strictly separated.

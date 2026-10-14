# Distributed outside the App Store, without App Sandbox

The app is for personal use, signed with Developer ID and shipped without App Sandbox. It must launch the Copilot CLI as a child process and read and write a user-chosen Vault that git and other tools also use; sandboxing would require security-scoped bookmarks and would block or complicate spawning the CLI. App Store distribution is therefore ruled out.

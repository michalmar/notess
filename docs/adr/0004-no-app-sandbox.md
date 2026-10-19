# Distributed outside the App Store, without App Sandbox

The app is for personal use and shipped outside the App Store without App Sandbox. It must launch the Copilot CLI as a child process and read and write a user-chosen Vault that git and other tools also use; sandboxing would require security-scoped bookmarks and would block or complicate spawning the CLI. App Store distribution is therefore ruled out.

Developer ID signing remains the intended distribution path, but automated main previews use ad-hoc signing so they do not require paid Apple Developer credentials. These previews are not notarized and may require explicit first-launch approval in macOS; the build script still supports Developer ID signing.

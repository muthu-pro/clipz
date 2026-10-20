fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac build

```sh
[bundle exec] fastlane mac build
```

Clean Release build → signed App Store .pkg in ../build/fastlane

### mac upload

```sh
[bundle exec] fastlane mac upload
```

Upload the latest .pkg to App Store Connect (binary only, no metadata)

### mac release

```sh
[bundle exec] fastlane mac release
```

Clean build + upload the binary to App Store Connect for review

### mac beta

```sh
[bundle exec] fastlane mac beta
```

Clean build + upload to TestFlight

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).

# Release packaging

One tagged source revision produces one CurseForge package that supports WoW
Forever and WoW Retail. The package holds both production manifests, and each
client loads only its own:

| Client | Manifest | Packager game type |
| --- | --- | --- |
| WoW Forever | `AsgardsGuildFellowship_Camelot.toc` | `forever` |
| WoW Retail | `AsgardsGuildFellowship_Mainline.toc` | `retail` |

The [BigWigs packager](https://github.com/BigWigsMods/packager) reads these
suffixes to tag the release with each client's game versions, so CurseForge
offers the file to both clients. Keep the suffixes to ones the packager
recognizes. An unrecognized suffix, such as `_Standard`, silently drops that
client from the release tags. Forever also accepts `_Mainline`, but it always
prefers its own `_Camelot` manifest, so both manifests must ship together.

## What the package contains

The package is one folder, `AsgardsGuildFellowship/`, holding:

- the two production manifests and every runtime module they load (`Core/`,
  `Adapters/`, `AsgardsGuildFellowship.lua`);
- the pinned libraries under `Libs/`, which the packager fetches itself from
  the `.pkgmeta` externals (see [Libraries](#libraries));
- `README.md`, `LICENSE`, and a `CHANGELOG.md`.

`.pkgmeta` leaves out the development manifests, `tests/`, `tools/`, `docs/`,
`ai/`, and `.github/`. The packager also leaves out every file git doesn't
track, so a fetched development `Libs/` folder is never packaged.

### Libraries

The libraries are not committed. [`tools/libraries.txt`](../tools/libraries.txt)
pins each one, and `.pkgmeta` lists the same pins as externals. CI runs
`lua5.1 tools/check-libraries.lua`, which fails when the two differ, so change
a pin in both files together.

- LibStub, CallbackHandler-1.0, LibDBIcon-1.0, and LibSharedMedia-3.0 come
  from CurseForge's svn repositories, pinned by their tag folder URL. The
  packager fetches these with **svn**, so building needs an svn client.
- LibDataBroker-1.1 and the Details! Framework come from GitHub, pinned by
  git tag.

Each library keeps its own license file inside its folder (for example,
LibSharedMedia-3.0 is LGPL). The add-on's own code is MIT, in `LICENSE`.

## Build and inspect locally

```sh
tools/build-package.sh            # writes .release/AsgardsGuildFellowship-<version>.zip
unzip -l .release/AsgardsGuildFellowship-*.zip
```

The script needs:

- **bash 4.3 or newer** for the packager. macOS ships bash 3.2, so install a
  newer one (`brew install bash`) and point the script at it:

  ```sh
  PACKAGER_BASH=/opt/homebrew/bin/bash tools/build-package.sh
  ```

- **an svn client** for the CurseForge library externals
  (macOS: `brew install subversion`; Debian/Ubuntu:
  `sudo apt-get install subversion`). Without one, the script stops before
  building and says so.

It downloads the packager at a pinned commit (`PACKAGER_COMMIT` in
`tools/packager.env`) through `tools/fetch-packager.sh`, which refuses to run
a download whose SHA-256 isn't `PACKAGER_SHA256` from the same file. Builds
and releases share both pins; to update the packager, change them together
(`shasum -a 256 release.sh` gives the new digest). It runs the packager with
`-d`, so nothing is ever uploaded. It builds from a fresh
clone of the committed history, so uncommitted changes are not packaged; it
prints a note when you have some.

The script fails unless the packager tags the build for both clients
(`Build type: multi-version`). It then runs
`tools/check-package.sh <package.zip> <packager.log>`, which fails when:

- a production manifest is missing, or a file it loads (the library files
  included) is not in the zip;
- a pinned library's folder is missing, or the packager's log doesn't show it
  fetched at exactly its pinned tag and URL;
- the production manifests disagree on `## Version`, or still contain an
  unreplaced `@project-version@` (and, during a release, when the version is
  not exactly the release tag or a manifest's `## Interface` isn't the
  release's game versions);
- a development manifest, test, tool, doc, `ai/`, CI file, `.pkgmeta`, or a
  leftover from `tools/Fetch-Libraries.ps1` was packaged;
- any manifest other than the two production manifests was packaged, or a
  file sits outside the `AsgardsGuildFellowship/` folder;
- `README.md` or `LICENSE` is missing.

On macOS the packager's changelog step may print a harmless `sed` warning. CI
builds on Linux, where it does not appear.

### The Release package CI job

CI runs the same script on every pull request and every push to `main`, in the
**Release package** job of `.github/workflows/test.yml`. It installs svn, runs
the release tools' own tests (every `tests/tools/*.test.sh`), builds and
validates the package without uploading, and keeps the zip as a downloadable
workflow artifact (**AsgardsGuildFellowship-package**) for 30 days.

## Game versions

Releases take each client's game versions from two GitHub repository
variables, not from the committed manifests:

| Variable | Client | Current value |
| --- | --- | --- |
| `FOREVER_INTERFACE` | WoW Forever | `16000, 16001` |
| `RETAIL_INTERFACE` | WoW Retail | `120100` |

Each is a comma-separated list. Just before packaging, the Release workflow
writes them into the production manifests (`tools/apply-interfaces.sh`). A
missing variable, an empty entry, or a value that isn't a 5 or 6 digit number
stops the release before anything is built.

During a patch rollout, list the current and the previous interface (for
example `120100, 120200`), so players on either build see the add-on as up to
date. Once the rollout is over, drop the older one. Never keep anything older
than the previous patch.

The committed manifests are used only by the development install and the
tests. To update them after a game patch, run the dev interface setter:

```sh
tools/set-interface.sh retail 120200
tools/set-interface.sh forever 16001 16002
```

It updates that client's production and development manifests and the test
expectation in `tests/spec/bootstrap_spec.lua`, and reminds you that releases
use the repository variable instead. It validates every number before writing
anything.

Read a client's interface in game with `/dump (select(4, GetBuildInfo()))`.

## Versions

The add-on's version comes from the release tag. The production manifests
declare `## Version: @project-version@`, which the packager replaces with the
tag (for example `v0.2.0`) when it builds a release. That is the version shown
in the game's AddOns list and on CurseForge. The development manifests declare
`dev`. Builds that are not releases, such as those on pull requests, are
versioned by the packager from the commit instead.

## Before a release

1. Confirm each client's interface number in the running client
   (`/dump (select(4, GetBuildInfo()))`). If it changed, update the
   `FOREVER_INTERFACE` or `RETAIL_INTERFACE` variable, and run
   `tools/set-interface.sh` so the committed manifests and tests match.
2. Pass each client's in-game checklist on the current live build of that
   client. The checklists are GitHub issues:
   - [#7, In-game verification checklist: foundation](https://github.com/FinalAsgard/asgards-guild-fellowship/issues/7)
   - [#17, In-game verification checklist: Fellowship roster](https://github.com/FinalAsgard/asgards-guild-fellowship/issues/17)

   A release claims support for a client only after that client's checklists
   pass. A pass on one client never counts for the other.
3. Build and inspect the package as above, or download the **Release package**
   artifact from the latest CI run on `main`.

## Publishing to CurseForge

Publishing a GitHub release publishes the add-on. The **Release** workflow
(`.github/workflows/release.yml`) runs when a release is published and:

1. checks that the release's tag is a valid version and that the production
   manifests take their version from it (`tools/check-release-tag.sh`), and
   that **Set as a pre-release** matches the tag (checked for `alpha` or `beta`
   tags, unchecked otherwise);
2. runs the Lua syntax check and the full test suite;
3. writes the game versions from the repository variables into the production
   manifests (`tools/apply-interfaces.sh`);
4. writes the release notes to `CHANGELOG.md`, so they become the changelog on
   CurseForge and inside the package (with no notes, a changelog is generated
   from git history instead);
5. builds and validates the package without uploading
   (`tools/build-package.sh` with `PACKAGE_WORKING_TREE=1`, which packages the
   release checkout in place so the game versions and changelog written above
   are included);
6. builds it again with the same pinned packager and uploads it to CurseForge,
   tagged for both Forever and Retail (`tools/publish-release.sh`), then checks
   the uploaded zip the same way;
7. attaches the zip to the GitHub release.

Any failed step stops the release before anything is uploaded, except the
upload step itself. The packager never gets a GitHub token, so it can't edit
the GitHub release: the title and notes stay exactly as written.

### One-time setup

1. Create the add-on project on CurseForge (World of Warcraft, AddOns) and note
   its **Project ID** from the project's About panel.
2. In the GitHub repository, open **Settings → Secrets and variables →
   Actions**:
   - under **Variables**, add `CURSEFORGE_PROJECT_ID` with the numeric project
     ID, and `FOREVER_INTERFACE` and `RETAIL_INTERFACE` with the game versions
     (see [Game versions](#game-versions));
   - under **Secrets**, add `CF_API_KEY` with a token from
     <https://legacy.curseforge.com/account/api-tokens>.
3. Leave CurseForge's own **automatic packaging** off, and don't add its
   webhook to GitHub. This workflow already uploads every release, so both
   together would upload each version twice.

Without the game version variables, the release stops before building.
Without `CURSEFORGE_PROJECT_ID` or `CF_API_KEY`, the upload step stops with a
message naming what is missing, and nothing is uploaded. Issue
[#32](https://github.com/FinalAsgard/asgards-guild-fellowship/issues/32) tracks
this setup.

### Cutting a release

1. Do the checks in [Before a release](#before-a-release).
2. On GitHub, open **Releases → Draft a new release**:
   - **Choose a tag**: type the new tag, for example `v0.2.0`, and create it on
     `main`. This tag is the version: the packager writes it into the
     production manifests' `## Version`, so nothing needs editing beforehand.
     Tags look like `v1.2.3`, or `v1.2.3-beta1` for a pre-release.
   - **Release title** and **notes**: whatever players should read. The notes
     become the CurseForge changelog.
   - **Set as a pre-release**: check it for `alpha` or `beta` tags (for example
     `v0.2.0-beta1`), which CurseForge lists as alpha or beta files; leave it
     unchecked for a full release. A mismatch stops the release with a message
     saying which setting the tag needs.
   - Click **Publish release**. Saving a draft does not start a release.
3. Watch the **Release** run in the repository's **Actions** tab. The zip is
   attached to the release when it finishes. CurseForge may take a few minutes
   to review and list a new file.

Pushing a tag without publishing a release does nothing. Editing a published
release's notes later changes only the GitHub page, not CurseForge.

### Recovering from a failed run

If the run fails before the **Upload to CurseForge** step, nothing was
uploaded:

1. Read the failed step's log for the cause, and fix it (on `main`, through a
   pull request, if it needs a code change; in the repository settings if a
   variable or secret is wrong).
2. Delete the GitHub release, then delete its tag (**Releases** → the release
   → **Delete**, then **Tags** → the tag → **Delete**, or
   `git push origin :refs/tags/v0.2.0`).
3. Publish the release again with the same tag, as in
   [Cutting a release](#cutting-a-release).

If the upload step itself or a later step failed, check the CurseForge
project's **Files** page first. If the file is there, don't publish the same
version again or re-run the job, since either would upload it twice. Instead,
download the file from CurseForge and attach it to the GitHub release by hand,
or fix the cause and cut the next version.

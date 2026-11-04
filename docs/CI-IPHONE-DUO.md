# iPhone Duo GitHub Actions build

The `Build unsigned iPhone Duo IPA` workflow builds the Duo patch without signing
credentials. It pins application source to `f7e27d14fd08ab289511df8bf79649785086d361`
and Xcode 27.1. Update the source pin and cache prefix together when changing the
source or toolchain; it does not automatically build the latest branch tip.

## Operation

Enable GitHub Actions in your fork. A push changing
`.github/workflows/build-duo-ipa.yml` runs the build. Manual dispatch is also
available once GitHub has registered the workflow on the default branch.

The SDK job extracts the runner's Xcode 27.1 SDKs, verifies the iOS SDK version,
and encrypts the transfer to the ARM64 Linux job using a fresh per-run RSA key
and AES key. The private key stays in the runtime runner's temporary directory.
The author's compatibility directory names still say 26.5; the actual SDK is 27.1.
Use this workflow only where your SDK and runner usage is authorized.

The runtime job uses the author's Docker build, selects the bundled ARM64
premake5, supplies a CI usbmux placeholder for setup, and builds through notices.
It preserves `.work`, staged libraries, runtime data and generated WinIOS state
with `actions/cache`, including after failures. Cache keys include the source /
SDK generation plus the run and attempt, with a generation-specific fallback.
GitHub caches can expire or be evicted; the staged-resource artifact is retained
for two days, and failure diagnostics for seven days. Neither is a permanent backup.

The macOS job restores those staged resources, generates the author's Xcode
project, and packages S1Probe.app with PlayportJIT.appex using
`CODE_SIGNING_ALLOWED=NO`. Xcode Release configuration here still produces the
**development app variant**, not the upstream public-release variant.

Download `Playport-Duo-unsigned` from the run's artifacts. Recipients must sign
with their own account, preserve Increased Memory Limit and the JIT extension,
and follow `docs/DEVICE.md` for Developer Mode, LocalDevVPN and pairing.

Do not treat an Actions artifact as a distribution-complete release. Before
sharing an IPA publicly, provide its matching Corresponding Source, licenses,
build instructions and checksum as described in `docs/DISTRIBUTION.md`.
This workflow does not publish releases, carry personal certificates or install
anything on a phone.

## Evidence

The repository-specific predecessor completed here:
https://github.com/KevZhi/playport/actions/runs/41866894102

It took 2h 27m 34s (runtime approximately 2h 21m, macOS IPA packaging 5m 47s).
KevZhi reports successful operation on an iPhone Duo running iOS 27.3 after
personal development signing. No comprehensive game or performance test is claimed.
The workflow in this PR replaces the predecessor's hard-coded repository with
`github.repository`; that generalized revision has not been rebuilt end-to-end.

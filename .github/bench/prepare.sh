#!/usr/bin/env bash
# Not timed. Clone upstream apple-browsers at the pinned commit (sparse), patch for unsigned builds, resolve SPM.
set -eo pipefail
rm -rf "${DDG_SRC:?}"
git clone --filter=blob:none --no-checkout "$BENCH_REPO_URL" "$DDG_SRC"
cd "$DDG_SRC"
git sparse-checkout set iOS SharedPackages scripts SnapshotReferences
git checkout --force "$BENCH_COMMIT"
git submodule update --init --depth 1
echo "Source: $BENCH_REF_NAME ($(git rev-parse HEAD))"
echo "Required Xcode (repo): $(cat .xcode-version 2>/dev/null || echo n/a)"
defaults write com.apple.dt.Xcode ShowBuildOperationDuration YES

# GRDB embed phase calls codesign --sign "${EXPANDED_CODE_SIGN_IDENTITY}", empty when unsigned: fall back to ad-hoc.
PBX="$IOS_DIR/$XCODE_PROJECT/project.pbxproj"
sed -i '' 's/--sign \\"${EXPANDED_CODE_SIGN_IDENTITY}\\"/--sign \\"${EXPANDED_CODE_SIGN_IDENTITY:--}\\"/' "$PBX"
grep -c 'EXPANDED_CODE_SIGN_IDENTITY:--' "$PBX" | xargs -I{} echo "Patched {} codesign call(s)"

# Remove the private DuckSans font package (SSH-only, optional in code)
python3 "$(cd "$(dirname "$0")" && pwd)/strip_ducksans.py" "$PBX" \
  "$IOS_DIR/$XCODE_PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

cd "$IOS_DIR"
xcodebuild -resolvePackageDependencies -project "$XCODE_PROJECT" -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages" \
  -skipPackagePluginValidation -skipMacroValidation

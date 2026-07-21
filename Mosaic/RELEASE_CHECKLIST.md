# newMosaic Release Checklist

## ローカルMVPリリース

1. `swift test`
2. `swift build -c release`
3. `bash scripts/ci/agent_governance_guard.sh`
4. `bash scripts/ci/local_quality_gate.sh`
5. `bash scripts/package_macos_app.sh`
6. `open dist/newMosaic.app` で起動確認

## GitHub リリース

- `CHANGELOG.md` を更新する。
- 日本語本文のリリースコミットを作成する。
- `v<MARKETING_VERSION>` タグを付与する。
- `git push origin main --tags` を実行する。
- `git show --no-patch --decorate --oneline v<MARKETING_VERSION>` と `git ls-remote --tags origin v<MARKETING_VERSION>` の一致を確認する。
